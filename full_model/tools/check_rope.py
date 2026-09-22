"""Independent rounded FP32 reference for full and partial rotary embeddings."""
import json
import math
import random
import sys
from pathlib import Path

from make_fp32_vectors import bits, value


def generate(directory: Path):
    directory.mkdir(parents=True,exist_ok=True)
    rng=random.Random(723)
    expected=[]
    with (directory/"rope.txt").open("w") as stream:
        for case,(nt,heads,dim,rot) in enumerate([(2,2,8,4),(2,3,64,64),(2,1,256,64)]):
            x=[value(bits(rng.uniform(-3,3))) for _ in range(nt*heads*dim)]
            angles=[rng.uniform(-math.pi,math.pi) for _ in range(nt*rot)]
            cos=[value(bits(math.cos(a))) for a in angles]
            sin=[value(bits(math.sin(a))) for a in angles]
            y=[]
            for t in range(nt):
                for h in range(heads):
                    for d in range(dim):
                        i=(t*heads+h)*dim+d
                        if d>=rot:y.append(x[i]);continue
                        partner=x[i+rot//2] if d<rot//2 else x[i-rot//2]
                        if d<rot//2:partner=-partner
                        left=value(bits(x[i]*cos[t*rot+d]))
                        right=value(bits(partner*sin[t*rot+d]))
                        y.append(value(bits(left+right)))
            expected.append([bits(v) for v in y])
            stream.write(f"{case} {nt} {heads} {dim} {rot}\n")
            for val in x+cos+sin:stream.write(f"{bits(val):08x}\n")
    (directory/"rope-expected.json").write_text(json.dumps(expected))


def check(directory: Path):
    expected=json.loads((directory/"rope-expected.json").read_text())
    seen=set()
    for line in (directory/"rope-results.txt").read_text().splitlines():
        case,index,word=line.split()
        case,index,word=int(case),int(index),int(word,16)
        if (case,index) in seen or expected[case][index]!=word:
            raise ValueError(f"Rotary mismatch: {line}")
        seen.add((case,index))
    if len(seen)!=sum(map(len,expected)):raise ValueError("Missing outputs")
    print(f"PASS full/partial rotary embedding: {len(expected)} cases, {len(seen)} bit-exact outputs")


if __name__=="__main__":
    (generate if sys.argv[1]=="generate" else check)(Path(sys.argv[2]))
