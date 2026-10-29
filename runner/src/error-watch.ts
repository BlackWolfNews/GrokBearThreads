// The error watch: the librarian keeping an eye on Threadbear itself
// (docs/protocol.md, "Error watch"). Every warning and error the runner
// logs is grouped by what it says, with ids, numbers and temp paths taken
// out, so the same fault twenty times is one group. Every CHECK_MS, groups
// it hasn't decided about go to the small model, which says which look
// like a bug in Threadbear worth working on and which are noise (a network
// blip, a model's own limit). For each one worth it, a thread starts in
// Threadbear's repo with the error and is told to find the cause and fix
// it, or say why not and stop.
//
// Only the live runner watches: one run from a release, which knows the
// checkout it was built from. A dev runner or a test has no repo to fix.
// It waits while the librarian is paused, opens at most MAX_PER_DAY
// threads a day, and never a second for an error whose thread is still
// open. Groups and what was decided are kept in error-watch.json.
import crypto from 'node:crypto';
import path from 'node:path';
import type { Clock, TimerHandle } from './clock.ts';
import type { Logger } from './log.ts';
import type { Models } from './models/index.ts';
import type { MessageOrigin, ThreadSummary } from './protocol.ts';
import type { ThreadRecord } from './store.ts';
import { atomicWriteFileSync, readJsonSync } from './fsutil.ts';

export const CHECK_MS = 15 * 60_000;
// A thread a day is plenty; more likely means one fault seen many ways.
export const MAX_PER_DAY = 3;
// An error let be is asked about again only after this, and only if it
// has happened since.
export const IGNORE_FOR_MS = 7 * 86_400_000;
// An error whose thread was archived and that still happens is asked
// about again after this: the fix may not have shipped yet.
export const REOPEN_AFTER_MS = 86_400_000;
const GROUPS_KEPT = 200;
const SAMPLES_KEPT = 3;
const LINE_CHARS = 600;
// Its own lines, and model calls failing (a login's limit, a provider
// down), which say nothing about Threadbear's code.
const SKIP = [/^error watch/, /^model call failed$/];

export type ErrorDecision = { what: 'opened' | 'ignored'; at: string; why: string; threadId?: string; count: number };

export type ErrorGroup = {
  id: string;
  level: 'WARN' | 'ERROR';
  msg: string;
  // What it said, as the first one did: the key that tells groups apart.
  sig: string;
  count: number;
  firstAt: string;
  lastAt: string;
  // The latest few lines as logged.
  samples: string[];
  decision?: ErrorDecision;
};

type Saved = { groups?: ErrorGroup[]; day?: { date: string; opened: number } };

export type ErrorWatchHost = {
  threadRecords(): ThreadRecord[];
  create(params: { text: string; title?: string; cwd?: string; origin?: MessageOrigin }): { thread: ThreadSummary };
};

export type ErrorWatchDeps = {
  host: ErrorWatchHost;
  models?: Pick<Models, 'generate'>;
  // The Threadbear checkout threads are opened in; none, and nothing is.
  repo?: string;
  logFile?: string | null;
  paused: () => boolean;
  // Into the librarian's list of what it did.
  noted: (threadId: string, threadTitle: string, text: string, costUsd?: number) => void;
};

export class ErrorWatch {
  private file: string;
  private clock: Clock;
  // The log as it was before tee wrapped it, so its own lines aren't seen.
  private log: Logger;
  private groups = new Map<string, ErrorGroup>();
  private day = { date: '', opened: 0 };
  private deps?: ErrorWatchDeps;
  private timer?: TimerHandle;
  private checking = false;
  private dirty = false;
  private stopped = false;

  constructor(opts: { home: string; clock: Clock; log: Logger }) {
    this.file = path.join(opts.home, 'error-watch.json');
    this.clock = opts.clock;
    this.log = opts.log;
    const saved = readJsonSync<Saved>(this.file);
    for (const g of saved?.groups ?? []) if (g && typeof g.sig === 'string') this.groups.set(g.sig, g);
    if (saved?.day) this.day = saved.day;
  }

  // The logger every part of the runner is given: the same lines go to the
  // log, and warnings and errors are seen here too.
  tee(log: Logger): Logger {
    return {
      info: log.info,
      debug: log.debug,
      warn: (m, e) => {
        log.warn(m, e);
        this.seen('WARN', m, e);
      },
      error: (m, e) => {
        log.error(m, e);
        this.seen('ERROR', m, e);
      },
    };
  }

