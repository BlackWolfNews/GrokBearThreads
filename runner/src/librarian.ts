// The librarian: the runner's own background job that keeps projects up
// to date (docs/protocol.md, "Projects"). It watches threads' turns and
// moves, and now and then asks the small model (models/index.ts, feature
// "projects") which projects a thread belongs in, whether it needs a new
// one, and where the thread has got a project to. What it decides takes
// effect straight away; Mike can take a thread out, and then it's never
// put back (projects.ts).
//
// One look at a time, the soonest due first. Its queue, what it did and
// whether it's paused are kept in librarian.json, so a runner restart
// (which happens whenever main moves) doesn't lose them. The app shows all
// of it in the Librarian view (LibrarianStatus).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import type { Clock, TimerHandle } from './clock.ts';
import type { Logger } from './log.ts';
import type { Models, ModelFailure } from './models/index.ts';
import type { Notification, ThreadActivity } from './runner.ts';
import type { LibrarianEntry, LibrarianJob, LibrarianOutcome, LibrarianReason, LibrarianStatus } from './protocol.ts';
import { ErrorCode, RpcError } from './protocol.ts';
import type { ThreadRecord } from './store.ts';
import type { ProjectRecord, Projects } from './projects.ts';
import { atomicWriteFileSync, readJsonSync } from './fsutil.ts';
import { findUp, isInside } from './patches.ts';

// What the librarian needs from the runner.
export type LibrarianHost = {
  threadRecords(): ThreadRecord[];
  threadGist(threadId: string, opts?: { recent?: number; chars?: number }): { first?: string; recent: { who: 'user' | 'assistant'; text: string }[] };
  resolveThread(idOrPrefix: string): string;
  onThreadActivity(fn: (a: ThreadActivity) => void): () => void;
  onNotification(fn: (n: Notification) => void): () => void;
  publish(n: Notification): void;
};

// How long after a turn ends before a look, so a quick follow-up turn
// doesn't mean two looks.
export const SETTLE_MS = 10_000;
// A thread with more turns is looked at again no sooner than this.
export const CATCH_UP_MS = 60 * 60_000;
// Without a key or budget, how long before trying again.
const OFF_RETRY_MS = 10 * 60_000;
const RECENT_KEPT = 50;
// A backfill looks at threads active this recently.
const BACKFILL_DAYS = 30;

// Which reason wins when a thread is queued twice.
const RANK: Record<LibrarianReason, number> = { asked: 0, moved: 1, 'new-folder': 2, 'first-turn': 3, 'catch-up': 4 };

type Look = { at: string; seq: number };
type Saved = {
  paused?: boolean;
  queue?: LibrarianJob[];
  recent?: LibrarianEntry[];
  looks?: Record<string, Look>;
  day?: { date: string; looks: number; spentUsd: number };
};

// What the model is asked to answer.
type Answer = {
  projects?: unknown;
  new?: unknown;
  state?: unknown;
  addFolders?: unknown;
  why?: unknown;
};

export class Librarian {
  private host: LibrarianHost;
  private projects: Projects;
  private models?: Pick<Models, 'generate'>;
  private clock: Clock;
  private log: Logger;
  private file: string;
  private home: string;
  private paused = false;
  private queue = new Map<string, LibrarianJob>();
  private recent: LibrarianEntry[] = [];
  private looks: Record<string, Look> = {};
  private day = { date: '', looks: 0, spentUsd: 0 };
  // Folders each thread has edited in since its last look, by repo.
  private edited = new Map<string, Set<string>>();
  private current?: LibrarianJob & { startedAt: string };
  private off?: string;
  private timer?: TimerHandle;
  private timerAt = Infinity;
  private stopped = false;
  private unsubs: (() => void)[] = [];

  constructor(deps: { host: LibrarianHost; projects: Projects; models?: Pick<Models, 'generate'>; clock: Clock; log: Logger; home: string; userHome?: string }) {
    this.host = deps.host;
    this.projects = deps.projects;
    this.models = deps.models;
    this.clock = deps.clock;
    this.log = deps.log;
    this.file = path.join(deps.home, 'librarian.json');
    this.home = deps.userHome ?? os.homedir();
  }

