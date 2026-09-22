"""Multihead numerical fixtures with independent grouped-query and delta references."""
import json
import math
import random
import struct
import sys
from pathlib import Path

from check_attention_delta import AttentionDeltaFixtures
from make_fp32_vectors import bits, value


def generate(directory: Path):
    directory.mkdir(parents=True, exist_ok=True)
    rng = random.Random(841)
    expected = {}
    with (directory / "heads.txt").open("w") as stream:
        for case, (nt, nk, kd, vd, heads, kv) in enumerate([(2, 2, 2, 2, 4, 2), (3, 3, 2, 4, 3, 3)]):
            samples = lambda n: [value(bits(rng.uniform(-1, 1))) for _ in range(n)]
            q, k, v = samples(nt*heads*kd), samples(nk*kv*kd), samples(nk*kv*vd)
            g = [value(bits(-.1*(i+1))) for i in range(nt*heads)]
            beta = [value(bits(.2+(i%3)*.3)) for i in range(nt*heads)]
            inputs = [q, k, v, g, beta] if case else [q, k, v, [1, 1]]
            words = [23 if case else 22, case, 5, 6 if case else 0xffffffff,
                     0, 1, 2, 3, 4 if case else 0xffffffff, 0xffffffff]
            words[0] |= 3 << 8
            words += [nt, heads, kd, vd, 0] if case else [nt, nk, kd, heads, kv]
            checksum = 0x4f4a5031
            for word in words:
                checksum ^= word
            words.append(checksum)
            stream.write(f"{case} {struct.pack('<16I',*words)[::-1].hex()} {sum(len(x) for x in inputs)}\n")
            for tensor, data in enumerate(inputs):
                for index, datum in enumerate(data):
                    encoded = int(datum) if case == 0 and tensor == 3 else bits(datum)
                    stream.write(f"{tensor*1024+index} {encoded:08x}\n")
            case_expected = {}
            for head in range(heads):
                kh = head//(heads//kv)
                if case:
                    qh = [q[(t*heads+head)*kd+d] for t in range(nt) for d in range(kd)]
                    khs = [k[(t*heads+head)*kd+d] for t in range(nt) for d in range(kd)]
                    vh = [v[(t*heads+head)*vd+d] for t in range(nt) for d in range(vd)]
                    gh = [g[t*heads+head] for t in range(nt)]
                    bh = [beta[t*heads+head] for t in range(nt)]
                    result, state = AttentionDeltaFixtures.delta_reference(qh,khs,vh,gh,bh,[0.]*(kd*vd),nt,kd,vd)
                    for i,x in enumerate(state):
                        case_expected[str(6*1024+head*kd*vd+i)] = x
                else:
                    result=[]
                    for t in range(nt):
                        scores=[sum(q[(t*heads+head)*kd+d]*k[(j*kv+kh)*kd+d] for d in range(kd))/math.sqrt(kd) for j in range(t+1)]
                        weights=[math.exp(s-max(scores)) for s in scores]
                        result.extend(sum(weights[j]*v[(j*kv+kh)*vd+d] for j in range(t+1))/sum(weights) for d in range(vd))
                for t in range(nt):
                    for d in range(vd):
                        case_expected[str(5*1024+(t*heads+head)*vd+d)] = result[t*vd+d]
            expected[str(case)] = case_expected
    (directory / "heads-expected.json").write_text(json.dumps(expected))


def check(directory: Path):
    expected = json.loads((directory / "heads-expected.json").read_text())
    seen = set()
    errors=[]
    for line in (directory / "heads-results.txt").read_text().splitlines():
        case,address,word=line.split()
        key=case,address
        if key in seen:
            raise ValueError("Duplicate write")
        seen.add(key)
        result=value(int(word,16))
        reference=expected[case][address]
        error=abs(result-reference)
        if not math.isfinite(result) or error>2e-5:
            raise ValueError(f"Head mapping/numerical failure: {line}, expected {reference}")
        errors.append(error)
    if len(seen)!=sum(len(v) for v in expected.values()):
        raise ValueError("Missing writes")
    print(f"PASS multihead numerical mapping: {len(seen)} committed outputs/state values; max abs error {max(errors):.9g}")


if __name__ == "__main__":
    (generate if sys.argv[1]=="generate" else check)(Path(sys.argv[2]))
