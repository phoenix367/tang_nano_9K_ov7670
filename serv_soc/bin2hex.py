#!/usr/bin/env python3
"""Convert a raw firmware .bin into the 32-bit-word hex `servant_ram` loads via
$readmemh (one little-endian word per line, 8 hex digits) -- identical output to
SERV's sw/makehex.py but writing to an explicit output path (so the CMake custom
command needs no shell redirection). Usage: bin2hex.py <in.bin> <out.hex>"""
import sys

data = open(sys.argv[1], "rb").read()
data += b"\x00" * ((-len(data)) % 4)          # pad to a whole word
with open(sys.argv[2], "w") as f:
    for i in range(0, len(data), 4):
        word = data[i] | (data[i + 1] << 8) | (data[i + 2] << 16) | (data[i + 3] << 24)
        f.write("%08X\n" % word)
