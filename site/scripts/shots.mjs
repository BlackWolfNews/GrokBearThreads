#!/usr/bin/env node
// Full page screenshots of the built site for review, desktop (1440 wide) and phone (390 wide),
// into site/review/ (gitignored). Serve it first (`npm run serve`), then `npm run shots`.
// Playwright comes from wherever it's installed (PLAYWRIGHT_DIR, default Mike's mikerosoft.app
// checkout), so the site itself has no dependencies.
//
// Every .reveal section is shown and the tagline lit before the shot, since a full page shot
// doesn't scroll and they'd otherwise stay hidden.
import { mkdirSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const base = process.env.SITE_URL_LOCAL ?? "http://localhost:5176";
const playwrightDir = process.env.PLAYWRIGHT_DIR ?? `${process.env.HOME}/dev/me/mikerosoft.app/`;
const { chromium } = createRequire(playwrightDir.endsWith("/") ? playwrightDir : `${playwrightDir}/`)("playwright");
const out = join(dirname(fileURLToPath(import.meta.url)), "../review");
mkdirSync(out, { recursive: true });

const browser = await chromium.launch();
for (const [name, viewport, scale] of [["desktop", { width: 1440, height: 900 }, 1], ["phone", { width: 390, height: 844 }, 2]]) {
  const page = await browser.newPage({ viewport, deviceScaleFactor: scale, isMobile: name === "phone", hasTouch: name === "phone" });
  for (const [path, file] of [["/", "home"], ["/nope", "404"]]) {
    await page.goto(base + path, { waitUntil: "load" });
    await page.evaluate(async () => {
      document.querySelectorAll(".reveal").forEach((el) => el.classList.add("in"));
      document.querySelectorAll(".tagline .word").forEach((el) => el.classList.add("on"));
      // Lazy images only load near the screen, so load them all now, waiting 5 s at most.
      document.querySelectorAll('img[loading="lazy"]').forEach((img) => { img.loading = "eager"; });
      const loaded = Promise.all([...document.images].map((img) => img.decode().catch(() => null)));
      await Promise.race([loaded, new Promise((r) => setTimeout(r, 5000))]);
    });
    await page.waitForTimeout(900);
    const path_ = join(out, `${file}-${name}.png`);
    await page.screenshot({ path: path_, fullPage: true });
    console.log(path_);
  }
  await page.close();
}
await browser.close();
