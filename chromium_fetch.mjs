#!/usr/bin/env node
// Tier 2: a real Chromium solves whatever the origin serves, then its cookie jar
// (including cf_clearance) is used to fetch the raw bytes.
//
//   node chromium_fetch.mjs <url> <out> [referer]
//
// Nothing here synthesises a fingerprint: this is the browser.
import { chromium } from "playwright";
import fs from "node:fs";

const [, , url, out, referer] = process.argv;
if (!url || !out) {
  console.error("usage: chromium_fetch.mjs <url> <out> [referer]");
  process.exit(2);
}
const origin = new URL(referer || url).origin;

const browser = await chromium.launch({
  headless: true,
  args: ["--no-sandbox", "--disable-dev-shm-usage"],
});
try {
  const context = await browser.newContext({
    locale: "en-US",
    timezoneId: "UTC",
    viewport: { width: 1366, height: 768 },
  });
  const page = await context.newPage();

  // Visit the origin first so any challenge runs and sets its cookie.
  let challenged = false;
  try {
    await page.goto(origin, { waitUntil: "domcontentloaded", timeout: 60000 });
    for (let i = 0; i < 20; i++) {
      const t = await page.title();
      if (/just a moment|attention required|checking your browser|verify/i.test(t)) {
        challenged = true;
        await page.waitForTimeout(2000);
      } else break;
    }
  } catch (e) {
    console.error(`chromium_fetch: origin visit: ${e.message}`);
  }

  const resp = await context.request.get(url, { timeout: 180000 });
  if (resp.status() !== 200) {
    console.error(`chromium_fetch: status ${resp.status()} (challenged=${challenged})`);
    process.exit(1);
  }
  const body = await resp.body();
  fs.writeFileSync(out, body);
  console.error(
    `chromium_fetch: 200, ${body.length} bytes, challenged=${challenged}, ua=${await page.evaluate(() => navigator.userAgent)}`
  );
} finally {
  await browser.close();
}
