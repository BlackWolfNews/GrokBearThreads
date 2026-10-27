// The runner following main by itself (docs/dev-tools.md, "The runner
// updating itself"). Every few minutes a runner that runs from a release
// looks at main in the checkout it was built from. When what a release
// holds of runner/ (src, bin, package.json, package-lock.json) differs
// there from what's running, it builds a release of main the way
// deploy-runner.sh does (checks, snapshot, smoke test, point current at
// it), from its own clone under <home>/runner/update/src so nothing an
// agent has going in the checkout is built or disturbed, and then asks for
// the usual restart once no thread is busy. A tree whose build failed, or
// whose release crashed at startup, isn't tried again until main changes.
import { spawn, spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import type { Clock, TimerHandle } from './clock.ts';
import type { Logger } from './log.ts';
import { currentLink, readRelease, readState, type ReleaseJson } from './release.ts';
import type { RestartResult } from './restart.ts';
import { atomicWriteFileSync, readJsonSync } from './fsutil.ts';

export const CHECK_INTERVAL_MS = 5 * 60_000;
// After this release is marked good: a release about to be rolled back
// should never deploy anything.
export const FIRST_CHECK_MS = 30_000;
// Background shells and subagents hold the update's restart this long at
// most (turns always hold it), as deploy-runner.sh's default --wait.
export const BACKGROUND_WAIT_MS = 30 * 60_000;
// What a release holds from runner/, as deploy.mjs's RELEASE_PATHS: only a
// change to these changes what runs, so a commit that only touches tests
// or docs doesn't restart the runner.
export const RELEASE_PATHS = ['src', 'bin', 'package.json', 'package-lock.json'];
const TRANSIENT = /Another deploy \(pid/;

export type UpdateState = 'off' | 'idle' | 'checking' | 'building' | 'waiting' | 'failed';

// runner.status's `update` (docs/protocol.md).
export type UpdateStatus = {
  state: UpdateState;
  checkout?: string;
  // off: why updates are off; failed: what went wrong.
  reason?: string;
  checkedAt?: string;
  // The commit on main the last check saw, and the release built from it
  // (waiting to start) when there is one.
  commit?: string;
  release?: string;
  logFile?: string;
};

export type MainInfo = { commit: string; short: string; subject: string; tree: string };
export type DeployResult = { ok: true; id: string } | { ok: false; error: string; transient?: boolean };

// <home>/runner/update.json: the build that failed, so it isn't retried
// every five minutes.
export type UpdateFile = { failed?: { tree: string; commit: string; at: string; error: string } };

export type UpdateDeps = {
  home: string;
  // This runner's release.json; a runner run from a checkout has none, and
  // doesn't follow anything.
  release?: ReleaseJson;
  enabled: boolean;
  clock: Clock;
  log: Logger;
  notice: (level: 'info' | 'warning' | 'error', message: string) => void;
  // Restarter.request with when: 'idle'.
  restart: (p: { release: string; reason: string; backgroundWaitMs: number }) => RestartResult;
  pendingRestart: () => boolean;
  // Replaced in tests: bringing the clone to main, and the deploy itself.
  sync?: (checkout: string, prefix: string, dir: string) => Promise<MainInfo>;
  treeOf?: (dir: string, prefix: string, commit: string) => string | undefined;
  deploy?: (runnerDir: string, home: string, logFile: string) => Promise<DeployResult>;
};

export type Decision = { action: 'build' } | { action: 'nothing'; why: string };

// Whether main is worth building. running.tree is what this release holds
// (undefined when it can't be worked out); current is the release the
// current link names.
export function decideUpdate(i: {
  mainTree: string;
  running: { id: string; tree?: string };
  current?: string;
  pendingRestart: boolean;
  failed?: { tree: string };
  crashedTrees: Set<string>;
}): Decision {
  if (!i.running.tree) return { action: 'nothing', why: "can't tell what this release was built from" };
  if (i.pendingRestart) return { action: 'nothing', why: 'a restart is already pending' };
  if (i.current && i.current !== i.running.id) return { action: 'nothing', why: `release ${i.current} is current and waiting to start` };
  if (i.mainTree === i.running.tree) return { action: 'nothing', why: 'up to date with main' };
  if (i.failed?.tree === i.mainTree) return { action: 'nothing', why: 'the last build of this tree failed; waiting for main to change' };
  if (i.crashedTrees.has(i.mainTree)) return { action: 'nothing', why: 'a release of this tree crashed at startup; waiting for main to change' };
  return { action: 'build' };
}

export function updateDir(home: string): string {
  return path.join(home, 'runner', 'update');
}

export function updateFilePath(home: string): string {
  return path.join(home, 'runner', 'update.json');
}

export function updateLogPath(home: string): string {
  return path.join(home, 'runner', 'update.log');
}

function git(cwd: string, args: string[]): string {
  const r = spawnSync('git', ['-C', cwd, ...args], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  if (r.status !== 0) throw new Error(`git ${args.join(' ')} failed: ${String(r.stderr).trim()}`);
  return r.stdout.trim();
}

// The object hashes of the release paths at `rev`, joined: the same formula
// deploy.mjs writes as `tree` in release.json. Undefined when `rev` isn't
// in the repo or holds none of them.
export function releaseTreeAt(repo: string, prefix: string, rev: string): string | undefined {
  const r = spawnSync('git', ['-C', repo, 'ls-tree', rev, '--', ...RELEASE_PATHS.map((p) => prefix + p)], { encoding: 'utf8' });
  if (r.status !== 0) return undefined;
  const hashes = r.stdout
    .split('\n')
    .filter(Boolean)
    .map((line) => line.split(/\s+/)[2]);
  return hashes.length ? hashes.join('+') : undefined;
}

// Brings <dir> to the checkout's main: a clone of the checkout (so only
// what's committed on main is built, never a working tree), fetched and
// reset each time. runner/node_modules is kept between runs for the checks,
// and dropped when package-lock.json changed so they install afresh.
export async function syncClone(checkout: string, prefix: string, dir: string): Promise<MainInfo> {
  if (!fs.existsSync(path.join(dir, '.git'))) {
    fs.rmSync(dir, { recursive: true, force: true });
    fs.mkdirSync(path.dirname(dir), { recursive: true });
    git(path.dirname(dir), ['clone', '-q', '--no-checkout', checkout, dir]);
  }
  git(dir, ['fetch', '-q', checkout, 'refs/heads/main']);
  git(dir, ['checkout', '-q', '-B', 'main', 'FETCH_HEAD']);
  const modules = path.join(dir, prefix, 'node_modules');
  git(dir, ['clean', '-qfdx', '-e', `${prefix}node_modules`]);
  const lockFile = path.join(dir, prefix, 'package-lock.json');
  // Beside the clone, not in it: git clean would take it out each time.
  const stamp = path.join(path.dirname(dir), 'installed-lock');
  const lock = fs.existsSync(lockFile) ? crypto.createHash('sha256').update(fs.readFileSync(lockFile)).digest('hex') : '';
  let had = '';
  try {
    had = fs.readFileSync(stamp, 'utf8').trim();
  } catch {
    // first run
  }
  if (had !== lock) {
    fs.rmSync(modules, { recursive: true, force: true });
    fs.writeFileSync(stamp, lock + '\n');
  }
  const tree = releaseTreeAt(dir, prefix, 'HEAD');
  if (!tree) throw new Error(`main in ${checkout} has no ${prefix}src to build`);
  return { commit: git(dir, ['rev-parse', 'HEAD']), short: git(dir, ['rev-parse', '--short', 'HEAD']), subject: git(dir, ['log', '-1', '--format=%s']), tree };
}

// deploy.mjs from the clone, stopping after it has pointed current at the
// new release (--no-restart): the runner asks for the restart itself, so
// the build never has to outlive it. Its output goes to logFile.
export function runDeploy(runnerDir: string, home: string, logFile: string): Promise<DeployResult> {
  return new Promise((resolve) => {
    const env: Record<string, string | undefined> = {};
    for (const [k, v] of Object.entries(process.env)) if (!k.startsWith('THREADBARE_')) env[k] = v;
    let fd: number;
    try {
      fd = fs.openSync(logFile, 'w');
    } catch (e) {
      resolve({ ok: false, error: `couldn't open ${logFile}: ${(e as Error).message}` });
      return;
    }
    const child = spawn(process.execPath, [path.join(runnerDir, 'scripts', 'deploy.mjs'), '--no-restart', '--home', home], {
      cwd: runnerDir,
      env,
      stdio: ['ignore', fd, fd],
    });
    fs.closeSync(fd);
    child.on('error', (e) => resolve({ ok: false, error: e.message }));
    child.on('close', (code, signal) => {
      if (code === 0) {
        const id = currentLink(home);
        resolve(id ? { ok: true, id } : { ok: false, error: 'the deploy finished but current names no release' });
        return;
      }
      let text = '';
      try {
        text = fs.readFileSync(logFile, 'utf8');
      } catch {
        // nothing written
      }
      const lines = text.trim().split('\n').filter(Boolean);
      const last = lines.at(-1) ?? (signal ? `stopped by ${signal}` : `exit ${code}`);
      resolve({ ok: false, error: last.slice(0, 300), transient: TRANSIENT.test(text) });
    });
  });
}

export class RunnerUpdater {
  private deps: UpdateDeps;
  private timer?: TimerHandle;
  private state: UpdateState = 'off';
  private reason?: string;
  private checkedAt?: string;
  private commit?: string;
  private releaseBuilt?: string;
  private busy = false;
  private stopped = false;

  constructor(deps: UpdateDeps) {
    this.deps = deps;
  }

  // Called once this release has been marked good.
  start(): void {
    const { release, enabled, log } = this.deps;
    const off = (why: string) => {
      this.state = 'off';
      this.reason = why;
      log.info('not following main', { why });
    };
    if (!enabled) return off('followMain is off in runner.json');
    if (!release) return off('running from a checkout, not a release');
    if (!release.checkout || !release.prefix) return off('this release was built before releases recorded their checkout; deploy once by hand');
    if (!fs.existsSync(path.join(release.checkout, '.git'))) return off(`the checkout it was built from, ${release.checkout}, is gone`);
    this.state = 'idle';
    log.info('following main', { checkout: release.checkout, release: release.id });
    this.timer = this.deps.clock.setTimeout(() => this.tick(), FIRST_CHECK_MS);
  }

  stop(): void {
    this.stopped = true;
    this.timer?.cancel();
    this.timer = undefined;
  }

  status(): UpdateStatus {
    const out: UpdateStatus = { state: this.state };
    if (this.deps.release?.checkout) out.checkout = this.deps.release.checkout;
    if (this.reason) out.reason = this.reason;
    if (this.checkedAt) out.checkedAt = this.checkedAt;
    if (this.commit) out.commit = this.commit;
    if (this.releaseBuilt) out.release = this.releaseBuilt;
    if (this.state !== 'off') out.logFile = updateLogPath(this.deps.home);
    return out;
  }

  private tick(): void {
    this.timer = undefined;
    void this.check().finally(() => {
      if (!this.stopped && this.state !== 'off') this.timer = this.deps.clock.setTimeout(() => this.tick(), CHECK_INTERVAL_MS);
    });
  }

  // One look at main, and a build if it's worth one. Public for tests.
  async check(): Promise<Decision | undefined> {
    const { home, release, log } = this.deps;
    if (this.busy || this.stopped || !release?.checkout || !release.prefix) return undefined;
    this.busy = true;
    const wasFailed = this.state === 'failed';
    this.state = 'checking';
    try {
      const dir = path.join(updateDir(home), 'src');
      const main = await (this.deps.sync ?? syncClone)(release.checkout, release.prefix, dir);
      this.checkedAt = new Date(this.deps.clock.now()).toISOString();
      this.commit = main.commit;
      const treeOf = this.deps.treeOf ?? releaseTreeAt;
      const running = { id: release.id, tree: release.tree ?? (release.dirty ? undefined : treeOf(dir, release.prefix, release.commit)) };
      const file = readJsonSync<UpdateFile>(updateFilePath(home));
      const decision = decideUpdate({
        mainTree: main.tree,
        running,
        current: currentLink(home),
        pendingRestart: this.deps.pendingRestart(),
        failed: file?.failed,
        crashedTrees: this.crashedTrees(dir, release.prefix, treeOf),
      });
      if (decision.action === 'nothing') {
        log.debug('main checked', { commit: main.short, why: decision.why });
        // A failure stays on show until main moves on from it.
        this.state = wasFailed && file?.failed?.tree === main.tree ? 'failed' : 'idle';
        return decision;
      }
      this.state = 'building';
      this.reason = undefined;
      log.info('building a release of main', { commit: main.short, subject: main.subject });
      const result = await (this.deps.deploy ?? runDeploy)(path.join(dir, release.prefix), home, updateLogPath(home));
      if (this.stopped) return decision;
      if (!result.ok) {
        if (result.transient) {
          log.info('could not build main now; trying again later', { error: result.error });
          this.state = 'idle';
          return decision;
        }
        this.state = 'failed';
        this.reason = result.error;
        atomicWriteFileSync(updateFilePath(home), JSON.stringify({ failed: { tree: main.tree, commit: main.commit, at: this.checkedAt, error: result.error } } as UpdateFile, null, 2) + '\n');
        log.error('could not build a release of main', { commit: main.short, error: result.error });
        this.deps.notice('warning', `The runner couldn't update to main at ${main.short} (${main.subject}): ${result.error}. The output is in ${updateLogPath(home)}.`);
        return decision;
      }
      this.releaseBuilt = result.id;
      this.state = 'waiting';
      const res = this.deps.restart({ release: result.id, reason: `Updating to main at ${main.short}: ${main.subject}`, backgroundWaitMs: BACKGROUND_WAIT_MS });
      log.info('release of main built; restart asked for', { release: result.id, commit: main.short, waitingFor: res.waitingFor });
      return decision;
    } catch (e) {
      // Git trouble in the clone, say: logged, and tried again next time.
      log.warn('could not check main', { error: String(e) });
      this.state = wasFailed ? 'failed' : 'idle';
      return undefined;
    } finally {
      this.busy = false;
    }
  }

  // The trees of releases that crashed at startup (deploy.mjs's `crashed`
  // and launch.mjs's rolledBack), so a commit that crashed isn't built and
  // deployed every five minutes.
  private crashedTrees(dir: string, prefix: string, treeOf: NonNullable<UpdateDeps['treeOf']>): Set<string> {
    const out = new Set<string>();
    const state = readState(this.deps.home) as (ReturnType<typeof readState> & { crashed?: unknown }) | undefined;
    const ids = new Set<string>(Array.isArray(state?.crashed) ? state.crashed.filter((x): x is string => typeof x === 'string') : []);
    if (state?.rolledBack?.from) ids.add(state.rolledBack.from);
    if (state?.lastGood) ids.delete(state.lastGood);
    for (const id of ids) {
      const r = readRelease(path.join(this.deps.home, 'runner', 'releases', id));
      if (!r) continue;
      const tree = r.tree ?? (r.dirty ? undefined : treeOf(dir, prefix, r.commit));
      if (tree) out.add(tree);
    }
    return out;
  }
}
