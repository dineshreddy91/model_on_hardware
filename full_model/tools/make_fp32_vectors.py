"""Independent finite FP32 references including cancellation and subnormals."""
import math
import random
import struct
import sys
from pathlib import Path


def value(bits: int) -> float:
    return struct.unpack("<f", struct.pack("<I", bits))[0]


def bits(number: float) -> int:
    try:
        return struct.unpack("<I", struct.pack("<f", number))[0]
    except OverflowError:
        return 0xFF800000 if number < 0 else 0x7F800000


def main() -> None:
    randomizer = random.Random(1701)
    edge = [0, 1, 2, 0x7FFFFF, 0x800000, 0x800001, 0x3F000000,
            0x3F800000, 0x3F800001, 0x33800000, 0x33000000, 0x7F7FFFFF]
    edge += [x | 0x80000000 for x in edge]
    pairs = [(a, b) for a in edge for b in edge]
    for _ in range(30000):
        a, b = randomizer.getrandbits(32), randomizer.getrandbits(32)
        if math.isfinite(value(a)) and math.isfinite(value(b)):
            pairs.append((a, b))
            pairs.append((a, a ^ 0x80000000))
    with Path(sys.argv[1]).open("w") as stream:
        for a, b in pairs:
            # Binary64 exactly represents every binary32 product. For addition,
            # any binary64 rounding of distant exponents cannot affect FP32 RNE.
            for op, result in enumerate((value(a) + value(b), value(a) * value(b))):
                stream.write(f"{op} {a:08x} {b:08x} {bits(result):08x}\n")


if __name__ == "__main__":
    main()
