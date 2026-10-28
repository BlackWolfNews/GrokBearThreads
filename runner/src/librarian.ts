// The librarian: the runner's own background job that keeps projects up
// to date (docs/protocol.md, "Projects"). It watches threads' turns and
// moves, and now and then asks the small model (models/index.ts, feature
// "projects") which projects a thread belongs in, whether it needs a new
// one, where the thread has got a project to, and whether the thread's
// title still fits. What it decides takes effect straight away; Mike can
// take a thread out, and then it's never put back (projects.ts).
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
import { LINKS_MAX } from './projects.ts';
import { atomicWriteFileSync, readJsonSync } from './fsutil.ts';
import { findUp, isInside } from './patches.ts';
import { SYMBOLS, fileHash, findIcon, storeIcon } from './project-icons.ts';

// What the librarian needs from the runner.
export type LibrarianHost = {
  threadRecords(): ThreadRecord[];
  threadGist(threadId: string, opts?: { recent?: number; chars?: number }): { first?: string; recent: { who: 'user' | 'assistant'; text: string }[] };
  threadSince?(threadId: string, seq: number): { chars: number; links: boolean };
  resolveThread(idOrPrefix: string): string;
  onThreadActivity(fn: (a: ThreadActivity) => void): () => void;
  onNotification(fn: (n: Notification) => void): () => void;
  publish(n: Notification): void;
  // Keeps the look's line on where the thread is up to, shown at the top
  // of its Highlights (docs/protocol.md).
  setBrief?(threadId: string, text: string): void;
  // Renames a thread whose title no longer says what it's about; returns
  // the title it took, or nothing when it kept the old one.
  retitleFromLibrarian?(threadId: string, title: string, from: string): string | undefined;
};

// How long after a turn ends before a look, so a quick follow-up turn
// doesn't mean two looks.
export const SETTLE_MS = 10_000;
// How long after a new thread's first message before a look from that
// alone, so it's filed while its first turn is still going (a long one
// used to leave it unfiled for as long as it ran).
export const FIRST_MESSAGE_MS = 5_000;
// A thread with more turns is looked at again no sooner than this.
export const CATCH_UP_MS = 20 * 60_000;
// A catch-up look is skipped, with no model call, when the turns since the
// last look edited nothing, gave no link and said less than this much: a
// quick "thanks" or "go" rarely changes a project, its state or a title.
// What they said still counts towards the next one.
export const CATCH_UP_MIN_CHARS = 400;
// How often to look for turns the librarian never heard end. A turn that
// ends in an older runner while it drains after a handover is only heard
// by that runner, whose librarian has stopped; main moving every few
// minutes made that common. Threads active within SWEEP_DAYS.
export const SWEEP_MS = 5 * 60_000;
const SWEEP_DAYS = 2;
// Without a key or budget, how long before trying again.
const OFF_RETRY_MS = 10 * 60_000;
const RECENT_KEPT = 50;
// A backfill looks at threads active this recently.
const BACKFILL_DAYS = 30;
// Icons: every project's folders are looked through again this often, so
// a repo that gets a new app icon shows it; a new project or one whose
// folders changed is looked at after ICON_SOON_MS.
export const ICON_SWEEP_MS = 60 * 60_000;
export const ICON_SOON_MS = 3_000;

// Which reason wins when a thread is queued twice.
const RANK: Record<LibrarianReason, number> = { asked: 0, moved: 1, 'new-folder': 2, 'first-turn': 3, 'first-message': 4, 'catch-up': 5 };

// `early`: the look was from the first message alone, so the first turn's
// end still gets a look of its own.
type Look = { at: string; seq: number; early?: boolean };
type Saved = {
  paused?: boolean;
  queue?: LibrarianJob[];
  recent?: LibrarianEntry[];
  looks?: Record<string, Look>;
  day?: Day;
};

// The day's looks, skips and what they used. spentUsd is OpenRouter's,
// notionalUsd what the pool's would have cost on the API (not spent).
type Day = { date: string; looks: number; spentUsd: number; skipped?: number; tokens?: number; notionalUsd?: number };

// What the model is asked to answer.
type Answer = {
  projects?: unknown;
  new?: unknown;
  state?: unknown;
  addFolders?: unknown;
  links?: unknown;
  thread?: unknown;
  title?: unknown;
  why?: unknown;
};

