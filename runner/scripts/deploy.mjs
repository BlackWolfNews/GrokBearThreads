// deploy-runner.sh's logic: builds a release of the runner from this
// checkout and switches the live runner to it (docs/dev-tools.md, "Runner
// releases"). deploy-runner.sh runs it with the pinned Node. It uses only
// Node built-ins (rpc-client.mjs talks to the runner), so it works without
// the checkout's node_modules and against any runner version.
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { parseArgs } from 'node:util';
import { pointCurrent, readCurrentLink, readState, releaseExists, writeState } from '../launch.mjs';
import { connectRpc } from './rpc-client.mjs';

const HELP = `deploy-runner.sh: build a runner release from this checkout and switch the
live runner to it.

  1. typecheck and unit tests        5. restart the runner
  2. snapshot runner/ at HEAD        6. check it came up on the new release,
  3. smoke test the snapshot            or go back to the previous one
  4. point current at it             7. keep the newest 5 plus the last good one

Options:
  --skip-checks     skip step 1
  --allow-dirty     build from uncommitted files (the id ends in -dirty)
  --now             restart straight away with launchctl kickstart, stopping
                    turns in progress (refused inside a thread unless --force)
  --force           with --now, inside a thread too
  --wait 30m        how long to wait for running threads before giving up
                    (s, m or h)
  --resume "text"   sent to this thread as a new turn after the restart
                    (inside a thread, where there's a default)
  --rollback        go back to the previous release instead of building one
  --list            show the releases and which one is running
  --home DIR        data dir (default $THREADBARE_HOME, else
                    ~/Library/Application Support/Threadbare)
  --label LABEL     launchd label (default com.mikerosoft.threadbare.runner)
  --dry-run         say what would happen and change nothing

For install-runner.sh:
  --no-restart      stop after step 4
  --check           only step 6, for the release current points at
`;

const DEFAULT_LABEL = 'com.mikerosoft.threadbare.runner';
const DEFAULT_HOME = path.join(os.homedir(), 'Library', 'Application Support', 'Threadbare');
// What a release holds from runner/, besides node_modules and release.json.
const RELEASE_PATHS = ['src', 'bin', 'package.json', 'package-lock.json'];
const KEEP_RELEASES = 5;
const HEALTH_MS = 30_000;
const ID_RE = /^\d{8}T\d{6}Z-[0-9a-f]+(-dirty)?$/;
const BUSY = new Set(['starting', 'running', 'waiting']);

// A failure with a message for whoever ran the script; no stack trace.
class Fail extends Error {}

const say = (msg) => console.log(msg);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Run on exit, including Ctrl-C: stop a smoke-test runner, drop the lock
// and any half-built release.
const cleanups = [];
process.on('exit', () => {
  for (const fn of cleanups.splice(0).reverse()) {
    try {
      fn();
    } catch {
      // best effort
    }
  }
});
process.on('SIGINT', () => process.exit(130));
process.on('SIGTERM', () => process.exit(143));

function expandHome(p) {
  return p === '~' ? os.homedir() : p.startsWith('~/') ? path.join(os.homedir(), p.slice(2)) : p;
}

function sameDir(a, b) {
  const real = (p) => {
    try {
      return fs.realpathSync(p);
    } catch {
      return path.resolve(p);
    }
  };
  return real(a) === real(b);
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return undefined;
  }
}

function parseDuration(s) {
  const m = /^(\d+(?:\.\d+)?)(ms|s|m|h)?$/.exec(String(s).trim());
  if (!m) throw new Fail(`Can't read the time "${s}"; use something like 90s, 30m or 2h.`);
  return Number(m[1]) * { ms: 1, s: 1000, m: 60_000, h: 3_600_000 }[m[2] ?? 's'];
}

function fmtDuration(ms) {
  return ms >= 3_600_000 && ms % 3_600_000 === 0 ? `${ms / 3_600_000}h` : ms >= 60_000 && ms % 60_000 === 0 ? `${ms / 60_000}m` : `${Math.round(ms / 1000)}s`;
}

function plural(n, word) {
  return `${n} ${word}${n === 1 ? '' : 's'}`;
}

function tail(file, lines = 40) {
  try {
    return fs.readFileSync(file, 'utf8').trimEnd().split('\n').slice(-lines).join('\n');
  } catch {
    return `(no log at ${file})`;
  }
}

// The pinned Node first on PATH (npm's shebang finds it there), and no
// THREADBARE_* variables: inside a thread they name the live runner, and
// tests or a smoke-test runner must never pick that up.
function cleanEnv(extra = {}) {
  const env = {};
  for (const [k, v] of Object.entries(process.env)) if (!k.startsWith('THREADBARE_')) env[k] = v;
  env.PATH = `${path.dirname(process.execPath)}:${process.env.PATH ?? ''}`;
  return { ...env, ...extra };
}

