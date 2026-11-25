#!/usr/bin/env python3
"""Lock and fetch the exact RPMs an image is built from.

  rpm-lock.py lock <image> <packages.txt>
      Resolve every package an unlocked build installed (the build evidence's
      packages.txt, `rpm -qa`) against rpms/<image>.repos, and write
      rpms/<image>.lock: each repository's metadata revision, its comps file
      and each RPM's path and SHA-256.

  rpm-lock.py fetch <image> <dir>
      Download what rpms/<image>.lock lists, check each file's SHA-256, and
      make <dir> a repository of exactly those packages (createrepo_c), which
      the installer then installs from and nothing else. Downloads are cached
      in $RPM_CACHE (default ~/.cache/alma-x86v2-xcp/rpms), by digest.

A locked build installs the same packages whatever the upstream repositories
hold by then. Renovate notices when a repository's metadata changes (the
revision in each `repo` line); .github/workflows/rpm-lock.yml then rewrites the
lockfile from an unlocked build.
"""

import concurrent.futures
import gzip
import hashlib
import io
import lzma
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_NS = {"repo": "http://linux.duke.edu/metadata/repo"}
COMMON_NS = {"c": "http://linux.duke.edu/metadata/common"}
USER_AGENT = "alma-x86v2-xcp-rpm-lock"


def die(msg):
    print(f"rpm-lock: {msg}", file=sys.stderr)
    sys.exit(1)


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                return resp.read()
        except urllib.error.HTTPError as e:
            if e.code < 500 or attempt == 3:
                raise RuntimeError(f"GET {url}: {e}") from e
        except OSError as e:
            if attempt == 3:
                raise RuntimeError(f"GET {url}: {e}") from e
        time.sleep(2**attempt)


def decompress(name, data):
    if name.endswith(".gz"):
        return gzip.decompress(data)
    if name.endswith(".xz"):
        return lzma.decompress(data)
    if name.endswith(".zst"):
        return subprocess.run(["zstd", "-dc"], input=data, stdout=subprocess.PIPE, check=True).stdout
    return data


def read_repos(image):
    path = os.path.join(ROOT, "rpms", f"{image}.repos")
    repos = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            name, url = line.split()
            repos.append((name, url if url.endswith("/") else url + "/"))
    if not repos:
        die(f"{path} lists no repositories")
    return repos


def repomd(url):
    """The revision, and the primary and comps locations, of a repository."""
    root = ET.fromstring(get(url + "repodata/repomd.xml"))
    revision = root.findtext("repo:revision", namespaces=REPO_NS)
    data = {}
    for d in root.findall("repo:data", REPO_NS):
        loc = d.find("repo:location", REPO_NS).get("href")
        checksum = d.find("repo:checksum", REPO_NS)
        data[d.get("type")] = (loc, checksum.get("type"), checksum.text)
    return revision, data


def check(data, kind, expected, what):
    actual = hashlib.new(kind, data).hexdigest()
    if actual != expected:
        raise RuntimeError(f"{what}: {kind} is {actual}, expected {expected}")


def primary(url, data):
    """Map 'name-version-release.arch' to (location, sha256, size)."""
    loc, kind, digest = data["primary"]
    raw = get(url + loc)
    check(raw, kind, digest, url + loc)
    packages = {}
    for _, elem in ET.iterparse(io.BytesIO(decompress(loc, raw))):
        if elem.tag != "{%s}package" % COMMON_NS["c"]:
            continue
        name = elem.findtext("c:name", namespaces=COMMON_NS)
        arch = elem.findtext("c:arch", namespaces=COMMON_NS)
        ver = elem.find("c:version", COMMON_NS)
        checksum = elem.find("c:checksum", COMMON_NS)
        href = elem.find("c:location", COMMON_NS).get("href")
        size = elem.find("c:size", COMMON_NS).get("package")
        if checksum.get("type") != "sha256":
            raise RuntimeError(f"{url}: {name} has a {checksum.get('type')} checksum, not sha256")
        nvra = f"{name}-{ver.get('ver')}-{ver.get('rel')}.{arch}"
        packages.setdefault(nvra, (href, checksum.text, size))
        elem.clear()
    return packages


