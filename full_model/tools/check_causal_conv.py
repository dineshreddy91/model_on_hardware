"""Independent INT8/FP16 causal depthwise convolution reference."""
import json
import random
import struct
import sys
from pathlib import Path

from make_fp32_vectors import bits, value


def generate(directory: Path):
    directory.mkdir(parents=True, exist_ok=True)
    rng = random.Random(812)
    expected = []
    with (directory / "causal_conv.txt").open("w") as stream:
        for case, (nt, channels, kernel) in enumerate([(7, 3, 4), (3, 7, 1), (2, 11, 3), (1, 6144, 4)]):
            x = [value(bits(rng.uniform(-3, 3))) for _ in range(nt * channels)]
            weights = [rng.randrange(-128, 128) for _ in range(channels * kernel)]
            scales = [rng.choice([0x0001, 0x0400, 0x2400, 0x3400, 0x3C00, 0]) for _ in range(channels)]
            y = []
            for token in range(nt):
                for channel in range(channels):
                    scale = struct.unpack("<e", struct.pack("<H", scales[channel]))[0]
                    total = 0.0
                    for tap in range(kernel):
                        source_token = token + tap - kernel + 1
                        if source_token < 0:
                            continue
                        weight = value(bits(weights[channel * kernel + tap] * scale))
                        product = value(bits(x[source_token * channels + channel] * weight))
                        total = value(bits(total + product))
                    y.append(bits(total))
            expected.append(y)
            stream.write(f"{case} {nt} {channels} {kernel}\n")
            for word in [bits(v) for v in x] + [v & 255 for v in weights] + scales:
                stream.write(f"{word:08x}\n")
    (directory / "causal_conv-expected.json").write_text(json.dumps(expected))


def check(directory: Path):
    expected = json.loads((directory / "causal_conv-expected.json").read_text())
    seen = set()
    for line in (directory / "causal_conv-results.txt").read_text().splitlines():
        case, index, word = line.split()
        case, index, word = int(case), int(index), int(word, 16)
        if (case, index) in seen or expected[case][index] != word:
            raise ValueError(f"Convolution mismatch: {line}, expected {expected[case][index]:08x}")
        seen.add((case, index))
    if len(seen) != sum(map(len, expected)):
        raise ValueError("Missing outputs")
    print(f"PASS causal convolution: {len(expected)} cases, {len(seen)} bit-exact outputs")


if __name__ == "__main__":
    (generate if sys.argv[1] == "generate" else check)(Path(sys.argv[2]))