function setup(v) {
  const home = path.resolve(expandHome(v.home ?? process.env.THREADBARE_HOME ?? process.env.THREADBARE_DATA_DIR ?? DEFAULT_HOME));
  const isDefaultHome = sameDir(home, DEFAULT_HOME);
  const label = v.label ?? DEFAULT_LABEL;
  // Only a thread of the runner being deployed to counts: a thread on the
  // live runner deploying to a sandbox isn't stopped by that restart.
  const threadHome = process.env.THREADBARE_HOME || process.env.THREADBARE_DATA_DIR || DEFAULT_HOME;
  const threadId = process.env.THREADBARE_THREAD_ID && sameDir(threadHome, home) ? process.env.THREADBARE_THREAD_ID : null;
  return {
    home,
    dir: path.join(home, 'runner'),
    releases: path.join(home, 'runner', 'releases'),
    label,
    // Kickstarting the default label for some other data dir would restart
    // the real runner, so a sandbox has to name its own.
    labelKnown: v.label !== undefined || isDefaultHome,
    target: `gui/${process.getuid()}/${label}`,
    log: isDefaultHome ? path.join(os.homedir(), 'Library', 'Logs', 'threadbare-runner.log') : path.join(home, 'runner.log'),
    threadId,
    launchctl: process.env.THREADBARE_LAUNCHCTL || 'launchctl',
    npm: path.join(path.dirname(process.execPath), 'npm'),
    runnerDir: path.resolve(import.meta.dirname, '..'),
  };
}

// ---------------------------------------------------------------- talking to the runner

// One authenticated connection to the runner at `home`, found the way tb
// finds it: the port in runner.json and the token in secrets/. Rejects with
// `down: true` when nothing is listening.
async function connect(home, timeoutMs = 3000) {
  const port = readJson(path.join(home, 'runner.json'))?.port;
  let token;
  try {
    token = fs.readFileSync(path.join(home, 'secrets', 'runner-token'), 'utf8').trim();
  } catch {
    throw Object.assign(new Error('no runner token'), { down: true });
  }
  if (!port) throw Object.assign(new Error('no port in runner.json'), { down: true });
  const conn = await connectRpc(port, token, timeoutMs);
  try {
    conn.hello = await conn.call('hello', { client: 'deploy-runner', version: '1' });
  } catch (e) {
    conn.close();
    throw e;
  }
  return conn;
}

async function rpc(home, method, params) {
  const c = await connect(home);
  try {
    return await c.call(method, params);
  } finally {
    c.close();
  }
}

// What's running: { state: 'up', version, pid? }, 'down' (nothing
// listening), or 'unknown' (there but not answering in time).
async function probe(home) {
  let c;
  try {
    c = await connect(home);
  } catch (e) {
    return { state: e.down ? 'down' : 'unknown' };
  }
  let pid;
  try {
    pid = (await c.call('runner.status', {})).pid;
  } catch {
    // older runners have no runner.status
  } finally {
    c.close();
  }
  return { state: 'up', version: String(c.hello?.runnerVersion ?? ''), pid };
}

const releaseOf = (version) => (version && version.includes('+') ? version.slice(version.indexOf('+') + 1) : null);

// Waits for the runner to come back on `id`. `before` is what answered
// before the restart was asked for (or null). The restart has to start
// within `startMs`; from then on the new runner has 30 s. Coming back on
// any other release (launch.mjs going back to lastGood, say) fails at once.
async function awaitRelease(home, id, before, startMs) {
  const start = Date.now();
  let downAt = null;
  for (;;) {
    const p = await probe(home);
    const now = Date.now();
    if (p.state === 'up' && releaseOf(p.version) === id) return { result: 'ok', ...p };
    if (p.state === 'down') downAt ??= now;
    else if (p.state === 'up') {
      const restarted = !before ? true : p.pid && before.pid ? p.pid !== before.pid : downAt !== null || p.version !== before.version;
      if (restarted) return { result: 'other', ...p };
    }
    if (downAt !== null && now - downAt > HEALTH_MS) return { result: 'timeout' };
    if (downAt === null && now - start > startMs) return { result: 'pending' };
    await sleep(500);
  }
}

function jobLoaded(c) {
  return spawnSync(c.launchctl, ['print', c.target], { stdio: 'ignore' }).status === 0;
}

