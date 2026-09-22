"""Synthetic hardware bring-up check; this is not full-model inference."""
import json
import math
import sys
from pathlib import Path

from core_fixture import CoreFixture
from execution import ExecutionPlan
from ir import GraphProgram
from schema import Storage
from full_model.host.model_runtime import FullModelDevice


class CoreHardwareCheck:
    def __init__(self, directory: Path):
        self.directory = directory
        CoreFixture().generate(directory)
        self.graph = GraphProgram.model_validate_json((directory / "program.json").read_bytes())
        self.payloads = {int(path.stem): path.read_bytes() for path in (directory / "payloads").glob("*.bin")}
        self.expected = json.loads((directory / "expected.json").read_text())

    def check_outputs(self, outputs: dict[str, list[float]]) -> None:
        actual = [value for tid in self.graph.outputs for value in outputs[self.graph.tensors[tid].name]]
        if len(actual) != len(self.expected) or any(
            not math.isfinite(a) or abs(a - b) > 2e-5 * max(1, abs(b))
            for a, b in zip(actual, self.expected)
        ):
            raise RuntimeError(f"Synthetic FPGA graph mismatch: {actual} versus {self.expected}")

    def run(self) -> dict:
        results = []
        with FullModelDevice() as device:
            device.initialize_hbm()
            for tid, payload in self.payloads.items():
                tensor = self.graph.tensors[tid]
                if tensor.storage != Storage.WEIGHT:
                    continue
                for offset in range(0, len(payload), 256):
                    part = payload[offset:offset + 256]
                    padded = part + bytes((-len(part)) % 8)
                    address = device.address(tensor.base, offset)
                    device.upload(address, padded)
                    device.verify(address, padded)
            device.configure(
                (self.directory / "program.bin").read_bytes(),
                (self.directory / "tensors.bin").read_bytes(),
                b"".join(item.encode() for item in ExecutionPlan(self.graph).metadata),
            )
            inputs = {tid: self.payloads[tid] for tid in self.graph.input_ids}
            for _ in range(2):
                result = device.execute(self.graph, inputs, timeout_seconds=30)
                result["execution"] = "synthetic_fpga_core_check"
                self.check_outputs(result["outputs"])
                results.append(result)
        report = {"scope": "Synthetic seven-operation graph; not full-model inference", "passed": True, "runs": results}
        (self.directory / "hardware-results.json").write_text(json.dumps(report, indent=2) + "\n")
        return report


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: run_core_smoke.py OUTPUT_DIRECTORY")
    print(json.dumps(CoreHardwareCheck(Path(sys.argv[1])).run(), indent=2))
