# Results — `repo.archlinuxpower.org/base/powerpc/base.db` 403

All measurements taken **2026-10-13**, from GitHub-hosted `ubuntu-latest` runners
(Azure, AS8075 Microsoft) and from a residential VE egress (AS61461) as an allowed
control. Origin is Cloudflare-fronted (`server: cloudflare`, `cf-ray`, `alt-svc: h3`).

## 1. What the 403 actually is

`HTTP/2 403` with all of:

| marker | value |
| --- | --- |
| `cf-mitigated` | `challenge` |
| `accept-ch` / `critical-ch` | a Client-Hints list (`Sec-CH-UA-*`, `UA-*`) |
| `server-timing` | `chlray;desc="…"` |
| CSP `script-src` | `… https://challenges.cloudflare.com` |
| body (`content-length: 5356`) | `<title>Just a moment...`, `Enable JavaScript and cookies`, `cf_chl_opt`, `challenge-platform` |

That is Cloudflare's **Managed Challenge** interstitial, not an origin `403` and not a
Cloudflare "1020 access denied by firewall rule" page. The `chlray` timing descriptor
is the challenge subrequest ray.

## 2. The failing request, reproduced

From `pkgforge-dev/docker-archlinux`, `scripts/resolve-anchor:23` sends
`User-Agent: docker-archlinux-mirrorlist/1 (+https://github.com/pkgforge-dev/docker-archlinux)`
and `scripts/resolve-anchor:85` does `curl -sSfL -A "$UA" …`. The URL is
`rootfs/ppc/etc/pacman.d/mirrorlist:8` and its proxy fallback is `:9`.

From the CI runner: **direct `403`, and through `api.rv.pkgforge.dev` `403`** — exactly
the original report. The on-disk 403 body is the challenge above, so `curl -f` turns it
into `exit 22` and `resolve-anchor` reports `curl: (22) … 403`.

## 3. Same IP, client shape varies (run 38401006178, egress 20.168.100.242)

| client | status |
| --- | --- |
| system curl (default UA) | 403 challenge |
| system curl + mirror UA | 403 challenge |
| system curl + Chrome UA | 403 challenge |
| system curl `--http1.1` | 403 challenge |
| curl-impersonate Chrome 136 / 131 | **200** |
| curl-impersonate Firefox 135 | **200** |
| curl-impersonate Safari 172 | **200** |
| workerd + `worker.js` verbatim | **200** |
| relay (Cloudflare egress), Node TLS | **200** |
| relay (`azure-westus2`), Node TLS | **200** |

## 4. Isolation: which signal flips it (run 38401318456, egress 57.151.137.136)

| change | status |
| --- | --- |
| nothing (plain curl) | 403 |
| full Chrome header set, default curl TLS | 403 |
| browser cipher list + curves, curl UA | 403 |
| **browser cipher list + curves + full Chrome headers** | **200** |
| curl-impersonate Chrome (full ClientHello), `--http1.1` | 200 |
| Node TLS: default / TLS1.2 / browser ciphers+curves / firefox / safari | 403 |
| b-ids Chrome UA string only | 403 |
| workerd | 200 |

So the TLS cipher list alone is not enough, and browser headers alone are not enough;
the edge wants the two to be **mutually consistent**. Node TLS can present browser
cipher names but not the extension order/GREASE/ALPS/cert-compression of a real
ClientHello, and it is scored accordingly.

## 5. Stability (run 38401504222, egress 20.102.103.115)

| cell | 5 samples |
| --- | --- |
| plain curl | 403 403 403 403 403 |
| Chrome headers only | 403 403 403 403 403 |
| browser ciphers only | 403 403 403 403 403 |
| **browser ciphers + Chrome headers** | **200 200 200 200 200** |
| Chrome UA only | 403 403 403 403 403 |
| curl-impersonate chrome / firefox / safari | 200 200 200 / 200 200 200 / 200 200 200 |
| workerd | 200 200 200 |

## 6. Proxies and egress controls (run 38401504222)