// Asynchronous on purpose: kickstart -k returns once the old runner has
// exited, and the runner's shutdown waits for its clients, so this process
// has to keep its own connections moving meanwhile.
async function kickstart(c) {
  if (!c.labelKnown) {
    throw new Fail(`${c.home} isn't the default data dir, so pass --label with its launchd label to restart it.`);
  }
  const r = await new Promise((resolve) => {
    const child = spawn(c.launchctl, ['kickstart', '-k', c.target], { stdio: ['ignore', 'pipe', 'pipe'] });
    let text = '';
    child.stdout.on('data', (d) => (text += d));
    child.stderr.on('data', (d) => (text += d));
    child.on('error', (e) => resolve({ status: null, text: e.message }));
    child.on('close', (status) => resolve({ status, text }));
  });
  if (r.status !== 0) throw new Fail(`launchctl kickstart -k ${c.target} failed: ${r.text.trim()}`);
}

// For runners without runner.restart: no thread starting, running or
// waiting on an approval. Returns [] when idle, else the busy threads.
async function waitUntilIdle(c, waitMs) {
  const end = Date.now() + waitMs;
  let shown = '';
  for (;;) {
    let busy;
    try {
      const r = await rpc(c.home, 'threads.list', { include: ['inbox', 'snoozed', 'archived'] });
      busy = r.threads.filter((t) => BUSY.has(t.status));
    } catch {
      return []; // nothing answering, so nothing to interrupt
    }
    if (busy.length === 0) return [];
    const names = busy.map((t) => `${t.id.slice(0, 8)} "${t.title}"`).join(', ');
    if (names !== shown) {
      say(`Waiting for ${plural(busy.length, 'thread')} to finish (up to ${fmtDuration(waitMs)}): ${names}`);
      shown = names;
    }
    if (Date.now() >= end) return busy;
    await sleep(Math.min(2000, Math.max(100, end - Date.now())));
  }
}

// ---------------------------------------------------------------- releases

function listReleases(c) {
  try {
    return fs
      .readdirSync(c.releases)
      .filter((n) => ID_RE.test(n))
      .sort()
      .reverse();
  } catch {
    return [];
  }
}

function currentId(c) {
  return readCurrentLink(c.dir) ?? readState(c.dir).current;
}

// Swaps the link first (that's what launch.mjs starts), then records it.
function activate(c, id) {
  const state = readState(c.dir);
  const was = currentId(c);
  pointCurrent(c.dir, id);
  writeState(c.dir, { ...state, current: id, previous: was ?? state.previous });
  say(`current now points at ${id}${was ? ` (was ${was})` : ''}.`);
}

function restore(c, before) {
  pointCurrent(c.dir, before.current);
  writeState(c.dir, { ...readState(c.dir), current: before.current, previous: before.previous });
}

function pruneList(c, extraKeep = []) {
  const state = readState(c.dir);
  const ids = listReleases(c);
  // The newest 5 plus lastGood, as specced, and never anything current,
  // previous or still running points at, whatever its age.
  const keep = new Set([...ids.slice(0, KEEP_RELEASES), state.lastGood, state.current, state.previous, currentId(c), ...extraKeep]);
  return ids.filter((id) => !keep.has(id));
}

function prune(c, extraKeep) {
  const gone = pruneList(c, extraKeep);
  for (const id of gone) fs.rmSync(path.join(c.releases, id), { recursive: true, force: true });
  // Builds a killed deploy left behind; this one holds the lock, so no
  // other deploy is building.
  for (const name of fs.existsSync(c.releases) ? fs.readdirSync(c.releases) : []) {
    if (name.startsWith('.building-')) fs.rmSync(path.join(c.releases, name), { recursive: true, force: true });
  }
  if (gone.length) say(`Removed ${plural(gone.length, 'old release')}: ${gone.join(', ')}`);
}

// A directory made with mkdir, which fails if it exists, so two deploys
// (two threads, say) never build or swap at once.
function lock(c) {
  fs.mkdirSync(c.dir, { recursive: true });
  const dir = path.join(c.dir, 'deploy.lock');
  for (let tries = 0; tries < 2; tries++) {
    try {
      fs.mkdirSync(dir);
      fs.writeFileSync(path.join(dir, 'pid'), String(process.pid));
      cleanups.push(() => fs.rmSync(dir, { recursive: true, force: true }));
      return;
    } catch (e) {
      if (e.code !== 'EEXIST') throw e;
    }
    const pid = Number(readJson(path.join(dir, 'pid')) ?? 0);
    let alive = false;
    try {
      alive = pid > 0 && (process.kill(pid, 0), true);
    } catch (e) {
      alive = e.code === 'EPERM';
    }
    if (alive) throw new Fail(`Another deploy (pid ${pid}) is working on ${c.dir}. Wait for it to finish.`);
    fs.rmSync(dir, { recursive: true, force: true });
  }
  throw new Fail(`Couldn't take the deploy lock in ${c.dir}.`);
}

