#!/usr/bin/env python3
"""Set every install time in an RPM database to a fixed time.
Usage: rpmdb-times.py <rpmdb.sqlite> <epoch>

rpm records when it installed each package (RPMTAG_INSTALLTIME) and in which
transaction (RPMTAG_INSTALLTID, the transaction's start time), in the header
it stores for the package and in the Installtid index. Two builds of the same
packages differ only there. This rewrites both to <epoch>, in place, then
vacuums the database so that its pages are laid out from its content alone.

The tags sit outside each header's signed region, which `rpm -V` and the
header digests cover, so the headers still verify.

normalize.sh runs this on the finished disk, with the image's own rpmdb.
"""

import sqlite3
import struct
import sys

RPMTAG_INSTALLTIME = 1008
RPMTAG_INSTALLTID = 1128
RPM_INT32_TYPE = 4


def patch(blob, epoch):
    """The header blob with both tags set to epoch, and how many it set."""
    blob = bytearray(blob)
    il, dl = struct.unpack_from(">II", blob, 0)
    data = 8 + 16 * il
    if data + dl != len(blob):
        raise ValueError(f"header of {len(blob)} bytes says {il} entries and {dl} bytes of data")
    found = 0
    for i in range(il):
        tag, typ, offset, count = struct.unpack_from(">IIiI", blob, 8 + 16 * i)
        if tag in (RPMTAG_INSTALLTIME, RPMTAG_INSTALLTID):
            if typ != RPM_INT32_TYPE or count != 1:
                raise ValueError(f"tag {tag} has type {typ} and count {count}")
            struct.pack_into(">I", blob, data + offset, epoch)
            found += 1
    return bytes(blob), found


def main():
    if len(sys.argv) != 3 or not sys.argv[2].isdigit():
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    path, epoch = sys.argv[1], int(sys.argv[2])
    db = sqlite3.connect(path, isolation_level=None)
    db.execute("BEGIN")
    headers = 0
    for hnum, blob in db.execute("SELECT hnum, blob FROM Packages").fetchall():
        new, found = patch(blob, epoch)
        if found != 2:
            raise SystemExit(f"{path}: package {hnum} has {found} of the 2 install-time tags")
        db.execute("UPDATE Packages SET blob = ? WHERE hnum = ?", (new, hnum))
        headers += 1
    # Index keys of integer tags are the value in the host's byte order;
    # rpm on x86 is little-endian.
    tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
    if "Installtid" in tables:
        db.execute("UPDATE Installtid SET key = ?", (struct.pack("<I", epoch),))
    db.execute("COMMIT")
    db.execute("VACUUM")
    db.close()
    print(f"{path}: install times of {headers} packages set to {epoch}")


if __name__ == "__main__":
    main()
