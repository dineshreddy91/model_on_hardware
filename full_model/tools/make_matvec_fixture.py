"""Export a complete quantized matrix and deterministic input for RTL checking."""
import hashlib
import json
import sys
from contextlib import ExitStack
from pathlib import Path

import torch
from safetensors import safe_open


def write_words(path: Path, matrix: torch.Tensor, lanes: int = 32) -> None:
    with path.open("w") as stream:
        for row in matrix.tolist():
            # Nonzero padding exercises the RTL column mask.
            row += [127] * ((-len(row)) % lanes)
            for offset in range(0, len(row), lanes):
                stream.write("".join(f"{value & 255:02x}" for value in reversed(row[offset:offset + lanes])) + "\n")


def main() -> None:
    if len(sys.argv) not in (4, 5):
        raise SystemExit("Usage: make_matvec_fixture.py CHECKPOINT TENSOR OUTPUT [HBM_DIRECTORY]")
    checkpoint, tensor_name, output = sys.argv[1:4]
    destination = Path(output)
    destination.mkdir(parents=True, exist_ok=True)
    with safe_open(checkpoint, framework="pt", device="cpu") as reader:
        weights = reader.get_tensor(tensor_name)
    if weights.ndim != 2 or weights.dtype != torch.int8:
        raise ValueError("Expected a rank-two INT8 weight matrix")
    if len(sys.argv) == 5:
        hbm = Path(sys.argv[4])
        manifest = json.loads((hbm / "hbm_manifest.json").read_text())
        if (manifest["bank_count"], manifest["burst_bytes"]) != (32, 256):
            raise ValueError("RTL reader requires the 32-bank, 256-byte stripe format")
        entry = next(item for item in manifest["tensors"] if item["name"] == tensor_name)
        payload = bytearray()
        with ExitStack() as stack:
            banks = [stack.enter_context((hbm / f"hbm_bank_{bank:02d}.bin").open("rb")) for bank in range(32)]
            for chunk in range(entry["chunks"]):
                bank = banks[chunk % 32]
                bank.seek(entry["base_address"] + (chunk // 32) * 256)
                block = bank.read(256)
                if len(block) != 256:
                    raise ValueError("Truncated HBM bank")
                payload.extend(block)
        payload = payload[:entry["logical_bytes"]]
        if hashlib.sha256(payload).hexdigest() != entry["sha256"]:
            raise ValueError("HBM tensor checksum mismatch")
        if payload != weights.contiguous().numpy().tobytes():
            raise ValueError("HBM tensor differs from the quantized checkpoint")
        print(f"Verified real HBM tensor at bank-local base {entry['base_address']:#x}")
    rows, columns = weights.shape
    if columns > 4096 or columns % 32:
        raise ValueError("Integrated HBM test requires columns <= 4096 and divisible by 32")
    activation = ((torch.arange(columns, dtype=torch.int64) * 73 + 19) % 256 - 128).to(torch.int8)
    expected = weights.to(torch.int64) @ activation.to(torch.int64)
    if not ((expected >= -(2**31)) & (expected < 2**31)).all():
        raise ValueError("Reference exceeds INT32 accumulator range")
    write_words(destination / "activations.mem", activation.unsqueeze(0))
    write_words(destination / "weights.mem", weights)
    (destination / "expected.mem").write_text("".join(f"{int(x) & 0xffffffff:08x}\n" for x in expected))
    (destination / "dimensions.svh").write_text(f"localparam int ROWS = {rows};\nlocalparam int COLS = {columns};\n")
    (destination / "metadata.json").write_text(json.dumps({"tensor": tensor_name, "rows": rows, "columns": columns, "hbm_verified": len(sys.argv) == 5, "input": "synthetic deterministic signed INT8", "reference": "PyTorch INT64 matvec; raw sums, without scales or bias"}, indent=2) + "\n")
    print(f"Exported {rows} x {columns}: {rows * columns} real weights")


if __name__ == "__main__":
    main()