function git(cwd, args, opts = {}) {
  const r = spawnSync('git', ['-C', cwd, ...args], { encoding: opts.encoding ?? 'utf8', maxBuffer: 64 * 1024 * 1024 });
  if (r.status !== 0) throw new Fail(`git ${args.join(' ')} failed: ${String(r.stderr).trim()}`);
  return opts.encoding === 'buffer' ? r.stdout : r.stdout.trim();
}

function gitInfo(c) {
  const root = git(c.runnerDir, ['rev-parse', '--show-toplevel']);
  // Only files that end up in the release count as uncommitted changes:
  // tests, scripts and docs don't change what runs (and a worktree's
  // node_modules symlink shows up as untracked).
  const changes = git(c.runnerDir, ['status', '--porcelain', '--untracked-files=all', '--', ...RELEASE_PATHS]);
  return {
    root,
    prefix: git(c.runnerDir, ['rev-parse', '--show-prefix']),
    commit: git(c.runnerDir, ['rev-parse', 'HEAD']),
    short: git(c.runnerDir, ['rev-parse', '--short', 'HEAD']),
    changes: changes ? changes.split('\n') : [],
  };
}

function newReleaseId(c, short, dirty) {
  for (;;) {
    const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z');
    const id = `${stamp}-${short}${dirty ? '-dirty' : ''}`;
    if (!fs.existsSync(path.join(c.releases, id))) return id;
    // Two builds in one second: wait for the next.
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1000 - (Date.now() % 1000) + 5);
  }
}

// Runs a step with its output in a log file, printed only if it fails.
function step(name, cmd, args, opts) {
  process.stdout.write(`${name}... `);
  const started = Date.now();
  const logFile = path.join(os.tmpdir(), `threadbare-deploy-${process.pid}-${name.toLowerCase().replace(/[^a-z0-9]+/g, '-')}.log`);
  const fd = fs.openSync(logFile, 'w');
  const r = spawnSync(cmd, args, { ...opts, stdio: ['ignore', fd, fd] });
  fs.closeSync(fd);
  const secs = `${((Date.now() - started) / 1000).toFixed(1)}s`;
  if (r.status === 0) {
    say(`ok (${secs})`);
    fs.rmSync(logFile, { force: true });
    return;
  }
  say(`failed (${secs})`);
  console.error(tail(logFile));
  throw new Fail(`${name} failed; the whole output is in ${logFile}`);
}

function checks(c) {
  const opts = { cwd: c.runnerDir, env: cleanEnv() };
  if (!fs.existsSync(path.join(c.runnerDir, 'node_modules'))) step('Installing the checkout\'s packages', c.npm, ['ci', '--no-audit', '--no-fund'], opts);
  step('Typecheck', c.npm, ['run', 'typecheck'], opts);
  step('Unit tests', c.npm, ['test'], opts);
}

function snapshotHead(c, g, dest) {
  const wanted = RELEASE_PATHS.map((p) => g.prefix + p);
  // Only paths HEAD has, or git archive refuses the whole lot.
  const present = git(g.root, ['ls-tree', '--name-only', 'HEAD', '--', ...wanted]).split('\n').filter(Boolean);
  const tar = path.join(dest, '.snapshot.tar');
  git(g.root, ['archive', '--format=tar', `--output=${tar}`, 'HEAD', '--', ...present]);
  const strip = g.prefix.split('/').filter(Boolean).length;
  const r = spawnSync('tar', ['-xf', tar, '-C', dest, '--strip-components', String(strip)], { encoding: 'utf8' });
  fs.rmSync(tar, { force: true });
  if (r.status !== 0) throw new Fail(`Couldn't unpack the snapshot: ${r.stderr.trim()}`);
}

// --allow-dirty: the files as they are, tracked or new (ignored ones and
// node_modules stay out), with deletions honoured.
function snapshotWorkingTree(c, dest) {
  const files = git(c.runnerDir, ['ls-files', '-z', '--cached', '--others', '--exclude-standard', '--', ...RELEASE_PATHS], { encoding: 'buffer' })
    .toString('utf8')
    .split('\0')
    .filter(Boolean);
  for (const f of new Set(files)) {
    const from = path.join(c.runnerDir, f);
    let st;
    try {
      st = fs.lstatSync(from);
    } catch {
      continue; // deleted, not yet committed
    }
    if (st.isDirectory()) continue;
    fs.mkdirSync(path.dirname(path.join(dest, f)), { recursive: true });
    fs.cpSync(from, path.join(dest, f), { verbatimSymlinks: true, preserveTimestamps: true });
  }
}

