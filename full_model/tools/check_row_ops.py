"""Independent analytic references for the tensor-memory arithmetic adapter."""
import json
import math
import random
import struct
import sys
from pathlib import Path

from make_fp32_vectors import bits, value


class RowFixtures:
    def __init__(self):
        self.rng = random.Random(324)

    @staticmethod
    def encode(values, dtype):
        if dtype == 1:
            return [struct.unpack("<H", struct.pack("<e", x))[0] for x in values]
        if dtype == 2:
            return [int(x) & 0xFFFFFFFF for x in values]
        return [bits(x) for x in values]

    @staticmethod
    def decode(words, dtype):
        if dtype == 1:
            return [struct.unpack("<e", struct.pack("<H", x))[0] for x in words]
        if dtype == 2:
            return [x if x < 2**31 else x - 2**32 for x in words]
        return [value(x) for x in words]

    def cases(self):
        configs = [(op, 0, 3, 8) for op in (1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15)]
        configs += [(4, 1, 2, 768), (5, 1, 3, 128), (5, 2, 3, 1024), (7, 1, 2, 1024), (8, 0, 1, 6144)]
        for op, flags, rows, width in configs:
            dtypes = [2 if op == 3 else 1 if op == 12 else 3,
                      1 if op in (6, 7) or (op == 4 and flags == 1) else 2 if flags == 2 else 3,
                      1 if op in (3, 6) else 3]
            a = [self.rng.uniform(-3, 3) for _ in range(rows * width)]
            if op == 3:
                a = [self.rng.randrange(-50000, 50000) for _ in a]
            b = [self.rng.uniform(0.2, 1.2) for _ in range(rows if op == 3 or flags == 2 else width if op in (6, 7) or flags == 1 else rows * width)]
            if flags == 2:
                b = [0, 1, 0]
            c = [self.rng.uniform(0.02, 0.15) for _ in range(width)]
            tensors = [self.encode(x, dt) for x, dt in zip((a, b, c), dtypes)]
            a, b, c = [self.decode(x, dt) for x, dt in zip(tensors, dtypes)]
            output, scales = [], []
            for row in range(rows):
                x = a[row * width:(row + 1) * width]
                if op == 1:
                    scale = value(bits(max(map(abs, x)) * value(bits(1 / 127)))) or 1
                    scales.append(scale)
                    y = [max(-127, min(127, round(value(bits(v * value(bits(1 / scale))))))) & 255 for v in x]
                elif op == 3:
                    y = [value(bits(value(bits(v * c[i])) * b[row])) for i, v in enumerate(x)]
                elif op in (4, 5):
                    rhs = b[row:row + 1] * width if flags == 2 else b if flags == 1 else b[row * width:(row + 1) * width]
                    y = [u + v if op == 4 else u * v for u, v in zip(x, rhs)]
                elif op in (6, 7):
                    mean = sum(x) / width if op == 6 else 0
                    variance = sum((v - mean)**2 for v in x) / width
                    y = [(v - mean) / math.sqrt(variance + 1e-6) * (b[i] + (1 if flags else 0)) + (c[i] if op == 6 else 0)
                         for i, v in enumerate(x)]
                elif op == 8:
                    y = [v / (1 + math.exp(-v)) for v in x]
                elif op == 9:
                    y = [0.5 * v * (1 + math.tanh(math.sqrt(2 / math.pi) * (v + 0.044715 * v**3))) for v in x]
                elif op == 10:
                    y = [0.5 * v * (1 + math.erf(v / math.sqrt(2))) for v in x]
                elif op == 11:
                    y = [1 / (1 + math.exp(-v)) for v in x]
                elif op == 12:
                    y = [math.exp(v) for v in x]
                elif op == 13:
                    y = [math.log1p(math.exp(v)) for v in x]
                elif op == 14:
                    y = [-v for v in x]
                else:
                    e = [math.exp(v - max(x)) for v in x]
                    y = [v / sum(e) for v in e]
                output.extend(y)
            yield (op, flags, rows, width, *dtypes), tensors, output, scales

    def generate(self, directory: Path):
        directory.mkdir(parents=True, exist_ok=True)
        expected = []
        with (directory / "row_ops.txt").open("w") as stream:
            for case, (header, tensors, output, scales) in enumerate(self.cases()):
                op, flags, rows, width, *dtypes = header
                stream.write(f"{case} {op} {flags} {rows} {width} {bits(1e-6):08x} " + " ".join(map(str, dtypes)) + "\n")
                for tensor in tensors:
                    stream.write(f"{len(tensor)}\n")
                    for word in tensor:
                        stream.write(f"{word:08x}\n")
                expected.append({"op": op, "outputs": output, "scales": scales})
        (directory / "row_ops-expected.json").write_text(json.dumps(expected))

    @staticmethod
    def check(directory: Path):
        expected = json.loads((directory / "row_ops-expected.json").read_text())
        seen = set()
        maximum = 0
        for line in (directory / "row_ops-results.txt").read_text().splitlines():
            case, tensor, index, word = line.split()
            case, tensor, index, word = int(case), int(tensor), int(index), int(word, 16)
            key = (case, tensor, index)
            target = expected[case]["scales" if tensor == 4 else "outputs"][index]
            if key in seen:
                raise ValueError("Duplicate output")
            seen.add(key)
            if expected[case]["op"] == 1 and tensor == 3:
                if word != target:
                    raise ValueError(f"Quantization mismatch: {line} != {target}")
            else:
                error = abs(value(word) - target) / max(1, abs(target))
                maximum = max(maximum, error)
                if not math.isfinite(error) or error > 2e-5:
                    raise ValueError(f"Row operator mismatch: {line} != {target}, error={error}")
        if len(seen) != sum(len(c["outputs"]) + len(c["scales"]) for c in expected):
            raise ValueError("Missing outputs")
        print(f"PASS row arithmetic: {len(expected)} cases, {len(seen)} outputs, maximum scaled error {maximum:.9g}")


if __name__ == "__main__":
    getattr(RowFixtures(), sys.argv[1])(Path(sys.argv[2]))