  // Starts checking, once there's a runner to open threads in. Lines seen
  // before this are kept for the first check.
  start(deps: ErrorWatchDeps): void {
    this.deps = deps;
    if (!deps.repo || !deps.models) return;
    this.timer = this.clock.setTimeout(() => void this.tick(), CHECK_MS);
  }

  stop(): void {
    this.stopped = true;
    this.timer?.cancel();
    this.save();
  }

  list(): ErrorGroup[] {
    return [...this.groups.values()].sort((a, b) => b.lastAt.localeCompare(a.lastAt));
  }

  // ---------------------------------------------------------------- seeing

  private seen(level: 'WARN' | 'ERROR', msg: string, extra?: Record<string, unknown>): void {
    try {
      if (SKIP.some((r) => r.test(msg))) return;
      const said = extra ? firstString(extra, ['error', 'message', 'reason']) : undefined;
      const sig = `${level} ${msg}${said ? ' ' + normalise(said) : ''}`;
      const at = new Date(this.clock.now()).toISOString();
      const line = `${at} ${level} ${msg}${extra ? ' ' + safeJson(extra) : ''}`.slice(0, LINE_CHARS);
      const g = this.groups.get(sig);
      if (g) {
        g.count++;
        g.lastAt = at;
        g.samples = [...g.samples, line].slice(-SAMPLES_KEPT);
      } else {
        const id = crypto.createHash('sha1').update(sig).digest('hex').slice(0, 8);
        this.groups.set(sig, { id, level, msg, sig, count: 1, firstAt: at, lastAt: at, samples: [line] });
        this.trim();
        this.dirty = true;
        // A new one is kept straight away, in case the runner is about to
        // crash; repeats wait for the next check.
        this.save();
        return;
      }
      this.dirty = true;
    } catch {
      // Watching must never make logging throw.
    }
  }

  private trim(): void {
    if (this.groups.size <= GROUPS_KEPT) return;
    const oldest = [...this.groups.values()].sort((a, b) => a.lastAt.localeCompare(b.lastAt));
    for (const g of oldest.slice(0, this.groups.size - GROUPS_KEPT)) this.groups.delete(g.sig);
  }

  // -------------------------------------------------------------- checking

  private async tick(): Promise<void> {
    if (this.stopped) return;
    try {
      await this.check();
    } catch (e) {
      this.log.warn('error watch check failed', { error: String(e) });
    }
    if (!this.stopped) this.timer = this.clock.setTimeout(() => void this.tick(), CHECK_MS);
  }

  // One look at the groups due one: public for tests.
  async check(): Promise<{ opened: string[]; ignored: string[] }> {
    const none = { opened: [], ignored: [] };
    const deps = this.deps;
    if (!deps?.repo || !deps.models || this.checking || deps.paused()) return this.saved(none);
    this.rollDay();
    const room = MAX_PER_DAY - this.day.opened;
    const due = this.list().filter((g) => this.isDue(g));
    if (room <= 0 || !due.length) return this.saved(none);
    this.checking = true;
    try {
      const res = await deps.models.generate({ feature: 'errors', cwd: deps.repo, system: SYSTEM, prompt: this.prompt(due, room), maxTokens: 1500 });
      if (!res.ok) {
        this.log.info('error watch could not ask', { reason: res.reason });
        return this.saved(none);
      }
      const answer = parseAnswer(res.value);
      if (!answer) {
        this.log.warn('error watch: the answer was not JSON', { text: res.value.slice(0, 200) });
        return this.saved(none);
      }
      return this.saved(this.apply(deps, due, answer, room, res.costUsd));
    } finally {
      this.checking = false;
    }
  }

  // Never decided; let be a week ago and seen since; or its thread was put
  // away and it's still happening a day after.
  private isDue(g: ErrorGroup): boolean {
    const d = g.decision;
    if (!d) return true;
    const now = this.clock.now();
    const since = Date.parse(d.at);
    if (d.what === 'ignored') return g.count > d.count && now - since >= IGNORE_FOR_MS;
    const t = d.threadId ? this.deps?.host.threadRecords().find((r) => r.id === d.threadId) : undefined;
    if (t && !t.archivedAt) return false;
    const after = Math.max(since, t?.archivedAt ? Date.parse(t.archivedAt) : 0);
    return Date.parse(g.lastAt) > after && g.count > d.count && now - since >= REOPEN_AFTER_MS;
  }

