#!/usr/bin/env python3
"""Report every difference between two snapshots of the same image's build.

Usage: compare.py <snapshot A> <snapshot B>

The snapshots are scripts/repro/snapshot.sh's output directories. The report
(Markdown) goes to stdout. It exits 0 whatever it finds: for now this is a
measurement, not a check.
"""

import difflib
import json
import os
import sys
from collections import Counter

TEXT_LIMIT = 256 * 1024
DIFF_LINES = 60
MTIME_EXAMPLES = 40


def read(path: str) -> str:
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except FileNotFoundError:
        return ""


def section(title: str) -> None:
    print(f"\n## {title}\n")


def text_diff(a: str, b: str, name: str, limit: int = DIFF_LINES) -> None:
    lines = list(
        difflib.unified_diff(
            a.splitlines(), b.splitlines(), f"A/{name}", f"B/{name}", lineterm="", n=1
        )
    )
    if not lines:
        return
    print("```diff")
    for line in lines[:limit]:
        print(line[:300])
    if len(lines) > limit:
        print(f"... {len(lines) - limit} more diff lines")
    print("```")


def small_files(a_dir: str, b_dir: str, names: list[str]) -> None:
    for name in names:
        a, b = read(os.path.join(a_dir, name)), read(os.path.join(b_dir, name))
        if a == b:
            print(f"- `{name}`: identical")
        else:
            print(f"- `{name}`: **differs**")
            text_diff(a, b, name)


def blocks(a_dir: str, b_dir: str) -> None:
    names = sorted(set(os.listdir(os.path.join(a_dir, "blocks"))) | set(os.listdir(os.path.join(b_dir, "blocks"))))
    print("| device | blocks | non-zero (A) | differing | differing MiB | first differing offsets |")
    print("|---|---|---|---|---|---|")
    for name in names:
        a = read(os.path.join(a_dir, "blocks", name)).split()
        b = read(os.path.join(b_dir, "blocks", name)).split()
        n = max(len(a), len(b))
        differing = [i for i in range(n) if (a[i] if i < len(a) else None) != (b[i] if i < len(b) else None)]
        nonzero = sum(1 for x in a if x != "0")
        offsets = ", ".join(hex(i * 4096) for i in differing[:6])
        print(
            f"| {name} | {n} | {nonzero} | {len(differing)} | {len(differing) * 4096 / 2**20:.1f} | {offsets} |"
        )


def load_manifest(path: str) -> dict:
    result = {}
    try:
        with open(path) as f:
            for line in f:
                e = json.loads(line)
                result[e["path"]] = e
    except FileNotFoundError:
        pass
    return result


def is_text(path: str) -> bool:
    try:
        if os.path.getsize(path) > TEXT_LIMIT:
            return False
        with open(path, "rb") as f:
            data = f.read()
        if b"\0" in data:
            return False
        data.decode("utf-8")
        return True
    except (OSError, UnicodeDecodeError):
        return False


def top(path: str, depth: int = 2) -> str:
    parts = path.split("/")
    return "/".join(parts[:depth]) if len(parts) > depth else os.path.dirname(path) or "."


