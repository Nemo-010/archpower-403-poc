#!/usr/bin/env node
// Direct (no relay) userspace TLS handshake from this host to the origin, with a
// selectable ClientHello shape. Isolates the TLS fingerprint from the relay and
// from curl: same source IP, one variable changed.
//
//   node node_tls_direct.mjs <profile> [host] [path]
import tls from "node:tls";
import { PROFILES } from "./tls_profiles.mjs";

const [, , profileName = "node", host = "repo.archlinuxpower.org", pathq = "/base/powerpc/base.db"] = process.argv;
const profile = PROFILES[profileName];
if (!profile) {
  console.error(`unknown profile: ${profileName}`);
  process.exit(2);
}

const started = Date.now();
const result = { target: `${host}:443${pathq}`, tlsProfile: profileName };
try {
  const t = tls.connect({ host, port: 443, servername: host, rejectUnauthorized: false, ...profile });
  let buf = Buffer.alloc(0);
  await new Promise((resolve, reject) => {
    const stop = setTimeout(() => reject(new Error("timeout")), 25000);
    t.on("secureConnect", () => {
      result.tlsVersion = t.getProtocol();
      result.alpn = t.alpnProtocol || null;
      t.write(
        `GET ${pathq} HTTP/1.1\r\nHost: ${host}\r\n` +
          `User-Agent: node-tls-probe/1 (+poc)\r\nAccept: */*\r\nConnection: close\r\n\r\n`
      );
    });
    t.on("data", (d) => {
      buf = Buffer.concat([buf, d]);
      if (buf.length > 32768) t.destroy();
    });
    t.on("end", () => { clearTimeout(stop); resolve(); });
    t.on("close", () => { clearTimeout(stop); resolve(); });
    t.on("error", (e) => { clearTimeout(stop); reject(e); });
  });
  const text = buf.toString("latin1");
  const m = /^HTTP\/\d\.\d (\d{3})/.exec(text);
  result.httpStatus = m ? Number(m[1]) : null;
  result.bytes = buf.length;
  const he = text.indexOf("\r\n\r\n");
  if (he > 0) {
    result.headers = Object.fromEntries(
      text.slice(0, he).split("\r\n").slice(1).map((l) => {
        const i = l.indexOf(":");
        return [l.slice(0, i).toLowerCase().trim(), l.slice(i + 1).trim()];
      })
    );
  }
  result.bodyHead = text.slice(he + 4, he + 80).replace(/\s+/g, " ").trim();
} catch (e) {
  result.error = e.message;
}
result.elapsedMs = Date.now() - started;
console.log(JSON.stringify(result));
