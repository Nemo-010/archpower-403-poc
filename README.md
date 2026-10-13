# archpower-403-poc (temporary)

Reproduction harness for the `403` that `pkgforge-dev/docker-archlinux` hit fetching
`https://repo.archlinuxpower.org/base/powerpc/base.db` (kth5/archpower#160).

Question under test: is the block keyed on the **source IP/ASN**, or on the **TLS
ClientHello / User-Agent / HTTP version**?

`worker.js` is `pkgforge-dev/reverse-proxies/api.rv.pkgforge.dev/worker.js` verbatim.
`probe.sh` runs one target path through several client shapes from the current egress.
`relay_probe.mjs` sends raw TCP through `tcp.ssh.relay.ajam.dev` and runs a Node TLS
ClientHello over it, so the same bytes can be compared from different source IPs.

No issue, comment or pull request is opened anywhere. Results land in the Actions summary.
