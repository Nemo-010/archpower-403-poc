# A GHCR mirror of an ArchPOWER repository

`repo.archlinuxpower.org` answers **403** with a Cloudflare managed challenge to
every client it does not like, and it does not like GitHub runners. The origin
is fine with a residential address; a runner is not. This directory turns "get
the bytes out of the origin" into a weekly job that uses the one client which
does get through, and leaves the build and the consumer reading GHCR instead.

## Why a real Chromium

Measured on run `38410453428`, one runner, same IP, all on
`https://repo.archlinuxpower.org/base/powerpc/base.db`:

| client | status | bytes | note |
| --- | ---: | ---: | --- |
| plain curl | 403 | 5356 | the challenge page |
| Chromium headless shell | 403 | 0 | `HeadlessChrome/156`, `navigator.webdriver` true |
| full Chromium, default UA | 403 | 0 | still `HeadlessChrome/156`, still challenged |
| **full Chromium, real Chrome UA** | **200** | **741171** | byte-identical |
| full Chromium, real UA + stealth | 200 | 741171 | `navigator.webdriver` gone |
| curl-impersonate chrome136 | 200 | 741171 | control |

Two things decide it, and both had to be fixed:

1. **The user agent.** `HeadlessChrome/...` is challenged; a real `Chrome/...`
   is not. The TLS stack does not change between those two rows.
2. **Which stack fetches.** Playwright's `context.request` is its own Node-side
   client with a non-browser ClientHello; it returns 403 even after the page
   loaded the origin with no challenge (visible as `title: "Index of /"` with
   `status: 403`). The fetch must be an **in-page `fetch()`** so Chromium's
   fingerprint and cookie jar apply.

## What it produces

One OCI artifact per repository/architecture:

```
ghcr.io/<ns>/archpower-<repo>:<arch>
```

holding every file, its detached `.sig`, both databases, and `index.tsv`:

```
# url-path	filename	sha256	size
base/powerpc	base.db	9fb3d3cd...	741171
base/any	base-any.db	2df5ce18...	504891
base/powerpc	acl-2.4.0-1-powerpc.pkg.tar.zst	73f78138...	166581
```

Measured for `base/powerpc` + `base/any`: **144 files, 154 MiB**, of which the
download closure is 142 packages (see `enumerate.py` — `base` here is a real
metapackage, not a group).

## Running it

```sh
NS=<ghcr-namespace> bash mirror/sync.sh base powerpc      # one repo and arch
NS=<ns> MAX_FILES=500 bash mirror/sync.sh base powerpc    # a slice, for the
                                                          # whole repository
```

The databases are always refetched; `SKIP_FETCH=1` reuses packages already in
`stage/`, which is what makes a re-run cheap. `.github/workflows/mirror-sync.yml`
runs it weekly with the stage in the Actions cache, so a slice-per-run schedule
can cover a repository whose whole sync exceeds a runner's disk.

Every package is checked twice before it is uploaded: the detached signature
against the pinned ArchPOWER keyring in `keys/`, and its sha256 against the
value the database carries.

## The consumer side

`ghcr-fetch` is a pacman `XferCommand`:

```
XferCommand = /usr/bin/ghcr-fetch %u %o
```

It keeps upstream's `Server` lines, so `%u` is the origin URL and only the path
is used; `/etc/ghcr-mirror.conf` names the namespace and the image's own
architecture (needed because `any` packages are mirrored inside the
architecture's artifact). It reads `index.tsv` out of the artifact, pulls one
blob by digest, and re-checks the sha256 — a truncated or swapped blob is
refused even though the transport is a registry rather than the signed origin.
Blob reads are 307s to the storage backend, so the curl calls follow redirects.

Verified end to end on the runner and locally: cold `oras pull` of 289 files,
`gpg` signature GOOD, and `ghcr-fetch` returning `base.db` **byte-identical**
both with a token and anonymously. The epoch filename (`zlib-1:1.3.2-…`), a
`+`-bearing filename, and the `base/any` path all pull.

Two notes for a build that uses this instead of the origin:

- Staging escapes a `:` in a filename (Arch epochs put one there, and `oras`
  reads `path:type`), so the layer titles are not the real names. `index.tsv`
  is, and pulls are by digest, so nothing depends on the title.
- The package has to be **public** for the shipped wrapper to pull anonymously.

## Limits

- This is a mirror of a repository the origin publishes; redistribution is the
  origin's call and worth a yes before it is wired into anything shipped.
- The sync leg is still circumvention — the arms race did not go away, it moved
  into one weekly job where a break costs freshness and not a build. A real
  Chromium is the leg that does not need a synthesised signature maintained.
- `SKIP_FETCH` trades freshness for speed on purpose; the databases never come
  from the cache, so the closure a run resolves is always current.
