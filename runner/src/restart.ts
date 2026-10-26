// Restarting the runner without cutting a turn short (docs/dev-tools.md,
// section 2). runner.restart saves the request in <home>/restart.json and
// waits until no thread is starting, running or waiting on an approval or
// a question, and no CLI is running background shells or subagents; then
// main.ts shuts down the way it does on SIGTERM and exits 0, and launchd
// starts the runner again. The next start reads the file, notes the restart
// in the threads that asked to carry on, and sends each of them its resume
// text as a turn of the runner's own.
import fs from 'node:fs';
import path from 'node:path';
import type { Runner } from './runner.ts';
import type { Clock } from './clock.ts';
import type { Logger } from './log.ts';
import type { ThreadStatus, ThreadSummary } from './protocol.ts';
import { ErrorCode, RpcError } from './protocol.ts';
import { atomicWriteFileSync, readJsonSync } from './fsutil.ts';
import { paths, RUNNER_VERSION } from './config.ts';

export type RestartWhen = 'idle' | 'now';
export type ResumeRequest = { threadId: string; text: string };

// A resume as saved. release is the release the request expected to come
// back on (deploy-runner.sh's), so a thread resumed on another one (after a
// crash rollback, or a later deploy) is told its change isn't running.
// afterSeq is the thread's last event when it asked: a message someone sent
// after that means they've moved on, and the resume isn't sent.
export type SavedResume = ResumeRequest & { requestedAt: string; release?: string; afterSeq?: number };

// <home>/restart.json. Several requests merge into one: "now" wins and
// every thread's resume is kept (a later one for the same thread replaces
// its earlier one).
export type RestartFile = {
  when: RestartWhen;
  reason?: string;
  requestedAt: string;
  fromVersion: string; // the runner that took the request, for the note afterwards
  release?: string; // the latest request's expected release
  resumes: SavedResume[];
  // When this runner began shutting down for it, or stopped for any other
  // reason while it was pending. A resume's age counts from here, so a
  // restart that waited an hour for a long turn still resumes.
  shutdownAt?: string;
  // restart.done.json only: the runner that handled it.
  handledBy?: string;
  handledRelease?: string;
};

export type RestartParams = { when?: RestartWhen; resume?: ResumeRequest; reason?: string; release?: string; cancel?: boolean };

export type Notice = { level: 'info' | 'warning' | 'error'; message: string };

// runner.status's result (docs/protocol.md).
export type RunnerStatus = {
  version: string;
  release?: string;
  pid: number;
  startedAt: string;
  home: string;
  logFile?: string;
  branch?: string;
  liveClis: number;
  running: string[]; // starting, running or waiting on an approval or a question
  background?: { threadId: string; tasks: string[] }[]; // background shells and subagents still going
  pendingRestart?: { when: RestartWhen; reason?: string; release?: string; resumeThreadId?: string; requestedAt: string; waitingFor: string[] };
};

export const RESUME_MAX_AGE_MS = 15 * 60_000;
export const RESUMES_PER_HOUR = 3;
const HOUR_MS = 60 * 60_000;

const BUSY: ThreadStatus[] = ['starting', 'running', 'waiting'];
const ALL: ('inbox' | 'snoozed' | 'archived')[] = ['inbox', 'snoozed', 'archived'];

export function restartPath(home: string): string {
  return path.join(home, 'restart.json');
}

// The restart.json this runner handled, kept until it has stayed up long
// enough to be marked good. If it crashes and launch.mjs goes back to the
// last good release, that runner resumes the same threads once more.
export function donePath(home: string): string {
  return path.join(home, 'restart.done.json');
}

export function resumesPath(home: string): string {
  return path.join(paths.run(home), 'resumes.json');
}

// Every CLI gets these, so tools an agent runs (tb self, deploy-runner.sh)
// know which thread and which runner they're in. THREADBARE_HOME is the one
// tb reads, and agents point it at a dev runner; THREADBARE_RUNNER_HOME
// always names the runner the thread is on, so the scripts' guards against
// restarting it from inside one of its threads go by that.
export function threadEnv(threadId: string, home: string): Record<string, string> {
  return { THREADBARE_THREAD_ID: threadId, THREADBARE_HOME: home, THREADBARE_RUNNER_HOME: home, THREADBARE_RUNNER_VERSION: RUNNER_VERSION };
}

