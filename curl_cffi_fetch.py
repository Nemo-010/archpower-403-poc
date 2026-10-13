#!/usr/bin/env python3
"""Engine: curl_cffi (BoringSSL + browser impersonation), direct."""
import sys
from curl_cffi import requests


def main() -> int:
    url, out = sys.argv[1], sys.argv[2]
    r = requests.get(url, impersonate="chrome", timeout=180, allow_redirects=True)
    if r.status_code != 200:
        sys.stderr.write(f"curl_cffi: status {r.status_code}\n")
        return 1
    with open(out, "wb") as fh:
        fh.write(r.content)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
