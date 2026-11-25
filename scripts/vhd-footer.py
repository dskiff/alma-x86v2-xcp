#!/usr/bin/env python3
"""Give a VHD fixed footer fields, so that the same disk makes the same file.

Usage: vhd-footer.py <file.vhd> <epoch> <image>

qemu-img writes the time of conversion and a random unique ID into the VHD
footer. This sets the time to <epoch> and the ID to one derived from <image>,
and updates the footer's checksum. A dynamic VHD (qemu's default) holds the
footer twice, at the start and at the end; both are rewritten and must match.
"""

import hashlib
import struct
import sys

FOOTER = 512
VHD_EPOCH = 946684800  # 2000-01-01T00:00:00Z, the VHD format's zero time
TIMESTAMP = slice(24, 28)
CHECKSUM = slice(64, 68)
UNIQUE_ID = slice(68, 84)


def fix(footer: bytes, timestamp: int, unique_id: bytes) -> bytes:
    if footer[:8] != b"conectix":
        sys.exit("not a VHD footer (no 'conectix' cookie)")
    f = bytearray(footer)
    f[TIMESTAMP] = struct.pack(">I", timestamp)
    f[UNIQUE_ID] = unique_id
    f[CHECKSUM] = b"\0\0\0\0"
    f[CHECKSUM] = struct.pack(">I", ~sum(f) & 0xFFFFFFFF)
    return bytes(f)


def main() -> None:
    if len(sys.argv) != 4:
        sys.exit("Usage: vhd-footer.py <file.vhd> <epoch> <image>")
    path, epoch, image = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    timestamp = max(epoch - VHD_EPOCH, 0)
    unique_id = hashlib.sha256(f"{image}-vhd".encode()).digest()[:16]

    with open(path, "r+b") as f:
        f.seek(-FOOTER, 2)
        end = f.tell()
        tail = fix(f.read(FOOTER), timestamp, unique_id)
        f.seek(0)
        head = f.read(FOOTER)
        dynamic = head[:8] == b"conectix"
        if dynamic:
            head = fix(head, timestamp, unique_id)
            if head != tail:
                sys.exit("the VHD's two footers differ")
            f.seek(0)
            f.write(head)
        f.seek(end)
        f.write(tail)
    kind = "dynamic" if dynamic else "fixed"
    print(f"{path}: {kind} VHD footer set to time {epoch} and ID {unique_id.hex()}")


if __name__ == "__main__":
    main()