export type RestarterDeps = {
  runner: Pick<Runner, 'list' | 'get' | 'send' | 'note' | 'notice' | 'onNotification' | 'events' | 'backgroundWork' | 'refuseNewTurns'>;
  home: string;
  clock: Clock;
  log: Logger;
  // Shuts the runner down the way SIGTERM does and exits 0 (main.ts).
  restart: () => void;
  version?: string;
  release?: string;
  branch?: string; // the branch the release was built from (release.json)
  logFile?: string;
  // launch.mjs's rollback notice, when this runner is an earlier release
  // because the one deployed kept crashing: the resumed thread asked for
  // the new one, so its note says so.
  rolledBack?: string;
  rolledBackFrom?: string; // the release launch.mjs went back from
  // The idle check and the restart run after the current tick: a turn that
  // ends and the queued message that starts straight after it never look
  // idle, and the runner.restart reply goes out before the runner stops.
  defer?: (fn: () => void) => void;
};

export class Restarter {
  private deps: RestarterDeps;
  private version: string;
  private defer: (fn: () => void) => void;
  private startedAt: string;
  private pending?: RestartFile;
  private restarting = false;
  private checkQueued = false;

  constructor(deps: RestarterDeps) {
    this.deps = deps;
    this.version = deps.version ?? RUNNER_VERSION;
    this.defer = deps.defer ?? ((fn) => setImmediate(fn));
    this.startedAt = new Date(deps.clock.now()).toISOString();
    // Any summary change can be a thread finishing.
    deps.runner.onNotification((n) => {
      if (n.method === 'thread.updated') this.queueCheck();
    });
  }

  // ------------------------------------------------------------ requests

  request(p: RestartParams): { scheduled: boolean; waitingFor: string[] } {
    const { runner, log } = this.deps;
    if (p.cancel) return this.cancel();
    // A thread that doesn't exist is an error now, not a lost resume later.
    const thread = p.resume ? runner.get(p.resume.threadId) : undefined;
    const now = this.isoNow();
    const next: RestartFile = this.pending ?? { when: 'idle', requestedAt: now, fromVersion: this.version, resumes: [] };
    if (p.when === 'now') next.when = 'now';
    if (p.reason) next.reason = p.reason;
    if (p.release) next.release = p.release;
    if (p.resume && thread) {
      const { threadId, text } = p.resume;
      next.resumes = next.resumes.filter((r) => r.threadId !== threadId);
      const saved: SavedResume = { threadId, text, requestedAt: now, afterSeq: thread.lastSeq };
      if (p.release) saved.release = p.release;
      next.resumes.push(saved);
    }
    this.pending = next;
    this.save();
    const waitingFor = next.when === 'now' || this.restarting ? [] : this.busy();
    log.info('restart requested', { when: next.when, reason: p.reason, resumeThreadId: p.resume?.threadId, waitingFor });
    if (!this.restarting) {
      if (waitingFor.length === 0) this.begin();
      else runner.notice('info', pendingMessage(waitingFor.length));
    }
    return { scheduled: true, waitingFor };
  }

  // Withdraws a restart that hasn't begun (tb restart --cancel).
  private cancel(): { scheduled: boolean; waitingFor: string[] } {
    if (this.restarting) throw new RpcError(ErrorCode.busy, 'The runner is already restarting.');
    if (!this.pending) return { scheduled: false, waitingFor: [] };
    this.pending = undefined;
    try {
      fs.rmSync(restartPath(this.deps.home), { force: true });
    } catch (e) {
      this.deps.log.warn('could not remove restart.json', { error: String(e) });
    }
    this.deps.log.info('restart cancelled');
    this.deps.runner.notice('info', 'The pending runner restart was cancelled.');
    return { scheduled: false, waitingFor: [] };
  }

