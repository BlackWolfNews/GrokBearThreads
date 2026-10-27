#!/usr/bin/env node
// The LaunchAgent's program when the runner runs from releases (see
// scripts/install-runner.sh and docs/dev-tools.md). install-runner.sh copies
// it to <home>/runner/launch.mjs, next to releases/, current and
// state.json, and it runs from there on its own, so it imports nothing but
// Node built-ins. scripts/deploy.mjs imports the state helpers from here so
// both agree on the file format.
//
// Each start records a boot. A release that keeps dying at startup (3
// boots in 10 minutes that neither stayed up long enough for main.ts to
// mark it good nor stopped cleanly) is swapped for the last good one. Then
// the release's src/main.ts is imported into this process, so launchd's
// signals reach the runner as they did before. A release that hasn't
// started listening within 90 seconds is stopped, so one that hangs at
// startup counts as crashing too.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

export const CRASH_BOOTS = 3;
// Long enough to hold three starts that each hang until the watchdog below
// stops them (launchd waits 5 s between starts). It can't catch a healthy
// release: one marked good is never rolled back, and clean stops (a
// restart, launchctl kickstart, a reboot) don't count.
export const CRASH_WINDOW_MS = 10 * 60_000;
export const START_TIMEOUT_MS = 90_000;
export const KEEP_BOOTS = 20;

export function emptyState() {
  return { current: null, previous: null, lastGood: null, boots: [] };
}

// A missing or unreadable state.json starts afresh rather than stopping the
// runner from booting; the current symlink still says what to run.
export function readState(dir) {
  try {
    const s = JSON.parse(fs.readFileSync(path.join(dir, 'state.json'), 'utf8'));
    if (s && typeof s === 'object' && !Array.isArray(s)) {
      return { ...emptyState(), ...s, boots: Array.isArray(s.boots) ? s.boots : [] };
    }
  } catch {
    // fall through
  }
  return emptyState();
}

// Temp file then rename, so a crash mid-write never leaves half a file.
// The temp name matches the pattern the runner's own atomic writes use.
export function writeState(dir, state) {
  const file = path.join(dir, 'state.json');
  const tmp = path.join(dir, `.state.json.${process.pid}.${crypto.randomBytes(4).toString('hex')}.tmp`);
  fs.writeFileSync(tmp, JSON.stringify(state, null, 2) + '\n');
  fs.renameSync(tmp, file);
}

// The release `current` points at, or null when there's no link yet.
export function readCurrentLink(dir) {
  try {
    return path.basename(fs.readlinkSync(path.join(dir, 'current')));
  } catch {
    return null;
  }
}

// A new link under a temp name renamed over the old one: rename is atomic,
// so `current` always names a whole release. The target is relative so the
// data dir can move.
export function pointCurrent(dir, id) {
  const link = path.join(dir, 'current');
  const tmp = `${link}.${process.pid}.tmp`;
  fs.rmSync(tmp, { force: true });
  fs.symlinkSync(path.join('releases', id), tmp);
  fs.renameSync(tmp, link);
}

export function releaseExists(dir, id) {
  return typeof id === 'string' && id !== '' && fs.existsSync(path.join(dir, 'releases', id, 'src', 'main.ts'));
}

// Decides what this boot starts, without touching the disk. `state.current`
// should already agree with the symlink. Returns the state to save, the
// release to start, and `rolledBack` when it went back to lastGood.
//
// Only boots since current was last activated count (deploy-runner.sh
// records `activated`), so `--rollback --force` onto a release that crashed
// a few minutes ago gives it fresh tries instead of going straight back.
export function planBoot(state, now, exists, pid = process.pid) {
  const at = new Date(now).toISOString();
  const current = state.current;
  const activatedAt = state.activated && state.activated.release === current ? Date.parse(state.activated.at) : NaN;
  const since = Math.max(now - CRASH_WINDOW_MS, Number.isFinite(activatedAt) ? activatedAt - 1 : -Infinity);
  const earlier = state.boots.filter((b) => b && b.release === current && !b.clean && Date.parse(b.at) > since).length;
  // This boot counts: the third start in the window is the one that
  // switches, so a broken release gets two tries.
  const crashLooping = Boolean(current) && current !== state.lastGood && earlier + 1 >= CRASH_BOOTS;
  const canRollBack = crashLooping && exists(state.lastGood);
  const start = canRollBack ? state.lastGood : current;
  const next = { ...state, boots: [...state.boots, { release: start, at, pid }].slice(-KEEP_BOOTS) };
  let rolledBack = null;
  if (canRollBack) {
    rolledBack = { from: current, to: start, at };
    // previous names the bad release, so `deploy-runner.sh --rollback` can
    // try it again on purpose.
    Object.assign(next, { current: start, previous: current, rolledBack });
  }
  return { state: next, start, rolledBack, stuck: crashLooping && !canRollBack };
}