  start(): void {
    const saved = readJsonSync<Saved>(this.file);
    if (!saved && fs.existsSync(this.file)) this.log.error('librarian.json could not be read; starting afresh', { file: this.file });
    this.paused = Boolean(saved?.paused);
    for (const j of saved?.queue ?? []) if (j && typeof j.threadId === 'string') this.queue.set(j.threadId, j);
    this.recent = (saved?.recent ?? []).slice(0, RECENT_KEPT);
    this.looks = saved?.looks ?? {};
    if (saved?.day) this.day = saved.day;
    if (!this.models) this.off = 'Model calls are off in this runner.';
    this.unsubs.push(this.host.onThreadActivity((a) => this.onActivity(a)));
    this.unsubs.push(
      this.host.onNotification((n) => {
        if (n.method !== 'thread.deleted') return;
        const id = n.params.threadId;
        delete this.looks[id];
        this.edited.delete(id);
        if (this.queue.delete(id)) this.changed();
      }),
    );
    this.schedule();
  }

  stop(): void {
    this.stopped = true;
    this.timer?.cancel();
    for (const u of this.unsubs) u();
  }

  // ---------------------------------------------------------------- reads

  status(): LibrarianStatus {
    this.rollDay();
    const s: LibrarianStatus = {
      state: this.current ? 'working' : this.paused ? 'paused' : this.off ? 'off' : 'idle',
      paused: this.paused,
      queue: this.sortedQueue(),
      recent: this.recent,
      looksToday: this.day.looks,
      spentTodayUsd: round(this.day.spentUsd),
    };
    if (this.off && !this.current) s.reason = this.off;
    if (this.current) s.current = this.current;
    return s;
  }

  // ---------------------------------------------------------------- asks

  // Queues a look at a thread now, or with none, at every recent thread it
  // has never looked at (a backfill).
  run(threadId?: string): LibrarianStatus {
    const now = this.clock.now();
    if (threadId) {
      const id = this.host.resolveThread(threadId);
      this.enqueue(id, 'asked', 'Asked for', now);
    } else {
      const since = now - BACKFILL_DAYS * 86_400_000;
      const due = this.host
        .threadRecords()
        .filter((t) => !this.looks[t.id] && Date.parse(t.lastActivityAt) >= since && t.lastSeq > 0)
        .sort((a, b) => b.lastActivityAt.localeCompare(a.lastActivityAt));
      // Newest first, a second apart so the queue keeps that order.
      due.forEach((t, i) => this.enqueue(t.id, 'asked', 'Looking at everything', now + i * 1000));
      this.log.info('librarian backfill', { threads: due.length });
    }
    // Asking again is a good moment to try again after a missing key.
    this.off = this.models ? undefined : this.off;
    this.changed();
    return this.status();
  }

  update(params: { paused?: boolean }): LibrarianStatus {
    if (params.paused !== undefined && params.paused !== this.paused) {
      this.paused = params.paused;
      this.log.info(this.paused ? 'librarian paused' : 'librarian resumed');
      this.changed();
    }
    return this.status();
  }

  // ------------------------------------------------------------- triggers

  private onActivity(a: ThreadActivity): void {
    const now = this.clock.now();
    const rec = this.host.threadRecords().find((t) => t.id === a.threadId);
    if (!rec) return;
    if (a.kind === 'moved') {
      this.enqueue(rec.id, 'moved', `Moved to ${this.tilde(a.to)}`, now + SETTLE_MS);
      this.changed();
      return;
    }
    if (a.outcome !== 'completed') return;
    const repos = this.edited.get(rec.id) ?? new Set<string>();
    for (const file of a.edited) repos.add(this.repoOf(file));
    if (repos.size) this.edited.set(rec.id, repos);
    const look = this.looks[rec.id];
    if (!look) {
      this.enqueue(rec.id, 'first-turn', 'Its first turn ended', now + SETTLE_MS);
    } else {
      const known = [rec.cwd, ...this.projects.foldersFor(rec).map((f) => f.folder)];
      const outside = [...repos].find((r) => !known.some((k) => isInside(r, k) || isInside(k, r)));
      if (outside) this.enqueue(rec.id, 'new-folder', `Edited files in ${this.tilde(outside)}`, now + SETTLE_MS);
      else this.enqueue(rec.id, 'catch-up', 'More turns since its last look', Math.max(now + SETTLE_MS, Date.parse(look.at) + CATCH_UP_MS));
    }
    this.changed();
  }

