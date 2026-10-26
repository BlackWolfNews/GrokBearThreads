// Which code this runner is, and the release bookkeeping in
// <home>/runner/state.json that launch.mjs and deploy-runner.sh share with
// it (docs/dev-tools.md). The LaunchAgent runs a snapshot under
// <home>/runner/releases/<id>/ with a release.json beside src/; a runner
// started from a checkout has none and reports itself as "+source".
import path from 'node:path';
import { atomicWriteFileSync, readJsonSync } from './fsutil.ts';
import type { Logger } from './log.ts';

export type ReleaseJson = { id: string; commit: string; dirty: boolean; builtAt: string; node: string };

export type RunnerState = {
  current: string;
  previous: string | null;
  lastGood: string | null;
  boots: { release: string; at: string }[];
  // reportedAt is the runner's own: set once the notice has gone out, so a
  // rollback is announced by the first runner after it and no other.
  rolledBack?: { from: string; to: string; at: string; reportedAt?: string };
};

// The folder holding src/, package.json and (in a release) release.json.
const CODE_ROOT = path.resolve(import.meta.dirname, '..');

export function readRelease(root = CODE_ROOT): ReleaseJson | undefined {
  const r = readJsonSync<ReleaseJson>(path.join(root, 'release.json'));
  return r && typeof r.id === 'string' && r.id ? r : undefined;
}

export function runnerVersion(root = CODE_ROOT): { version: string; release?: string } {
  const pkg = readJsonSync<{ version?: string }>(path.join(root, 'package.json'));
  const base = typeof pkg?.version === 'string' ? pkg.version : '0.0.0';
  const release = readRelease(root)?.id;
  return release ? { version: `${base}+${release}`, release } : { version: `${base}+source` };
}

export const RELEASE = runnerVersion();

export function statePath(home: string): string {
  return path.join(home, 'runner', 'state.json');
}

export function readState(home: string): RunnerState | undefined {
  const s = readJsonSync<RunnerState>(statePath(home));
  return s && typeof s === 'object' && !Array.isArray(s) ? s : undefined;
}

// Read, change and write back in one go, keeping fields this runner doesn't
// know about. A missing or unreadable state.json is left alone: that's a
// runner run from source, or a sandbox home with no releases.
function updateState(home: string, change: (s: RunnerState) => boolean): boolean {
  const s = readState(home);
  if (!s) return false;
  if (!change(s)) return false;
  atomicWriteFileSync(statePath(home), JSON.stringify(s, null, 2) + '\n');
  return true;
}

// Tells launch.mjs this release starts and stays up, so it is never rolled
// back from and is the one to go back to.
export function markGood(home: string, releaseId: string | undefined, log: Logger): boolean {
  if (!releaseId) return false;
  try {
    const changed = updateState(home, (s) => {
      if (s.lastGood === releaseId) return false;
      s.lastGood = releaseId;
      return true;
    });
    if (changed) log.info('marked this release good', { release: releaseId });
    return changed;
  } catch (e) {
    log.warn('could not mark this release good', { release: releaseId, error: String(e) });
    return false;
  }
}

// The message for a rollback launch.mjs did and nobody has reported yet.
// Marks it reported, so the next runner doesn't say it again.
export function takeRollbackNotice(home: string, log: Logger, now = Date.now()): string | undefined {
  let message: string | undefined;
  try {
    updateState(home, (s) => {
      const rb = s.rolledBack;
      if (!rb || typeof rb !== 'object' || rb.reportedAt) return false;
      message = `Release ${rb.from} kept crashing at startup, so the runner went back to ${rb.to}.`;
      rb.reportedAt = new Date(now).toISOString();
      return true;
    });
  } catch (e) {
    // Better to say it twice than not at all.
    log.warn('could not mark the rollback reported', { error: String(e) });
  }
  if (message) log.warn('running an earlier release after a rollback', { message });
  return message;
}

// A release counts as good once it has been listening this long: launch.mjs
// rolls back one that boots 3 times in 2 minutes without getting here.
// THREADBARE_GOOD_AFTER_MS shortens it for tests.
export const GOOD_AFTER_MS = 60_000;

// Returns a cancel for main.ts's shutdown: a runner that is stopping (one
// whose shutdown hangs, say) hasn't shown it stays up.
export function markGoodLater(home: string, releaseId: string | undefined, log: Logger, env: NodeJS.ProcessEnv = process.env): () => void {
  if (!releaseId) return () => {};
  const fromEnv = env.THREADBARE_GOOD_AFTER_MS ? Number(env.THREADBARE_GOOD_AFTER_MS) : NaN;
  const ms = Number.isFinite(fromEnv) && fromEnv >= 0 ? fromEnv : GOOD_AFTER_MS;
  const timer = setTimeout(() => markGood(home, releaseId, log), ms);
  timer.unref();
  return () => clearTimeout(timer);
}
