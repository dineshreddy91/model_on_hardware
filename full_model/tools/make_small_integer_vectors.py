"""Exact binary32 encodings of every bounded integer conversion input."""
import sys
from pathlib import Path

from make_fp32_vectors import bits

with Path(sys.argv[1]).open("w") as stream:
    for x in range(8192):
        stream.write(f"0 {x:08x} {bits(float(x)):08x}\n")
    for x in range(-512,512):
        stream.write(f"1 {x&1023:08x} {bits(float(x)):08x}\n")