  status(): RunnerStatus {
    const all = this.deps.runner.list(ALL);
    const running = all.filter((t) => BUSY.includes(t.status)).map((t) => t.id);
    const out: RunnerStatus = {
      version: this.version,
      pid: process.pid,
      startedAt: this.startedAt,
      home: this.deps.home,
      liveClis: all.filter((t) => t.live).length,
      running,
      background: this.deps.runner.backgroundWork(),
    };
    if (this.deps.release) out.release = this.deps.release;
    if (this.deps.branch) out.branch = this.deps.branch;
    if (this.deps.logFile) out.logFile = this.deps.logFile;
    const p = this.pending;
    if (p) {
      const pr: NonNullable<RunnerStatus['pendingRestart']> = { when: p.when, requestedAt: p.requestedAt, waitingFor: p.when === 'now' || this.restarting ? [] : this.busy() };
      if (p.reason) pr.reason = p.reason;
      if (p.release) pr.release = p.release;
      const last = p.resumes.at(-1);
      if (last) pr.resumeThreadId = last.threadId;
      out.pendingRestart = pr;
    }
    return out;
  }

  // Sent after each hello, so an app that connects while a restart waits
  // knows about it.
  helloNotices(): Notice[] {
    if (!this.pending) return [];
    return [{ level: 'info', message: this.restarting ? pendingMessage(0) : pendingMessage(this.busy().length) }];
  }

  // --------------------------------------------------------- idle check

  // The threads a restart waits for: a turn starting, running or waiting on
  // an approval or a question, or background shells and subagents the CLI
  // is still running after its turn ended. Stopping the runner stops those
  // too, and an agent waiting on a 40-minute test run would never hear back.
  private busy(): string[] {
    const ids = new Set(
      this.deps.runner
        .list(ALL)
        .filter((t) => BUSY.includes(t.status))
        .map((t) => t.id),
    );
    for (const b of this.deps.runner.backgroundWork()) ids.add(b.threadId);
    return [...ids];
  }

  private queueCheck(): void {
    if (!this.pending || this.restarting || this.checkQueued) return;
    this.checkQueued = true;
    this.defer(() => {
      this.checkQueued = false;
      if (!this.pending || this.restarting) return;
      if (this.pending.when === 'now' || this.busy().length === 0) this.begin();
    });
  }

  private begin(): void {
    if (this.restarting || !this.pending) return;
    this.restarting = true;
    // A turn started now would be cut off before it got going.
    this.deps.runner.refuseNewTurns('The runner is restarting; send again in a moment.');
    this.pending.shutdownAt = this.isoNow();
    this.save();
    this.deps.log.info('restarting', { when: this.pending.when, reason: this.pending.reason });
    this.deps.runner.notice('info', pendingMessage(0));
    this.defer(() => this.deps.restart());
  }

  // main.ts calls this whenever the runner stops, whatever stopped it
  // (launchctl kickstart, a reboot, the restart itself). A pending restart
  // counts as done from here, so a resume's age starts now rather than when
  // the restart was first asked for.
  stopping(): void {
    // Stopping cleanly isn't crashing: the restart this runner handled is done.
    this.proven();
    if (!this.pending || this.pending.shutdownAt) return;
    this.pending.shutdownAt = this.isoNow();
    this.save();
  }

  // main.ts calls this once the runner has stayed up long enough to be
  // marked good: the restart it handled won't need handling again.
  proven(): void {
    try {
      fs.rmSync(donePath(this.deps.home), { force: true });
    } catch (e) {
      this.deps.log.warn('could not remove restart.done.json', { error: String(e) });
    }
  }

  private save(): void {
    try {
      atomicWriteFileSync(restartPath(this.deps.home), JSON.stringify(this.pending, null, 2) + '\n');
    } catch (e) {
      // Still restarts; only a crash before then would lose it.
      this.deps.log.error('could not save restart.json', { error: String(e) });
    }
  }

  // ------------------------------------------------------- next start

