"""Small integration graph for the real AXI/program core; not a model benchmark."""
import json
import math
import random
import struct
import sys
from pathlib import Path

from builder import GraphBuilder, WeightPlacement
from execution import ExecutionPlan
from ir import GraphProgram, LifetimeAllocator
from schema import DType, InputProfile, Opcode, Storage


class CoreFixture:
    @staticmethod
    def f32(x):
        return struct.unpack("<f", struct.pack("<f", x))[0]

    @staticmethod
    def physical(base, offset):
        bank = (offset >> 8) % 32
        local = base + (offset >> 13) * 256 + offset % 256
        if local >= 0x02000000:
            local = local - 0x02000000 + 0x10000
        if local >= 0x40000:
            raise ValueError("Fixture exceeds testbench memory")
        return bank * 0x40000 + local

    def generate(self, directory: Path):
        directory.mkdir(parents=True, exist_ok=True)
        rng = random.Random(245)
        embedding = [rng.randrange(-127, 128) for _ in range(8 * 32)]
        matrix = [rng.randrange(-127, 128) for _ in range(3 * 32)]
        specifications = [
            ("embedding", (8, 32), DType.INT8, embedding),
            ("embedding.scale", (8,), DType.FLOAT16, [0.03125] * 8),
            ("norm.weight", (32,), DType.FLOAT16, [1.0] * 32),
            ("norm.bias", (32,), DType.FLOAT16, [0.0] * 32),
            ("score.weight", (3, 32), DType.INT8, matrix),
            ("score.weight.scale", (3,), DType.FLOAT16, [0.0078125] * 3),
        ]
        placements = [WeightPlacement(name=name, shape=shape, dtype=dtype, base_address=i * 4096,
                                      logical_bytes=math.prod(shape) * dtype.byte_size, padded_bytes=32 * 4096,
                                      sha256="0" * 64) for i, (name, shape, dtype, _) in enumerate(specifications)]
        b = GraphBuilder(placements)
        reg = b.registry
        ids = reg.add("ids", (3,), DType.INT32, Storage.INPUT)
        last = reg.add("last", (1,), DType.INT32, Storage.INPUT)
        x = b.operation(Opcode.EMBEDDING, "embedded", (ids, b.weight("embedding"), b.weight("embedding.scale")),
                        (3, 32), (8, 32))
        x = b.norm(x, "norm", "normalized")
        logits = b.linear(x, "score", "scores")
        last_logits = b.operation(Opcode.GATHER_LAST, "last_logits", (logits, last), (1, 3))
        probabilities = b.operation(Opcode.SOFTMAX, "probabilities", (last_logits,))
        b.emit(Opcode.END, "end", (), ())
        tensors, peak = LifetimeAllocator().place(reg.tensors, b.instructions, (last_logits, probabilities))
        graph = GraphProgram(profile=InputProfile(), tensors=tensors, instructions=b.instructions,
                             outputs=(last_logits, probabilities), covered_weights=tuple(sorted(b.used_weights)),
                             input_ids=(ids, last), peak_bank_address=peak, config_sha256="0" * 64, manifest_sha256="0" * 64)
        graph.validate_dataflow()
        graph.write(directory)
        ExecutionPlan(graph).write(directory)
        (directory / "tensors.mem").write_text("".join(t.encode()[::-1].hex() + "\n" for t in tensors))
        payloads = {i: values for i, (_, _, _, values) in enumerate(specifications)}
        payloads.update({ids: [7, 0, 3], last: [2]})
        codes = {DType.INT8: "b", DType.FLOAT16: "e", DType.INT32: "i", DType.FLOAT32: "f"}
        payload_directory = directory / "payloads"
        payload_directory.mkdir(exist_ok=True)
        with (directory / "memory.mem").open("w") as stream:
            for tid, values in payloads.items():
                tensor = tensors[tid]
                payload = struct.pack("<" + codes[tensor.dtype] * len(values), *values)
                (payload_directory / f"{tid}.bin").write_bytes(payload)
                for offset, byte in enumerate(payload):
                    stream.write(f"@{self.physical(tensor.base, offset):x} {byte:02x}\n")
        row = [v * 0.03125 for v in embedding[3 * 32:4 * 32]]
        mean = sum(row) / 32
        variance = sum((v - mean)**2 for v in row) / 32
        normalized = [self.f32((v - mean) / math.sqrt(variance + 1e-6)) for v in row]
        scale = self.f32(max(map(abs, normalized)) * self.f32(1 / 127))
        inverse = self.f32(1 / scale)
        quantized = [round(self.f32(v * inverse)) for v in normalized]
        expected_logits = [self.f32(self.f32(sum(a * w for a, w in zip(quantized, matrix[i * 32:(i + 1) * 32])) * 0.0078125) * scale) for i in range(3)]
        exps = [math.exp(v - max(expected_logits)) for v in expected_logits]
        expected = expected_logits + [v / sum(exps) for v in exps]
        addresses = [self.physical(tensors[tid].base, i * 4) for tid in graph.outputs for i in range(3)]
        (directory / "control.txt").write_text(f"{len(graph.instructions)} {len(tensors)}\n" + "\n".join(map(str, addresses)) + "\n")
        (directory / "expected.json").write_text(json.dumps(expected))

    @staticmethod
    def check(directory: Path):
        expected = json.loads((directory / "expected.json").read_text())
        words = (directory / "results.txt").read_text().split()
        if len(words) != len(expected):
            raise ValueError("Incomplete core outputs")
        actual = [struct.unpack("<f", struct.pack("<I", int(word, 16)))[0] for word in words]
        for x, y in zip(actual, expected):
            if not math.isfinite(x) or abs(x - y) > 2e-5 * max(1, abs(y)):
                raise ValueError(f"Core mismatch: {actual} vs {expected}")
        print(f"PASS integrated AXI graph numerical outputs: logits={actual[:3]}, probabilities={actual[3:]}")


if __name__ == "__main__":
    getattr(CoreFixture(), sys.argv[1])(Path(sys.argv[2]))
