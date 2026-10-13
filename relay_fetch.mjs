#!/usr/bin/env node
// Engine: raw TCP over the relay WebSocket, then a browser-shaped TLS ClientHello
// from Node. Uses a different egress (Cloudflare Gateway) and a different stack.
//
//   RELAY_TOKEN=... node relay_fetch.mjs <url> <out>
import tls from "node:tls";
import http from "node:http";
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
    const wsUrl = `wss://${relayHost}/connect/${u.hostname}/${u.port || 443}?${params}`;
    const ws = new WebSocket(wsUrl);
    ws.binaryType = "arraybuffer";
    const sock = new RelaySocket();
    const timer = setTimeout(() => { try { ws.close(); } catch {} reject(new Error("relay open timeout")); }, timeoutMs);
    ws.addEventListener("open", () => { clearTimeout(timer); sock.attach(ws); resolve(sock); });
    ws.addEventListener("message", (e) => { if (typeof e.data !== "string") sock.deliver(new Uint8Array(e.data)); });
    ws.addEventListener("error", () => { clearTimeout(timer); reject(new Error("relay websocket error")); });
    ws.addEventListener("close", () => { sock.push(null); });
  });
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
  const file = fs.createWriteStream(out);
  await new Promise((resolve, reject) => {
    const req = http.request(
      {
        host: u.hostname,
        port: u.port || 443,
        path: u.pathname + u.search,
        method: "GET",
        createConnection: () => tlsSock,
        agent: false,
        headers: { Host: u.hostname, "User-Agent": "relay-fetch/1", Accept: "*/*" },
      },
      (res) => {
        if (res.statusCode !== 200) { reject(new Error(`relay: status ${res.statusCode}`)); return; }
        res.pipe(file);
        file.on("finish", resolve);
        res.on("error", reject);
      }
    );
    req.on("error", reject);
    req.end();
  });
} catch (e) {
  console.error(`relay_fetch: ${e.message}`);
  process.exit(1);
}
