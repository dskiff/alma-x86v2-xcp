#!/usr/bin/env python3
"""Serve a directory over HTTP on the host's loopback, for the installer.
Usage: serve-rpms.py <dir> <port file>

Binds 127.0.0.1 on a free port and writes the port to <port file> once it
listens. QEMU's user networking maps the guest's 10.0.2.2 to the host's
127.0.0.1, so the installer reaches it at http://10.0.2.2:<port>/. Runs until
killed. build.sh starts it for the locked repositories (scripts/rpm-lock.py
fetch).
"""

import functools
import http.server
import os
import sys


class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # Anaconda fetches hundreds of files; errors still show as failures there.


def main():
    if len(sys.argv) != 3 or not os.path.isdir(sys.argv[1]):
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    handler = functools.partial(Handler, directory=sys.argv[1])
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    tmp = sys.argv[2] + ".tmp"
    with open(tmp, "w") as f:
        f.write(f"{server.server_address[1]}\n")
    os.replace(tmp, sys.argv[2])
    server.serve_forever()


if __name__ == "__main__":
    main()
