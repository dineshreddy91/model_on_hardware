#!/usr/bin/env python3
import json
from pathlib import Path

from safetensors.torch import load_file


def hex8(value: int) -> str:
    return f"{value & 0xff:02x}"


def main() -> None:
    project_dir = Path(__file__).resolve().parents[1]
    root = project_dir.parent
    output = project_dir / "sim/head_fixture"
    output.mkdir(parents=True, exist_ok=True)
    fixture = json.loads((root / "fpga-head/fixture.json").read_text())
    weights = load_file(root / "fpga-int8/openjev-0.8b-int8.safetensors")["score.weight"]
    (output / "activation.mem").write_text(
        "\n".join(hex8(value) for value in fixture["activation_int8"]) + "\n"
    )
    for label in range(3):
        (output / f"weight{label}.mem").write_text(
            "\n".join(hex8(int(value)) for value in weights[label]) + "\n"
        )
    (output / "expected.svh").write_text(
        "localparam logic signed [31:0] EXPECTED0 = 32'sd{};\n"
        "localparam logic signed [31:0] EXPECTED1 = 32'sd{};\n"
        "localparam logic signed [31:0] EXPECTED2 = -32'sd{};\n".format(
            fixture["expected_accumulators"][0],
            fixture["expected_accumulators"][1],
            abs(fixture["expected_accumulators"][2]),
        )
    )


if __name__ == "__main__":
    main()