  // Handles the restart.json the previous runner left (it restarted, or
  // crashed while a restart was pending, which comes to the same thing).
  // The file moves to restart.done.json first, so a resume that crashes
  // this runner isn't sent again by the next start of the same release; but
  // if this release keeps crashing and launch.mjs goes back to the last good
  // one, that runner finds restart.done.json with the rollback and resumes
  // the same threads once more, saying what happened.
  resumeAfterRestart(): void {
    const { log, home } = this.deps;
    const file = restartPath(home);
    const done = donePath(home);
    let saved: RestartFile | undefined;
    let again = false;
    if (fs.existsSync(file)) {
      saved = readJsonSync<RestartFile>(file);
      try {
        if (saved && typeof saved === 'object') {
          atomicWriteFileSync(done, JSON.stringify({ ...saved, handledBy: this.version, handledRelease: this.deps.release }, null, 2) + '\n');
        }
        fs.unlinkSync(file);
      } catch (e) {
        log.warn('could not move restart.json aside', { error: String(e) });
      }
    } else if (fs.existsSync(done)) {
      // Left by a runner that didn't stay up. Only worth acting on if that
      // runner was the release launch.mjs has just gone back from.
      const left = readJsonSync<RestartFile>(done);
      if (this.deps.rolledBack && left && typeof left === 'object' && left.handledRelease !== undefined && left.handledRelease === this.deps.rolledBackFrom) {
        saved = left;
        again = true;
      }
      try {
        fs.unlinkSync(done);
      } catch (e) {
        log.warn('could not remove restart.done.json', { error: String(e) });
      }
      if (!again) return;
    } else {
      return;
    }
    if (!saved || typeof saved !== 'object') {
      log.warn('restart.json could not be read; nothing to resume');
      return;
    }
    const from = again && typeof saved.handledBy === 'string' ? saved.handledBy : typeof saved.fromVersion === 'string' ? saved.fromVersion : 'an unknown version';
    log.info('restarted', { from, to: this.version, reason: saved.reason, again });
    for (const r of Array.isArray(saved.resumes) ? saved.resumes : []) {
      if (!r || typeof r.threadId !== 'string' || typeof r.text !== 'string') continue;
      this.resumeOne(saved, r, from);
    }
  }

  private resumeOne(saved: RestartFile, r: SavedResume, from: string): void {
    const { runner, log, home } = this.deps;
    let thread: ThreadSummary;
    try {
      thread = runner.get(r.threadId);
    } catch {
      log.warn('the thread to resume after the restart is gone', { threadId: r.threadId });
      return;
    }
    try {
      const now = this.deps.clock.now();
      // From the shutdown if the old runner got that far; else from when this
      // thread asked (a later request merged in has its own time).
      const at = Date.parse(saved.shutdownAt ?? r.requestedAt ?? saved.requestedAt);
      const fresh = Number.isFinite(at) && now - at < RESUME_MAX_AGE_MS;
      const branch = this.deps.branch && this.deps.branch !== 'main' ? ` (from branch ${this.deps.branch})` : '';
      let note = `Runner restarted: ${from} to ${this.version}${branch}`;
      if (this.deps.rolledBack) note += `\n\n${this.deps.rolledBack}`;
      const warning = this.wrongRelease(r);
      if (warning && !this.deps.rolledBack) note += `\n\n${warning}`;
      const why = !fresh
        ? `the request is more than ${RESUME_MAX_AGE_MS / 60_000} minutes old`
        : thread.archivedAt
          ? 'this thread is archived'
          : thread.snoozedUntil !== undefined && Date.parse(thread.snoozedUntil) > now
            ? 'this thread is snoozed'
            : this.spokenSince(r)
              ? 'a message was sent to this thread after the restart was asked for'
              : !takeResume(home, r.threadId, now)
                ? `this thread has already been resumed ${RESUMES_PER_HOUR} times in the last hour`
                : undefined;
      if (why) note += `\n\nNot carrying on by itself: ${why}.`;
      runner.note(r.threadId, note);
      if (why) {
        log.info('not resuming a thread after the restart', { threadId: r.threadId, why });
        return;
      }
      // The note is only for the app; the model hears about a rollback, or a
      // release that isn't the one it deployed, from the message itself.
      const heads = [this.deps.rolledBack, warning].filter(Boolean);
      const text = heads.length ? `Note from the runner: ${heads.join(' ')} Check tb logs before going on. Your message for after the restart follows.\n\n${r.text}` : r.text;
      runner.send(r.threadId, text, [], { origin: 'runner' });
      log.info('resumed a thread after the restart', { threadId: r.threadId });
    } catch (e) {
      log.error('could not resume a thread after the restart', { threadId: r.threadId, error: String(e) });
    }
  }

