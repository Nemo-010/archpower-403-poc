#!/usr/bin/env node
// Engine: raw TCP over the relay WebSocket, then a browser-shaped TLS ClientHello
// from Node. Uses a different egress (Cloudflare Gateway) and a different stack.
//
//   RELAY_TOKEN=... node relay_fetch.mjs <url> <out>
import tls from "node:tls";
import fs from "node:fs";
import { Duplex } from "node:stream";
import { PROFILES } from "./tls_profiles.mjs";

const [, , urlArg, out] = process.argv;
if (!urlArg || !out) {
  console.error("usage: relay_fetch.mjs <url> <out>");
  process.exit(2);
}
const u = new URL(urlArg);
const token = process.env.RELAY_TOKEN;
if (!token) {
  console.error("set RELAY_TOKEN");
  process.exit(2);
}
const relayHost = process.env.RELAY_HOST || "tcp.ssh.relay.ajam.dev";
const road = process.env.RELAY_ROAD || "vpc";

class RelaySocket extends Duplex {
  _read() {}
  _write(chunk, _enc, cb) {
    try { if (this.ws && this.ws.readyState === WebSocket.OPEN) this.ws.send(chunk); } catch (e) { this.emit("error", e); }
    cb();
  }
  _final(cb) { try { this.ws?.close(); } catch {} cb(); }
  attach(ws) { this.ws = ws; }
  deliver(u8) { this.push(Buffer.from(u8)); }
  _destroy(err, cb) { try { this.ws?.close(); } catch {} cb(err); }
}

function openRelay(timeoutMs = 20000) {
  return new Promise((resolve, reject) => {
    const params = new URLSearchParams({ token });
    if (road === "vpc" || road === "direct") params.set("path", road);
    const ws = new WebSocket(`wss://${relayHost}/connect/${u.hostname}/${u.port || 443}?${params}`);
    ws.binaryType = "arraybuffer";
    const sock = new RelaySocket();
    const timer = setTimeout(() => { try { ws.close(); } catch {} reject(new Error("relay open timeout")); }, timeoutMs);
    ws.addEventListener("open", () => { clearTimeout(timer); sock.attach(ws); resolve(sock); });
    ws.addEventListener("message", (e) => { if (typeof e.data !== "string") sock.deliver(new Uint8Array(e.data)); });
    ws.addEventListener("error", () => { clearTimeout(timer); reject(new Error("relay websocket error")); });
    ws.addEventListener("close", () => { sock.push(null); });
  });
}

function dechunk(buf) {
  const parts = [];
  let i = 0;
  while (i < buf.length) {
    const nl = buf.indexOf("\r\n", i);
    if (nl < 0) return null;
    const size = parseInt(buf.slice(i, nl).toString("latin1").split(";")[0], 16);
    if (Number.isNaN(size)) return null;
    if (size === 0) return Buffer.concat(parts);
    const start = nl + 2;
    if (start + size > buf.length) return null;
    parts.push(buf.slice(start, start + size));
    i = start + size + 2;
  }
  return null;
}

try {
  const sock = await openRelay();
  const tlsSock = tls.connect({
    socket: sock,
    servername: u.hostname,
    rejectUnauthorized: false,
    ...PROFILES[process.env.RELAY_TLS || "chrome"],
  });
  await new Promise((resolve, reject) => {
    tlsSock.once("secureConnect", resolve);
    tlsSock.once("error", reject);
  });

  let buf = Buffer.alloc(0);
  const wrote = await new Promise((resolve, reject) => {
    tlsSock.on("data", (d) => { buf = Buffer.concat([buf, d]); });
    tlsSock.on("error", reject);
    tlsSock.on("end", () => resolve(true));
    tlsSock.on("close", () => resolve(true));
    tlsSock.write(
      `GET ${u.pathname}${u.search} HTTP/1.1\r\nHost: ${u.hostname}\r\n` +
        `User-Agent: relay-fetch/1\r\nAccept: */*\r\nConnection: close\r\n\r\n`
    );
    setTimeout(() => reject(new Error("relay fetch timeout")), 120000);
  });
  if (!wrote) throw new Error("relay closed early");

  const he = buf.indexOf("\r\n\r\n");
  if (he < 0) throw new Error("no HTTP header terminator");
  const head = buf.slice(0, he).toString("latin1");
  const m = /^HTTP\/\d\.\d (\d{3})/.exec(head);
  const status = m ? Number(m[1]) : 0;
  if (status !== 200) throw new Error(`relay: status ${status}`);

  const rawBody = buf.slice(he + 4);
  let body = rawBody;
  if (/transfer-encoding:\s*chunked/i.test(head)) {
    const d = dechunk(rawBody);
    if (!d) throw new Error("bad chunked body");
    body = d;
  } else {
    const cl = /content-length:\s*(\d+)/i.exec(head);
    if (cl) body = rawBody.slice(0, Number(cl[1]));
  }
  fs.writeFileSync(out, body);
} catch (e) {
  console.error(`relay_fetch: ${e.message}`);
  process.exit(1);
}
