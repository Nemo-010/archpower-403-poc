#!/usr/bin/env node
// SPDX-License-Identifier: 0BSD
//
// Retrieve a URL with node-tls-client (Go uTLS).
//
//   node tls_client_fetch.mjs <url> <out>
//
// Env:
//   TLS_CLIENT_ID  profile (default: chrome_131)
import fs from "node:fs";
import { initTLS, destroyTLS, Session } from "node-tls-client";

const [, , url, out] = process.argv;
if (!url || !out) {
  console.error("usage: tls_client_fetch.mjs <url> <out>");
  process.exit(2);
}

// The native library has to be initialised before a session is created.
await initTLS();
const session = new Session({
  clientIdentifier: process.env.TLS_CLIENT_ID || "chrome_131",
});
try {
  const r = await session.get(url, { timeout: 180 });
  if (r.status !== 200) {
    console.error(`tls_client: status ${r.status}`);
    process.exit(1);
  }
  const body = r.body;
  const buf = Buffer.isBuffer(body)
    ? body
    : typeof body === "string"
      ? Buffer.from(body, "binary")
      : Buffer.from(body);
  fs.writeFileSync(out, buf);
} finally {
  try { await session.close(); } catch {}
  try { await destroyTLS(); } catch {}
}
