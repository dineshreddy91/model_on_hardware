"""Reconstruct the INT8 checkpoint, requiring every saved tensor hash to match.

Usage: restore_quantized_checkpoint.py ORIGINAL_SAFETENSORS HBM_MANIFEST OUTPUT
This never silently substitutes a new quantization for the validated checkpoint.
"""
import hashlib
import json
import sys
from pathlib import Path

import torch
from safetensors import safe_open
from safetensors.torch import save_file


class CheckpointRestorer:
    def __init__(self, manifest: Path):
        self.entries = {entry["name"]: entry for entry in json.loads(manifest.read_text())["tensors"]}

    @staticmethod
    def quantize(weight: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
        weight = weight.float()
        flat = weight.reshape(weight.shape[0], -1)
        scale = flat.abs().amax(dim=1).clamp_min(1e-8) / 127
        quantized = (flat / scale[:, None]).round().clamp(-127, 127).to(torch.int8)
        return quantized.reshape(weight.shape).contiguous(), scale.half().contiguous()

    def validate(self, name: str, value: torch.Tensor) -> None:
        entry = self.entries[name]
        if list(value.shape) != entry["shape"] or str(value.dtype).removeprefix("torch.") != entry["dtype"]:
            raise ValueError(f"Restored tensor metadata mismatch: {name}")
        actual = hashlib.sha256(value.numpy().tobytes()).hexdigest()
        if actual != entry["sha256"]:
            raise ValueError(f"Restored tensor checksum mismatch: {name}: {actual}")

    def restore(self, source: Path, destination: Path) -> None:
        restored = {}
        with safe_open(source, framework="pt", device="cpu") as reader:
            for name, entry in self.entries.items():
                if name.endswith(".scale"):
                    continue
                if entry["dtype"] == "int8":
                    quantized, scale = self.quantize(reader.get_tensor(name))
                    restored[name] = quantized
                    restored[name + ".scale"] = scale
                    self.validate(name + ".scale", scale)
                elif entry["dtype"] == "float16":
                    restored[name] = reader.get_tensor(name).half().contiguous()
                else:
                    raise ValueError(f"Unsupported saved dtype: {entry['dtype']}")
                self.validate(name, restored[name])
        if restored.keys() != self.entries.keys():
            raise ValueError("Restored checkpoint does not cover every manifest tensor")
        destination.parent.mkdir(parents=True, exist_ok=True)
        save_file(restored, str(destination))
        print(f"PASS: restored {len(restored)} tensors; every shape, dtype and SHA256 matches", flush=True)


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    torch.set_num_threads(8)
    CheckpointRestorer(Path(sys.argv[2])).restore(Path(sys.argv[1]), Path(sys.argv[3]))


if __name__ == "__main__":
    main()
