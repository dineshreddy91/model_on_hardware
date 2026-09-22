"""Independent binary64 reference, then IEEE binary32 rounding for RTL tests."""
import random
import struct
import sys
from pathlib import Path


def main():
    destination = Path(sys.argv[1])
    randomizer = random.Random(20260922)
    edges = [0, 1, -1, 127, -128, 16777217, 16777219, 2147483647, -2147483648]
    count = 0
    with destination.open("w") as stream:
        for scale_bits in range(65536):
            scale = struct.unpack("<e", struct.pack("<H", scale_bits))[0]
            for accumulator in (*edges, randomizer.randint(-2147483648, 2147483647)):
                invalid = (scale_bits >> 10) & 31 == 31
                # Finite products have <=42 significant bits, exactly representable
                # in binary64, so packing binary32 performs the only rounding.
                expected = 0 if invalid else struct.unpack("<I", struct.pack("<f", accumulator * scale))[0]
                stream.write(f"{accumulator & 0xffffffff:08x} {scale_bits:04x} {expected:08x} {int(invalid)}\n")
                count += 1
    print(f"Generated {count} independently rounded conversion vectors")


if __name__ == "__main__":
    main()
