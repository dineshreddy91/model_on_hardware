"""Compile the pinned single-image 0.8B model to a complete quantized tensor graph."""
import hashlib
import json
from pathlib import Path

from builder import GraphBuilder, WeightPlacement
from ir import GraphProgram, LifetimeAllocator
from schema import DType, InputProfile, Opcode, Storage
from text import TextLowering
from vision import VisionLowering


class OpenJevCompiler:
    def __init__(self, config_path: Path, manifest_path: Path):
        self.config_bytes = config_path.read_bytes()
        self.manifest_bytes = manifest_path.read_bytes()
        self.config = json.loads(self.config_bytes)
        manifest = json.loads(self.manifest_bytes)
        if (manifest["bank_count"], manifest["burst_bytes"], manifest["alignment"]) != (32, 256, 4096):
            raise ValueError("Unsupported HBM format")
        self.weights = [WeightPlacement.model_validate(t) for t in manifest["tensors"]]
        self._validate_architecture()

    def _validate_architecture(self) -> None:
        text, vision = self.config["text_config"], self.config["vision_config"]
        if self.config["architectures"] != ["Qwen3_5ForSequenceClassification"]:
            raise ValueError("Unsupported model architecture")
        if (vision["depth"], vision["hidden_size"], vision["num_heads"], vision["spatial_merge_size"],
            text["hidden_size"], text["num_hidden_layers"], text["num_attention_heads"], text["num_key_value_heads"],
            text["head_dim"], text["linear_num_key_heads"], text["linear_num_value_heads"],
            text["linear_key_head_dim"], text["linear_value_head_dim"]) != (12, 768, 12, 2, 1024, 24, 8, 2, 256, 16, 16, 128, 128):
            raise ValueError("Compiler currently supports only the pinned 0.8B topology")
        expected_text = {"intermediate_size": 3584, "linear_conv_kernel_dim": 4,
                         "vocab_size": 248320, "rms_norm_eps": 1e-6,
                         "attn_output_gate": True, "attention_bias": False}
        expected_vision = {"intermediate_size": 3072, "patch_size": 16,
                           "temporal_patch_size": 2, "in_channels": 3,
                           "num_position_embeddings": 2304, "out_hidden_size": 1024,
                           "deepstack_visual_indexes": []}
        if any(text.get(k) != v for k, v in expected_text.items()) or any(
            vision.get(k) != v for k, v in expected_vision.items()
        ):
            raise ValueError("Unsupported model dimensions or operation semantics")
        if text.get("rope_parameters") != {
            "mrope_interleaved": True, "mrope_section": [11, 11, 10],
            "partial_rotary_factor": 0.25, "rope_theta": 10000000, "rope_type": "default"
        }:
            raise ValueError("Unsupported rotary position semantics")
        if text["layer_types"] != ["full_attention" if i % 4 == 3 else "linear_attention" for i in range(24)]:
            raise ValueError("Unexpected decoder layer pattern")
        if vision["hidden_act"] != "gelu_pytorch_tanh" or text["hidden_act"] != "silu" or self.config.get("use_cache"):
            raise ValueError("Unsupported activation or cached inference mode")

    def compile(self, profile: InputProfile) -> GraphProgram:
        builder = GraphBuilder(self.weights)
        reg = builder.registry
        nv, ni, nt = profile.patch_tokens, profile.image_tokens, profile.text_tokens
        inputs = {}
        for name, shape, dtype in [
            ("pixels", (nv, 1536), DType.FLOAT32), ("input_ids", (nt,), DType.INT32),
            ("interpolation_indices", (nv, 4), DType.INT32), ("interpolation_weights", (nv, 4), DType.FLOAT32),
            ("vision_cos", (nv, 64), DType.FLOAT32), ("vision_sin", (nv, 64), DType.FLOAT32),
            ("text_cos", (nt, 64), DType.FLOAT32), ("text_sin", (nt, 64), DType.FLOAT32),
            ("image_slots", (ni,), DType.INT32), ("key_mask", (nt,), DType.INT32),
            ("last_token", (1,), DType.INT32),
        ]:
            inputs[name] = reg.add("input." + name, shape, dtype, Storage.INPUT)
        image = VisionLowering(builder).lower(inputs, profile)
        outputs = TextLowering(builder).lower(image, inputs, nt, self.config["text_config"]["layer_types"])
        builder.emit(Opcode.END, "end", (), ())
        missing = {p.name for p in self.weights} - builder.used_weights
        if missing:
            raise ValueError(f"Graph did not use checkpoint tensors: {sorted(missing)}")
        tensors, peak = LifetimeAllocator().place(reg.tensors, builder.instructions, outputs)
        program = GraphProgram(profile=profile, tensors=tensors, instructions=builder.instructions,
                               outputs=outputs, covered_weights=tuple(sorted(builder.used_weights)),
                               input_ids=tuple(inputs.values()), peak_bank_address=peak,
                               config_sha256=hashlib.sha256(self.config_bytes).hexdigest(),
                               manifest_sha256=hashlib.sha256(self.manifest_bytes).hexdigest())
        program.validate_dataflow()
        return program
