"""Independent binary64 equations for attention and gated-delta RTL fixtures."""
import json
import math
import random
import sys
from pathlib import Path

from make_fp32_vectors import bits, value


class AttentionDeltaFixtures:
    def __init__(self, directory: Path):
        self.directory = directory
        self.rng = random.Random(29841)

    def samples(self, count: int, scale: float = 1.0) -> list[float]:
        return [value(bits(self.rng.uniform(-scale, scale))) for _ in range(count)]

    def attention(self) -> None:
        cases = []
        geometries = [(1, 1, 1, 0, 0, 0), (3, 5, 3, 0, 0, 1),
                      (4, 4, 8, 0, 1, 0), (2, 6, 5, 4, 1, 1),
                      (2, 3, 64, 0, 0, 0), (2, 3, 256, 1, 1, 1)]
        with (self.directory / "attention.txt").open("w") as stream:
            for nq, nk, dim, offset, causal, masked in geometries:
                for variant in range(3):
                    q = self.samples(nq * dim, 12 if variant == 2 else 1)
                    k = self.samples(nk * dim, 12 if variant == 2 else 1)
                    v = self.samples(nk * dim)
                    if variant == 1:
                        q = [0.0] * len(q)
                    mask = [int(i % 3 != 1) for i in range(nk)]
                    outputs = []
                    for row in range(nq):
                        keys = [j for j in range(nk) if (not causal or j <= offset + row)
                                and (not masked or mask[j])]
                        scores = [math.fsum(q[row * dim + d] * k[j * dim + d]
                                            for d in range(dim)) / math.sqrt(dim) for j in keys]
                        weights = [math.exp(x - max(scores)) for x in scores]
                        denominator = math.fsum(weights)
                        outputs.extend(math.fsum(w * v[j * dim + d] for w, j in zip(weights, keys)) / denominator
                                       for d in range(dim))
                    case_id = len(cases)
                    cases.append({"expected": outputs, "dim": dim, "causal": causal, "masked": masked})
                    stream.write(f"{case_id} {nq} {nk} {dim} {offset} {causal} {masked}\n")
                    for x in q + k + v:
                        stream.write(f"{bits(x):08x}\n")
                    for x in mask:
                        stream.write(f"{x:08x}\n")
        (self.directory / "attention.json").write_text(json.dumps(cases))

    @staticmethod
    def delta_reference(q: list[float], k: list[float], v: list[float], g: list[float],
                        beta: list[float], initial: list[float], nt: int, kd: int, vd: int) -> tuple[list[float], list[float]]:
        state = list(initial)
        outputs = []
        for t in range(nt):
            qt, kt = q[t * kd:(t + 1) * kd], k[t * kd:(t + 1) * kd]
            qnorm = math.sqrt(math.fsum(x*x for x in qt) + value(bits(1e-6))) * math.sqrt(kd)
            knorm = math.sqrt(math.fsum(x*x for x in kt) + value(bits(1e-6)))
            qt, kt = [x / qnorm for x in qt], [x / knorm for x in kt]
            state = [x * math.exp(g[t]) for x in state]
            prediction = [math.fsum(state[i * vd + j] * kt[i] for i in range(kd)) for j in range(vd)]
            delta = [(v[t * vd + j] - prediction[j]) * beta[t] for j in range(vd)]
            state = [state[i * vd + j] + kt[i] * delta[j] for i in range(kd) for j in range(vd)]
            outputs.extend(math.fsum(state[i * vd + j] * qt[i] for i in range(kd)) for j in range(vd))
        return outputs, state

    def delta(self) -> None:
        cases = []
        previous_state = []
        geometries = [(3, 1, 1, 0), (4, 3, 2, 1), (2, 3, 2, 2),
                      (3, 8, 5, 0), (2, 128, 4, 1), (2, 128, 128, 0)]
        with (self.directory / "delta.txt").open("w") as stream:
            for nt, kd, vd, initial_mode in geometries:
                q, k, v = self.samples(nt * kd), self.samples(nt * kd), self.samples(nt * vd)
                g = [value(bits(-0.2 * (i + 1))) for i in range(nt)]
                beta = [value(bits((i % 3) / 2)) for i in range(nt)]
                initial = previous_state if initial_mode == 2 else self.samples(kd * vd)
                if initial_mode == 0:
                    initial = [0.0] * (kd * vd)
                output, final_state = self.delta_reference(q, k, v, g, beta, initial, nt, kd, vd)
                case_id = len(cases)
                cases.append({"expected": output, "state": final_state, "key_dim": kd,
                              "value_dim": vd, "initial_mode": initial_mode})
                previous_state = final_state
                stream.write(f"{case_id} {nt} {kd} {vd} {initial_mode}\n")
                for x in q + k + v + initial + g + beta:
                    stream.write(f"{bits(x):08x}\n")
            # Zero keys and queries must preserve a decayed state and output zero.
            nt, kd, vd = 2, 3, 2
            q = k = [0.0] * (nt * kd)
            v, initial = self.samples(nt * vd), self.samples(kd * vd)
            g, beta = [0.0, -104.0], [1.0, 1.0]
            output, final_state = self.delta_reference(q, k, v, g, beta, initial, nt, kd, vd)
            case_id = len(cases)
            cases.append({"expected": output, "state": final_state, "key_dim": kd,
                          "value_dim": vd, "initial_mode": 1})
            stream.write(f"{case_id} {nt} {kd} {vd} 1\n")
            for x in q + k + v + initial + g + beta:
                stream.write(f"{bits(x):08x}\n")
        (self.directory / "delta.json").write_text(json.dumps(cases))

    def generate(self) -> None:
        self.directory.mkdir(parents=True, exist_ok=True)
        self.attention()
        self.delta()

    def check(self, name: str) -> None:
        expected = json.loads((self.directory / f"{name}.json").read_text())
        actual = {}
        for line in (self.directory / f"{name}-results.txt").read_text().splitlines():
            case_id, kind, index, raw = line.split()
            key = (int(case_id), int(kind), int(index))
            if key in actual:
                raise AssertionError(f"Duplicate result {key}")
            actual[key] = value(int(raw, 16))
        count, maximum = 0, 0.0
        for case_id, case in enumerate(expected):
            for kind, field in ((0, "expected"), (1, "state")):
                for index, reference in enumerate(case.get(field, [])):
                    observed = actual.pop((case_id, kind, index))
                    error = abs(observed - reference)
                    if not math.isfinite(observed) or error > 2e-4 * max(1, abs(reference)):
                        raise AssertionError(f"{name} case={case_id} kind={kind} index={index}: got {observed}, expected {reference}")
                    maximum = max(maximum, error)
                    count += 1
        if actual:
            raise AssertionError("Unexpected output indices")
        print(f"PASS {name} numerical reference: {len(expected)} commands, {count} values, max absolute error {maximum:.9g}")


if __name__ == "__main__":
    fixtures = AttentionDeltaFixtures(Path(sys.argv[2]))
    if sys.argv[1] == "generate":
        fixtures.generate()
    else:
        fixtures.check(sys.argv[1])