export class Librarian {
  private host: LibrarianHost;
  private projects: Projects;
  private models?: Pick<Models, 'generate'> & Partial<Pick<Models, 'unavailable'>>;
  private clock: Clock;
  private log: Logger;
  private file: string;
  private home: string;
  private paused = false;
  private queue = new Map<string, LibrarianJob>();
  private recent: LibrarianEntry[] = [];
  private looks: Record<string, Look> = {};
  private day: Day = { date: '', looks: 0, spentUsd: 0 };
  // Folders each thread has edited in since its last look, by repo.
  private edited = new Map<string, Set<string>>();
  // Repos its shell commands ran in since its last look (`cd ~/dev/me/app`),
  // for a thread in a catch-all folder that never uses Edit or Write.
  private workedIn = new Map<string, Set<string>>();
  private current?: LibrarianJob & { startedAt: string };
  private off?: string;
  // `off` is there because no model could be reached at all (no pool, no
  // key), so it clears by itself once one can.
  private offForSetup = false;
  private timer?: TimerHandle;
  private timerAt = Infinity;
  private sweepTimer?: TimerHandle;
  private stopped = false;
  private unsubs: (() => void)[] = [];
  // What each project's icon was last worked out from (folders, title, who
  // set it), so only a changed one is looked at between sweeps.
  private iconSeen = new Map<string, string>();
  private iconTimer?: TimerHandle;
  private iconTimerAt = Infinity;
  private iconRun?: Promise<void>;
  private iconAgain = false;
  private iconFullDue = 0;