  // Set when the thread asked for a release that isn't the one running.
  private wrongRelease(r: SavedResume): string | undefined {
    if (typeof r.release !== 'string' || !r.release || r.release === this.deps.release) return undefined;
    return `Release ${r.release} isn't running (this is ${this.deps.release ?? 'a runner run from source'}), so the change it carries isn't live.`;
  }

  // Someone wrote in the thread after it asked to be carried on: the resume
  // would talk over them.
  private spokenSince(r: SavedResume): boolean {
    if (typeof r.afterSeq !== 'number') return false;
    for (let after = r.afterSeq; ; ) {
      const page = this.deps.runner.events(r.threadId, { afterSeq: after, limit: 10_000 }).events;
      if (page.some((e) => e.type === 'user.message' && e.origin !== 'runner')) return true;
      if (page.length < 10_000) return false;
      after = page[page.length - 1].seq;
    }
  }

  private isoNow(): string {
    return new Date(this.deps.clock.now()).toISOString();
  }
}

export function pendingMessage(waiting: number): string {
  if (waiting === 0) return 'The runner is restarting now.';
  return waiting === 1 ? 'The runner will restart when 1 thread finishes.' : `The runner will restart when ${waiting} threads finish.`;
}

// At most RESUMES_PER_HOUR automatic resumes per thread in any hour, kept in
// run/resumes.json so a restart loop (an agent that deploys, resumes and
// deploys again) stops by itself. Returns false when the thread is over.
export function takeResume(home: string, threadId: string, now: number): boolean {
  const file = resumesPath(home);
  const all = readJsonSync<Record<string, string[]>>(file) ?? {};
  const recent = (ts: unknown): string[] =>
    Array.isArray(ts) ? ts.filter((t): t is string => typeof t === 'string' && now - Date.parse(t) < HOUR_MS) : [];
  const out: Record<string, string[]> = {};
  for (const [id, ts] of Object.entries(all)) {
    const kept = recent(ts);
    if (kept.length) out[id] = kept;
  }
  const mine = out[threadId] ?? [];
  if (mine.length >= RESUMES_PER_HOUR) return false;
  out[threadId] = [...mine, new Date(now).toISOString()];
  atomicWriteFileSync(file, JSON.stringify(out, null, 2) + '\n');
  return true;
}

// ----------------------------------------------------------------- RPC

// runner.status and runner.restart, served by rpc.ts beside the runner's
// own methods.
export function restartMethods(r: Restarter): Record<string, (p: Record<string, unknown>) => unknown> {
  return {
    'runner.status': () => r.status(),
    'runner.restart': (p) => r.request(parseRestartParams(p)),
  };
}

function bad(message: string): RpcError {
  return new RpcError(ErrorCode.badParams, message);
}

export function parseRestartParams(p: Record<string, unknown>): RestartParams {
  const out: RestartParams = {};
  if (p.cancel !== undefined && p.cancel !== null && p.cancel !== false) {
    if (p.cancel !== true) throw bad('cancel must be true or false');
    out.cancel = true;
  }
  if (p.release !== undefined && p.release !== null) {
    if (typeof p.release !== 'string' || !p.release) throw bad('release must be a release id');
    out.release = p.release;
  }
  if (p.when !== undefined && p.when !== null) {
    if (p.when !== 'idle' && p.when !== 'now') throw bad('when must be "idle" or "now"');
    out.when = p.when;
  }
  if (p.reason !== undefined && p.reason !== null) {
    if (typeof p.reason !== 'string') throw bad('reason must be a string');
    if (p.reason.trim()) out.reason = p.reason.trim();
  }
  if (p.resume !== undefined && p.resume !== null) {
    const r = p.resume as Record<string, unknown>;
    if (typeof r !== 'object' || Array.isArray(r)) throw bad('resume must be an object');
    if (typeof r.threadId !== 'string' || !r.threadId) throw bad('resume.threadId must be a string');
    if (typeof r.text !== 'string' || !r.text.trim()) throw bad('resume.text must be a non-empty string');
    out.resume = { threadId: r.threadId, text: r.text };
  }
  return out;
}
