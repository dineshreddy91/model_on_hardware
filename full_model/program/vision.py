"""Vision transformer lowering, including exact-GELU merger semantics."""
from builder import GraphBuilder
from schema import InputProfile, Opcode


class VisionLowering:
    def __init__(self, builder: GraphBuilder):
        self.b = builder

    def lower(self, inputs: dict[str, int], profile: InputProfile) -> int:
        b, reg = self.b, self.b.registry
        nv, ni = profile.patch_tokens, profile.image_tokens
        x = b.linear(inputs["pixels"], "model.visual.patch_embed.proj", "vision.patch")
        position = b.operation(Opcode.INTERPOLATE, "vision.position", (
            b.weight("model.visual.pos_embed.weight"), b.weight("model.visual.pos_embed.weight.scale"),
            inputs["interpolation_indices"], inputs["interpolation_weights"]), (nv, 768), (48, 48, nv, 768))
        x = b.operation(Opcode.ADD, "vision.position_add", (x, position))
        for layer in range(12):
            prefix, stage = f"model.visual.blocks.{layer}", f"vision.{layer}"
            residual = x
            normed = b.norm(x, prefix + ".norm1", stage + ".norm1")
            qkv = b.linear(normed, prefix + ".attn.qkv", stage + ".qkv")
            q, k, v = [reg.view(stage + "." + name, qkv, (nv, 12, 64), offset=part * 768 * 4,
                                strides=(2304 * 4, 64 * 4, 4)) for part, name in enumerate(("q", "k", "v"))]
            q = b.operation(Opcode.ROPE, stage + ".q_rope", (q, inputs["vision_cos"], inputs["vision_sin"]), parameters=(64,))
            k = b.operation(Opcode.ROPE, stage + ".k_rope", (k, inputs["vision_cos"], inputs["vision_sin"]), parameters=(64,))
            attended = b.operation(Opcode.ATTENTION, stage + ".attention", (q, k, v),
                                   (nv, 12, 64), (nv, nv, 64, 12, 12))
            merged = reg.view(stage + ".heads", attended, (nv, 768))
            projected = b.linear(merged, prefix + ".attn.proj", stage + ".projection")
            x = b.operation(Opcode.ADD, stage + ".attention_residual", (residual, projected))
            residual = x
            normed = b.norm(x, prefix + ".norm2", stage + ".norm2")
            hidden = b.linear(normed, prefix + ".mlp.linear_fc1", stage + ".fc1")
            hidden = b.operation(Opcode.GELU_TANH, stage + ".gelu", (hidden,))
            projected = b.linear(hidden, prefix + ".mlp.linear_fc2", stage + ".fc2")
            x = b.operation(Opcode.ADD, stage + ".mlp_residual", (residual, projected))
        x = b.norm(x, "model.visual.merger.norm", "merger.norm")
        x = reg.view("merger.grouped", x, (ni, 3072))
        x = b.linear(x, "model.visual.merger.linear_fc1", "merger.fc1")
        x = b.operation(Opcode.GELU_ERF, "merger.gelu_erf", (x,))
        return b.linear(x, "model.visual.merger.linear_fc2", "merger.fc2")
