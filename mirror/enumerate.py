#!/usr/bin/env python3
# SPDX-License-Identifier: 0BSD
"""Print the download closure of a repository as a TSV index.

    <url-path>\t<filename>\t<sha256>\t<compressed-size>

The closure is resolved from the databases through %DEPENDS%, with %PROVIDES%
honoured. `base` in ArchPOWER is a metapackage, not a group, so the download
set is its transitive closure. The two databases live under different paths
(`base/powerpc` and `base/any`), so each source is named on the command line and
carried through to the output.

    enumerate.py --source base/powerpc base.db --source base/any base-any.db
"""
import re
import subprocess
import sys
import collections

FIELD = re.compile(r"%([A-Z0-9]+)%")


def desc_text(path):
    """A repository database is a zstd or gzip tar of */desc members."""
    if path == "-":
        return sys.stdin.read()
    for cmd in (
        ["tar", "--zstd", "-xOf", path, "--wildcards", "*/desc"],
        ["tar", "-xzOf", path, "--wildcards", "*/desc"],
    ):
        try:
            out = subprocess.run(cmd, capture_output=True, check=True).stdout
            if out:
                return out.decode("utf-8", "replace")
        except Exception:
            pass
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def records(path):
    out, cur, field = [], {}, None
    for line in desc_text(path).split("\n"):
        m = FIELD.fullmatch(line.strip())
        if m:
            field = m.group(1)
            if field == "FILENAME" and cur:
                out.append(cur)
                cur = {}
            cur.setdefault(field, [])
            continue
        if field:
            if line.strip() == "":
                field = None
            else:
                cur[field].append(line.rstrip())
    if cur:
        out.append(cur)
    return [r for r in out if r.get("NAME")]


def main(argv):
    sources, packages = [], []
    i = 1
    while i < len(argv):
        if argv[i] == "--source":
            sources.append((argv[i + 2], argv[i + 1]))  # (path, url-path)
            i += 3
        elif argv[i].startswith("--package="):
            packages.append(argv[i].split("=", 1)[1])
            i += 1
        else:
            sources.append((argv[i], argv[i].rstrip("/").split("/")[-1]))
            i += 1
    if not sources:
        print(__doc__, file=sys.stderr)
        return 2
    if not packages:
        packages = ["base", "archpower-keyring"]

    by, home = {}, {}
    for path, prefix in sources:
        for r in records(path):
            name = r["NAME"][0]
            by.setdefault(name, r)
            home.setdefault(name, prefix)

    provides = collections.defaultdict(list)
    for name, r in by.items():
        for p in r.get("PROVIDES", []):
            provides[re.split(r"[<>=]", p)[0]].append(name)

    def resolve(tok):
        tok = re.split(r"[<>=]", tok)[0]
        if tok in by:
            return tok
        return provides[tok][0] if tok in provides else None

    seen, stack, missing = set(), list(packages), set()
    while stack:
        name = stack.pop()
        if name in seen:
            continue
        seen.add(name)
        r = by.get(name)
        if not r:
            missing.add(name)
            continue
        for d in r.get("DEPENDS", []):
            t = resolve(d)
            if t:
                stack.append(t)
            else:
                missing.add(d)

    rows = []
    for name in sorted(seen):
        r = by.get(name)
        if r:
            rows.append((home[name], r["FILENAME"][0], r["SHA256SUM"][0], r["CSIZE"][0]))
    for prefix, fn, sha, size in rows:
        print(f"{prefix}\t{fn}\t{sha}\t{size}")
    if missing:
        print(f"unresolved dependencies: {sorted(missing)}", file=sys.stderr)
        return 1
    print(f"{len(rows)} packages", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
