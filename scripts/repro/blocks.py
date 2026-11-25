#!/usr/bin/env python3
"""Print a digest of every 4 KiB block of a device or file, one per line.

Usage: blocks.py <device>

Each line is the block's 8-byte BLAKE2b digest in hex, or "0" for an
all-zero block, so two builds can be compared block by block, and a block's
line number times 4096 is its offset.
"""

import hashlib
import sys

BLOCK = 4096
CHUNK = 256 * BLOCK
ZERO = bytes(BLOCK)


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("Usage: blocks.py <device>")
    out = sys.stdout
    with open(sys.argv[1], "rb", buffering=0) as f:
        while True:
            chunk = f.read(CHUNK)
            if not chunk:
                break
            for i in range(0, len(chunk), BLOCK):
                block = chunk[i : i + BLOCK]
                if block == ZERO[: len(block)]:
                    out.write("0\n")
                else:
                    out.write(hashlib.blake2b(block, digest_size=8).hexdigest() + "\n")


if __name__ == "__main__":
    main()
