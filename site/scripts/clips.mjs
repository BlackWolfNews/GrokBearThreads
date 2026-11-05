#!/usr/bin/env node
// Records the hero's clips: the demo app (mock runner, made-up threads, dark mode) driven through
// one feature each, recorded from its window and encoded into public/clips/. The results are
// committed, so this only runs when the clips should change. Encodes use two threads, to stay
// light on the Mac they run on.
//
//   MOCK_SCRIPTED_TURNS=$PWD/scripts/clips/turns.json \
//     ../app/Tools/dev-app.sh start --mock --appearance dark --size 1240x820 --id siteclips
//   node scripts/clips.mjs [name...]        (all of them without names)
//   ../app/Tools/dev-app.sh stop --id siteclips
//
// turns.json has the made-up replies the mock streams when a clip sends a message or answers a
// question, and made-up content for a few demo threads (their asks, a review, a panel). Needs
// Screen Recording permission for the shell (scripts/record-window.swift), ffmpeg,
// and a dark mode screenshot set for the window's traffic lights (HERO_SHOTS, as images.mjs):
// a window in the background draws them as a grey blob, so each clip gets the screenshot's.
// A clip changes the mock's threads (it sends messages, answers a question), so record from a
// fresh instance: stop and start it again before running them all.
import { execFileSync, spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
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

// One per slide in scripts/build.mjs's SLIDES, in the same order, which follows the launch video's:
// the bits Mike is most excited about. `setup` runs before recording; `window` names a window
// other than the main one to record (alone, so the main one doesn't cover it); `file` is a clip
// made elsewhere, cropped to the others' shape instead of recorded.
const CLIPS = {
  // A card of asks answered one click at a time, then the thread goes off into Running.
  decisions: {
    setup: () => run({ cmd: "mode", mode: "inbox" }, { cmd: "open", id: "demo_testflight_beta" }),
    play: async () => {
      await wait(1100);
      run({ cmd: "decide", pick: "1:1" });
      await wait(1100);
      run({ cmd: "decide", pick: "2:2" });
      await wait(1100);
      run({ cmd: "decide", pick: "3:1" });
      await wait(900);
      run({ cmd: "decide", send: true });
      await idle("demo_testflight_beta");
      await wait(1400);
    },
  },
  // The options window: each design in turn, then side by side, one picked with a note.
  options: {
    setup: () => run({ cmd: "mode", mode: "inbox" }, { cmd: "open", id: "demo_design_review" }, { cmd: "review" },
      // 820 less its 33 pt title bar, so the whole window is the main one's 1240 x 820.
      { cmd: "resize", review: "review_account_picker", w: 1240, h: 787 }),
    window: { cmd: "window", review: "review_account_picker" },
    play: async () => {
      await wait(1300);
      run({ cmd: "review", show: 1 });
      await wait(1300);
      run({ cmd: "review", show: 2 });
      await wait(1300);
      run({ cmd: "review", mode: "All" });
      await wait(1400);
      run({ cmd: "review", pick: "B" });
      await wait(700);
      run({ cmd: "review", notes: { B: "This one, but give the map a bit more room" } });
      await wait(1800);
    },
  },
  // Done threads archived with a click (the flight into the Den), so the inbox is what's left.
  inbox: {
    setup: () => run({ cmd: "mode", mode: "inbox" }, { cmd: "open", id: "bruce_media" }),
    play: async () => {
      await wait(1100);
      run({ cmd: "archive", id: "bruce_media" });
      await wait(1300);
      run({ cmd: "open", id: "demo_tidy_imports" });
      await wait(1100);
      run({ cmd: "archive", id: "demo_tidy_imports" });
      await wait(1300);
      run({ cmd: "open", id: "demo_settings_tabs" });
      await wait(1100);
      run({ cmd: "archive", id: "demo_settings_tabs" });
      await wait(1500);
    },
  },
  // No folder to pick: a new thread just starts, and the librarian files threads into projects.
  librarian: {
    setup: () => run({ cmd: "mode", mode: "inbox" }, { cmd: "new" }),
    play: async () => {
      await wait(900);
      await type("Why does the Walkies map jump when I zoom out?");
      await wait(400);
      run({ cmd: "return" });
      await wait(2600);
      run({ cmd: "mode", mode: "librarian" });
      await wait(2800);
    },
  },
  // The iPhone app, from the launch video's B-roll (Mike's own thread on his phone: the bike
  // pedal picture it made him).
  phone: {
    file: process.env.CLIPS_PHONE ?? join(homedir(), "dev/convex/convex-videos/threadbear-launch/broll/bike-pedals/phone-thread.mp4"),
  },
  // Patches: the built-in Convex panel, a project's own stats panel, and its button.
  patches: {
    setup: () => run({ cmd: "mode", mode: "inbox" }, { cmd: "open", id: "demo_dark_mode" }, { cmd: "panel", id: "threadbear.highlights" }),
    play: async () => {
      await wait(1000);
      run({ cmd: "panel", id: "convex.dashboard" });
      await wait(1800);
      run({ cmd: "panel", id: "walkies.stats" });
      await wait(1800);
      run({ cmd: "action", id: "walkies.seed-walks" });
      await wait(1800);
    },
  },
  // Mike's release in the Updates panel, brought into this copy by a thread.
  fork: {
    setup: () => {
      run({ cmd: "mode", mode: "inbox" }, { cmd: "open", id: "demo_upload_resume" });
      run({ cmd: "mock", method: "updates", params: { state: "idle", upstream: { state: "available", checkedAt: new Date().toISOString(),
        release: { tag: "release/2026-11-05", commit: "64b4f2e", date: new Date().toISOString(), changes: 6, subjects: [
          "The hero plays clips of the app", "Setup asks which Convex team in the dry run", "Copying from a thread keeps its links in Slack",
          "A card about pools the first time a pool has two logins", "Editing a message asks before it stops background work",
          "Schedules can change their login"] } } } });
    },
    play: async () => {
      await wait(900);
      run({ cmd: "updates", show: true });
      await wait(2000);
      run({ cmd: "click", tip: "Start a thread that merges Mike's release into your main. It asks before it lands." });
      await wait(5500);
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
  const mp4 = join(out, `${name}.mp4`);
  if (clip.file) {
    // Cropped from the middle to the windows' 1600 x 1058, sound off.
    execFileSync("ffmpeg", ["-loglevel", "error", "-y", "-i", clip.file, "-vf",
      "crop=ih*1600/1058:ih,fps=30,scale=1600:1058:flags=lanczos,format=yuv420p", "-c:v", "libx264", "-preset", "slow", "-threads", "2",
      "-crf", "26", "-an", "-movflags", "+faststart", mp4]);
  } else {
    console.log(`${name}: setting up`);
    try { run({ cmd: "escape" }); } catch {}
    try { run({ cmd: "updates", show: false }); } catch {}
    clip.setup();
    await wait(1200);
    const raw = join(work, `${name}.mov`);
    rmSync(raw, { force: true });
    const target = clip.window ? run(clip.window).match(/window ok (\d+)/)[1] : windowId;
    const recording = spawn(recorder, [target, raw, "60", ...(clip.window ? ["--window-only"] : [])], { stdio: "inherit" });
    await wait(700);
    await clip.play();
    writeFileSync(`${raw}.stop`, "");
    await new Promise((r) => recording.on("exit", r));
    if (!existsSync(raw)) throw new Error(`${name}: nothing recorded`);
    // H.264 for every browser, 1600 wide (the hero shows it at 1100 at most, so sharp on 2x
    // screens up to about 800), 30 fps, no sound, the index up front so it starts at once.
    execFileSync("ffmpeg", ["-loglevel", "error", "-y", "-i", raw, "-i", lights, "-filter_complex",
      "[0][1]overlay=0:0,fps=30,scale=1600:-2:flags=lanczos,format=yuv420p", "-c:v", "libx264", "-preset", "slow", "-threads", "2",
      "-crf", "26", "-an", "-movflags", "+faststart", mp4]);
  }
  // The first frame, for the poster and for anyone with reduced motion.
  execFileSync("ffmpeg", ["-loglevel", "error", "-y", "-i", mp4, "-frames:v", "1", "-c:v", "libwebp", "-quality", "80", join(out, `${name}.webp`)]);
  const seconds = execFileSync("ffprobe", ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", mp4], { encoding: "utf8" }).trim();
  console.log(`${name}: ${mp4.replace(site + "/", "")}, ${Number(seconds).toFixed(1)} s`);
}
