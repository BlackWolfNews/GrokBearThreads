#!/usr/bin/env node
// The LaunchAgent's program when the runner runs from releases (see
// scripts/install-runner.sh and docs/dev-tools.md). install-runner.sh copies
// it to <home>/runner/launch.mjs, next to releases/, current and
// state.json, and it runs from there on its own, so it imports nothing but
// Node built-ins. scripts/deploy.mjs imports the state helpers from here so
// both agree on the file format.
//
// Each start records a boot. A release that keeps dying at startup (3 boots
// in 2 minutes without main.ts marking it good) is swapped for the last
// good one. Then the release's src/main.ts is imported into this process,
// so launchd's signals reach the runner as they did before.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

export const CRASH_BOOTS = 3;
export const CRASH_WINDOW_MS = 2 * 60_000;
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
export function planBoot(state, now, exists) {
  const at = new Date(now).toISOString();
  const current = state.current;
  const earlier = state.boots.filter((b) => b && b.release === current && Date.parse(b.at) > now - CRASH_WINDOW_MS).length;
  // This boot counts: the third start in the window is the one that
  // switches, so a broken release gets two tries.
  const crashLooping = Boolean(current) && current !== state.lastGood && earlier + 1 >= CRASH_BOOTS;
  const canRollBack = crashLooping && exists(state.lastGood);
  const start = canRollBack ? state.lastGood : current;
  const next = { ...state, boots: [...state.boots, { release: start, at }].slice(-KEEP_BOOTS) };
  let rolledBack = null;
  if (canRollBack) {
    rolledBack = { from: current, to: start, at };
    // previous names the bad release, so `deploy-runner.sh --rollback` can
    // try it again on purpose.
    Object.assign(next, { current: start, previous: current, rolledBack });
  }
  return { state: next, start, rolledBack, stuck: crashLooping && !canRollBack };
}

function log(level, msg, extra) {
  // Same line format as the runner's log (src/log.ts); launchd sends
  // stderr to the runner's log file.
  process.stderr.write(`${new Date().toISOString()} ${level} launch: ${msg}${extra ? ' ' + JSON.stringify(extra) : ''}\n`);
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
    pointCurrent(dir, plan.start);
    log('WARN', `release ${plan.rolledBack.from} started ${CRASH_BOOTS} times in 2 minutes without being marked good; going back to ${plan.start}`);
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
  await import(pathToFileURL(path.join(root, 'src', 'main.ts')).href);
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
