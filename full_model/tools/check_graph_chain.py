"""Independent numerical check of the real two-engine simulation."""
import math
import sys
from pathlib import Path

from check_attention_delta import AttentionDeltaFixtures
from make_fp32_vectors import value

q, k, v = [1., 0., 0., 1.], [.5, 1., -.5, .25], [.25, -.5, 1., .5]
attention = []
for row in range(2):
    scores = [sum(q[2*row+d]*k[2*j+d] for d in range(2))/math.sqrt(2) for j in range(2)]
    weights = [math.exp(s-max(scores)) for s in scores]
    attention.extend(sum(w*v[2*j+d] for j, w in enumerate(weights))/sum(weights) for d in range(2))
output, state = AttentionDeltaFixtures.delta_reference(attention, k, v, [-.25]*2, [.5]*2, [0.]*4, 2, 2, 2)
expected = {(0, 0): attention, (1, 0): output, (1, 1): state}
seen = set()
errors = []
for line in Path(sys.argv[1]).read_text().splitlines():
    stage, kind, index, word = line.split()
    key = int(stage), int(kind)
    index = int(index)
    identity = key, index
    if identity in seen:
        raise ValueError("Duplicate output")
    seen.add(identity)
    actual, reference = value(int(word, 16)), expected[key][index]
    error = abs(actual-reference)
    if not math.isfinite(actual) or error > 2e-5:
        raise ValueError(f"Numerical mismatch: {identity}, {actual}, {reference}")
    errors.append(error)
if len(seen) != 12:
    raise ValueError("Missing outputs")
print(f"PASS graph chain numerical comparison: 12 values; max abs error {max(errors):.9g}")
