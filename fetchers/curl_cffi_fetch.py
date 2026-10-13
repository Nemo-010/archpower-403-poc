#!/usr/bin/env python3
# SPDX-License-Identifier: 0BSD
"""Retrieve a URL with curl_cffi (BoringSSL).

    python3 curl_cffi_fetch.py <url> <out>

Env:
    IMPERSONATE  curl_cffi profile (default: chrome)
"""
import os
import sys

from curl_cffi import requests


def main() -> int:
    if len(sys.argv) < 3:
        sys.stderr.write("usage: curl_cffi_fetch.py <url> <out>\n")
        return 2
    url, out = sys.argv[1], sys.argv[2]
    r = requests.get(
        url,
        impersonate=os.environ.get("IMPERSONATE", "chrome"),
        timeout=180,
        allow_redirects=True,
    )
    if r.status_code != 200:
        sys.stderr.write(f"curl_cffi: status {r.status_code}\n")
        return 1
    with open(out, "wb") as fh:
        fh.write(r.content)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
