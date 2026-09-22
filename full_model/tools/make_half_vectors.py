"""Independent binary16 to binary32 vectors, including every finite encoding."""
import struct
import sys
from pathlib import Path


if __name__ == '__main__':
    with Path(sys.argv[1]).open('w') as stream:
        for bits in range(65536):
            if (bits >> 10) & 31 == 31:
                continue
            value = struct.unpack('<e', struct.pack('<H', bits))[0]
            expected = struct.unpack('<I', struct.pack('<f', value))[0]
            stream.write(f'{bits:04x} {expected:08x}\n')
