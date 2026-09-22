"""Lower Qwen3.5 grouped-query and gated-delta decoder blocks."""
from builder import GraphBuilder
from schema import Opcode


class TextLowering:
    def __init__(self, builder: GraphBuilder):
        self.b = builder

    def attention(self, x: int, prefix: str, stage: str, inputs: dict[str, int], nt: int) -> int:
        b, reg = self.b, self.b.registry
        attention = prefix + ".self_attn"
        q_gate = b.linear(x, attention + ".q_proj", stage + ".q_gate")
        q = reg.view(stage + ".q", q_gate, (nt, 8, 256), strides=(4096 * 4, 512 * 4, 4))
        gate = reg.view(stage + ".gate", q_gate, (nt, 8, 256), offset=256 * 4, strides=(4096 * 4, 512 * 4, 4))
        k = b.linear(x, attention + ".k_proj", stage + ".k_proj")
        v = b.linear(x, attention + ".v_proj", stage + ".v_proj")
        k, v = reg.view(stage + ".k", k, (nt, 2, 256)), reg.view(stage + ".v", v, (nt, 2, 256))
        q = b.norm(q, attention + ".q_norm", stage + ".q_norm", True, True)
        k = b.norm(k, attention + ".k_norm", stage + ".k_norm", True, True)
        q = b.operation(Opcode.ROPE, stage + ".q_rope", (q, inputs["text_cos"], inputs["text_sin"]), parameters=(64,))
        k = b.operation(Opcode.ROPE, stage + ".k_rope", (k, inputs["text_cos"], inputs["text_sin"]), parameters=(64,))
        mixed = b.operation(Opcode.ATTENTION, stage + ".attention", (q, k, v, inputs["key_mask"]),
                            (nt, 8, 256), (nt, nt, 256, 8, 2), flags=3)
        gate = b.operation(Opcode.SIGMOID, stage + ".gate_sigmoid", (gate,))
        mixed = b.operation(Opcode.MULTIPLY, stage + ".gated", (mixed, gate))
        mixed = reg.view(stage + ".merged", mixed, (nt, 2048))
        return b.linear(mixed, attention + ".o_proj", stage + ".out_proj")

    def recurrence(self, x: int, prefix: str, stage: str, inputs: dict[str, int], nt: int) -> int:
        b, reg = self.b, self.b.registry
        attention = prefix + ".linear_attn"
        masked_input = b.operation(Opcode.MULTIPLY, stage + ".padding_mask", (x, inputs["key_mask"]), flags=2)
        qkv = b.linear(masked_input, attention + ".in_proj_qkv", stage + ".qkv")
        z = b.linear(masked_input, attention + ".in_proj_z", stage + ".z")
        beta = b.linear(masked_input, attention + ".in_proj_b", stage + ".b")
        a = b.linear(masked_input, attention + ".in_proj_a", stage + ".a")
        convolved = b.operation(Opcode.CAUSAL_CONV, stage + ".conv", (
            qkv, b.weight(attention + ".conv1d.weight"), b.weight(attention + ".conv1d.weight.scale")),
            parameters=(nt, 6144, 4))
        convolved = b.operation(Opcode.SILU, stage + ".conv_silu", (convolved,))
        q, k, v = [reg.view(stage + "." + name, convolved, (nt, 16, 128), offset=part * 2048 * 4,
                            strides=(6144 * 4, 128 * 4, 4)) for part, name in enumerate(("q", "k", "v"))]
        beta = b.operation(Opcode.SIGMOID, stage + ".beta", (beta,))
        dt = b.operation(Opcode.ADD, stage + ".dt", (a, b.weight(attention + ".dt_bias")), flags=1)
        dt = b.operation(Opcode.SOFTPLUS, stage + ".softplus", (dt,))
        decay_scale = b.operation(Opcode.EXP, stage + ".decay_scale", (b.weight(attention + ".A_log"),))
        g = b.operation(Opcode.MULTIPLY, stage + ".decay_product", (dt, decay_scale), flags=1)
        g = b.operation(Opcode.NEGATE, stage + ".log_decay", (g,))
        mixed = reg.add(stage + ".delta_output", (nt, 16, 128))
        final_state = reg.add(stage + ".delta_state", (16, 128, 128))
        b.emit(Opcode.GATED_DELTA, stage + ".gated_delta", (q, k, v, g, beta), (mixed, final_state),
               (nt, 16, 128, 128), flags=3)
        mixed = b.norm(mixed, attention + ".norm", stage + ".gated_norm", True, False)
        z = reg.view(stage + ".z_heads", z, (nt, 16, 128))
        z = b.operation(Opcode.SILU, stage + ".z_silu", (z,))
        mixed = b.operation(Opcode.MULTIPLY, stage + ".norm_gate", (mixed, z))
        mixed = reg.view(stage + ".merged", mixed, (nt, 2048))
        return b.linear(mixed, attention + ".out_proj", stage + ".out_proj")

    def lower(self, image: int, inputs: dict[str, int], nt: int, layer_types: list[str]) -> tuple[int, int]:
        b = self.b
        embedded = b.operation(Opcode.EMBEDDING, "text.embedding", (
            inputs["input_ids"], b.weight("model.language_model.embed_tokens.weight"),
            b.weight("model.language_model.embed_tokens.weight.scale")), (nt, 1024), (248320, 1024))
        x = b.operation(Opcode.SCATTER_IMAGE, "text.image_insert", (embedded, image, inputs["image_slots"]), (nt, 1024))
        for layer, kind in enumerate(layer_types):
            prefix, stage = f"model.language_model.layers.{layer}", f"text.{layer}"
            residual = x
            normed = b.norm(x, prefix + ".input_layernorm", stage + ".input_norm", True, True)
            if kind == "full_attention":
                mixed = self.attention(normed, prefix, stage, inputs, nt)
            else:
                mixed = self.recurrence(normed, prefix, stage, inputs, nt)
            x = b.operation(Opcode.ADD, stage + ".attention_residual", (residual, mixed))
            residual = x
            normed = b.norm(x, prefix + ".post_attention_layernorm", stage + ".post_norm", True, True)
            gate = b.linear(normed, prefix + ".mlp.gate_proj", stage + ".mlp_gate")
            up = b.linear(normed, prefix + ".mlp.up_proj", stage + ".mlp_up")
            gate = b.operation(Opcode.SILU, stage + ".mlp_silu", (gate,))
            hidden = b.operation(Opcode.MULTIPLY, stage + ".mlp_product", (gate, up))
            down = b.linear(hidden, prefix + ".mlp.down_proj", stage + ".mlp_down")
            x = b.operation(Opcode.ADD, stage + ".mlp_residual", (residual, down))
        x = b.norm(x, "model.language_model.norm", "text.final_norm", True, True)
        pooled = b.operation(Opcode.GATHER_LAST, "classifier.pool", (x, inputs["last_token"]), (1, 1024))
        logits = b.linear(pooled, "score", "classifier.logits")
        probabilities = b.operation(Opcode.SOFTMAX, "classifier.probabilities", (logits,))
        return logits, probabilities
