#!/usr/bin/env node
// Raw TCP over the WebSocket relay, then a userspace TLS ClientHello from Node.
//
// Usage:
//   RELAY_TOKEN=<t> node relay_probe.mjs <relay-host> <target-host> <port> <path> <tlsProfile>
//
// path:        auto | vpc | direct          (relay egress road; see /index.md)
// tlsProfile:  node | node12 | chrome | firefox | safari
//
// Prints one JSON line: { relay, target, road, tlsProfile, httpStatus, headers, elapsedMs, error }
import tls from "node:tls";
import { Duplex } from "node:stream";

const [, , relayHost, targetHost, portArg, road = "auto", tlsProfile = "node"] = process.argv;
if (!relayHost || !targetHost) {
  console.error("usage: relay_probe.mjs <relay-host> <target-host> <port> [road] [tlsProfile]");
  process.exit(2);
}
const token = process.env.RELAY_TOKEN;
if (!token) {
  console.error("set RELAY_TOKEN (POST https://tcp.ssh.relay.ajam.dev/v1/mint)");
  process.exit(2);
}
const port = Number(portArg || 443);

class RelaySocket extends Duplex {
  _read() {}
  _write(chunk, _enc, cb) {
    try {
      if (this.ws && this.ws.readyState === WebSocket.OPEN) this.ws.send(chunk);
    } catch (e) {
      this.emit("error", e);
    }
    cb();
  }
  _final(cb) {
    try { this.ws?.close(); } catch {}
    cb();
  }
  attach(ws) { this.ws = ws; }
  deliver(u8) { this.push(Buffer.from(u8)); }
  _destroy(err, cb) {
    try { this.ws?.close(); } catch {}
    cb(err);
  }
}

function openRelay(timeoutMs = 20000) {
  return new Promise((resolve, reject) => {
    const params = new URLSearchParams({ token });
    if (road === "vpc" || road === "direct") params.set("path", road);
    const url = `wss://${relayHost}/connect/${targetHost}/${port}?${params}`;
    let ws;
    try { ws = new WebSocket(url); } catch (e) { return reject(e); }
    ws.binaryType = "arraybuffer";
    const sock = new RelaySocket();
    const timer = setTimeout(() => { try { ws.close(); } catch {} reject(new Error("relay open timeout")); }, timeoutMs);
    ws.addEventListener("open", () => { clearTimeout(timer); sock.attach(ws); resolve(sock); });
    ws.addEventListener("message", (e) => { if (typeof e.data !== "string") sock.deliver(new Uint8Array(e.data)); });
    ws.addEventListener("error", () => { clearTimeout(timer); reject(new Error("relay websocket error")); });
    ws.addEventListener("close", (e) => {
      clearTimeout(timer);
      // 1000/1005/1006 are normal for a half-closed TCP target.
      sock.push(null);
    });
  });
}

