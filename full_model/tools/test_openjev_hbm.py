import hashlib
import json
from pathlib import Path

import torch
from safetensors.torch import save_file

from build_openjev_hbm import HbmImageBuilder


def recover_tensor(output_dir: Path, placement: dict, bank_count: int, burst_bytes: int) -> bytes:
    streams = [(output_dir / f"hbm_bank_{bank:02d}.bin").open("rb") for bank in range(bank_count)]
    recovered = bytearray()
    try:
        for chunk in range(placement["chunks"]):
            bank = chunk % bank_count
            bank_chunk = chunk // bank_count
            streams[bank].seek(placement["base_address"] + bank_chunk * burst_bytes)
            recovered.extend(streams[bank].read(burst_bytes))
    finally:
        for stream in streams:
            stream.close()
    return bytes(recovered[: placement["logical_bytes"]])


def test_round_trip(tmp_path: Path) -> None:
    tensors = {
        "short": torch.arange(31, dtype=torch.int8),
        "crosses_banks": torch.arange(9000, dtype=torch.int32).to(torch.int8),
        "fp16": torch.linspace(-1, 1, 513, dtype=torch.float16),
    }
    checkpoint = tmp_path / "fixture.safetensors"
    output_dir = tmp_path / "hbm"
    save_file(tensors, checkpoint)
    manifest = HbmImageBuilder().build(checkpoint, output_dir)
    entries = {entry["name"]: entry for entry in manifest["tensors"]}
    for name, tensor in tensors.items():
        expected = tensor.numpy().tobytes(order="C")
        actual = recover_tensor(output_dir, entries[name], 32, 256)
        assert actual == expected
        assert entries[name]["sha256"] == hashlib.sha256(expected).hexdigest()
        assert entries[name]["base_address"] % 4096 == 0
    saved = json.loads((output_dir / "hbm_manifest.json").read_text())
    assert saved["bank_count"] == 32
    assert len(saved["bank_images"]) == 32
