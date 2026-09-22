"""Hardware-only Doom/Box Runner benchmark. Setup is separate from request latency."""
import hashlib
import json
import subprocess
import sys
import time
from pathlib import Path

from execution import ExecutionPlan
from ir import GraphProgram
from prepare_inputs import InputPreparer
from full_model.host.model_runtime import FullModelDevice
from full_model.host.compare_reference import OfflineReference


class FpgaBenchmark:
    def __init__(self, program_directory: Path, hbm_directory: Path, processor_directory: Path, loader: Path):
        self.program_directory = program_directory
        self.hbm_directory = hbm_directory
        self.loader = loader.resolve()
        requirements = json.loads((program_directory / "requirements.json").read_text())
        for name, key in (("program.json", "graph_json_sha256"), ("program.bin", "program_sha256"),
                          ("tensors.bin", "tensor_table_sha256")):
            if hashlib.sha256((program_directory / name).read_bytes()).hexdigest() != requirements[key]:
                raise ValueError(f"Program checksum mismatch: {name}")
        self.graph = GraphProgram.model_validate_json((program_directory / "program.json").read_bytes())
        self.plan = ExecutionPlan(self.graph)
        self.instructions = b"".join(item.encode() for item in self.graph.instructions)
        self.descriptors = b"".join(item.encode() for item in self.graph.tensors)
        if self.instructions != (program_directory / "program.bin").read_bytes() or self.descriptors != (program_directory / "tensors.bin").read_bytes():
            raise ValueError("Program binaries differ from validated graph")
        manifest_bytes = (hbm_directory / "hbm_manifest.json").read_bytes()
        if hashlib.sha256(manifest_bytes).hexdigest() != self.graph.manifest_sha256:
            raise ValueError("HBM manifest differs from compiled model")
        manifest = json.loads(manifest_bytes)
        for item in manifest["bank_images"]:
            path = hbm_directory / f"hbm_bank_{item['bank']:02d}.bin"
            digest = hashlib.sha256()
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(4 << 20), b""):
                    digest.update(chunk)
            if path.stat().st_size != item["bytes"] or digest.hexdigest() != item["sha256"]:
                raise ValueError(f"HBM bank checksum mismatch: {path.name}")
        self.preparer = InputPreparer(processor_directory, self.graph)

    def run(self, output: Path):
        output.mkdir(parents=True, exist_ok=True)
        inputs = Path(__file__).resolve().parents[1] / "benchmark/inputs"
        requests = [
            ("box_runner", inputs / "gameplay-trex.jpg", "The runner should jump to avoid the obstacle."),
            ("doom", inputs / "gameplay-doom.jpg", "An enemy is visible in front of the player."),
        ]
        with FullModelDevice() as device:
            device.initialize_hbm()
            setup = time.perf_counter_ns()
            with (output / "hbm_load_and_verify.txt").open("w") as log:
                subprocess.run([str(self.loader), str(self.hbm_directory), "--verify", "--pci"], check=True, stdout=log, stderr=subprocess.STDOUT)
            device.configure(self.instructions, self.descriptors, b"".join(item.encode() for item in self.plan.metadata))
            setup_ms = (time.perf_counter_ns() - setup) / 1e6
            hardware = subprocess.run(["fpga-describe-local-image", "-S", "0", "-H"], check=True, capture_output=True, text=True).stdout
            results = []
            for name, image, hypothesis in requests:
                print(f"Starting full-model FPGA request: {name}", flush=True)
                started = time.perf_counter_ns()
                payloads, prepared = self.preparer.prepare(image, hypothesis)
                try:
                    result = device.execute(self.graph, payloads,
                                            progress=lambda status: print(json.dumps({"request": name, "progress": status}), flush=True))
                except Exception as error:
                    retired = device.read(0x534)
                    failure = {"request": name, "hardware": hardware, "error": str(error),
                               "instructions_retired": retired,
                               "next_graph_stage": self.graph.instructions[min(retired, len(self.graph.instructions) - 1)].stage,
                               "device_cycles": device.read(0x52C) | device.read(0x530) << 32,
                               "elapsed_request_ms": (time.perf_counter_ns() - started) / 1e6,
                               "benchmark_complete": False, "cpu_model_fallback": False}
                    (output / f"{name}-failure.json").write_text(json.dumps(failure, indent=2) + "\n")
                    raise
                result.update({"request": name, "input": prepared,
                               "end_to_end_request_ms": (time.perf_counter_ns() - started) / 1e6})
                probabilities = result["outputs"][self.graph.tensors[self.graph.outputs[-1]].name]
                if len(probabilities) != 3 or any(p < 0 or p > 1 for p in probabilities) or abs(sum(probabilities) - 1) > 1e-4:
                    raise RuntimeError("FPGA classification probabilities are invalid")
                result["label_index"] = max(range(3), key=probabilities.__getitem__)
                result["label"] = self.preparer.config.id2label[result["label_index"]]
                reference_path = self.program_directory / "references" / f"{name}.json"
                if reference_path.is_file():
                    result["independent_comparison"] = OfflineReference.from_file(reference_path).compare(self.graph, payloads, result["outputs"])
                results.append(result)
                report = {"benchmark_complete": len(results) == len(requests), "requests_expected": len(requests),
                          "hardware": hardware, "model_revision": self.graph.model_revision,
                          "hbm_manifest_sha256": self.graph.manifest_sha256,
                          "weight_transfer": "pci_bar4_with_full_readback",
                          "setup_excluded_from_request_ms": setup_ms, "results": results,
                          "scope": "Single-image classification; no video throughput, GPU speedup or safety accuracy claim",
                          "correctness_status": "See per-request independent_comparison metrics; finite outputs alone do not establish model accuracy"}
                (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
                print(json.dumps(result), flush=True)


if __name__ == "__main__":
    if len(sys.argv) != 6:
        raise SystemExit("Usage: run_fpga_benchmark.py PROGRAM_DIR HBM_DIR PROCESSOR_DIR HBM_LOADER OUTPUT_DIR")
    FpgaBenchmark(*(Path(p) for p in sys.argv[1:5])).run(Path(sys.argv[5]))