// Marks this process's boot as a clean stop: the runner listened and then
// exited 0 (a planned restart, launchctl kickstart, a reboot). planBoot
// doesn't count those, so restarting a new release a few times in a row
// isn't mistaken for a crash loop.
export function markBootClean(dir, at, pid = process.pid) {
  const state = readState(dir);
  const boot = state.boots.findLast((b) => b && b.at === at && b.pid === pid);
  if (!boot || boot.clean) return false;
  boot.clean = true;
  writeState(dir, state);
  return true;
}

function log(level, msg, extra) {
  // Same line format as the runner's log (src/log.ts); launchd sends
  // stderr to the runner's log file. Written straight to the fd so a line
  // logged from the 'exit' handler isn't lost.
  const line = `${new Date().toISOString()} ${level} launch: ${msg}${extra ? ' ' + JSON.stringify(extra) : ''}\n`;
  try {
    fs.writeSync(2, line);
  } catch {
    // no stderr to write to
  }
}

async function main() {
  const dir = path.dirname(fileURLToPath(import.meta.url));
  const state = readState(dir);
  // The symlink is what deploy-runner.sh activates; state.json follows it.
  const linked = readCurrentLink(dir);
  if (linked) state.current = linked;
  if (!state.current) {
    log('ERROR', 'no release to start; build one with scripts/deploy-runner.sh or reinstall with scripts/install-runner.sh', { dir });
    process.exit(1);
  }
  const plan = planBoot(state, Date.now(), (id) => releaseExists(dir, id));
  if (plan.rolledBack) {
    log('WARN', `release ${plan.rolledBack.from} failed to start ${CRASH_BOOTS} times in ${CRASH_WINDOW_MS / 60_000} minutes without being marked good; going back to ${plan.start}`);
    try {
      pointCurrent(dir, plan.start);
    } catch (e) {
      // Bookkeeping must never stop the runner from starting: lastGood
      // still starts from its folder, and the next boot sees the link
      // still on the bad release and goes back again.
      log('ERROR', 'could not point current at the release it went back to', { release: plan.start, error: String(e) });
    }
  } else if (plan.stuck) {
    log('WARN', `release ${plan.start} keeps crashing at startup and there's no other good release to go back to`, { lastGood: state.lastGood });
  }
  try {
    writeState(dir, plan.state);
  } catch (e) {
    // Bookkeeping must never stop the runner from starting.
    log('WARN', 'could not record the boot', { error: String(e) });
  }
  const root = path.join(dir, 'releases', plan.start);
  log('INFO', 'starting release', { release: plan.start, pid: process.pid });
  process.chdir(root);
  // main.ts calls listening() once it is serving (src/release.ts).
  let listened = false;
  let watchdog;
  globalThis.threadbareLaunch = {
    listening() {
      listened = true;
      clearTimeout(watchdog);
    },
  };
  const at = plan.state.boots.at(-1).at;
  const startedMs = Date.now();
  process.on('exit', (code) => {
    if (code === 0 && listened) {
      try {
        markBootClean(dir, at);
      } catch {
        // the next boot just counts this one
      }
      return;
    }
    // A release that calls process.exit leaves nothing else in the log, and
    // after a crash rollback an agent reading tb logs needs to see which
    // release stopped, when and how.
    let good = false;
    try {
      good = readState(dir).lastGood === plan.start;
    } catch {
      // unreadable: say it counts
    }
    const secs = Math.round((Date.now() - startedMs) / 1000);
    log('ERROR', `release ${plan.start} exited with code ${code} after ${secs} s${listened ? '' : ', before it was listening'}${good ? '' : ', not marked good, so it counts as a failed start'}`);
  });
  const mod = await import(pathToFileURL(path.join(root, 'src', 'main.ts')).href);
  // Releases from before the hook never call it, so only those that say
  // they do get the watchdog. It keeps the process alive on purpose: a
  // startup that stalls with nothing left to run would otherwise exit 0.
  if (mod.REPORTS_LISTENING && !listened) {
    const ms = Number(process.env.THREADBARE_START_TIMEOUT_MS) > 0 ? Number(process.env.THREADBARE_START_TIMEOUT_MS) : START_TIMEOUT_MS;
    watchdog = setTimeout(() => {
      log('ERROR', `release ${plan.start} wasn't listening after ${Math.round(ms / 1000)} s; stopping it so it counts as a failed start`);
      process.exit(1);
    }, ms);
  }
}

// Only when run as the program, so deploy.mjs and the tests can import the
// helpers above without starting a runner.
function isMain() {
  try {
    return fs.realpathSync(process.argv[1] ?? '') === fs.realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
}

if (isMain()) {
  main().catch((e) => {
    log('ERROR', 'release failed to start', { error: e?.stack ?? String(e) });
    process.exit(1);
  });
}