  private prompt(due: ErrorGroup[], room: number): string {
    const lines = [`Open at most ${room} thread${room === 1 ? '' : 's'}.`, '', 'Errors:'];
    for (const g of due) {
      lines.push(`- ${g.id} [${g.level}] ${g.msg}: ${g.count} time${g.count === 1 ? '' : 's'}, first ${g.firstAt}, last ${g.lastAt}`);
      if (g.decision) {
        const t = g.decision.threadId ? this.deps?.host.threadRecords().find((r) => r.id === g.decision!.threadId) : undefined;
        lines.push(g.decision.what === 'opened' ? `  A thread already worked on it${t ? ` ("${t.title}")` : ''} and it has happened since.` : `  Let be before: ${g.decision.why}`);
      }
      for (const s of g.samples) lines.push(`  ${s}`);
    }
    const open = this.list()
      .filter((g) => g.decision?.what === 'opened' && !this.isDue(g))
      .map((g) => this.deps?.host.threadRecords().find((r) => r.id === g.decision!.threadId))
      .filter((t): t is ThreadRecord => Boolean(t && !t.archivedAt));
    if (open.length) {
      lines.push('', 'Threads already working on errors:');
      for (const t of open) lines.push(`- "${t.title}"`);
    }
    return lines.join('\n');
  }

  private apply(deps: ErrorWatchDeps, due: ErrorGroup[], a: Answer, room: number, costUsd?: number): { opened: string[]; ignored: string[] } {
    const byId = new Map(due.map((g) => [g.id, g]));
    const at = new Date(this.clock.now()).toISOString();
    const opened: string[] = [];
    const ignored: string[] = [];
    const decided = new Set<string>();
    for (const o of a.open) {
      if (opened.length >= room) break;
      const groups = o.ids.map((id) => byId.get(id)).filter((g): g is ErrorGroup => Boolean(g && !decided.has(g.id)));
      if (!groups.length) continue;
      let thread: ThreadSummary;
      try {
        ({ thread } = deps.host.create({ text: this.brief(groups, o.why), title: o.title, cwd: deps.repo, origin: 'runner' }));
      } catch (e) {
        // A handover or a missing login: asked again next check.
        this.log.warn('error watch could not open a thread', { error: String(e) });
        continue;
      }
      for (const g of groups) {
        g.decision = { what: 'opened', at, why: o.why, threadId: thread.id, count: g.count };
        decided.add(g.id);
      }
      this.day.opened++;
      opened.push(thread.id);
      this.log.info('error watch opened a thread', { threadId: thread.id, errors: groups.map((g) => g.msg) });
      deps.noted(thread.id, thread.title, `Opened a thread for ${quoteMsg(groups[0].msg)}${groups.length > 1 ? ` and ${groups.length - 1} more` : ''}`, opened.length === 1 ? costUsd : undefined);
    }
    // Everything else it was shown is let be, with the model's reason
    // when it gave one.
    const why = new Map(a.ignore.flatMap((i) => i.ids.map((id) => [id, i.why] as const)));
    for (const g of due) {
      if (decided.has(g.id)) continue;
      // Not opened only because the day's room ran out: asked again.
      if (a.open.some((o) => o.ids.includes(g.id)) && !why.has(g.id)) continue;
      g.decision = { what: 'ignored', at, why: why.get(g.id) || 'Not worth a thread', count: g.count };
      ignored.push(g.id);
    }
    if (ignored.length) this.log.info('error watch let errors be', { errors: ignored.length });
    this.dirty = true;
    return { opened, ignored };
  }

  // The new thread's first message.
  private brief(groups: ErrorGroup[], why: string): string {
    const out = [
      "The librarian noticed this in Threadbear's runner log, and it looks worth fixing.",
      '',
      why,
      '',
    ];
    for (const g of groups) {
      out.push(`${g.level} ${g.msg}: ${g.count} time${g.count === 1 ? '' : 's'} between ${g.firstAt} and ${g.lastAt}. The latest:`, '```', ...g.samples, '```', '');
    }
    out.push(
      `The whole log is \`tb logs\`${this.deps?.logFile ? ` (${this.deps.logFile})` : ''}. Find the cause, then fix it test-first in this thread's worktree and \`tb land\` it.`,
      "If it isn't a bug in Threadbear worth fixing (something outside it, expected, or already fixed on main), say why and stop without changing anything.",
    );
    return out.join('\n');
  }

