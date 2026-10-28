#!/usr/bin/env node
// Makes the site's images in public/ from the real app's screenshots and the mascot art. The
// results are committed, so this only runs when the pictures change. Needs ffmpeg (with libwebp)
// and sips, both on Mike's Mac.
//
//   node scripts/images.mjs [mac shots dir] [iPhone shots dir]
//
// Mac shots: app/Tools/screenshots.sh <dir> --appearance light (the mock runner's demo threads,
// made-up data; nothing from a real thread). iPhone shots: ios/scripts/sim-shots.sh <dir> (the
// FakeBackend's sample threads). Defaults are where those scripts were last pointed.
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const site = join(dirname(fileURLToPath(import.meta.url)), "..");
const repo = join(site, "..");
const mac = process.argv[2] ?? "/tmp/tb-shots-light";
const phone = process.argv[3] ?? "/tmp/tb-shots";
const screens = join(site, "public/screens");
const img = join(site, "public/img");
mkdirSync(screens, { recursive: true });
mkdirSync(img, { recursive: true });

/**
 * A PNG to WebP at `width` pixels wide, keeping transparency (the Mac window's round corners).
 * `crop` is ffmpeg's w:h:x:y, in the source's pixels, applied first.
 */
function webp(from, to, width, quality = 82, crop) {
  if (!existsSync(from)) throw new Error(`Missing ${from}`);
  const vf = `${crop ? `crop=${crop},` : ""}scale=${width}:-2:flags=lanczos`;
  execFileSync("ffmpeg", ["-loglevel", "error", "-y", "-i", from, "-vf", vf,
    "-c:v", "libwebp", "-quality", String(quality), "-pix_fmt", "yuva420p", to]);
  console.log(to.replace(site + "/", ""));
}

// The Mac app, from Screenshots.swift's scenes (2480 x 1640, a 1240 x 820 window at 2x). The
// hero is the whole window; the feature cards get the part that matters, cropped at full size,
// since the whole window shrunk into a card is too small to read.
const MAC = {
  "mac-thread": ["1-thread-bottom.png", 2200],
  // The transcript's last lines, "Bear with me" and the patch buttons over the message box.
  "mac-patches": ["6a-long-reply-streaming.png", 940, "940:630:720:1010"],
  // The account menu, open over a new thread (just the menu: around it is the sidebar, cut off).
  "mac-accounts": ["13a-account-picker.png", 700, "700:576:664:94"],
  // The middle of a finished turn: the plan, what changed and the before and after table.
  "mac-diffs": ["2-plan-and-diffs.png", 940, "940:985:720:150"],
};
for (const [name, [file, width, crop]] of Object.entries(MAC)) webp(join(mac, file), join(screens, `${name}.webp`), width, 82, crop);

// The iPhone app on the FakeBackend's sample threads.
for (const name of ["inbox", "approval", "question"]) webp(join(phone, `${name}.png`), join(screens, `phone-${name}.webp`), 600);

// The mascot: the workbench picture (docs/threadbear-design/mascot-c.png, the README hero) and
// three of the full body sprites, each used once.
const design = join(repo, "docs/threadbear-design");
webp(join(design, "mascot-c.png"), join(img, "workbench.webp"), 1200, 80);
for (const pose of ["wave", "sleep", "dizzy"]) webp(join(design, "sprites-full", `${pose}.png`), join(img, `bear-${pose}.webp`), 280, 85);

// Icons from the app icon (app/icons/threadbear.png, 1024 px).
const icon = join(repo, "app/icons/threadbear.png");
for (const [name, size] of [["icon-512", 512], ["icon-192", 192], ["apple-touch-icon", 180], ["favicon-32", 32]]) {
  execFileSync("sips", ["-z", String(size), String(size), icon, "--out", join(img, `${name}.png`)], { stdio: "ignore" });
  console.log(`public/img/${name}.png`);
}
