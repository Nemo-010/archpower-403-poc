# mirror

Publish an ArchPOWER repository as an OCI artifact, and serve it to pacman from
that artifact instead of from the origin.

`repo.archlinuxpower.org` returns **403** with a Cloudflare interstitial to
requests from GitHub-hosted runner address ranges; the same URL and user agent
return **200** from other networks (measured 2026-10-13). A real Chromium,
driven through its own network stack, returns 200 from a runner, so it performs
the retrieval once and the build and the installed system read the registry.

## Client choice

One runner, one source address, `base.db`, run `38410453428`:

| client | status | bytes |
| --- | ---: | ---: |
| plain curl | 403 | 5356 |
| Chromium headless shell | 403 | 0 |
| full Chromium, default user agent | 403 | 0 |
| **full Chromium, Chrome user agent** | **200** | **741171** |
| curl-impersonate `chrome136` | 200 | 741171 |
| curl_cffi `chrome` | 200 | 741171 |
| node-tls-client `chrome_131` | 200 | 741171 |

Two properties are load-bearing:

1. The user agent must be a `Chrome/<version>` string; `HeadlessChrome/<version>`
   receives 403 with the same TLS stack.
2. The request must be issued by the browser: an in-page `fetch()`. Playwright's
   request context is a separate Node-side HTTP client and returns 403 for the
   data request even after the page has loaded the origin.

`fetchers/chromium_fetch.mjs` derives its user agent from the running build's
version, so the user agent, the client hints and the TLS stack agree.

## Artifact

```
ghcr.io/<namespace>/archpower-<repo>:<arch>
```

Contents: both databases and their signatures, every package in the download
closure and its signature, and `index.tsv`:

```
# url-path	filename	sha256	size
base/powerpc	base.db	9fb3d3cd...	741171
base/any	base-any.db	2df5ce18...	504891
base/powerpc	acl-2.4.0-1-powerpc.pkg.tar.zst	73f78138...	166581
```

Measured for `base/powerpc` + `base/any`: 142 packages, 154 MiB, 144 index rows.

## Running

```sh
NS=<namespace> bash mirror/sync.sh base powerpc

# a slice of a repository larger than one runner's disk
NS=<namespace> MAX_FILES=500 bash mirror/sync.sh base powerpc
```

The databases are always refetched. `SKIP_FETCH=1` reuses packages already in
`stage/`, which is what makes a repeated run cheap.
`.github/workflows/mirror-sync.yml` runs it weekly with `stage/` in the Actions
cache, so a slice-per-run schedule can cover a whole repository.

Each package is checked twice before it is published: its detached signature
against the pinned keyring in `keys/`, and its sha256 against the value the
database carries.

## Client side

`ghcr-fetch` is a `XferCommand`:

```
XferCommand = /usr/bin/ghcr-fetch %u %o
```

It keeps upstream's `Server` lines, so `%u` is the origin URL and only the path
is used. `/etc/ghcr-mirror.conf` names the namespace and the image's own
architecture, because `any` packages are mirrored inside the architecture's
artifact. The file is located through `index.tsv` and retrieved by digest, then
checked against the sha256 in the index, so a truncated or replaced blob is
rejected even though the transport is a registry rather than the signed origin.
Blob reads redirect to the storage backend, so the curl calls follow redirects.

Verified on a runner and locally: a cold `oras pull` of 289 files, `gpg`
signature GOOD, and `ghcr-fetch` returning `base.db` byte-identical both with a
token and anonymously. An epoch filename (`zlib-1:1.3.2-…`), a `+`-bearing
filename and the `base/any` path all retrieve.

Notes:

- Staging escapes `:` in a filename, because an Arch epoch puts one there and
  `oras` reads `path:type`. `index.tsv` carries the real name and retrieval is
  by digest, so nothing depends on the layer title.
- The package must be public for an anonymous pull.

## Limits

- `SKIP_FETCH` trades freshness for speed by design; the databases never come
  from the cache, so the closure a run resolves is current.
- A slice run publishes a partial artifact. A client pulling a file that is not
  in the current slice sees it as absent.
