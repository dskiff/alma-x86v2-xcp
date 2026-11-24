#!/usr/bin/env python3
"""Print one JSON line per path under a mounted filesystem, sorted by path.

Usage: manifest.py <mount point>

Each line has the path (relative, "." for the root), its type, mode, owner,
link count, size, content digest (regular files), link target (symlinks) or
device number (device nodes), its extended attributes (SELinux labels among
them) and its mtime in nanoseconds. compare.py treats mtime separately from
the rest, so that "same content, different timestamps" shows as such.
"""

import hashlib
import json
import os
import stat
import sys


def kind(mode: int) -> str:
    for test, name in (
        (stat.S_ISREG, "file"),
        (stat.S_ISDIR, "dir"),
        (stat.S_ISLNK, "link"),
        (stat.S_ISCHR, "chr"),
        (stat.S_ISBLK, "blk"),
        (stat.S_ISFIFO, "fifo"),
        (stat.S_ISSOCK, "sock"),
    ):
        if test(mode):
            return name
    return "unknown"


def digest(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def xattrs(path: str) -> dict:
    result = {}
    try:
        names = os.listxattr(path, follow_symlinks=False)
    except OSError:
        return result
    for name in sorted(names):
        try:
            value = os.getxattr(path, name, follow_symlinks=False)
        except OSError as e:
            result[name] = f"<error {e.errno}>"
            continue
        try:
            result[name] = value.decode("utf-8").rstrip("\0")
        except UnicodeDecodeError:
            result[name] = "hex:" + value.hex()
    return result


def entry(root: str, rel: str) -> dict:
    path = os.path.join(root, rel)
    st = os.lstat(path)
    e = {
        "path": rel,
        "type": kind(st.st_mode),
        "mode": oct(stat.S_IMODE(st.st_mode)),
        "uid": st.st_uid,
        "gid": st.st_gid,
        "nlink": st.st_nlink if not stat.S_ISDIR(st.st_mode) else None,
        "size": st.st_size if stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode) else None,
        "xattrs": xattrs(path),
        "mtime": st.st_mtime_ns,
    }
    if stat.S_ISREG(st.st_mode):
        e["sha256"] = digest(path)
    elif stat.S_ISLNK(st.st_mode):
        e["target"] = os.readlink(path)
    elif stat.S_ISCHR(st.st_mode) or stat.S_ISBLK(st.st_mode):
        e["rdev"] = f"{os.major(st.st_rdev)}:{os.minor(st.st_rdev)}"
    return e


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("Usage: manifest.py <mount point>")
    root = sys.argv[1]
    paths = ["."]
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        rel = os.path.relpath(dirpath, root)
        for name in dirnames + filenames:
            paths.append(os.path.normpath(os.path.join(rel, name)))
    for rel in sorted(paths):
        print(json.dumps(entry(root, rel), sort_keys=True))


if __name__ == "__main__":
    main()