  // One job per thread: the more pressing reason and the sooner time win.
  private enqueue(threadId: string, reason: LibrarianReason, why: string, dueAtMs: number): void {
    const rec = this.host.threadRecords().find((t) => t.id === threadId);
    if (!rec) return;
    const job: LibrarianJob = { threadId, threadTitle: rec.title, reason, why, dueAt: new Date(dueAtMs).toISOString() };
    const had = this.queue.get(threadId);
    if (had) {
      const better = RANK[reason] < RANK[had.reason] ? job : had;
      const sooner = Math.min(dueAtMs, Date.parse(had.dueAt));
      this.queue.set(threadId, { ...better, threadTitle: rec.title, dueAt: new Date(sooner).toISOString() });
    } else {
      this.queue.set(threadId, job);
    }
  }

  // ------------------------------------------------------------- the pump

  private schedule(): void {
    if (this.stopped || this.current || this.paused) return;
    const next = this.sortedQueue()[0];
    if (!next) {
      this.timer?.cancel();
      this.timer = undefined;
      this.timerAt = Infinity;
      return;
    }
    const at = Date.parse(next.dueAt);
    if (at <= this.clock.now()) {
      // Already due (after a pause, or a restart): now, not on a timer.
      this.timer?.cancel();
      this.timer = undefined;
      this.timerAt = Infinity;
      void Promise.resolve().then(() => this.pump());
      return;
    }
    if (this.timer && this.timerAt <= at) return;
    this.timer?.cancel();
    this.timerAt = at;
    this.timer = this.clock.setTimeout(() => {
      this.timer = undefined;
      this.timerAt = Infinity;
      void this.pump();
    }, at - this.clock.now());
  }

  // Runs the jobs that are due, one at a time.
  async pump(): Promise<void> {
    while (!this.stopped && !this.current && !this.paused) {
      const job = this.sortedQueue()[0];
      if (!job || Date.parse(job.dueAt) > this.clock.now()) break;
      this.queue.delete(job.threadId);
      this.current = { ...job, startedAt: new Date(this.clock.now()).toISOString() };
      this.changed(false);
      try {
        await this.look(job);
      } catch (e) {
        this.log.error('librarian look failed', { threadId: job.threadId, error: String(e) });
        this.note(job, 'failed', (e as Error).message ?? String(e));
      } finally {
        this.current = undefined;
      }
      this.changed(false);
    }
    this.schedule();
  }

  // ----------------------------------------------------------- one look

  private async look(job: LibrarianJob): Promise<void> {
    const rec = this.host.threadRecords().find((t) => t.id === job.threadId);
    if (!rec) return;
    if (!this.models) {
      this.off = 'Model calls are off in this runner.';
      return;
    }
    const prompt = this.prompt(rec);
    const res = await this.models.generate({ feature: 'projects', cwd: rec.cwd, system: SYSTEM, prompt, maxTokens: 700 });
    if (!res.ok) {
      if (WAIT_FOR.includes(res.reason)) {
        // Nothing wrong with the job: try again once there's a key or budget.
        this.off = offReason(res.reason, res.message);
        this.enqueue(job.threadId, job.reason, job.why, this.clock.now() + OFF_RETRY_MS);
        return;
      }
      this.markLooked(rec);
      this.note(job, res.reason === 'private' ? 'skipped' : 'failed', res.reason === 'private' ? 'Private folder, not sent' : res.message);
      return;
    }
    this.off = undefined;
    this.rollDay();
    this.day.looks++;
    this.day.spentUsd += res.costUsd ?? 0;
    const answer = parseAnswer(res.value);
    if (!answer) {
      this.markLooked(rec);
      this.note(job, 'failed', "The model's answer wasn't JSON", undefined, res.costUsd);
      return;
    }
    this.apply(job, rec, answer, res.costUsd);
    this.markLooked(rec);
  }