  // -------------------------------------------------------------- helpers

  private rollDay(): void {
    const d = new Date(this.clock.now());
    const date = `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}`;
    if (this.day.date !== date) this.day = { date, opened: 0 };
  }

  private saved<T>(v: T): T {
    this.save();
    return v;
  }

  private save(): void {
    if (!this.dirty) return;
    try {
      atomicWriteFileSync(this.file, JSON.stringify({ groups: this.list(), day: this.day } satisfies Saved));
      this.dirty = false;
    } catch (e) {
      this.log.warn('error watch could not save', { error: String(e) });
    }
  }
}

// What tells one fault from another, without what changes each time:
// thread and session ids, hashes, temp paths and numbers.
export function normalise(s: string): string {
  return s
    .replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi, '<id>')
    .replace(/\b[0-9a-f]{7,40}\b/gi, (m) => (/\d/.test(m) ? '<hex>' : m))
    .replace(/(\/private)?\/(var\/folders|tmp)\/\S+/g, '<tmp>')
    .replace(/\d+/g, 'N')
    .slice(0, 300);
}

function firstString(o: Record<string, unknown>, keys: string[]): string | undefined {
  for (const k of keys) if (typeof o[k] === 'string' && o[k]) return o[k] as string;
  return undefined;
}

function quoteMsg(msg: string): string {
  return `"${msg.length > 60 ? msg.slice(0, 59) + '…' : msg}"`;
}

function safeJson(v: unknown): string {
  try {
    return JSON.stringify(v);
  } catch {
    return String(v);
  }
}

type Answer = { open: { ids: string[]; title: string; why: string }[]; ignore: { ids: string[]; why: string }[] };

export function parseAnswer(text: string): Answer | undefined {
  const t = text.trim().replace(/^```(?:json)?\s*/i, '').replace(/```\s*$/, '');
  const start = t.indexOf('{');
  const end = t.lastIndexOf('}');
  if (start < 0 || end <= start) return undefined;
  let v: unknown;
  try {
    v = JSON.parse(t.slice(start, end + 1));
  } catch {
    return undefined;
  }
  if (!v || typeof v !== 'object' || Array.isArray(v)) return undefined;
  const o = v as Record<string, unknown>;
  const ids = (x: unknown) => (Array.isArray(x) ? x.filter((i): i is string => typeof i === 'string') : []);
  const str = (x: unknown) => (typeof x === 'string' ? x.trim() : '');
  const open = (Array.isArray(o.open) ? o.open : [])
    .filter((x): x is Record<string, unknown> => !!x && typeof x === 'object')
    .map((x) => ({ ids: ids(x.ids), title: str(x.title).slice(0, 80) || 'Fix an error in Threadbear', why: str(x.why).slice(0, 1000) }))
    .filter((x) => x.ids.length);
  const ignore = (Array.isArray(o.ignore) ? o.ignore : [])
    .filter((x): x is Record<string, unknown> => !!x && typeof x === 'object')
    .map((x) => ({ ids: ids(x.ids), why: str(x.why).slice(0, 200) }))
    .filter((x) => x.ids.length);
  return { open, ignore };
}

export const SYSTEM = `You watch the runner log of Threadbear, Mike's own app for running AI coding agents in threads (a TypeScript runner and a SwiftUI Mac app). Given the warnings and errors it logged lately, grouped and counted, decide which point at a bug in Threadbear worth an agent's time, and which to let be.

Worth a thread: something in Threadbear's own code going wrong, like a lookup of a thread that has gone, a request the CLI rejects every time, a release that won't build, a crash, a file it can't read. Repeats make a bug likelier, but one clear error is enough.

Let be: the network or a service being briefly down ("fetch failed", timeouts that clear), a login out of room, something Mike or another app did, or what's already being worked on in one of the threads listed. Warnings that say the runner is coping ("will retry") are usually fine unless they never stop.

Put errors with the same cause in one thread (the same "Thread not found" from three places is one fault). Each thread's title is 3 to 7 words in sentence case naming the fault, with no quotes or full stop: "Deleted threads still get looked up".

Reply with JSON only, no prose and no code fence:
{"open": [{"ids": ["<error ids>"], "title": "...", "why": "two or three sentences for the agent: what seems to be wrong and where to start looking"}],
 "ignore": [{"ids": ["<error ids>"], "why": "one short line"}]}`;
