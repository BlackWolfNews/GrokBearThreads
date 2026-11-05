#!/usr/bin/env node
// Records the hero's clips: the demo app (mock runner, made-up threads, dark mode) driven through
// one feature each, recorded from its window and encoded into public/clips/. The results are
// committed, so this only runs when the clips should change.
//
//   MOCK_SCRIPTED_TURNS=$PWD/scripts/clips/turns.json \
//     ../app/Tools/dev-app.sh start --mock --appearance dark --size 1240x820 --id siteclips
//   node scripts/clips.mjs [name...]        (all six without names)
//   ../app/Tools/dev-app.sh stop --id siteclips
//
// turns.json has the made-up replies the mock streams when a clip sends a message or answers a
// question. Needs Screen Recording permission for the shell (scripts/record-window.swift), ffmpeg,
// and a dark mode screenshot set for the window's traffic lights (HERO_SHOTS, as images.mjs):
// a window in the background draws them as a grey blob, so each clip gets the screenshot's.
// A clip changes the mock's threads (it sends messages, answers a question), so record from a
// fresh instance: stop and start it again before running them all.
import { execFileSync, spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const site = join(dirname(fileURLToPath(import.meta.url)), "..");
const devApp = join(site, "../app/Tools/dev-app.sh");
const id = process.env.CLIPS_APP_ID ?? "siteclips";
const shots = process.env.HERO_SHOTS ?? "/tmp/tb-shots-dark";
const out = join(site, "public/clips");
const work = join(tmpdir(), "threadbear-site-clips");
mkdirSync(out, { recursive: true });
mkdirSync(work, { recursive: true });

function run(...commands) {
  const r = spawnSync(devApp, ["--id", id, "do", ...commands.map((c) => JSON.stringify(c))], { encoding: "utf8" });
  if (r.status !== 0) throw new Error(`${commands.map((c) => c.cmd).join(", ")}: ${r.stdout}${r.stderr}`);
  return r.stdout;
}
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
/** Types like a person: the composer (or a search box) filled a few letters at a time. */
async function type(text, field = "composer") {
  for (let i = 5; i < text.length + 5; i += 5) {
    const part = text.slice(0, i);
    run(field === "composer" ? { cmd: "type", text: part, replace: true } : { cmd: "search", text: part, projects: true });
  }
}
/** Waits for a thread's turn to finish, as the status command reports it. */
async function idle(thread, ms = 20000) {
  const end = Date.now() + ms;
  await wait(600);
  while (Date.now() < end) {
    const status = JSON.parse(run({ cmd: "status" }).replace(/^status ok /, ""));
    if (status.threads.find((t) => t.id === thread)?.status === "idle") return;
    await wait(250);
  }
  throw new Error(`${thread} still running`);
}

// The mock writes the landing pages thread's mockups into the instance's data folder.
const mockup = (name) => join(tmpdir(), "threadbear-dev-app", id, "data/work/site/mockups", name);

// One per slide in scripts/build.mjs's SLIDES, in the same order. `setup` runs before recording.
const CLIPS = {
  threads: {
    setup: () => run({ cmd: "mode", mode: "inbox" }, { cmd: "open", id: "demo_upload_resume" }),
    play: async () => {
      await wait(900);
      run({ cmd: "open", id: "demo_codex_poster" });
      await wait(1300);
      run({ cmd: "open", id: "demo_settings_tabs" });
      await wait(700);
      await type("Rename the Advanced tab to Runner, and check nothing else still says Advanced");
      await wait(300);
      run({ cmd: "return" });
      await idle("demo_settings_tabs");
      await wait(1600);
    },
  },
  patches: {
    // The Open logs button sends its prompt, the made-up turn answers it, and the Patches panel
    // shows where the buttons came from. (Not the Convex panel: the mock's says it's a stand-in.)
    setup: () => run({ cmd: "mode", mode: "inbox" }, { cmd: "open", id: "demo_dark_mode" }, { cmd: "panel", id: "threadbear.highlights" }),
    play: async () => {
      await wait(1000);
      run({ cmd: "action", id: "tools.open-logs" });
      await idle("demo_dark_mode");
      await wait(900);
      run({ cmd: "panel", id: "threadbear.patches" });
      await wait(2200);
    },
  },
  previews: {
    setup: () => run({ cmd: "mode", mode: "inbox" }, { cmd: "open", id: "demo_landing_pages" }, { cmd: "preview", close: true }, { cmd: "panel", id: "threadbear.highlights" }),
    play: async () => {
      await wait(1100);
      run({ cmd: "preview", path: mockup("home.html") });
      await wait(2400);
      run({ cmd: "preview", path: mockup("pricing.html") });
      await wait(2200);
    },
  },
  questions: {
    setup: () => run({ cmd: "mode", mode: "inbox" }, { cmd: "open", id: "demo_button_colour" }),
    play: async () => {
      await wait(1000);
      run({ cmd: "click", title: "Green" });
      await wait(800);
      run({ cmd: "click", title: "Send answer" });
      await idle("demo_button_colour");
      await wait(1600);
    },
  },
  projects: {
    // A thread with nothing previewed, so the pane beside the projects is its Highlights.
    setup: () => run({ cmd: "mode", mode: "inbox" }, { cmd: "open", id: "demo_tidy_imports" }),
    play: async () => {
      await wait(800);
      run({ cmd: "mode", mode: "projects" });
      await wait(2000);
      await type("walk", "projects");
      await wait(1800);
      run({ cmd: "search", text: "", projects: true });
      await wait(1200);
    },
  },
  logins: {
    // From a thread's message box at the bottom: from the new-thread one in the middle of the
    // window, the picker opens past the window's top and gets cut off.
    setup: () => run({ cmd: "mode", mode: "inbox" }, { cmd: "open", id: "demo_sqlite_vs_files" }),
    play: async () => {
      await wait(1000);
      run({ cmd: "composer-menu", menu: "model", show: true });
      await wait(2200);
      run({ cmd: "composer-menu", menu: "model", click: "Opus 5.5" });
      await wait(500);
      run({ cmd: "escape" });
      await wait(700);
      await type("Now try it with SQLite in WAL mode and compare");
      await wait(1400);
    },
  },
};

const recorder = join(work, "record-window");
execFileSync("swiftc", ["-O", join(site, "scripts/record-window.swift"), "-o", recorder], { stdio: "inherit" });
const windowId = run({ cmd: "window" }).match(/window ok (\d+)/)[1];
// The traffic lights from the screenshot set, laid over each clip's top left corner.
const lights = join(work, "lights.png");
execFileSync("ffmpeg", ["-loglevel", "error", "-y", "-i", join(shots, "1-thread-bottom.png"), "-vf", "crop=170:64:0:0", lights]);

for (const name of process.argv.slice(2).length ? process.argv.slice(2) : Object.keys(CLIPS)) {
  const clip = CLIPS[name];
  if (!clip) throw new Error(`No clip called ${name}`);
  console.log(`${name}: setting up`);
  try { run({ cmd: "escape" }); } catch {}
  clip.setup();
  await wait(1200);
  const raw = join(work, `${name}.mov`);
  rmSync(raw, { force: true });
  const recording = spawn(recorder, [windowId, raw, "60"], { stdio: "inherit" });
  await wait(700);
  await clip.play();
  writeFileSync(`${raw}.stop`, "");
  await new Promise((r) => recording.on("exit", r));
  if (!existsSync(raw)) throw new Error(`${name}: nothing recorded`);
  // H.264 for every browser, 1600 wide (the hero shows it at 1100 at most, so sharp on 2x
  // screens up to about 800), 30 fps, no sound, the index up front so it starts at once.
  const mp4 = join(out, `${name}.mp4`);
  execFileSync("ffmpeg", ["-loglevel", "error", "-y", "-i", raw, "-i", lights, "-filter_complex",
    "[0][1]overlay=0:0,fps=30,scale=1600:-2:flags=lanczos,format=yuv420p", "-c:v", "libx264", "-preset", "slow",
    "-crf", "26", "-an", "-movflags", "+faststart", mp4]);
  // The first frame, for the poster and for anyone with reduced motion.
  execFileSync("ffmpeg", ["-loglevel", "error", "-y", "-i", mp4, "-frames:v", "1", "-c:v", "libwebp", "-quality", "80", join(out, `${name}.webp`)]);
  const seconds = execFileSync("ffprobe", ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", mp4], { encoding: "utf8" }).trim();
  console.log(`${name}: ${mp4.replace(site + "/", "")}, ${Number(seconds).toFixed(1)} s`);
}
