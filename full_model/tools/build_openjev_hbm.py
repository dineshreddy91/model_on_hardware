#!/usr/bin/env python3
import argparse
import hashlib
import json
import math
from dataclasses import asdict, dataclass
from pathlib import Path

from safetensors import safe_open


@dataclass(frozen=True)
class TensorPlacement:
    name: str
    shape: list[int]
    dtype: str
    logical_bytes: int
    padded_bytes: int
    base_address: int
    chunks: int
    chunks_per_bank: int
    sha256: str


class HbmImageBuilder:
    def __init__(self, bank_count: int = 32, burst_bytes: int = 256, alignment: int = 4096):
        self.bank_count = bank_count
        self.burst_bytes = burst_bytes
        self.alignment = alignment

    def _align(self, value: int) -> int:
        return (value + self.alignment - 1) // self.alignment * self.alignment

    def build(self, checkpoint: Path, output_dir: Path) -> dict:
        output_dir.mkdir(parents=True, exist_ok=True)
        bank_paths = [output_dir / f"hbm_bank_{bank:02d}.bin" for bank in range(self.bank_count)]
        bank_files = [path.open("w+b") for path in bank_paths]
        placements: list[TensorPlacement] = []
        next_address = 0
        try:
            with safe_open(checkpoint, framework="pt", device="cpu") as reader:
                for name in sorted(reader.keys()):
                    tensor = reader.get_tensor(name).contiguous()
                    payload = tensor.numpy().tobytes(order="C")
                    logical_bytes = len(payload)
                    chunks = math.ceil(logical_bytes / self.burst_bytes)
                    chunks_per_bank = math.ceil(chunks / self.bank_count)
                    base_address = self._align(next_address)
                    allocation = chunks_per_bank * self.burst_bytes
                    padded_payload = payload + bytes(chunks * self.burst_bytes - logical_bytes)
                    for chunk_index in range(chunks):
                        bank = chunk_index % self.bank_count
                        bank_chunk = chunk_index // self.bank_count
                        bank_files[bank].seek(base_address + bank_chunk * self.burst_bytes)
                        start = chunk_index * self.burst_bytes
                        bank_files[bank].write(padded_payload[start : start + self.burst_bytes])
                    next_address = base_address + allocation
                    placements.append(
                        TensorPlacement(
                            name=name,
                            shape=list(tensor.shape),
                            dtype=str(tensor.dtype).removeprefix("torch."),
                            logical_bytes=logical_bytes,
                            padded_bytes=allocation * self.bank_count,
                            base_address=base_address,
                            chunks=chunks,
                            chunks_per_bank=chunks_per_bank,
                            sha256=hashlib.sha256(payload).hexdigest(),
                        )
                    )
        finally:
            for stream in bank_files:
                stream.close()

        bank_size = self._align(next_address)
        for path in bank_paths:
            with path.open("r+b") as stream:
                stream.truncate(bank_size)
        manifest = {
            "format": "openjev-hbm32-striped-v1",
            "checkpoint": str(checkpoint),
            "bank_count": self.bank_count,
            "burst_bytes": self.burst_bytes,
            "alignment": self.alignment,
            "address_rule": "bank=chunk%32; bank_address=base_address+(chunk//32)*256",
            "bank_size_bytes": bank_size,
            "total_hbm_bytes": bank_size * self.bank_count,
            "tensors": [asdict(item) for item in placements],
            "bank_images": [
                {
                    "bank": index,
                    "path": str(path),
                    "bytes": path.stat().st_size,
                    "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                }
                for index, path in enumerate(bank_paths)
            ],
        }
        (output_dir / "hbm_manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        return manifest


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("checkpoint", type=Path)
    parser.add_argument("output_dir", type=Path)
    args = parser.parse_args()
    manifest = HbmImageBuilder().build(args.checkpoint, args.output_dir)
    print(
        json.dumps(
            {
                "tensors": len(manifest["tensors"]),
                "bank_count": manifest["bank_count"],
                "bank_size_bytes": manifest["bank_size_bytes"],
                "total_hbm_bytes": manifest["total_hbm_bytes"],
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