  private prompt(rec: ThreadRecord): string {
    const list = this.projects.list();
    const lines: string[] = [];
    lines.push('Projects:');
    if (!list.length) lines.push('(none yet)');
    for (const p of list) {
      const state = p.state.split('\n')[0]?.slice(0, 160);
      lines.push(`- ${p.id} "${p.title}"; folders: ${p.folders.map((f) => this.tilde(f)).join(', ') || 'none'}` + (p.goals ? `; goals: ${p.goals.slice(0, 200).replace(/\s+/g, ' ')}` : '') + (state ? `; state: ${state}` : ''));
    }
    lines.push('');
    lines.push(`Thread "${rec.title}", in ${this.tilde(rec.cwd)}${this.isRepo(rec.cwd) ? '' : ' (not a repo: a catch-all folder)'}`);
    const inNow = (rec.projects ?? []).map((m) => `${m.id}${m.pinned ? ' (pinned)' : ''}`);
    lines.push(`Currently in: ${inNow.join(', ') || 'none'}`);
    if (rec.projectsLeft?.length) lines.push(`Never put it in: ${rec.projectsLeft.join(', ')}`);
    const repos = [...(this.edited.get(rec.id) ?? [])].map((r) => this.tilde(r));
    if (repos.length) lines.push(`Edited files in: ${repos.join(', ')}`);
    const gist = this.host.threadGist(rec.id);
    if (gist.first) lines.push('', `First message: ${gist.first}`);
    if (gist.recent.length) {
      lines.push('', 'Latest messages:');
      for (const m of gist.recent) lines.push(`${m.who === 'user' ? 'Mike' : 'Agent'}: ${m.text}`);
    }
    return lines.join('\n');
  }

  private apply(job: LibrarianJob, rec: ThreadRecord, a: Answer, costUsd?: number): void {
    const live = new Map(this.projects.list().map((p) => [p.id, p]));
    const wanted = Array.isArray(a.projects) ? a.projects.filter((x): x is string => typeof x === 'string' && live.has(x)) : [];
    const said: string[] = [];
    const ids = new Set<string>();
    let outcome: LibrarianOutcome = 'nothing';
    const bump = (o: LibrarianOutcome) => {
      const order: LibrarianOutcome[] = ['nothing', 'updated', 'left', 'joined', 'created'];
      if (order.indexOf(o) > order.indexOf(outcome)) outcome = o;
    };
    // A new project, when nothing fits.
    const fresh = readNew(a.new);
    if (fresh && !wanted.length) {
      const folders = fresh.folders.map((f) => this.expand(f)).filter((f) => this.isProjectFolder(f));
      try {
        const p = this.projects.create({ title: fresh.title, folders, goals: fresh.goals, state: fresh.state, by: 'librarian', byThread: rec.id });
        this.projects.changeMembership(rec.id, { add: [p.id], by: 'librarian' });
        said.push(`Made ${p.title} and put it there`);
        ids.add(p.id);
        bump('created');
      } catch (e) {
        this.log.warn('librarian could not make a project', { title: fresh.title, error: String(e) });
      }
    }
    if (wanted.length) {
      const r = this.projects.changeMembership(rec.id, { add: wanted, by: 'librarian' });
      if (r.joined.length) {
        said.push(`Put it in ${r.joined.map((p) => live.get(p)!.title).join(' and ')}`);
        r.joined.forEach((p) => ids.add(p));
        bump('joined');
      }
    }
    // Only a move or a direct ask takes the thread out of one of the
    // librarian's own guesses; turns alone shouldn't make it flap.
    if (job.reason === 'moved' || job.reason === 'asked') {
      const stale = (rec.projects ?? []).filter((m) => m.by === 'librarian' && !m.pinned && !wanted.includes(m.id)).map((m) => m.id);
      if (stale.length && Array.isArray(a.projects)) {
        const r = this.projects.changeMembership(rec.id, { remove: stale, by: 'librarian' });
        if (r.left.length) {
          said.push(`Took it out of ${r.left.map((p) => live.get(p)?.title ?? p).join(' and ')}`);
          r.left.forEach((p) => ids.add(p));
          bump('left');
        }
      }
    }
    // Where the thread got its projects to, and folders they've grown.
    const member = new Set((this.host.threadRecords().find((t) => t.id === rec.id)?.projects ?? []).map((m) => m.id));
    if (a.addFolders && typeof a.addFolders === 'object') {
      for (const [pid, folders] of Object.entries(a.addFolders as Record<string, unknown>)) {
        const p = live.get(pid);
        if (!p || !member.has(pid) || !Array.isArray(folders)) continue;
        const add = folders
          .filter((f): f is string => typeof f === 'string')
          .map((f) => this.expand(f))
          .filter((f) => this.isProjectFolder(f) && !p.folders.includes(f));
        if (!add.length) continue;
        this.projects.update(pid, { folders: [...p.folders, ...add] });
        said.push(`Added ${add.map((f) => this.tilde(f)).join(', ')} to ${p.title}`);
        ids.add(pid);
        bump('updated');
      }
    }
    if (a.state && typeof a.state === 'object') {
      const updated: string[] = [];
      for (const [pid, text] of Object.entries(a.state as Record<string, unknown>)) {
        const p = this.projects.record(pid);
        if (!p || !member.has(pid) || typeof text !== 'string' || !text.trim() || text.trim() === p.state) continue;
        this.projects.update(pid, { state: text.trim().slice(0, 2000) });
        updated.push(p.title);
        ids.add(pid);
      }
      if (updated.length) {
        said.push(`Updated ${updated.join(' and ')}'s state`);
        bump('updated');
      }
    }
    const why = typeof a.why === 'string' ? a.why.trim().slice(0, 200) : '';
    const text = said.length ? said.join('. ') : why ? `Nothing to change: ${lowerFirst(why)}` : 'Nothing to change';
    this.note(job, outcome, text, [...ids], costUsd);
  }

