#!/usr/bin/env node
// SPDX-License-Identifier: 0BSD
//
// Retrieve a URL with a real Chromium.
//
//   node chromium_fetch.mjs <url> <out> [referer]
//
// The HTTP request is issued from inside the page with fetch(), so it uses
// Chromium's own network stack and its cookie jar. Playwright's request context
// is a separate Node-side HTTP client and does not produce the same request.
//
// Env:
//   CHROME_UA    user agent (default: derived from the running build)
//   CHROME_WAIT  seconds to wait for the page to settle (default 20)
import { chromium } from "playwright";
import fs from "node:fs";

const [, , url, out, referer] = process.argv;
if (!url || !out) {
  console.error("usage: chromium_fetch.mjs <url> <out> [referer]");
  process.exit(2);
}
const origin = new URL(referer || url).origin;
const waitS = Number(process.env.CHROME_WAIT || 20);

// The full Chrome-for-Testing build, whose user agent and client hints match
// what it actually sends.
const browser = await chromium.launch({
  headless: true,
  channel: "chromium",
  args: ["--no-sandbox", "--disable-dev-shm-usage"],
});
try {
  // Derive the user agent from the build itself, so it stays consistent with
  // the client hints and the TLS stack as the build ages.
  const version = browser.version();
  const ua =
    process.env.CHROME_UA ||
    `Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/${version} Safari/537.36`;

  const context = await browser.newContext({
    userAgent: ua,
    locale: "en-US",
    timezoneId: "UTC",
    viewport: { width: 1366, height: 768 },
  });
  const page = await context.newPage();

  try {
    await page.goto(origin, { waitUntil: "domcontentloaded", timeout: 60000 });
    const deadline = Date.now() + waitS * 1000;
    while (Date.now() < deadline) {
      const ready = await page.evaluate(() => document.readyState).catch(() => "");
      if (ready === "complete") break;
      await page.waitForTimeout(250);
    }
  } catch (e) {
    console.error(`chromium_fetch: origin visit: ${e.message}`);
  }

  const r = await page.evaluate(async (u) => {
    const resp = await fetch(u, { credentials: "include", cache: "no-store" });
    if (!resp.ok) return { status: resp.status };
    const buf = new Uint8Array(await resp.arrayBuffer());
    let s = "";
    for (let i = 0; i < buf.length; i += 0x8000) {
      s += String.fromCharCode.apply(null, buf.subarray(i, i + 0x8000));
    }
    return { status: resp.status, b64: btoa(s) };
  }, url);

  if (r.status !== 200 || !r.b64) {
    console.error(`chromium_fetch: status ${r.status}`);
    process.exit(1);
  }
  fs.writeFileSync(out, Buffer.from(r.b64, "base64"));
} finally {
  await browser.close();
}