| path | status | note |
| --- | --- | --- |
| direct db from runner | 403 403 403 | reproduces the issue |
| `api.rv.pkgforge.dev/<url>` db | 403 403 403 | the header-only proxy does **not** fix it |
| `api.rv.pkgforge.dev/<url>` root | 403 403 403 | same from a datacenter client |
| `r.jina.ai/<url>` db | 422 422 422 | reader refuses `application/octet-stream`; not a 403 |
| `r.jina.ai/<url>` root | 200 200 200 | its backend applies a real browser identity |
| relay (Cloudflare egress) Node/Chrome TLS | 200 | clean egress passes plain |
| residential VE, plain curl | 200 | clean egress passes plain |

The rv proxy on a residential client returned 200 in an earlier local check, but from
the Azure client it returns 403. Header rewriting cannot change the worker's TLS shape
or its egress reputation.

## 7. Mechanism

`repo.archlinuxpower.org` sits behind Cloudflare with bot mitigation enabled. Each
request is scored from (a) source-IP reputation/ASN and (b) fingerprint consistency
across TLS ClientHello, HTTP version/settings, header order and Client Hints. A
datacenter IP (Azure/GitHub) is low-trust, so an inconsistent or obviously non-browser
client receives `403` + `cf-mitigated: challenge`; a browser-consistent client on the
same IP receives `200`. A clean residential IP is trusted enough that even plain curl
gets `200`.

* Not an IP-range denylist: browser-consistent requests pass `200` on the blocked IP.
* Not a TLS-only allowlist: browser ciphers with a curl UA still fail.
* Not a UA filter: a real Chrome UA alone still fails.
* The `403` is a challenge, so a JS-capable real browser would proceed; a JS-less
  mirror client cannot.

kth5's own `#69` comment documents a separate, deliberate country block (RU). That is
not what hits GitHub Actions in the US; the marker here is the managed challenge.

## 8. Scope and limits

* One origin, one path, one day. Cloudflare bot scores are adaptive; the split can move.
* No access to the archlinuxpower Cloudflare zone, so the exact rule name/setting
  (Bot Fight Mode vs Bot Management vs a managed WAF rule) cannot be named from
  outside; `cf-mitigated: challenge` is the evidence it is a Managed Challenge.
* The JS challenge was never solved, so this does not measure post-challenge access.
* IPv6 was not exercised (sandbox egress has no v6; CI used v4).
* No origin server config or package recipe was read for this; the archpower repo
  carries no edge configuration.
* `workerd` is the local runtime, not a deployed Worker colo; it isolates the worker
  code plus Cloudflare's fetch stack, not a specific Cloudflare egress IP.
* The docker build itself was not run; the failing step is the mirror fetch.
* No issue, comment, review or pull request was left in any other repository.

## 9. Sources

| claim | source |
| --- | --- |
| failing 403 direct and via proxy | `kth5/archpower#160` body; job log `pkgforge-dev/docker-archlinux` run 35714382243 |
| deliberate RU country block | `kth5/archpower#69` comment (2023-12-29) |
| mirror UA and `curl -f` | `pkgforge-dev/docker-archlinux` `scripts/resolve-anchor:23,85` |
| the two mirror servers | `pkgforge-dev/docker-archlinux` `rootfs/ppc/etc/pacman.d/mirrorlist:8-9` |
| rv worker only rewrites headers/UA | `pkgforge-dev/reverse-proxies` `api.rv.pkgforge.dev/worker.js:14-26,49-60` |
| what a real browser emits | `Azathothas/b-ids` README and `data/routes/{client-hello-hex,header-order,user-agent}` |
| challenge markers | measured response headers and body, section 1 |

## 10. Runs

* `archpower-403-probe` — <https://github.com/Nemo-010/archpower-403-poc/actions/runs/38401006178>
* `archpower-403-isolate` — <https://github.com/Nemo-010/archpower-403-poc/actions/runs/38401318456>
* `archpower-403-repeat` — <https://github.com/Nemo-010/archpower-403-poc/actions/runs/38401504222>