// Distinct ClientHello shapes. Node's defaults differ from a browser's; the point
// is that these produce different JA3/JA4 while the source IP (the relay) is fixed.
const PROFILES = {
  node: {},
  node12: { minVersion: "TLSv1.2", maxVersion: "TLSv1.2" },
  chrome: {
    minVersion: "TLSv1.2",
    maxVersion: "TLSv1.3",
    ciphers: [
      "TLS_AES_128_GCM_SHA256",
      "TLS_AES_256_GCM_SHA384",
      "TLS_CHACHA20_POLY1305_SHA256",
      "ECDHE-ECDSA-AES128-GCM-SHA256",
      "ECDHE-RSA-AES128-GCM-SHA256",
      "ECDHE-ECDSA-AES256-GCM-SHA384",
      "ECDHE-RSA-AES256-GCM-SHA384",
      "ECDHE-ECDSA-CHACHA20-POLY1305",
      "ECDHE-RSA-CHACHA20-POLY1305",
      "ECDHE-RSA-AES128-SHA",
      "ECDHE-RSA-AES256-SHA",
      "AES128-GCM-SHA256",
      "AES256-GCM-SHA384",
      "AES128-SHA",
      "AES256-SHA",
    ].join(":"),
    sigalgs: "ecdsa_secp256r1_sha256:rsa_pss_rsae_sha256:rsa_pkcs1_sha256:ecdsa_secp384r1_sha384:rsa_pss_rsae_sha384:rsa_pkcs1_sha384:rsa_pss_rsae_sha512:rsa_pkcs1_sha512",
    ALPNProtocols: ["h2", "http/1.1"],
    ecdhCurve: "X25519:P-256:P-384",
  },
  firefox: {
    minVersion: "TLSv1.2",
    maxVersion: "TLSv1.3",
    ciphers: [
      "TLS_AES_128_GCM_SHA256",
      "TLS_CHACHA20_POLY1305_SHA256",
      "TLS_AES_256_GCM_SHA384",
      "ECDHE-ECDSA-AES128-GCM-SHA256",
      "ECDHE-RSA-AES128-GCM-SHA256",
      "ECDHE-ECDSA-CHACHA20-POLY1305",
      "ECDHE-RSA-CHACHA20-POLY1305",
      "ECDHE-ECDSA-AES256-GCM-SHA384",
      "ECDHE-RSA-AES256-GCM-SHA384",
      "ECDHE-ECDSA-AES256-SHA",
      "ECDHE-ECDSA-AES128-SHA",
      "ECDHE-RSA-AES128-SHA",
      "ECDHE-RSA-AES256-SHA",
      "AES128-GCM-SHA256",
      "AES256-GCM-SHA384",
      "AES128-SHA",
      "AES256-SHA",
    ].join(":"),
    sigalgs: "ecdsa_secp256r1_sha256:ecdsa_secp384r1_sha384:ecdsa_secp521r1_sha512:rsa_pss_rsae_sha256:rsa_pss_rsae_sha384:rsa_pss_rsae_sha512:rsa_pkcs1_sha256:rsa_pkcs1_sha384:rsa_pkcs1_sha512",
    ALPNProtocols: ["h2", "http/1.1"],
    ecdhCurve: "X25519:P-256:P-384:P-521",
  },
  safari: {
    minVersion: "TLSv1.2",
    maxVersion: "TLSv1.3",
    ciphers: [
      "TLS_AES_128_GCM_SHA256",
      "TLS_AES_256_GCM_SHA384",
      "TLS_CHACHA20_POLY1305_SHA256",
      "ECDHE-ECDSA-AES128-GCM-SHA256",
      "ECDHE-RSA-AES128-GCM-SHA256",
      "ECDHE-ECDSA-AES256-GCM-SHA384",
      "ECDHE-RSA-AES256-GCM-SHA384",
      "ECDHE-ECDSA-CHACHA20-POLY1305",
      "ECDHE-RSA-CHACHA20-POLY1305",
      "ECDHE-ECDSA-AES128-SHA",
      "ECDHE-RSA-AES128-SHA",
      "ECDHE-ECDSA-AES256-SHA",
      "ECDHE-RSA-AES256-SHA",
      "AES128-GCM-SHA256",
      "AES256-GCM-SHA384",
      "AES128-SHA",
      "AES256-SHA",
    ].join(":"),
    ALPNProtocols: ["h2", "http/1.1"],
    ecdhCurve: "X25519:P-256:P-384:P-521",
  },
};

const started = Date.now();
const result = { relay: relayHost, target: `${targetHost}:${port}`, road, tlsProfile };

try {
  const sock = await openRelay();
  const tlsSock = tls.connect({ socket: sock, servername: targetHost, rejectUnauthorized: false, ...PROFILES[tlsProfile] });
  let buf = Buffer.alloc(0);
  await new Promise((resolve, reject) => {
    const hardStop = setTimeout(() => reject(new Error("tls/idle timeout")), 25000);
    tlsSock.on("secureConnect", () => {
      result.tlsVersion = tlsSock.getProtocol();
      result.alpn = tlsSock.alpnProtocol || null;
      tlsSock.write(
        `GET /base/powerpc/base.db HTTP/1.1\r\nHost: ${targetHost}\r\n` +
          `User-Agent: relay-tls-probe/1 (+poc)\r\nAccept: */*\r\nConnection: close\r\n\r\n`
      );
    });
    tlsSock.on("data", (d) => {
      buf = Buffer.concat([buf, d]);
      if (buf.length > 32768) tlsSock.destroy();
    });
    tlsSock.on("end", () => { clearTimeout(hardStop); resolve(); });
    tlsSock.on("close", () => { clearTimeout(hardStop); resolve(); });
    tlsSock.on("error", (e) => { clearTimeout(hardStop); reject(e); });
  });
  const text = buf.toString("latin1");
  const status = /^HTTP\/\d\.\d (\d{3})/.exec(text);
  result.httpStatus = status ? Number(status[1]) : null;
  result.bytes = buf.length;
  const hdrEnd = text.indexOf("\r\n\r\n");
  if (hdrEnd > 0) {
    result.headers = Object.fromEntries(
      text.slice(0, hdrEnd).split("\r\n").slice(1).map((l) => {
        const i = l.indexOf(":");
        return [l.slice(0, i).toLowerCase().trim(), l.slice(i + 1).trim()];
      })
    );
  }
  result.bodyHead = text.slice(hdrEnd + 4, hdrEnd + 80).replace(/\s+/g, " ").trim();
} catch (e) {
  result.error = e.message;
}
result.elapsedMs = Date.now() - started;
console.log(JSON.stringify(result));
