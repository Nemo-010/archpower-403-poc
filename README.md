# ArchPOWER repository access and mirror

`repo.archlinuxpower.org` returns **HTTP 403** with a Cloudflare interstitial to
requests originating from GitHub-hosted runner address ranges. The same URL and
the same user agent return **200** from other networks. Measured 2026-10-13.

This repository contains two independent pieces:

| path | what it is |
| --- | --- |
| `fetchers/` | programs that retrieve one URL, each using a different TLS/HTTP client stack, behind one interface |
| `mirror/` | a pipeline that retrieves an ArchPOWER repository through a real Chromium, verifies it, publishes it as an OCI artifact, and a pacman `XferCommand` that reads that artifact |
| `.github/workflows/` | a scheduled mirror job and a client-status probe |

Everything here is **0BSD**: use, modify, redistribute, relicense, with or
without attribution. See `LICENSE`.

## Client status

One runner, one source address, one URL
(`https://repo.archlinuxpower.org/base/powerpc/base.db`), run `38410453428`:

| client | status | bytes |
| --- | ---: | ---: |
| plain curl | 403 | 5356 |
| Chromium headless shell | 403 | 0 |
| full Chromium, default user agent | 403 | 0 |
| full Chromium, Chrome user agent | 200 | 741171 |
| curl-impersonate `chrome136` | 200 | 741171 |
| curl_cffi `chrome` | 200 | 741171 |
| node-tls-client `chrome_131` | 403 | 0 |

`node-tls-client` returns 200 from a residential network and 403 from a
runner (run `38421222856`); the other three return 200 from both. The
`.github/workflows/fetchers.yml` probe prints this table from a runner.

Two properties determine the result, and both are required:

1. **User agent.** The headless shell and the full build both report
   `HeadlessChrome/<version>` by default and receive 403; a `Chrome/<version>`
   user agent receives 200. The TLS stack is unchanged between those rows.
2. **Client stack.** The request must be issued by the browser itself. In
   `fetchers/chromium_fetch.mjs` the request is an in-page `fetch()`. Playwright's
   request context is a separate Node-side HTTP client and returns 403 for the
   data request even after the page has loaded the origin.

`fetchers/chromium_fetch.mjs` derives its default user agent from the running
build's own version, so the user agent, the client hints and the TLS stack stay
consistent as the build ages.

## Using a fetcher

Every program in `fetchers/` has the same interface:

```
<client> <url> <out>
```

It writes the response body to `<out>` and exits non-zero if it could not. See
`fetchers/README.md` for the dependency and environment variable of each.

`fetch.sh` runs an ordered list of them against one URL, checks the result
structurally, checks the detached signature against a pinned keyring, and falls
back to a last-known-good copy:

```sh
KEYRING=mirror/keys/archpower.gpg TRUSTED=mirror/keys/archpower-trusted \
  CLIENTS="chromium curl-impersonate curl-cffi tls-client" \
  CACHE_DIR=.cache OUT=base.db \
  bash fetch.sh
```

## The mirror

`mirror/sync.sh` retrieves a repository and its packages, verifies every file,
and publishes one OCI artifact per repository/architecture; `mirror/ghcr-fetch`
is the pacman `XferCommand` that reads it back. See `mirror/README.md`.

Measured for `base/powerpc` + `base/any`: 142 packages, 154 MiB, 144 index
rows, published as
`ghcr.io/<namespace>/archpower-base:powerpc`.

## Redundancy options

Independent pieces can be combined. Ordered roughly by how much each buys:

- **Several client stacks.** The four in `fetchers/` use Chromium's network
  service, BoringSSL (curl-impersonate, curl_cffi), and Go `uTLS`
  (node-tls-client). A change in what the origin accepts affects one stack at a
  time.
- **Several egress paths.** A GitHub-hosted runner, a self-hosted runner, a
  host on a network the origin accepts, or a TCP relay. The mirror reads from
  the registry and never contacts the origin, so egress only matters to the
  sync job.
- **Several mirror targets.** Publish the same artifact to more than one
  registry or static host, and have the client try each in order.
- **A complete index.** `index.tsv` inside the artifact maps every url-path to
  a filename, a sha256 and a size. It is what a client needs to pull one file
  without listing the artifact.
- **Two-level verification.** Detached signature against a pinned keyring, plus
  the sha256 from the index. Either can reject a file independently.
- **Content-addressed storage.** An OCI artifact is digest-addressed, so a
  truncated or replaced upload changes the digest rather than the contents a
  client already resolved.
- **A last-known-good cache.** `fetch.sh` and the mirror stage keep a verified
  copy, so a failure to retrieve costs freshness rather than availability.
- **A status probe.** `.github/workflows/fetchers.yml` runs every client from a
  runner and reports which return 200, so a change is visible before a job
  depends on it.
- **Pinned client versions.** Record the observed status next to the version of
  each client, so a status change can be attributed to a client update or to a
  change at the origin.
- **Staged syncs.** `MAX_FILES` makes one run a slice of a repository, and the
  Actions cache carries the verified files between runs, so a repository larger
  than a runner's disk can still be mirrored.
- **A read path with no origin dependency.** The shipped client reads only the
  registry. If every retrieval path stops working, published artifacts remain
  consistent and verifiable.