// Production packages. A release with the same package-lock.json and Node
// already has them, so they're cloned from it instead (APFS copy-on-write:
// seconds, and next to no disk); otherwise npm ci.
function installPackages(c, dest) {
  const lock = fs.readFileSync(path.join(dest, 'package-lock.json'));
  const state = readState(c.dir);
  const donors = [...new Set([state.current, state.lastGood, ...listReleases(c)])].filter(Boolean);
  for (const id of donors) {
    const dir = path.join(c.releases, id);
    try {
      if (readJson(path.join(dir, 'release.json'))?.node !== process.versions.node) continue;
      if (!fs.existsSync(path.join(dir, 'node_modules')) || !lock.equals(fs.readFileSync(path.join(dir, 'package-lock.json')))) continue;
    } catch {
      continue;
    }
    if (spawnSync('cp', ['-cR', path.join(dir, 'node_modules'), path.join(dest, 'node_modules')], { stdio: 'ignore' }).status === 0) {
      say(`Packages: cloned from ${id} (same package-lock.json).`);
      return;
    }
    fs.rmSync(path.join(dest, 'node_modules'), { recursive: true, force: true });
  }
  step('Installing packages (npm ci --omit=dev)', c.npm, ['ci', '--omit=dev', '--no-audit', '--no-fund', '--prefer-offline'], {
    cwd: dest,
    env: cleanEnv(),
  });
}

function build(c, id, g, dirty) {
  fs.mkdirSync(c.releases, { recursive: true });
  // Built under a hidden name and renamed when whole, so a release dir
  // never exists half-made.
  const tmp = path.join(c.releases, `.building-${id}`);
  const drop = () => fs.rmSync(tmp, { recursive: true, force: true });
  drop();
  fs.mkdirSync(tmp);
  cleanups.push(drop);
  say(`Building ${id} from ${dirty ? 'the working tree (uncommitted changes)' : `${g.short} (HEAD)`}...`);
  if (dirty) snapshotWorkingTree(c, tmp);
  else snapshotHead(c, g, tmp);
  if (!fs.existsSync(path.join(tmp, 'src', 'main.ts'))) throw new Fail(`The snapshot has no src/main.ts; is ${c.runnerDir} the runner?`);
  installPackages(c, tmp);
  fs.writeFileSync(
    path.join(tmp, 'release.json'),
    JSON.stringify({ id, commit: g.commit, dirty, builtAt: new Date().toISOString(), node: process.versions.node }, null, 2) + '\n',
  );
  fs.renameSync(tmp, path.join(c.releases, id));
}

// Starts the release on a temp data dir and port 0, says hello, checks the
// version names the release, and stops it. Logins and the claude binary
// point nowhere: nothing outside the temp dir is read or written.
async function smoke(c, id) {
  process.stdout.write('Smoke test... ');
  const root = path.join(c.releases, id);
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'threadbare-smoke-'));
  const home = path.join(tmp, 'home');
  const out = path.join(tmp, 'output.log');
  const fd = fs.openSync(out, 'a');
  const child = spawn(process.execPath, [path.join(root, 'src', 'main.ts')], {
    cwd: root,
    detached: true, // its own process group, so it can be stopped whole
    stdio: ['ignore', fd, fd],
    env: cleanEnv({
      THREADBARE_HOME: home,
      THREADBARE_PORT: '0',
      THREADBARE_LOG: path.join(tmp, 'runner.log'),
      THREADBARE_CLAUDE_PATH: path.join(tmp, 'no-claude'),
      THREADBARE_ACCOUNTS_DIR: path.join(tmp, 'no-accounts'),
      THREADBARE_CLAUDE_MAIN_DIR: path.join(tmp, 'no-main'),
      THREADBARE_CLAUDE_MAIN_JSON: path.join(tmp, 'no-main.json'),
    }),
  });
  fs.closeSync(fd);
  let exited = null;
  const gone = new Promise((r) => child.once('exit', (code, signal) => r((exited = { code, signal }))));
  const kill = (sig) => {
    try {
      process.kill(-child.pid, sig);
    } catch {
      // already gone
    }
  };
  const killNow = () => kill('SIGKILL');
  cleanups.push(killNow);
  const started = Date.now();
  let problem = null;
  try {
    let port = null;
    while (!port) {
      if (exited) throw new Error(`it exited (${exited.code ?? exited.signal}) before listening`);
      if (Date.now() - started > 30_000) throw new Error('it was not listening after 30 s');
      port = /listening on (\d+)/.exec(fs.readFileSync(out, 'utf8'))?.[1];
      if (!port) await sleep(100);
    }
    const p = await probe(home);
    if (p.state !== 'up') throw new Error(`hello on port ${port} got no answer`);
    if (releaseOf(p.version) !== id) throw new Error(`it says it is ${p.version || 'no version'}, not ${id}`);
  } catch (e) {
    problem = e.message;
  }
  kill('SIGTERM');
  const timer = setTimeout(killNow, 10_000);
  await gone;
  clearTimeout(timer);
  cleanups.splice(cleanups.indexOf(killNow), 1);
  if (problem) {
    say('failed');
    console.error(`Output:\n${tail(out)}\nRunner log:\n${tail(path.join(tmp, 'runner.log'))}`);
    fs.rmSync(tmp, { recursive: true, force: true });
    throw new Fail(`The smoke test failed: ${problem}. current is unchanged.`);
  }
  fs.rmSync(tmp, { recursive: true, force: true });
  say(`ok (${((Date.now() - started) / 1000).toFixed(1)}s)`);
}

