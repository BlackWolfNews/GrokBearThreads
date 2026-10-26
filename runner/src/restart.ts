// Restarting the runner without cutting a turn short (docs/dev-tools.md,
// section 2). runner.restart saves the request in <home>/restart.json and
// waits until no thread is starting, running or waiting on an approval or
// a question; then main.ts shuts down the way it does on SIGTERM and exits
// 0, and launchd starts the runner again. The next start reads the file,
// notes the restart in the threads that asked to carry on, and sends each
// of them its resume text as a turn of the runner's own.
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

// <home>/restart.json. Several requests merge into one: "now" wins and
// every thread's resume is kept (a later one for the same thread replaces
// its earlier one).
export type RestartFile = {
  when: RestartWhen;
  reason?: string;
  requestedAt: string;
  fromVersion: string; // the runner that took the request, for the note afterwards
  resumes: (ResumeRequest & { requestedAt: string })[];
  // When this runner began shutting down for it. A resume's age counts from
  // here, so a restart that waited an hour for a long turn still resumes.
  shutdownAt?: string;
};

export type Notice = { level: 'info' | 'warning' | 'error'; message: string };

// runner.status's result (docs/protocol.md).
export type RunnerStatus = {
  version: string;
  release?: string;
  pid: number;
  startedAt: string;
  home: string;
  logFile?: string;
  liveClis: number;
  running: string[]; // starting, running or waiting: the threads a restart waits for
  pendingRestart?: { when: RestartWhen; reason?: string; resumeThreadId?: string; requestedAt: string; waitingFor: string[] };
};

export const RESUME_MAX_AGE_MS = 15 * 60_000;
export const RESUMES_PER_HOUR = 3;
const HOUR_MS = 60 * 60_000;

const BUSY: ThreadStatus[] = ['starting', 'running', 'waiting'];
const ALL: ('inbox' | 'snoozed' | 'archived')[] = ['inbox', 'snoozed', 'archived'];

export function restartPath(home: string): string {
  return path.join(home, 'restart.json');
}

export function resumesPath(home: string): string {
  return path.join(paths.run(home), 'resumes.json');
}

// Every CLI gets these, so tools an agent runs (tb self, deploy-runner.sh)
// know which thread and which runner they're in.
export function threadEnv(threadId: string, home: string): Record<string, string> {
  return { THREADBARE_THREAD_ID: threadId, THREADBARE_HOME: home, THREADBARE_RUNNER_VERSION: RUNNER_VERSION };
}

export type RestarterDeps = {
  runner: Pick<Runner, 'list' | 'get' | 'send' | 'note' | 'notice' | 'onNotification'>;
  home: string;
  clock: Clock;
  log: Logger;
  // Shuts the runner down the way SIGTERM does and exits 0 (main.ts).
  restart: () => void;
  version?: string;
  release?: string;
  logFile?: string;
  // launch.mjs's rollback notice, when this runner is an earlier release
  // because the one deployed kept crashing: the resumed thread asked for
  // the new one, so its note says so.
  rolledBack?: string;
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

  request(p: { when?: RestartWhen; resume?: ResumeRequest; reason?: string }): { scheduled: boolean; waitingFor: string[] } {
    const { runner, log } = this.deps;
    if (p.resume) runner.get(p.resume.threadId); // a thread that doesn't exist is an error now, not a lost resume later
    const now = this.isoNow();
    const next: RestartFile = this.pending ?? { when: 'idle', requestedAt: now, fromVersion: this.version, resumes: [] };
    if (p.when === 'now') next.when = 'now';
    if (p.reason) next.reason = p.reason;
    if (p.resume) {
      const { threadId, text } = p.resume;
      next.resumes = next.resumes.filter((r) => r.threadId !== threadId);
      next.resumes.push({ threadId, text, requestedAt: now });
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
    };
    if (this.deps.release) out.release = this.deps.release;
    if (this.deps.logFile) out.logFile = this.deps.logFile;
    const p = this.pending;
    if (p) {
      const pr: NonNullable<RunnerStatus['pendingRestart']> = { when: p.when, requestedAt: p.requestedAt, waitingFor: p.when === 'now' || this.restarting ? [] : running };
      if (p.reason) pr.reason = p.reason;
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

  private busy(): string[] {
    return this.deps.runner
      .list(ALL)
      .filter((t) => BUSY.includes(t.status))
      .map((t) => t.id);
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
    this.pending.shutdownAt = this.isoNow();
    this.save();
    this.deps.log.info('restarting', { when: this.pending.when, reason: this.pending.reason });
    this.deps.runner.notice('info', pendingMessage(0));
    this.defer(() => this.deps.restart());
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
  // The file is removed first, so a resume that crashes this runner isn't
  // sent again on the next start.
  resumeAfterRestart(): void {
    const { runner, log, home } = this.deps;
    const file = restartPath(home);
    if (!fs.existsSync(file)) return;
    const saved = readJsonSync<RestartFile>(file);
    try {
      fs.unlinkSync(file);
    } catch (e) {
      log.warn('could not remove restart.json', { error: String(e) });
    }
    if (!saved || typeof saved !== 'object') {
      log.warn('restart.json could not be read; nothing to resume');
      return;
    }
    const now = this.deps.clock.now();
    const at = Date.parse(saved.shutdownAt ?? saved.requestedAt);
    const fresh = Number.isFinite(at) && now - at < RESUME_MAX_AGE_MS;
    const from = typeof saved.fromVersion === 'string' ? saved.fromVersion : 'an unknown version';
    log.info('restarted', { from, to: this.version, reason: saved.reason });
    for (const r of Array.isArray(saved.resumes) ? saved.resumes : []) {
      if (!r || typeof r.threadId !== 'string' || typeof r.text !== 'string') continue;
      let thread: ThreadSummary;
      try {
        thread = runner.get(r.threadId);
      } catch {
        log.warn('the thread to resume after the restart is gone', { threadId: r.threadId });
        continue;
      }
      try {
        let note = `Runner restarted: ${from} to ${this.version}`;
        if (this.deps.rolledBack) note += `\n\n${this.deps.rolledBack}`;
        const away = Boolean(thread.archivedAt) || (thread.snoozedUntil !== undefined && Date.parse(thread.snoozedUntil) > now);
        const send = fresh && !away && takeResume(home, r.threadId, now);
        if (!fresh) note += `\n\nNot carrying on by itself: the request is more than ${RESUME_MAX_AGE_MS / 60_000} minutes old.`;
        else if (!away && !send) note += `\n\nNot carrying on by itself: this thread has already been resumed ${RESUMES_PER_HOUR} times in the last hour.`;
        runner.note(r.threadId, note);
        if (send) {
          runner.send(r.threadId, r.text, [], { origin: 'runner' });
          log.info('resumed a thread after the restart', { threadId: r.threadId });
        } else {
          log.info('not resuming a thread after the restart', { threadId: r.threadId, fresh, away });
        }
      } catch (e) {
        log.error('could not resume a thread after the restart', { threadId: r.threadId, error: String(e) });
      }
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

export function parseRestartParams(p: Record<string, unknown>): { when?: RestartWhen; resume?: ResumeRequest; reason?: string } {
  const out: { when?: RestartWhen; resume?: ResumeRequest; reason?: string } = {};
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
