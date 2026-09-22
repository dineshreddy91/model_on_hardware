"""CPU-only input preparation; no learned model or inference is instantiated."""
import hashlib
import json
import sys
import time
from pathlib import Path

import numpy as np
import torch
from PIL import Image
from transformers import AutoConfig, AutoProcessor, __version__ as transformers_version
from transformers.models.qwen3_5.modeling_qwen3_5 import (
    Qwen3_5Model,
    Qwen3_5TextRotaryEmbedding,
    Qwen3_5VisionRotaryEmbedding,
    get_vision_interpolation_indices_and_weights,
    get_vision_position_ids,
)

from ir import GraphProgram
from schema import DType


class PositionOnly:
    """Reuse upstream coordinate indexing without constructing model weights."""
    get_rope_index = Qwen3_5Model.get_rope_index
    get_vision_position_ids = Qwen3_5Model.get_vision_position_ids

    def __init__(self, config):
        self.config = config


class InputPreparer:
    def __init__(self, processor_directory: Path, graph: GraphProgram):
        if transformers_version != "5.17.0":
            raise ValueError("Input preparation requires pinned Transformers 5.17.0")
        self.graph = graph
        self.config = AutoConfig.from_pretrained(processor_directory, local_files_only=True)
        self.processor = AutoProcessor.from_pretrained(processor_directory, local_files_only=True)
        self.processor.tokenizer.padding_side = "right"
        self.coordinates = PositionOnly(self.config)
        self.vision_rotary = Qwen3_5VisionRotaryEmbedding(self.config.vision_config)
        self.text_rotary = Qwen3_5TextRotaryEmbedding(self.config.text_config)
        config_hash = hashlib.sha256((processor_directory / "config.json").read_bytes()).hexdigest()
        if config_hash != graph.config_sha256:
            raise ValueError("Processor model config differs from compiled graph")

    @torch.no_grad()
    def prepare(self, image: Path, hypothesis: str) -> tuple[dict[int, bytes], dict]:
        started = time.perf_counter_ns()
        profile = self.graph.profile
        width, height = profile.grid_width * 16, profile.grid_height * 16
        messages = [{"role": "user", "content": [{"type": "image"}, {"type": "text", "text": hypothesis}]}]
        text = self.processor.apply_chat_template(messages, tokenize=False, add_generation_prompt=False)
        with Image.open(image) as frame:
            resized = frame.convert("RGB").resize((width, height), Image.Resampling.BICUBIC)
            data = self.processor(text=[text], images=[resized], size={"shortest_edge": width * height, "longest_edge": width * height},
                                  padding="max_length", max_length=profile.text_tokens, truncation=False,
                                  return_tensors="pt", return_mm_token_type_ids=True)
        if data["input_ids"].shape != (1, profile.text_tokens):
            raise ValueError("Prompt exceeds the compiled token capacity; recompile instead of truncating")
        grid = data["image_grid_thw"]
        if grid.tolist() != [[1, profile.grid_height, profile.grid_width]]:
            raise ValueError("Processor image grid differs from compiled graph")
        positions, _ = self.coordinates.get_rope_index(data["input_ids"], data["mm_token_type_ids"], grid,
                                                      attention_mask=data["attention_mask"])
        vision_positions = get_vision_position_ids(grid, 2, kwargs={})
        indices, weights = get_vision_interpolation_indices_and_weights(
            grid, num_grid_per_side=48, mode="bilinear", align_corners=True, spatial_merge_size=2, kwargs={})
        # These are trigonometric input coordinates, with no learned parameters.
        vcos, vsin = self.vision_rotary(torch.empty(profile.patch_tokens, 768), vision_positions)
        tcos, tsin = self.text_rotary(torch.empty(1, profile.text_tokens, 1024), positions)
        slots = torch.where(data["input_ids"][0] == self.config.image_token_id)[0]
        if slots.numel() != profile.image_tokens:
            raise ValueError("Image token count mismatch")
        mask = data["attention_mask"][0]
        count = int(mask.sum())
        if count == 0 or mask.tolist() != [1] * count + [0] * (profile.text_tokens - count):
            raise ValueError("Only nonempty, right-padded input is supported")
        values = {
            "pixels": data["pixel_values"], "input_ids": data["input_ids"][0],
            "interpolation_indices": indices, "interpolation_weights": weights,
            "vision_cos": vcos, "vision_sin": vsin, "text_cos": tcos[0], "text_sin": tsin[0],
            "image_slots": slots, "key_mask": mask, "last_token": torch.tensor([count - 1]),
        }
        payloads = {}
        for tid in self.graph.input_ids:
            tensor = self.graph.tensors[tid]
            array = values[tensor.name.removeprefix("input.")]
            if tuple(array.shape) != tensor.shape:
                raise ValueError(f"Input shape mismatch: {tensor.name}")
            dtype = np.dtype("<i4" if tensor.dtype == DType.INT32 else "<f4")
            payload = array.contiguous().cpu().numpy().astype(dtype, copy=False).tobytes()
            if len(payload) != tensor.logical_bytes:
                raise ValueError("Input byte count mismatch")
            payloads[tid] = payload
        elapsed = (time.perf_counter_ns() - started) / 1e6
        return payloads, {"image": str(image), "image_sha256": hashlib.sha256(image.read_bytes()).hexdigest(),
                          "hypothesis": hypothesis, "text_tokens_unpadded": count,
                          "image_grid": grid.tolist(), "resize": "224x224 bicubic" if (width, height) == (224, 224) else f"{width}x{height} bicubic",
                          "cpu_preprocessing_ms": elapsed, "transformers_version": transformers_version,
                          "learned_cpu_computation": False, "model_revision": self.graph.model_revision}

    def write(self, image: Path, hypothesis: str, output: Path):
        payloads, manifest = self.prepare(image, hypothesis)
        output.mkdir(parents=True, exist_ok=True)
        records = []
        for tid, payload in payloads.items():
            name = f"input_{tid}.bin"
            (output / name).write_bytes(payload)
            records.append({"tensor_id": tid, "file": name, "bytes": len(payload), "sha256": hashlib.sha256(payload).hexdigest()})
        manifest["inputs"] = records
        (output / "inputs.json").write_text(json.dumps(manifest, indent=2) + "\n")
        return manifest


if __name__ == "__main__":
    if len(sys.argv) != 6:
        raise SystemExit("Usage: prepare_inputs.py PROCESSOR_DIR PROGRAM_JSON IMAGE HYPOTHESIS OUTPUT_DIR")
    graph = GraphProgram.model_validate_json(Path(sys.argv[2]).read_bytes())
    manifest = InputPreparer(Path(sys.argv[1]), graph).write(Path(sys.argv[3]), sys.argv[4], Path(sys.argv[5]))
    print(json.dumps({k: v for k, v in manifest.items() if k != "inputs"}, indent=2))