  private markLooked(rec: ThreadRecord): void {
    this.looks[rec.id] = { at: new Date(this.clock.now()).toISOString(), seq: rec.lastSeq };
    this.edited.delete(rec.id);
  }

  private note(job: LibrarianJob, outcome: LibrarianOutcome, text: string, projectIds?: string[], costUsd?: number): void {
    const e: LibrarianEntry = {
      id: crypto.randomBytes(6).toString('hex'),
      at: new Date(this.clock.now()).toISOString(),
      threadId: job.threadId,
      threadTitle: this.host.threadRecords().find((t) => t.id === job.threadId)?.title ?? job.threadTitle,
      reason: job.reason,
      outcome,
      text,
    };
    if (projectIds?.length) e.projectIds = projectIds;
    if (costUsd !== undefined) e.costUsd = round(costUsd);
    this.recent.unshift(e);
    if (this.recent.length > RECENT_KEPT) this.recent.length = RECENT_KEPT;
    this.log.info('librarian looked', { threadId: job.threadId, reason: job.reason, outcome, text });
  }

  // ------------------------------------------------------------- helpers

  private sortedQueue(): LibrarianJob[] {
    return [...this.queue.values()].sort((a, b) => a.dueAt.localeCompare(b.dueAt) || RANK[a.reason] - RANK[b.reason]);
  }

  // Saves and tells every client. `reschedule` false while a look runs.
  private changed(reschedule = true): void {
    try {
      atomicWriteFileSync(
        this.file,
        JSON.stringify({ paused: this.paused, queue: [...this.queue.values()], recent: this.recent, looks: this.looks, day: this.day } satisfies Saved),
      );
    } catch (e) {
      this.log.warn('could not save librarian.json', { error: String(e) });
    }
    this.host.publish({ method: 'librarian.updated', params: { librarian: this.status() } });
    if (reschedule) {
      // A pause or resume, or a new job sooner than the timer.
      if (this.paused) {
        this.timer?.cancel();
        this.timer = undefined;
        this.timerAt = Infinity;
      } else this.schedule();
    }
  }

  private rollDay(): void {
    const d = new Date(this.clock.now());
    const date = `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}`;
    if (this.day.date !== date) this.day = { date, looks: 0, spentUsd: 0 };
  }

  // The repo a file belongs to (the nearest folder with .git), else its folder.
  private repoOf(file: string): string {
    const dir = path.dirname(file);
    return findUp(dir, this.home, (d) => fs.existsSync(path.join(d, '.git'))) ?? dir;
  }

  private isRepo(dir: string): boolean {
    return fs.existsSync(path.join(dir, '.git'));
  }

  // A folder a project may have: one that exists and looks like a project
  // of its own, never home or a catch-all folder of repos.
  private isProjectFolder(dir: string): boolean {
    if (dir === this.home || !isInside(dir, this.home)) return false;
    try {
      if (!fs.statSync(dir).isDirectory()) return false;
    } catch {
      return false;
    }
    return PROJECT_MARKERS.some((m) => fs.existsSync(path.join(dir, m))) || fs.readdirSync(dir).some((n) => n.endsWith('.xcodeproj') || n.endsWith('.tandem'));
  }

