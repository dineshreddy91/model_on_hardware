"""Independent math.erfc/log1p references for missing merger and decay operations."""
import math
import random
import sys
from pathlib import Path

from make_fp32_vectors import bits, value


def generate(path: Path):
    rng = random.Random(194)
    inputs = [-104., -88., -32., -16., -12., -8., -1., -1e-12, -0., 0., 1e-12,
              1., 8., 12., 16., 32., 88., 104., 1e30, -1e30]
    inputs += [rng.uniform(-16, 16) for _ in range(300)]
    with path.open("w") as stream:
        for op in (0, 1):
            for x in inputs:
                stream.write(f"{op} {bits(x):08x}\n")
            for word in (0x7f800000, 0xff800000, 0x7fc00000):
                stream.write(f"{op} {word:08x}\n")


def check(path: Path):
    count = 0
    maximum = [0., 0.]
    for line in path.read_text().splitlines():
        op, xword, yword, error = line.split()
        op, x, y = int(op), value(int(xword, 16)), value(int(yword, 16))
        if not math.isfinite(x):
            if int(error) != 1 or y != 0:
                raise ValueError("Nonfinite input accepted")
        else:
            expected = max(x, 0.) + math.log1p(math.exp(-abs(x))) if op == 0 else .5*x*math.erfc(-x/math.sqrt(2))
            if int(error) or not math.isfinite(y) or abs(y-expected)>2e-6*max(1., abs(expected)):
                raise ValueError(f"Mismatch: {line}; expected {expected}")
            maximum[op] = max(maximum[op], abs(y-expected)/max(1., abs(expected)))
        count += 1
    if count != 646:
        raise ValueError(f"Missing results: {count}")
    print(f"PASS special activations: {count} values; max scaled errors {maximum}; tolerance 2e-6")


if __name__ == "__main__":
    (generate if sys.argv[1] == "generate" else check)(Path(sys.argv[2]))
