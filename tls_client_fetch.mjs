#!/usr/bin/env node
// Engine: node-tls-client (Go uTLS) — a TLS stack independent of BoringSSL/OpenSSL.
import fs from "node:fs";
import { Session } from "node-tls-client";

const [, , url, out] = process.argv;
if (!url || !out) {
  console.error("usage: tls_client_fetch.mjs <url> <out>");
  process.exit(2);
}

const session = new Session({ clientIdentifier: "chrome_136" });
try {
  const r = await session.get(url, { timeout: 120 });
  if (r.status !== 200) {
    console.error(`tls-client: status ${r.status}`);
    process.exit(1);
  }
  const body = r.body;
  const buf =
    Buffer.isBuffer(body) ? body
      : typeof body === "string" ? Buffer.from(body, "binary")
        : Buffer.from(body);
  fs.writeFileSync(out, buf);
} finally {
  try { await session.close(); } catch {}
}