  // "~/x" against the home the librarian was given (a test's fake one).
  private expand(p: string): string {
    const t = p.trim();
    return path.resolve(t === '~' ? this.home : t.startsWith('~/') ? path.join(this.home, t.slice(2)) : t);
  }

  private tilde(p: string): string {
    return p === this.home || p.startsWith(this.home + path.sep) ? '~' + p.slice(this.home.length) : p;
  }
}

const PROJECT_MARKERS = ['.git', 'package.json', 'Package.swift', 'pyproject.toml', 'Cargo.toml', 'go.mod', 'AGENTS.md', 'CLAUDE.md'];

const WAIT_FOR: ModelFailure[] = ['no-key', 'off', 'over-budget'];

function offReason(reason: ModelFailure, message: string): string {
  if (reason === 'no-key') return 'No OpenRouter key';
  if (reason === 'over-budget') return "Today's model budget is spent";
  if (reason === 'off') return 'Model calls are off';
  return message;
}

export const SYSTEM = `You are the librarian in Threadbear, an app where Mike runs AI coding agents in threads. You keep his projects: groupings above folders that carry goals, state and notes from thread to thread. A project is a body of work he'll come back to (an app, a library, a video, a house job, an ongoing chore), never a single task. One project can span several repos, and a thread can be in several projects.

Given the project list and one thread, decide which projects the thread belongs in. Prefer existing projects. Make a new one only when the thread is clearly real work on something that fits none of them; a one-off question, a quick chore or a test belongs in none. Never put a thread back in one it says never to.

Reply with JSON only, no prose and no code fence:
{"projects": ["<ids of existing projects the thread belongs in, or []>"],
 "new": null or {"title": "short name, as Mike would say it", "folders": ["~/path of its repo(s)"], "goals": "one or two sentences: what it's for", "state": "one or two sentences: where it's up to"},
 "state": {"<project id>": "where that project is up to now, one to three sentences"} for projects this thread clearly moved on, else {},
 "addFolders": {"<project id>": ["~/path"]} for repos this thread shows belong to a project it's in, else {},
 "why": "one short line"}

Folders are repos the work lives in (the thread's folder when it's a repo, and the repos it edited), never a catch-all folder. State is plain words about the project, not the thread: what's done, what's next, what's blocked.`;

function parseAnswer(text: string): Answer | undefined {
  const t = text.trim().replace(/^```(?:json)?\s*/i, '').replace(/```\s*$/, '');
  const start = t.indexOf('{');
  const end = t.lastIndexOf('}');
  if (start < 0 || end <= start) return undefined;
  try {
    const v = JSON.parse(t.slice(start, end + 1)) as unknown;
    return v && typeof v === 'object' && !Array.isArray(v) ? (v as Answer) : undefined;
  } catch {
    return undefined;
  }
}

function readNew(v: unknown): { title: string; folders: string[]; goals: string; state: string } | undefined {
  if (!v || typeof v !== 'object') return undefined;
  const n = v as Record<string, unknown>;
  if (typeof n.title !== 'string' || !n.title.trim()) return undefined;
  return {
    title: n.title.trim().slice(0, 80),
    folders: Array.isArray(n.folders) ? n.folders.filter((f): f is string => typeof f === 'string') : [],
    goals: typeof n.goals === 'string' ? n.goals.trim().slice(0, 2000) : '',
    state: typeof n.state === 'string' ? n.state.trim().slice(0, 2000) : '',
  };
}

function lowerFirst(s: string): string {
  return s ? s[0].toLowerCase() + s.slice(1) : s;
}

function round(n: number): number {
  return Math.round(n * 10000) / 10000;
}

// ------------------------------------------------------------- the methods

export function librarianMethods(l: Librarian): Record<string, (p: Record<string, unknown>) => unknown> {
  return {
    'librarian.status': () => ({ librarian: l.status() }),
    'librarian.run': (p) => {
      if (p.threadId !== undefined && p.threadId !== null && typeof p.threadId !== 'string') throw new RpcError(ErrorCode.badParams, 'threadId must be a string');
      return { librarian: l.run((p.threadId as string | undefined) ?? undefined) };
    },
    'librarian.update': (p) => {
      if (p.paused !== undefined && typeof p.paused !== 'boolean') throw new RpcError(ErrorCode.badParams, 'paused must be a boolean');
      return { librarian: l.update({ paused: p.paused as boolean | undefined }) };
    },
  };
}

export type { ProjectRecord };