def lock(image, packages_txt):
    with open(packages_txt) as f:
        # gpg-pubkey "packages" are the keys rpm imported, not packages.
        wanted = sorted({l.strip() for l in f if l.strip() and not l.startswith("gpg-pubkey-")})
    repos = read_repos(image)
    lines = [
        f"# The exact packages {image} is built from. Written by scripts/rpm-lock.py",
        "# lock: don't edit by hand. Renovate bumps a repository's revision when its",
        "# metadata changes, and .github/workflows/rpm-lock.yml then rewrites this file.",
        "#",
        "# repo  <name> <url> <metadata revision>",
        "# comps <repo> <path> <sha256>",
        "# rpm   <repo> <path> <sha256> <size>",
    ]
    found = {}
    comps = None
    for name, url in repos:
        revision, data = repomd(url)
        lines.append(f"repo {name} {url} {revision}")
        if comps is None and "group" in data:
            loc, kind, digest = data["group"]
            if kind != "sha256":
                die(f"{url}: comps has a {kind} checksum, not sha256")
            comps = f"comps {name} {loc} {digest}"
        for nvra, (href, digest, size) in primary(url, data).items():
            found.setdefault(nvra, (name, href, digest, size))
    if comps is None:
        die("no repository has a comps (group) file")
    missing = [p for p in wanted if p not in found]
    if missing:
        die("not in any repository: " + ", ".join(missing))
    lines.append(comps)
    for p in wanted:
        name, href, digest, size = found[p]
        lines.append(f"rpm {name} {href} {digest} {size}")
    path = os.path.join(ROOT, "rpms", f"{image}.lock")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"{path}: {len(wanted)} packages")


def read_lock(image):
    path = os.path.join(ROOT, "rpms", f"{image}.lock")
    if not os.path.exists(path):
        die(f"{path} doesn't exist: run an unlocked build (RPM_LOCK=0 ./build.sh {image}) and rpm-lock.py lock")
    repos, comps, rpms = {}, None, []
    with open(path) as f:
        for n, line in enumerate(f, 1):
            fields = line.split()
            if not fields or fields[0].startswith("#"):
                continue
            if fields[0] == "repo" and len(fields) == 4:
                repos[fields[1]] = fields[2]
            elif fields[0] == "comps" and len(fields) == 4:
                comps = fields[1:]
            elif fields[0] == "rpm" and len(fields) == 5:
                rpms.append(fields[1:4])
            else:
                die(f"{path}:{n}: can't parse {line.strip()!r}")
    for repo, *_ in ([comps] if comps else []) + rpms:
        if repo not in repos:
            die(f"{path}: no repo line for {repo}")
    if comps is None or not rpms:
        die(f"{path} has no comps or no rpm lines")
    return repos, comps, rpms


def cached(cache, url, digest):
    """The path of url's file in the cache, downloading it if needed."""
    path = os.path.join(cache, digest[:2], digest)
    if os.path.exists(path):
        return path
    data = get(url)
    check(data, "sha256", digest, url)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    os.replace(tmp, path)
    return path


def fetch(image, out):
    repos, comps, rpms = read_lock(image)
    cache = os.environ.get("RPM_CACHE") or os.path.join(
        os.path.expanduser("~"), ".cache", "alma-x86v2-xcp", "rpms")
    if os.path.exists(out):
        shutil.rmtree(out)
    os.makedirs(os.path.join(out, "Packages"))

    def one(entry):
        repo, href, digest = entry
        src = cached(cache, repos[repo] + href, digest)
        dst = os.path.join(out, "Packages", os.path.basename(href))
        if os.path.exists(dst):
            raise RuntimeError(f"two locked packages are both named {os.path.basename(href)}")
        shutil.copyfile(src, dst)

    with concurrent.futures.ThreadPoolExecutor(8) as pool:
        for future in concurrent.futures.as_completed([pool.submit(one, e) for e in rpms]):
            future.result()
    repo, href, digest = comps
    shutil.copyfile(cached(cache, repos[repo] + href, digest), os.path.join(out, "comps.xml"))
    out = os.path.abspath(out)
    subprocess.run(["createrepo_c", "--quiet", "--groupfile", os.path.join(out, "comps.xml"), out], check=True)
    print(f"{out}: {len(rpms)} locked packages for {image}")


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "lock":
        lock(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 4 and sys.argv[1] == "fetch":
        fetch(sys.argv[2], sys.argv[3])
    else:
        print(__doc__, file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as e:
        die(str(e))