// ---------------------------------------------------------------- restart and health

function restartCommand(c) {
  return `launchctl kickstart -k ${c.target}`;
}

// Restarts the live runner onto `id` and checks it came up there. `before`
// is { current, previous } from before the switch, to go back to.
async function restartAndCheck(c, v, id, before, waitMs) {
  const baseline = await probe(c.home);
  const running = baseline.state === 'up' ? baseline : null;
  let startMs = HEALTH_MS;
  if (v.now) {
    say(`Restarting now: ${restartCommand(c)}`);
    await kickstart(c);
  } else {
    const params = { when: 'idle', reason: v.rollback ? `Rolling back to release ${id}` : `Deploying release ${id}` };
    if (c.threadId) {
      params.resume = { threadId: c.threadId, text: v.resume ?? `The runner restarted on release ${id}. Check that your change works, then carry on.` };
    }
    let res = null;
    let err = null;
    try {
      res = await rpc(c.home, 'runner.restart', params);
    } catch (e) {
      err = e;
    }
    if (err && err.code === -32601) {
      // A runner from before runner.restart: it can't wait for its own
      // threads, so this does, then kickstarts it.
      if (c.threadId) {
        say(`Release ${id} is current, but the live runner is too old to restart itself without ending this turn.`);
        say(`It starts ${id} on its next restart. When no thread is running, Mike can run:\n  ${restartCommand(c)}`);
        return 0;
      }
      const busy = await waitUntilIdle(c, waitMs);
      if (busy.length) {
        throw new Fail(
          `Threads were still running after ${fmtDuration(waitMs)}, so the runner wasn't restarted. Release ${id} is current and starts on the next restart:\n  ${restartCommand(c)}`,
        );
      }
      say(`No thread is running. Restarting: ${restartCommand(c)}`);
      await kickstart(c);
    } else if (err && typeof err.code === 'number') {
      throw new Fail(`runner.restart failed: ${err.message}. Release ${id} is current and starts on the runner's next restart.`);
    } else if (err) {
      // Nothing answering: the runner is down, stuck or not installed.
      if (c.threadId) {
        say(`Release ${id} is current, but the runner isn't answering (${err.message}). Mike can restart it with:\n  ${restartCommand(c)}`);
        return 0;
      }
      if (!c.labelKnown || !jobLoaded(c)) {
        throw new Fail(`The runner isn't answering and ${c.label} isn't loaded, so there's nothing to restart. Release ${id} is current; start it with scripts/install-runner.sh.`);
      }
      say(`The runner isn't answering (${err.message}). Restarting: ${restartCommand(c)}`);
      await kickstart(c);
    } else {
      const waiting = Array.isArray(res?.waitingFor) ? res.waitingFor : [];
      if (waiting.length && c.threadId) {
        const others = waiting.filter((t) => t !== c.threadId).length;
        say(
          `Release ${id} is current. The runner restarts when ${waiting.includes(c.threadId) ? (others ? `this thread and ${plural(others, 'other')} finish` : 'this turn ends') : `${plural(waiting.length, 'thread')} finish`}, then resumes this thread with:\n  "${params.resume.text}"\nEnd your turn now; there's nothing more to do here until then.`,
        );
        return 0;
      }
      if (waiting.length) {
        say(`The runner restarts when ${plural(waiting.length, 'thread')} finish: ${waiting.join(', ')}. Waiting up to ${fmtDuration(waitMs)}...`);
        startMs = waitMs;
      } else {
        say('The runner is restarting.');
      }
    }
  }

  const r = await awaitRelease(c.home, id, running, startMs);
  if (r.result === 'ok') {
    say(`The runner is up on ${id}${r.pid ? ` (pid ${r.pid})` : ''}.`);
    return 0;
  }
  if (r.result === 'pending') {
    if (startMs !== HEALTH_MS) {
      say(`The threads are still running after ${fmtDuration(waitMs)}. The restart stays queued: the runner starts ${id} when they finish.`);
      return 0;
    }
    throw new Fail(`The runner hasn't restarted after ${HEALTH_MS / 1000} s. Release ${id} is current and starts on its next restart:\n  ${restartCommand(c)}`);
  }
  return wentWrong(c, id, before, r);
}