def filesystem(a_dir: str, b_dir: str, fs: str) -> None:
    a = load_manifest(os.path.join(a_dir, "manifest", fs))
    b = load_manifest(os.path.join(b_dir, "manifest", fs))
    only_a = sorted(set(a) - set(b))
    only_b = sorted(set(b) - set(a))
    changed = []
    mtime_only = []
    for path in sorted(set(a) & set(b)):
        ea = {k: v for k, v in a[path].items() if k != "mtime"}
        eb = {k: v for k, v in b[path].items() if k != "mtime"}
        if ea != eb:
            changed.append(path)
        elif a[path]["mtime"] != b[path]["mtime"]:
            mtime_only.append(path)

    print(f"\n### {fs}\n")
    print(
        f"{len(a)} paths in A, {len(b)} in B. Only in A: {len(only_a)}. Only in B: {len(only_b)}. "
        f"Content or metadata differs: {len(changed)}. Only mtime differs: {len(mtime_only)}."
    )
    for label, paths in (("Only in A", only_a), ("Only in B", only_b)):
        if paths:
            print(f"\n{label}:\n")
            for p in paths[:100]:
                print(f"- `{p}`")
            if len(paths) > 100:
                print(f"- ... {len(paths) - 100} more")

    if changed:
        print("\nDiffering paths (excluding mtime):\n")
    for path in changed:
        ea, eb = a[path], b[path]
        fields = sorted(k for k in set(ea) | set(eb) if k != "mtime" and ea.get(k) != eb.get(k))
        detail = []
        for k in fields:
            if k == "sha256":
                detail.append(f"content (size {ea.get('size')} vs {eb.get('size')})")
            elif k == "xattrs":
                xa, xb = ea.get("xattrs", {}), eb.get("xattrs", {})
                keys = sorted(x for x in set(xa) | set(xb) if xa.get(x) != xb.get(x))
                detail.append("xattrs " + ", ".join(f"{x}: {xa.get(x)!r} vs {xb.get(x)!r}" for x in keys))
            elif k != "size":
                detail.append(f"{k}: {ea.get(k)!r} vs {eb.get(k)!r}")
        print(f"- `{path}`: {'; '.join(detail)}")
        if "sha256" in fields:
            fa = os.path.join(a_dir, "tree", fs, path)
            fb = os.path.join(b_dir, "tree", fs, path)
            if is_text(fa) and is_text(fb):
                text_diff(read(fa), read(fb), f"{fs}/{path}", limit=30)
            else:
                print("  (binary or large; no diff shown)")

    if mtime_only:
        groups = Counter(top(p) for p in mtime_only)
        print("\nOnly mtime differs, by directory:\n")
        for d, n in groups.most_common(30):
            print(f"- `{d}`: {n}")
        print("\nExamples (A mtime, B mtime, in seconds):\n")
        for p in mtime_only[:MTIME_EXAMPLES]:
            print(f"- `{p}`: {a[p]['mtime'] / 1e9:.3f} vs {b[p]['mtime'] / 1e9:.3f}")


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit("Usage: compare.py <snapshot A> <snapshot B>")
    a_dir, b_dir = sys.argv[1:]

    print("# Reproducibility report")

    section("Build output files")
    fa = dict(reversed(l.split(maxsplit=1)) for l in read(os.path.join(a_dir, "files.sha256")).splitlines())
    fb = dict(reversed(l.split(maxsplit=1)) for l in read(os.path.join(b_dir, "files.sha256")).splitlines())
    # Build directories are named after the build, so compare by suffix.
    def norm(d: dict) -> dict:
        out = {}
        for name, h in d.items():
            base = os.path.basename(name)
            if base.endswith(".vhd"):
                base = "<build>.vhd"
            out[os.path.join(os.path.dirname(name), base)] = h
        return out

    fa, fb = norm(fa), norm(fb)
    print("| file | identical |")
    print("|---|---|")
    for name in sorted(set(fa) | set(fb)):
        print(f"| `{name}` | {'yes' if fa.get(name) == fb.get(name) else '**no**'} |")

    section("Disk layout")
    small_files(a_dir, b_dir, ["sfdisk.txt", "blkid.txt", "lvm.txt"])

    section("Block-level differences (4 KiB blocks)")
    blocks(a_dir, b_dir)

    section("Build evidence")
    ev_a = os.path.join(a_dir, "evidence")
    names = sorted(os.listdir(ev_a)) if os.path.isdir(ev_a) else []
    small_files(ev_a, os.path.join(b_dir, "evidence"), [n for n in names if not n.endswith((".xml", ".html"))])
    for n in names:
        if n.endswith((".xml", ".html")):
            same = read(os.path.join(ev_a, n)) == read(os.path.join(b_dir, "evidence", n))
            print(f"- `{n}`: {'identical' if same else '**differs** (not shown)'}")

    section("Filesystems")
    fss = sorted(set(os.listdir(os.path.join(a_dir, "manifest"))) | set(os.listdir(os.path.join(b_dir, "manifest"))))
    for fs in fss:
        filesystem(a_dir, b_dir, fs)


if __name__ == "__main__":
    main()