  constructor(deps: { host: LibrarianHost; projects: Projects; models?: Pick<Models, 'generate'> & Partial<Pick<Models, 'unavailable'>>; clock: Clock; log: Logger; home: string; userHome?: string }) {
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
        if (n.method === 'projects.updated') this.iconsSoon();
        if (n.method !== 'thread.deleted') return;
        const id = n.params.threadId;
        delete this.looks[id];
        this.edited.delete(id);
        this.workedIn.delete(id);
        if (this.queue.delete(id)) this.changed();
      }),
    );
    this.sweep();
    this.schedule();
    this.iconsSoon();
  }

  stop(): void {
    this.stopped = true;
    this.timer?.cancel();
    this.sweepTimer?.cancel();
    this.iconTimer?.cancel();
    for (const u of this.unsubs) u();
  }

  // ---------------------------------------------------------------- reads

  status(): LibrarianStatus {
    this.rollDay();
    // Whether there's a pool or a key is known without asking the model;
    // room and budget aren't.
    const why = this.models?.unavailable?.();
    if (!this.current && !this.off && why) {
      this.off = why;
      this.offForSetup = true;
    } else if (this.offForSetup && this.models?.unavailable && !why) {
      this.off = undefined;
      this.offForSetup = false;
    }
    const s: LibrarianStatus = {
      state: this.current ? 'working' : this.paused ? 'paused' : this.off ? 'off' : 'idle',
      paused: this.paused,
      queue: this.sortedQueue(),
      recent: this.recent,
      looksToday: this.day.looks,
      spentTodayUsd: round(this.day.spentUsd),
      skippedToday: this.day.skipped ?? 0,
      tokensToday: this.day.tokens ?? 0,
      notionalTodayUsd: round(this.day.notionalUsd ?? 0),
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
    if (this.models) this.offForSetup = false;
    this.changed();
    return this.status();
  }

  update(params: { paused?: boolean }): LibrarianStatus {
    if (params.paused !== undefined && params.paused !== this.paused) {
      this.paused = params.paused;
      this.log.info(this.paused ? 'librarian paused' : 'librarian resumed');
      // Symbols wait while paused: look at every project again now.
      if (!this.paused) {
        this.iconFullDue = 0;
        this.iconsSoon();
      }
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
    if (a.kind === 'turn.start') {
      if (this.looks[rec.id] || this.queue.has(rec.id) || this.current?.threadId === rec.id) return;
      this.enqueue(rec.id, 'first-message', 'Its first message came in', now + FIRST_MESSAGE_MS);
      this.changed();
      return;
    }
    if (a.outcome !== 'completed') return;
    const repos = this.edited.get(rec.id) ?? new Set<string>();
    for (const file of a.edited) repos.add(this.repoOf(file));
    if (repos.size) this.edited.set(rec.id, repos);
    const worked = this.workedIn.get(rec.id) ?? new Set<string>();
    for (const dir of a.workedIn ?? []) {
      const repo = this.repoOfDir(dir);
      if (repo !== this.repoOfDir(rec.cwd) && this.isProjectFolder(repo)) worked.add(repo);
    }
    if (worked.size) this.workedIn.set(rec.id, worked);
    const look = this.looks[rec.id];
    if (!look || look.early) {
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

  // Queues every recent thread with a finished turn the librarian hasn't
  // looked at since, then checks again in SWEEP_MS. Events are the quick
  // path; this is what makes a missed one not matter.
  private sweep(): void {
    if (this.stopped) return;
    this.sweepTimer = this.clock.setTimeout(() => this.sweep(), SWEEP_MS);
    // With no models, a look does nothing and leaves no mark.
    if (!this.models) return;
    const now = this.clock.now();
    const since = now - SWEEP_DAYS * 86_400_000;
    let found = 0;
    for (const t of this.host.threadRecords()) {
      if (!t.lastTurnCompletedSeq || Date.parse(t.lastActivityAt) < since) continue;
      if (this.queue.has(t.id) || this.current?.threadId === t.id) continue;
      const look = this.looks[t.id];
      if (look && look.seq >= t.lastTurnCompletedSeq) continue;
      if (!look || look.early) this.enqueue(t.id, 'first-turn', 'Its first turn ended while the runner was restarting', now);
      else this.enqueue(t.id, 'catch-up', 'More turns since its last look', Math.max(now, Date.parse(look.at) + CATCH_UP_MS));
      found++;
    }
    if (!found) return;
    this.log.info('librarian sweep', { threads: found });
    this.changed();
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
    if (this.quiet(rec, job)) {
      // Its seq stays, so what these turns said counts towards the next.
      this.looks[rec.id] = { ...this.looks[rec.id], at: new Date(this.clock.now()).toISOString() };
      this.rollDay();
      this.day.skipped = (this.day.skipped ?? 0) + 1;
      this.log.info('librarian skipped a quiet catch-up', { threadId: rec.id });
      return;
    }
    const prompt = this.prompt(rec, job);
    // rec is the live record: the title as the model saw it, so a rename
    // during the call isn't undone.
    const title = rec.title;
    const res = await this.models.generate({ feature: 'projects', cwd: rec.cwd, system: SYSTEM, prompt, maxTokens: 2000 });
    if (!res.ok) {
      if (WAIT_FOR.includes(res.reason)) {
        // Nothing wrong with the job: try again once there's a model, room
        // or budget.
        this.off = res.reason === 'no-key' ? (this.models.unavailable?.() ?? offReason(res.reason, res.message)) : offReason(res.reason, res.message);
        this.offForSetup = res.reason === 'no-key';
        this.enqueue(job.threadId, job.reason, job.why, this.clock.now() + OFF_RETRY_MS);
        return;
      }
      this.markLooked(rec, job);
      this.note(job, res.reason === 'private' ? 'skipped' : 'failed', res.reason === 'private' ? 'Private folder, not sent' : res.message);
      return;
    }
    this.off = undefined;
    this.offForSetup = false;
    this.rollDay();
    this.day.looks++;
    this.used(res);
    const answer = parseAnswer(res.value);
    if (!answer) {
      this.markLooked(rec, job);
      this.note(job, 'failed', "The model's answer wasn't JSON", undefined, res.costUsd);
      return;
    }
    this.apply(job, rec, answer, res.costUsd, prompt, title);
    this.markLooked(rec, job);
  }

  // A catch-up whose turns edited nothing, gave no link and said little
  // since the last look: not worth a model call (CATCH_UP_MIN_CHARS).
  private quiet(rec: ThreadRecord, job: LibrarianJob): boolean {
    const look = this.looks[rec.id];
    if (job.reason !== 'catch-up' || !look || look.early || !this.host.threadSince) return false;
    if (this.edited.get(rec.id)?.size) return false;
    if (this.newWorkedIn(rec).length) return false;
    const since = this.host.threadSince(rec.id, look.seq);
    return !since.links && since.chars < CATCH_UP_MIN_CHARS;
  }

  private prompt(rec: ThreadRecord, job: LibrarianJob): string {
    const list = this.projects.list();
    const lines: string[] = [];
    lines.push('Projects:');
    if (!list.length) lines.push('(none yet)');
    for (const p of list) {
      const state = p.state.split('\n')[0]?.slice(0, 160);
      lines.push(`- ${p.id} "${p.title}"; folders: ${p.folders.map((f) => this.tilde(f)).join(', ') || 'none'}` + (p.goals ? `; goals: ${p.goals.slice(0, 200).replace(/\s+/g, ' ')}` : '') + (state ? `; state: ${state}` : '') + (p.links.length ? `; links: ${p.links.map((l) => l.url).join(' ')}` : ''));
    }
    lines.push('');
    lines.push(`Thread "${rec.title}", in ${this.tilde(rec.cwd)}${this.isRepo(rec.cwd) ? '' : ' (not a repo: a catch-all folder)'}`);
    const inNow = (rec.projects ?? []).map((m) => `${m.id}${m.pinned ? ' (pinned)' : ''}`);
    lines.push(`Currently in: ${inNow.join(', ') || 'none'}`);
    if (rec.projectsLeft?.length) lines.push(`Never put it in: ${rec.projectsLeft.join(', ')}`);
    if (selfFiled(rec)) lines.push('Filed by its own agent or Mike: leave its projects as they are (projects [], new null).');
    if (rec.titleSet) lines.push('Its title was set by Mike or an agent: keep it (title null).');
    const repos = [...(this.edited.get(rec.id) ?? [])].map((r) => this.tilde(r));
    if (repos.length) lines.push(`Edited files in: ${repos.join(', ')}`);
    const worked = [...(this.workedIn.get(rec.id) ?? [])].filter((r) => !this.edited.get(rec.id)?.has(r)).map((r) => this.tilde(r));
    if (worked.length) lines.push(`Ran commands in: ${worked.join(', ')}`);
    const gist = this.host.threadGist(rec.id);
    if (job.reason === 'first-message') lines.push("It has only just started: file it from what it's about, and don't change any project's state yet.");
    if (gist.first) lines.push('', `First message: ${gist.first}`);
    if (gist.recent.length) {
      lines.push('', 'Latest messages:');
      for (const m of gist.recent) lines.push(`${m.who === 'user' ? 'Mike' : 'Agent'}: ${m.text}`);
    }
    return lines.join('\n');
  }

  // `seen` is the prompt the look was given: a link must be in it, so the
  // model can't make one up. `title` is the thread's title it was given.
  private apply(job: LibrarianJob, rec: ThreadRecord, a: Answer, costUsd?: number, seen = '', title = rec.title): void {
    const live = new Map(this.projects.list().map((p) => [p.id, p]));
    // A thread its agent or Mike filed is theirs to file: the look only
    // keeps its line and the state of the projects it's in.
    const self = selfFiled(rec);
    if (self) {
      a = { ...a, projects: [], new: null };
    }
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
    if (!self && (job.reason === 'moved' || job.reason === 'asked')) {
      // Not one it has just made (ids) for this very thread.
      const stale = (rec.projects ?? []).filter((m) => m.by === 'librarian' && !m.pinned && !wanted.includes(m.id) && !ids.has(m.id)).map((m) => m.id);
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
    // Places Mike will keep going back to (a live site, an admin page),
    // added and never taken away: links are Mike's and agents' to prune.
    if (a.links && typeof a.links === 'object') {
      for (const [pid, list] of Object.entries(a.links as Record<string, unknown>)) {
        const p = this.projects.record(pid);
        if (!p || !member.has(pid) || !Array.isArray(list)) continue;
        const add = list.filter(
          (l): l is { title?: string; url: string } =>
            !!l && typeof l === 'object' && typeof (l as { url?: unknown }).url === 'string' && seen.includes((l as { url: string }).url) && !p.links.some((h) => h.url.replace(/\/+$/, '') === (l as { url: string }).url.replace(/\/+$/, '')),
        );
        if (!add.length || p.links.length + add.length > LINKS_MAX) continue;
        try {
          this.projects.addLinks(pid, add.map((l) => ({ title: typeof l.title === 'string' ? l.title : undefined, url: l.url })));
        } catch (e) {
          this.log.warn('librarian could not add links', { projectId: pid, error: String(e) });
          continue;
        }
        said.push(`Added ${add.length === 1 ? 'a link' : `${add.length} links`} to ${p.title}`);
        ids.add(pid);
        bump('updated');
      }
    }
    if (a.state && typeof a.state === 'object' && job.reason !== 'first-message') {
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
    // Not a change to any project, so not in what the look says it did.
    if (typeof a.thread === 'string' && a.thread.trim()) this.host.setBrief?.(rec.id, a.thread);
    // A thread that has moved on from its title gets a new one. Not from
    // the first message alone: the title model has only just named it.
    if (typeof a.title === 'string' && a.title.trim() && job.reason !== 'first-message') {
      const renamed = this.host.retitleFromLibrarian?.(rec.id, a.title, title);
      if (renamed) {
        said.push(`Renamed it ${renamed}`);
        bump('updated');
      }
    }
    const why = typeof a.why === 'string' ? a.why.trim().slice(0, 200) : '';
    const text = said.length ? said.join('. ') : why ? `Nothing to change: ${lowerFirst(why)}` : 'Nothing to change';
    this.note(job, outcome, text, [...ids], costUsd);
  }

  private markLooked(rec: ThreadRecord, job: LibrarianJob): void {
    // Its seq as it is now, after any notes the look added.
    const seq = this.host.threadRecords().find((t) => t.id === rec.id)?.lastSeq ?? rec.lastSeq;
    this.looks[rec.id] = { at: new Date(this.clock.now()).toISOString(), seq, ...(job.reason === 'first-message' ? { early: true } : {}) };
    // An early look hasn't seen the turn's edits yet; the first-turn look will.
    if (job.reason !== 'first-message') {
      this.edited.delete(rec.id);
      this.workedIn.delete(rec.id);
    }
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

  // ------------------------------------------------------------- icons

  // A look at icons shortly, for new or changed projects (or all of them
  // when the hourly sweep is due).
  private iconsSoon(): void {
    this.iconTimerSet(this.clock.now() + ICON_SOON_MS);
  }

  private iconTimerSet(at: number): void {
    if (this.stopped) return;
    if (this.iconTimer && this.iconTimerAt <= at) return;
    this.iconTimer?.cancel();
    this.iconTimerAt = at;
    this.iconTimer = this.clock.setTimeout(() => {
      this.iconTimer = undefined;
      this.iconTimerAt = Infinity;
      void this.keepIcons();
    }, Math.max(0, at - this.clock.now()));
  }

  // Finds, refreshes or picks every project's icon that needs it. One run
  // at a time; a change during a run means another straight after.
  keepIcons(): Promise<void> {
    if (this.iconRun) {
      this.iconAgain = true;
      return this.iconRun;
    }
    this.iconRun = (async () => {
      do {
        this.iconAgain = false;
        const now = this.clock.now();
        const full = now >= this.iconFullDue;
        if (full) this.iconFullDue = now + ICON_SWEEP_MS;
        for (const p of this.projects.list()) {
          if (this.stopped) return;
          const rec = this.projects.record(p.id);
          if (!rec) continue;
          const sig = JSON.stringify([rec.folders, rec.title, rec.icon?.by ?? '', rec.icon?.image?.path ?? rec.icon?.symbol ?? '']);
          if (!full && this.iconSeen.get(rec.id) === sig) continue;
          try {
            await this.keepIcon(rec.id);
          } catch (e) {
            this.log.warn('librarian could not keep an icon', { projectId: rec.id, error: String(e) });
          }
          // As it is now, after any change this made, so that isn't
          // looked at again.
          const after = this.projects.record(rec.id);
          if (after) this.iconSeen.set(rec.id, JSON.stringify([after.folders, after.title, after.icon?.by ?? '', after.icon?.image?.path ?? after.icon?.symbol ?? '']));
        }
      } while (this.iconAgain && !this.stopped);
    })().finally(() => {
      this.iconRun = undefined;
      if (!this.stopped) this.iconTimerSet(this.iconFullDue);
    });
    return this.iconRun;
  }

  // One project: the best picture in its folders, copied again when it's
  // a different file or the file has changed; with none, a symbol from the
  // small model. Never one Mike or an agent chose.
  private async keepIcon(projectId: string): Promise<void> {
    const rec = this.projects.record(projectId);
    if (!rec || (rec.icon && rec.icon.by !== 'librarian')) return;
    const found = rec.folders.length ? await findIcon(rec.folders, [rec.title]) : undefined;
    if (found) {
      const hash = await fileHash(found.path);
      if (!hash) return;
      const had = rec.icon?.image;
      if (had && rec.icon?.from === found.path && rec.icon.hash === hash && fs.existsSync(had.path)) return;
      const image = await storeIcon(found.path, this.projects.iconDir, rec.id, hash);
      if (this.stopped) return;
      this.projects.setFoundIcon(rec.id, { image, from: found.path, hash });
      this.log.info('librarian found an icon', { projectId: rec.id, from: found.path });
      return;
    }
    // A picture whose folder has left the project goes; one whose file has
    // just gone from a repo that's still there stays until there's another.
    if (rec.icon?.image) {
      const from = rec.icon.from;
      if (from && rec.folders.some((f) => isInside(from, f)) && fs.existsSync(rec.icon.image.path)) return;
    } else if (rec.icon?.symbol) {
      return;
    }
    const symbol = await this.pickSymbol(rec);
    if (this.stopped) return;
    if (symbol) {
      this.projects.setFoundIcon(rec.id, { symbol });
      this.log.info('librarian picked a symbol', { projectId: rec.id, symbol });
    } else if (rec.icon?.image) {
      // Its picture's folder went and there's no symbol yet: the app's letter.
      this.projects.chooseIcon(rec.id, {}, 'librarian').catch(() => {});
    }
  }

  // A symbol for a project with no picture, from SYMBOLS. Not while paused,
  // and like a look, inside the budget and never for a private folder.
  private async pickSymbol(rec: ProjectRecord): Promise<string | undefined> {
    if (!this.models || this.paused) return undefined;
    const prompt = [
      `Project "${rec.title}"`,
      rec.folders.length ? `Folders: ${rec.folders.map((f) => this.tilde(f)).join(', ')}` : '',
      rec.goals ? `Goals: ${rec.goals.slice(0, 400)}` : '',
      '',
      `Symbols: ${SYMBOLS.join(' ')}`,
    ]
      .filter((l) => l !== undefined)
      .join('\n');
    const res = await this.models.generate({ feature: 'projects', cwd: rec.folders[0], system: SYMBOL_SYSTEM, prompt, maxTokens: 1000 });
    if (!res.ok) {
      if (!WAIT_FOR.includes(res.reason)) this.log.info('librarian could not pick a symbol', { projectId: rec.id, reason: res.reason });
      return undefined;
    }
    this.rollDay();
    this.used(res);
    const words = res.value.toLowerCase().match(/[a-z0-9.]+/g) ?? [];
    return words.map((w) => w.replace(/\.+$/, '')).find((w) => SYMBOLS.includes(w));
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

  // What a call used, into the day's figures.
  private used(res: { costUsd?: number; tokens?: number; notionalUsd?: number }): void {
    this.day.spentUsd += res.costUsd ?? 0;
    this.day.tokens = (this.day.tokens ?? 0) + (res.tokens ?? 0);
    this.day.notionalUsd = (this.day.notionalUsd ?? 0) + (res.notionalUsd ?? 0);
  }

  // The repo a file belongs to (the nearest folder with .git), else its
  // folder. A git worktree counts as its main checkout: worktrees come and
  // go, and the main one is where the project's patches live.
  private repoOf(file: string): string {
    return this.repoOfDir(path.dirname(file));
  }

  private repoOfDir(dir: string): string {
    const repo = findUp(dir, this.home, (d) => fs.existsSync(path.join(d, '.git')));
    return repo ? mainCheckout(repo) : dir;
  }

  // Repos the thread ran commands in that neither its folder nor any of
  // its projects has.
  private newWorkedIn(rec: ThreadRecord): string[] {
    const known = [rec.cwd, ...this.projects.foldersFor(rec).map((f) => f.folder)];
    return [...(this.workedIn.get(rec.id) ?? [])].filter((r) => !known.some((k) => isInside(r, k) || isInside(k, r)));
  }

  private isRepo(dir: string): boolean {
    return fs.existsSync(path.join(dir, '.git'));
  }

  // A folder a project may have: one that exists and looks like a project
  // of its own, never home or a catch-all folder of repos.
  private isProjectFolder(dir: string): boolean {
    if (dir === this.home || !isInside(dir, this.home)) return false;
    if (mainCheckout(dir) !== dir) return false;
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

// Whether the thread's agent or Mike put it in a project (join_project,
// create_project or the app), rather than the librarian.
function selfFiled(rec: ThreadRecord): boolean {
  return (rec.projects ?? []).some((m) => m.by !== 'librarian');
}

// The main checkout of a git worktree (its .git is a file naming
// <main>/.git/worktrees/<name>), else the folder itself.
export function mainCheckout(dir: string): string {
  try {
    const text = fs.readFileSync(path.join(dir, '.git'), 'utf8');
    const m = /^gitdir:\s*(.+?)\s*$/m.exec(text);
    const gitdir = m ? path.resolve(dir, m[1]) : undefined;
    const marker = `${path.sep}.git${path.sep}worktrees${path.sep}`;
    if (gitdir && gitdir.includes(marker)) return gitdir.slice(0, gitdir.indexOf(marker));
  } catch {
    // A .git folder (EISDIR) or none: the folder is its own checkout.
  }
  return dir;
}

const PROJECT_MARKERS = ['.git', 'package.json', 'Package.swift', 'pyproject.toml', 'Cargo.toml', 'go.mod', 'AGENTS.md', 'CLAUDE.md'];

const WAIT_FOR: ModelFailure[] = ['no-key', 'off', 'over-budget', 'no-room'];

function offReason(reason: ModelFailure, message: string): string {
  if (reason === 'no-key') return 'No Claude pool or OpenRouter key';
  // "Every login in Claude is out of room"
  if (reason === 'no-room') return message.replace(/\.$/, '');
  if (reason === 'over-budget') return "Today's model budget is spent";
  if (reason === 'off') return 'Model calls are off';
  return message;
}

export const SYSTEM = `You are the librarian in Threadbear, an app where Mike runs AI coding agents in threads. You keep his projects: groupings above folders that carry goals, state and notes from thread to thread. A project is a body of work he'll come back to (an app, a library, a video, a house job, an ongoing chore), never a single task. One project can span several repos, and a thread can be in several projects.

Given the project list and one thread, decide which projects the thread belongs in. A thread belongs in a project when it's about that project: building, fixing, planning, ideas, research or questions for it. A thread whose folder is a project's repo almost always belongs in that project. Prefer existing projects. Make a new one when the thread is about a body of work that fits none of them (its own repo is a strong sign); a one-off question, a quick chore or a throwaway test belongs in none. Never put a thread back in one it says never to.

Reply with JSON only, no prose and no code fence:
{"projects": ["<ids of existing projects the thread belongs in, or []>"],
 "new": null or {"title": "short name, as Mike would say it", "folders": ["~/path of its repo(s)"], "goals": "one or two sentences: what it's for", "state": "one or two sentences: where it's up to"},
 "state": {"<project id>": "the project's new state"} only when this thread changed where the whole project stands (shipped or finished something, made a decision, hit a blocker), else {},
 "addFolders": {"<project id>": ["~/path"]} for repos this thread shows belong to a project it's in, else {},
 "links": {"<project id>": [{"title": "Live site", "url": "https://..."}]} for lasting places of a project it's in that the messages give and the project doesn't list yet, else {},
 "thread": "where this thread itself is up to, as two or three short bullets, one per line, each starting \"- \": what it did or found, and what it's waiting on or doing next",
 "title": null, or a new title when the thread's title no longer says what it's about (see below),
 "why": "one short line"}

Folders are repos the work lives in (the thread's folder when it's a repo, the repos it edited, and the ones it ran commands in when the work was about them, not a look at something else), never a catch-all folder. A project with no folders that this thread worked on in a repo should get that repo through addFolders. State is two to four plain sentences about the whole project, not this thread: what's done, what's next, what's blocked. Start from the current state, keep what's still true and fold the change in; don't replace it with this thread's details. Ideas and plans that aren't built yet don't change the state.

Links are the few places Mike keeps going back to for a project: its live site, admin page, dashboard, store listing. Copy the url exactly from the messages and give it a short title ("Live site", "Admin", "App Store"). Never a pull request, commit, issue, docs page, localhost, file or one-off page.

Keep the thread's title (title null) unless it no longer says what the thread is about: the work moved on to something else, or the title is only the first words of the first message ("Hey, does the library, sorry, the librarian, does it update"). A better wording of the same subject is no reason. A new title is 2 to 6 words about the whole thread as it is now, in sentence case (a capital for the first word and for names only), with no quotes, full stop, dash or emoji: "Fix the flaky upload test on CI", "Librarian renames threads that move on".

The thread bullets are for Mike glancing at the thread later: concrete, in his plain words, each under ten words, no full stops. The last one says who's waiting on whom ("Waiting on Mike to pick a design", "Fixing the last failing test").`;

const SYMBOL_SYSTEM = `You pick an icon for a project in Threadbear, Mike's app for running AI coding agents. Given the project and a list of SF Symbol names, reply with the one name from the list that best shows what the project is about, and nothing else.`;

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
