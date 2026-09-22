"""Float64 division reference for row quantization; FP32 stored scale contract."""
import json
import math
import random
import sys
from pathlib import Path

from make_fp32_vectors import bits, value


def generate(directory: Path):
    directory.mkdir(parents=True, exist_ok=True)
    rng=random.Random(772)
    rows=[[0.]*8,[-127.,-.5,.5,1.5,2.5,126.5,127.],
          [value(1),-value(1),value(0x007fffff)],[-3e38,3e38,1e30]]
    rows += [[rng.uniform(-3,3) for _ in range(n)] for n in (1,64,1024,3072,3584,4096)]
    # A unit-scale row exercises both neighbors of every supported half-integer.
    boundaries = [-127., 127.]
    for integer in range(-127, 127):
        word = bits(integer + 0.5)
        boundaries.extend(value(neighbor) for neighbor in (word - 1, word, word + 1))
    rows.append(boundaries)
    expected=[]
    with (directory/"quantize.txt").open("w") as stream:
        for row_id,row in enumerate(rows):
            row=[value(bits(x)) for x in row]
            maximum=max(abs(x) for x in row)
            scale=max(value(bits(maximum*value(0x3c010204))),value(0x00800000)) if maximum else 1.
            quantized=[max(-127,min(127,round(x/scale))) for x in row]
            expected.append({"scale":scale,"quantized":quantized})
            stream.write(f"{row_id} {len(row)}\n")
            for x in row:stream.write(f"{bits(x):08x}\n")
    (directory/"quantize-expected.json").write_text(json.dumps(expected))


def check(directory: Path):
    expected=json.loads((directory/"quantize-expected.json").read_text())
    seen=set()
    for line in (directory/"quantize-results.txt").read_text().splitlines():
        row,scale,index,word=line.split()
        row,scale,index,word=int(row),int(scale),int(index),int(word,16)
        key=row,scale,index
        if key in seen:raise ValueError("Duplicate output")
        seen.add(key)
        if scale:
            if index or value(word)!=expected[row]["scale"]:raise ValueError("Scale mismatch")
        else:
            observed=word if word<128 else word-256
            if observed!=expected[row]["quantized"][index]:
                raise ValueError(f"Quantization mismatch: {line}, expected {expected[row]['quantized'][index]}")
    count=sum(len(r["quantized"])+1 for r in expected)
    if len(seen)!=count:raise ValueError("Missing values")
    print(f"PASS row quantization: {len(expected)} rows, {count} exact scales/INT8 outputs")


if __name__=="__main__":
    (generate if sys.argv[1]=="generate" else check)(Path(sys.argv[2]))