// Health check failed: go back to the release that was current before and
// show the end of the runner's log.
async function wentWrong(c, id, before, r) {
  console.error(
    r.result === 'other'
      ? `The runner came back on ${releaseOf(r.version) ?? r.version} instead of ${id}.`
      : `The runner didn't come back on ${id} within ${HEALTH_MS / 1000} s of the restart.`,
  );
  const rolledBack = readState(c.dir).rolledBack;
  if (rolledBack?.from === id) console.error(`launch.mjs went back to ${rolledBack.to} after ${id} kept crashing at startup.`);
  if (before.current && before.current !== id && releaseExists(c.dir, before.current)) {
    restore(c, before);
    console.error(`current points at ${before.current} again.`);
    const now = await probe(c.home);
    if (now.state === 'up' && releaseOf(now.version) === before.current) {
      console.error(`The runner is already running ${before.current}.`);
    } else if (c.labelKnown) {
      console.error(`Restarting: ${restartCommand(c)}`);
      try {
        await kickstart(c);
      } catch (e) {
        console.error(e.message);
      }
    } else {
      console.error(`Restart it with its label: launchctl kickstart -k gui/${process.getuid()}/<label>`);
    }
  } else {
    console.error('There is no earlier release to go back to.');
  }
  console.error(`\nEnd of ${c.log}:\n${tail(c.log)}`);
  return 1;
}

// ---------------------------------------------------------------- commands

async function list(c) {
  const state = readState(c.dir);
  const cur = currentId(c);
  const ids = listReleases(c);
  if (!ids.length) {
    say(`No releases in ${c.releases}.`);
  } else {
    say(`Releases in ${c.releases}, newest first:`);
    const width = Math.max(...ids.map((id) => id.length));
    for (const id of ids) {
      const info = readJson(path.join(c.releases, id, 'release.json')) ?? {};
      const marks = [
        id === cur && 'current',
        id === state.previous && 'previous',
        id === state.lastGood && 'last good',
        id === state.rolledBack?.from && 'crashed at startup',
      ]
        .filter(Boolean)
        .join(', ');
      const built = info.builtAt ? info.builtAt.replace('T', ' ').replace(/\.\d+Z$/, ' UTC') : '?';
      say(`${id === cur ? '*' : ' '} ${id.padEnd(width)}  ${marks.padEnd(28)}built ${built}, node ${info.node ?? '?'}`);
    }
  }
  if (state.rolledBack) say(`Last crash rollback: ${state.rolledBack.from} to ${state.rolledBack.to} at ${state.rolledBack.at}.`);
  const p = await probe(c.home);
  say(p.state === 'up' ? `Running: ${p.version}${p.pid ? ` (pid ${p.pid})` : ''}` : `The runner at ${c.home} isn't answering.`);
  return 0;
}

async function check(c) {
  const id = currentId(c);
  if (!id) throw new Fail(`No current release in ${c.dir}.`);
  const r = await awaitRelease(c.home, id, null, HEALTH_MS);
  if (r.result === 'ok') {
    say(`The runner is up on ${id}.`);
    return 0;
  }
  console.error(
    r.result === 'other' ? `The runner is running ${r.version}, not ${id}.` : `The runner didn't come up on ${id} within ${HEALTH_MS / 1000} s.`,
  );
  console.error(`\nEnd of ${c.log}:\n${tail(c.log)}`);
  return 1;
}

function describeRestart(c, v, id) {
  if (v['no-restart']) return 'no restart (--no-restart)';
  if (v.now) return restartCommand(c);
  const resume = c.threadId ? `, then resume this thread with "${v.resume ?? `The runner restarted on release ${id}. Check that your change works, then carry on.`}"` : '';
  return `ask the runner to restart once no thread is running (runner.restart)${resume}`;
}

async function rollback(c, v, waitMs) {
  const state = readState(c.dir);
  const cur = currentId(c);
  const target = state.previous;
  if (!target) throw new Fail('There is no previous release to go back to.');
  if (target === cur) throw new Fail(`current already points at ${target}.`);
  if (!releaseExists(c.dir, target)) throw new Fail(`The previous release ${target} isn't in ${c.releases} any more.`);
  if (v['dry-run']) {
    say(`Would point current at ${target} (now ${cur}).`);
    say(`Would restart: ${describeRestart(c, v, target)}.`);
    return 0;
  }
  lock(c);
  const before = { current: cur, previous: state.previous };
  activate(c, target);
  return restartAndCheck(c, v, target, before, waitMs);
}

// launch.mjs is only copied in by install-runner.sh: a change to it in this
// checkout doesn't reach the LaunchAgent until a reinstall.
function warnStaleLaunch(c) {
  try {
    if (!fs.readFileSync(path.join(c.runnerDir, 'launch.mjs')).equals(fs.readFileSync(path.join(c.dir, 'launch.mjs')))) {
      say(`Note: launch.mjs in this checkout differs from ${path.join(c.dir, 'launch.mjs')}. Releases don't update it; scripts/install-runner.sh does.`);
    }
  } catch {
    // not installed yet; deploy() refuses that case
  }
}

