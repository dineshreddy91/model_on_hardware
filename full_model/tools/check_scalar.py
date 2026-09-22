"""Generate scalar RTL fixtures or check results against independent math functions."""
import math
import random
import sys
from pathlib import Path

from make_fp32_vectors import bits, value


def reference(op: int, a: float, b: float) -> float | None:
    if not math.isfinite(a) or (op < 2 and not math.isfinite(b)) or op > 7:
        return None
    if op == 0:
        return a + b
    if op == 1:
        return a * b
    if op == 2:
        return None if a > 88 else math.exp(a)
    if op == 3:
        return None if a == 0 else 1 / a
    if op == 4:
        return None if a <= 0 else 1 / math.sqrt(a)
    if op == 7:
        argument = 2 * math.sqrt(2 / math.pi) * (a + 0.044715 * a**3)
    else:
        argument = a
    exponential = math.exp(-abs(argument))
    sigmoid = (exponential if argument < 0 else 1) / (1 + exponential)
    return sigmoid if op == 5 else a * sigmoid


def generate(path: Path) -> None:
    rng = random.Random(814)
    with path.open("w") as stream:
        for op in range(8):
            inputs = [-104, -100, -88, -20, -10, -2, -1, -0.0, 0.0,
                      1e-30, 0.125, 0.5, 1, 2, 10, 20, 80, 88, 89]
            inputs += [rng.uniform(-20, 20) for _ in range(50)]
            inputs += [value(x) for x in (1, 0x7FFFFF, 0x800000, 0x7F7FFFFF,
                                          0x7F800000, 0x7FC00000)]
            broad_inputs = []
            while len(broad_inputs) < 50:
                candidate = value(rng.getrandbits(32))
                if math.isfinite(candidate):
                    broad_inputs.append(candidate)
            inputs += broad_inputs
            for a in inputs:
                stream.write(f"{op:x} {bits(a):08x} {bits(0.75):08x}\n")
        stream.write("f 3f800000 00000000\n")


def check(path: Path) -> None:
    count = 0
    maximum = [0.0] * 8
    underflow_floor_cases = 0
    for line in path.read_text().splitlines():
        op, a, b, actual, error = [int(x, 16) for x in line.split()]
        expected = reference(op, value(a), value(b))
        invalid = expected is None or not math.isfinite(value(bits(expected)))
        if bool(error) != invalid:
            raise AssertionError(f"Error flag: {line}, expected={expected}")
        if invalid:
            if actual != 0:
                raise AssertionError(f"Invalid result must be zero: {line}")
        else:
            expected = value(bits(expected))
            observed = value(actual)
            # Composite activations can underflow their exponential before
            # multiplying by x; allow a floor below normal model magnitudes.
            # GELU composes several rounded FP32 products before exp. In
            # its negative tail, an argument ULP is magnified into relative
            # output error even though absolute error is tiny (~1e-33).
            relative_budget = 2e-5 if op == 7 else 4e-6
            tolerance = max(relative_budget * abs(expected), 1e-37)
            if abs(observed - expected) > tolerance:
                raise AssertionError(f"Numeric mismatch: {line}, expected={expected}, got={observed}")
            if abs(expected) < 1e-37 and observed != expected:
                underflow_floor_cases += 1
            if abs(expected) >= 1e-37:
                maximum[op] = max(maximum[op], abs((observed - expected) / expected))
        count += 1
    if count != 1001:
        raise AssertionError(f"Missing results: {count}")
    print(f"PASS scalar numerical references: {count} cases; max relative errors above 1e-37 {maximum}; underflow-floor cases {underflow_floor_cases}")


if __name__ == "__main__":
    (generate if sys.argv[1] == "generate" else check)(Path(sys.argv[2]))
