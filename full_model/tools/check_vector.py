"""Vector references use independent Python math, never RTL-derived output."""
import json
import math
import random
import sys
from pathlib import Path

from check_scalar import reference
from make_fp32_vectors import bits, value


def generate(path: Path, include_bank_boundaries: bool = False) -> None:
    rng = random.Random(814)
    expected = []
    with path.open("w") as stream:
        for op in range(11):
            for length in (1, 3, 16, 64):
                for kind in range(3):
                    a = [rng.uniform(-4, 4) for _ in range(length)]
                    if kind == 1:
                        a = [2.0] * length
                    if kind == 2:
                        a = [1000 + rng.uniform(-2, 2) for _ in range(length)]
                    if op in (2, 3, 4):
                        a = [abs(x) % 10 + 0.1 for x in a]
                    a = [value(bits(x)) for x in a]
                    b = [value(bits(rng.uniform(0.5, 1.5))) for _ in a]
                    c = [value(bits(rng.uniform(-0.5, 0.5))) for _ in a]
                    eps = value(bits(1e-6))
                    if op < 8:
                        output = [reference(op, x, y) for x, y in zip(a, b)]
                    elif op in (8, 9):
                        mean = math.fsum(a) / length if op == 9 else 0
                        variance = math.fsum((x - mean)**2 for x in a) / length
                        output = [(x - mean) / math.sqrt(variance + eps) * gamma + (beta if op == 9 else 0)
                                  for x, gamma, beta in zip(a, b, c)]
                    else:
                        exponentials = [math.exp(x - max(a)) for x in a]
                        output = [x / math.fsum(exponentials) for x in exponentials]
                    case_id = len(expected)
                    expected.append({"op": op, "length": length, "expected": output})
                    stream.write(f"{case_id} {op:x} {length} {bits(eps):08x}\n")
                    for x, y, z in zip(a, b, c):
                        stream.write(f"{bits(x):08x} {bits(y):08x} {bits(z):08x}\n")
        if include_bank_boundaries:
            for length in (2057, 4096):
                case_id = len(expected)
                values = [float(i % 7 - 3) for i in range(length)]
                stream.write(f"{case_id} 0 {length} {bits(1e-5):08x}\n")
                for x in values:
                    stream.write(f"{bits(x):08x} {bits(1.25):08x} 00000000\n")
                expected.append({"op": 0, "length": length, "expected": [x + 1.25 for x in values]})
    path.with_suffix(".json").write_text(json.dumps(expected))


def check(input_path: Path, results_path: Path) -> None:
    cases = json.loads(input_path.with_suffix(".json").read_text())
    results = {}
    for line in results_path.read_text().splitlines():
        case_id, index, actual = line.split()
        key = (int(case_id), int(index))
        if key in results:
            raise AssertionError(f"Duplicate result: {key}")
        results[key] = value(int(actual, 16))
    maximum_absolute = [0.0] * 11
    for case_id, case in enumerate(cases):
        for index, expected in enumerate(case["expected"]):
            actual = results.pop((case_id, index))
            # FP32 sequential reductions incur cancellation error when inputs
            # share a large offset (tested at 1000); final-model error gates
            # require checkpoint/image-specific tolerances before deployment.
            tolerance = 0.001 if case["op"] == 9 else 2e-5 * max(1, abs(expected))
            if not math.isfinite(actual) or abs(actual - expected) > tolerance:
                raise AssertionError(f"case={case_id}, op={case['op']}, index={index}, expected={expected}, actual={actual}")
            maximum_absolute[case["op"]] = max(maximum_absolute[case["op"]], abs(actual - expected))
    if results:
        raise AssertionError("Unexpected outputs")
    print(f"PASS vector numerical references: {len(cases)} vectors, {sum(c['length'] for c in cases)} outputs")
    print(f"Maximum absolute error by opcode: {maximum_absolute}")


if __name__ == "__main__":
    if sys.argv[1] in ("generate", "generate-hbm"):
        generate(Path(sys.argv[2]), include_bank_boundaries=sys.argv[1] == "generate-hbm")
    else:
        check(Path(sys.argv[2]), Path(sys.argv[3]))