async function deploy(c, v, waitMs) {
  // Without launch.mjs the LaunchAgent still runs a checkout, so a restart
  // would never pick up the release.
  if (!v['no-restart'] && !fs.existsSync(path.join(c.dir, 'launch.mjs'))) {
    throw new Fail(`The runner at ${c.home} doesn't run from releases yet. Install it with scripts/install-runner.sh, which builds the first release.`);
  }
  const g = gitInfo(c);
  if (g.changes.length && !v['allow-dirty']) {
    throw new Fail(
      `runner/ has uncommitted changes in what a release holds:\n${g.changes.map((l) => `  ${l}`).join('\n')}\nCommit them, or pass --allow-dirty to build from the files as they are.`,
    );
  }
  const dirty = g.changes.length > 0;
  if (v['dry-run']) {
    const id = newReleaseId(c, g.short, dirty);
    say('Dry run: nothing changes.');
    say(v['skip-checks'] ? 'Would skip the checks.' : 'Would run the typecheck and unit tests.');
    say(`Would build ${id} from ${dirty ? 'the working tree' : `${g.short} (HEAD)`} into ${c.releases}, then smoke test it.`);
    say(`Would point current at ${id}${currentId(c) ? ` (now ${currentId(c)})` : ''}.`);
    say(`Would restart: ${describeRestart(c, v, id)}.`);
    const gone = pruneList(c, [id]);
    say(gone.length ? `Would remove: ${gone.join(', ')}` : 'Would remove no old releases.');
    return 0;
  }
  lock(c);
  warnStaleLaunch(c);
  if (v['skip-checks']) say('Skipping the checks.');
  else checks(c);
  const id = newReleaseId(c, g.short, dirty);
  build(c, id, g, dirty);
  try {
    await smoke(c, id);
  } catch (e) {
    fs.rmSync(path.join(c.releases, id), { recursive: true, force: true });
    throw e;
  }
  const state = readState(c.dir);
  const before = { current: currentId(c), previous: state.previous };
  activate(c, id);
  let code = 0;
  if (v['no-restart']) say('Not restarting (--no-restart).');
  else code = await restartAndCheck(c, v, id, before, waitMs);
  const running = releaseOf((await probe(c.home)).version);
  prune(c, [running]);
  return code;
}

async function main(argv) {
  let v;
  try {
    ({ values: v } = parseArgs({
      args: argv,
      strict: true,
      options: {
        'skip-checks': { type: 'boolean' },
        'allow-dirty': { type: 'boolean' },
        now: { type: 'boolean' },
        force: { type: 'boolean' },
        wait: { type: 'string' },
        resume: { type: 'string' },
        rollback: { type: 'boolean' },
        list: { type: 'boolean' },
        home: { type: 'string' },
        label: { type: 'string' },
        'dry-run': { type: 'boolean' },
        'no-restart': { type: 'boolean' },
        check: { type: 'boolean' },
        help: { type: 'boolean', short: 'h' },
      },
    }));
  } catch (e) {
    console.error(`${e.message}\nSee scripts/deploy-runner.sh --help.`);
    return 2;
  }
  if (v.help) {
    process.stdout.write(HELP);
    return 0;
  }
  const c = setup(v);
  if (v.list) return list(c);
  if (v.check) return check(c);
  // Everything that can be refused is refused before anything is built.
  if (v.force && !v.now) throw new Fail('--force only goes with --now.');
  if (v.now && v['no-restart']) throw new Fail('--now and --no-restart contradict each other.');
  if (v.now && !c.labelKnown) throw new Fail(`--now restarts through launchd, and ${c.home} isn't the default data dir, so pass --label with its launchd label.`);
  if (v.now && c.threadId && !v.force) {
    throw new Fail(
      "--now would stop the runner this thread runs on, ending this turn. Leave it out: the runner then restarts once this turn ends and resumes this thread. (--now --force does it anyway.)",
    );
  }
  if (v.resume !== undefined && !c.threadId) {
    throw new Fail('--resume picks up the thread it runs in, so it only works inside a Threadbare thread of this runner (THREADBARE_THREAD_ID).');
  }
  const waitMs = parseDuration(v.wait ?? '30m');
  if (v.rollback) return rollback(c, v, waitMs);
  return deploy(c, v, waitMs);
}

main(process.argv.slice(2)).then(
  (code) => process.exit(code),
  (e) => {
    console.error(e instanceof Fail ? e.message : (e?.stack ?? String(e)));
    process.exit(1);
  },
);
