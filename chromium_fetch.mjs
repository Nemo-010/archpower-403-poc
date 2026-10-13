#!/usr/bin/env node
// Tier 2: a real Chromium solves whatever the origin serves, then its cookie jar
// (including cf_clearance) is used to fetch the raw bytes.
//
//   node chromium_fetch.mjs <url> <out> [referer]
//
// Env:
//   CHROME_FULL=1     use the full Chrome-for-Testing build, new headless mode
//   CHROME_UA=...     override the user agent
//   CHROME_STEALTH=1  drop the automation tells Playwright leaves behind
//   CHROME_WAIT=...   seconds to wait out a challenge (default 30)
import { chromium } from "playwright";
import fs from "node:fs";

const [, , url, out, referer] = process.argv;
if (!url || !out) {
  console.error("usage: chromium_fetch.mjs <url> <out> [referer]");
  process.exit(2);
}
const origin = new URL(referer || url).origin;
const full = process.env.CHROME_FULL === "1";
const stealth = process.env.CHROME_STEALTH === "1";
const ua = process.env.CHROME_UA || undefined;
const waitS = Number(process.env.CHROME_WAIT || 30);

const args = ["--no-sandbox", "--disable-dev-shm-usage"];
if (stealth) args.push("--disable-blink-features=AutomationControlled");

const launch = full ? { channel: "chromium", args } : { args };
const browser = await chromium.launch({ headless: true, ...launch });
try {
  const context = await browser.newContext({
    userAgent: ua,
    locale: "en-US",
    timezoneId: "UTC",
    viewport: { width: 1366, height: 768 },
  });
  if (stealth) {
    await context.addInitScript(() => {
      Object.defineProperty(navigator, "webdriver", { get: () => undefined });
      window.chrome = window.chrome || { runtime: {} };
      Object.defineProperty(navigator, "plugins", { get: () => [1, 2, 3, 4, 5] });
      Object.defineProperty(navigator, "languages", { get: () => ["en-US", "en"] });
    });
  }
  const page = await context.newPage();

  let challenged = false;
  let title = "";
  try {
    await page.goto(origin, { waitUntil: "domcontentloaded", timeout: 60000 });
    const deadline = Date.now() + waitS * 1000;
    while (Date.now() < deadline) {
      title = await page.title().catch(() => "");
      if (/just a moment|attention required|checking your browser|verify|one more step/i.test(title)) {
        challenged = true;
        await page.waitForTimeout(2000);
      } else break;
    }
  } catch (e) {
    console.error(`chromium_fetch: origin visit: ${e.message}`);
  }

  const resp = await context.request.get(url, { timeout: 180000 });
  const status = resp.status();
  const body = status === 200 ? await resp.body() : Buffer.alloc(0);
  if (status === 200) fs.writeFileSync(out, body);
  const seenUA = await page.evaluate(() => navigator.userAgent).catch(() => "?");
  const wd = await page.evaluate(() => navigator.webdriver).catch(() => "?");
  console.log(
    JSON.stringify({
      status,
      bytes: body.length,
      challenged,
      title,
      ua: seenUA,
      webdriver: wd,
      full,
      stealth,
    })
  );
  process.exit(status === 200 ? 0 : 1);
} finally {
  await browser.close();
}
