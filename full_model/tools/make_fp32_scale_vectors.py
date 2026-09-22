"""Independent power-of-two scaling references for the registered ALU."""
import math
import random
import sys
from pathlib import Path

from make_fp32_vectors import bits, value


rng=random.Random(445)
words=[0,0x80000000,1,0x007fffff,0x00800000,0x3f800000,0x7f7fffff,0xff7fffff]
words += [rng.getrandbits(32) for _ in range(1000)]
with Path(sys.argv[1]).open("w") as stream:
    for word in words:
        if not math.isfinite(value(word)):
            continue
        for exponent in (-300,-150,-149,-127,-126,-1,0,1,126,127,149,300):
            result=bits(math.ldexp(value(word),exponent))
            stream.write(f"2 {word:08x} {exponent&0xffffffff:08x} {result:08x}\n")
