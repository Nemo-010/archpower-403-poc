# archpower-403-poc (temporary)

Reproduces and explains the `403` that `pkgforge-dev/docker-archlinux` hit fetching
`https://repo.archlinuxpower.org/base/powerpc/base.db` (`kth5/archpower#160`).

The one-line answer: **it is a Cloudflare Managed Challenge (Bot Management), not an
IP-range denylist and not a pure TLS/JA3 allowlist.** The origin's Cloudflare edge
scores each request from the *combination* of source-IP reputation and client
fingerprint consistency (TLS ClientHello + HTTP version/settings + header set). From a
datacenter IP a plain `curl` is challenged (`403`, `cf-mitigated: challenge`, "Just a
moment…"), while a browser-consistent client passes with `200` **from the same IP**.

Full evidence tables and run links: [`RESULTS.md`](./RESULTS.md).

## Reproduce

Local control (this machine's egress is a clean residential IP, so everything is `200`):

```sh
CI_DIR=/path/to/curl-impersonate bash probe.sh
```

workerd, the `api.rv.pkgforge.dev` worker verbatim:

```sh
npm install workerd@1.20261013.1
./node_modules/.bin/workerd serve config.capnp &   # 127.0.0.1:8787
curl -s -o /dev/null -w '%{http_code}\n' \
  'http://127.0.0.1:8787/https://repo.archlinuxpower.org/base/powerpc/base.db'
```

Node userspace TLS, one ClientHello shape at a time (no curl, no relay):

```sh
node node_tls_direct.mjs chrome
```

Raw TCP through the relay, then a Node TLS ClientHello over it (the "IP branch" of the
brief): `tcp.ssh.relay.ajam.dev` forwards binary WebSocket frames to the target TCP
socket, so the same bytes can be issued from a different egress.

```sh
RELAY_TOKEN="$(curl -sS -X POST https://tcp.ssh.relay.ajam.dev/v1/mint \
  -H 'content-type: application/json' -d '{}' | jq -r .token)"
RELAY_TOKEN="$RELAY_TOKEN" node relay_probe.mjs tcp.ssh.relay.ajam.dev \
  repo.archlinuxpower.org 443 vpc node
```

GitHub CI (the egress that actually fails): the three workflows under
`.github/workflows/` run the same matrix from a GitHub-hosted Azure runner and write a
table to the run summary.

## Files

| file | what it is |
| --- | --- |
| `worker.js` | `pkgforge-dev/reverse-proxies/api.rv.pkgforge.dev/worker.js` verbatim |
| `config.capnp` | workerd config serving that worker |
| `probe.sh` | one target path through system curl / browser TLS / HTTP versions |
| `node_tls_direct.mjs` | direct Node TLS with a selectable ClientHello shape |
| `relay_probe.mjs` | raw TCP over the relay WebSocket + Node TLS |
| `tls_profiles.mjs` | the ClientHello shapes used above |
| `RESULTS.md` | measured tables, run links, mechanism, scope |

## What this means for the mirror

`api.rv.pkgforge.dev` only rewrites headers and User-Agent (`worker.js:14-26`,
`worker.js:49-60`). The check that fires is upstream of that: the worker's own
Cloudflare fetch still presents a low-trust fingerprint from a low-reputation egress,
so it returns `403` too when called from a datacenter client (measured, see
`RESULTS.md`). A header-only proxy cannot fix a TLS/header-consistency score. A
fetcher that presents a real browser identity (a `tls-client`/`curl-impersonate`
style stack, or the relay with a clean egress) gets `200` on the same path.

Same problem space as Neucom Info's own proxy work: the Electrosphere only accepts a
client whose identity is internally consistent, however it is assembled.
