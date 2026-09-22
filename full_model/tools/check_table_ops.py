"""Independent numerical fixtures for embedding/interpolation/scatter/gather RTL."""
import json
import random
import struct
import sys
from pathlib import Path

from make_fp32_vectors import bits, value


class TableFixtures:
    def __init__(self):
        self.rng = random.Random(913)

    @staticmethod
    def fp16(word):
        return struct.unpack("<e", struct.pack("<H", word))[0]

    def cases(self):
        for channels in (3, 768, 1024):
            nt, rows = 4, 8
            weights = [self.rng.randrange(-128, 128) for _ in range(rows * channels)]
            scales = [1, 0x0400, 0x2400, 0x3400, 0x3C00, 0, 0x3000, 0x2800]
            ids = [7, 0, 3, 4]
            expected = [bits(weights[row * channels + c] * self.fp16(scales[row]))
                        for row in ids for c in range(channels)]
            yield (16, nt, channels, rows, 0), [ids, [w & 255 for w in weights], scales, []], expected
            corners = [self.rng.randrange(rows) for _ in range(nt * 4)]
            coefficients = [bits(x) for _ in range(nt) for x in (0.125, 0.375, 0.25, 0.25)]
            expected = []
            for t in range(nt):
                for c in range(channels):
                    total = 0.0
                    for corner in range(4):
                        row = corners[t * 4 + corner]
                        dequant = value(bits(weights[row * channels + c] * self.fp16(scales[row])))
                        product = value(bits(dequant * value(coefficients[t * 4 + corner])))
                        total = value(bits(total + product))
                    expected.append(bits(total))
            yield (17, nt, channels, rows, 0), [[w & 255 for w in weights], scales, corners, coefficients], expected
            x = [bits(self.rng.uniform(-5, 5)) for _ in range(nt * channels)]
            image = [bits(self.rng.uniform(-5, 5)) for _ in range(2 * channels)]
            expected = image[channels:] + x[channels:2 * channels] + image[:channels] + x[3 * channels:]
            yield (19, nt, channels, 0, 2), [x, image, [2, 0], []], expected
            yield (19, nt, channels, 0, 0), [x, [], [], []], x
            yield (20, nt, channels, 0, 0), [x, [2], [], []], x[2 * channels:3 * channels]

    def generate(self, directory: Path):
        directory.mkdir(parents=True, exist_ok=True)
        expected = []
        with (directory / "table_ops.txt").open("w") as stream:
            for case, (header, tensors, output) in enumerate(self.cases()):
                stream.write(" ".join(map(str, (case, *header))) + "\n")
                for tensor in tensors:
                    stream.write(f"{len(tensor)}\n")
                    for word in tensor:
                        stream.write(f"{word:08x}\n")
                expected.append(output)
        (directory / "table_ops-expected.json").write_text(json.dumps(expected))

    @staticmethod
    def check(directory: Path):
        expected = json.loads((directory / "table_ops-expected.json").read_text())
        seen = set()
        for line in (directory / "table_ops-results.txt").read_text().splitlines():
            case, index, word = line.split()
            case, index, word = int(case), int(index), int(word, 16)
            if (case, index) in seen or expected[case][index] != word:
                raise ValueError(f"Table operator mismatch: {line}, expected {expected[case][index]:08x}")
            seen.add((case, index))
        if len(seen) != sum(map(len, expected)):
            raise ValueError("Missing outputs")
        print(f"PASS four table operators: {len(expected)} cases, {len(seen)} bit-exact outputs")


if __name__ == "__main__":
    getattr(TableFixtures(), sys.argv[1])(Path(sys.argv[2]))
