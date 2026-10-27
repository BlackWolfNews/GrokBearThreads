// Schedules: a message sent at a set time, once (`at`) or over and over
// (`cron`), to a thread or to a new thread each time. Like Convex's
// scheduled functions and crons. Kept in schedules.json in the data dir and
// served as the schedules.* methods beside the runner's own (see
// "Schedules" in docs/protocol.md).
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import type { Runner } from './runner.ts';
import type { Clock, TimerHandle } from './clock.ts';
import type { Logger } from './log.ts';
import type { EffortLevel, PermissionMode, Schedule } from './protocol.ts';
import { EFFORT_LEVELS, ErrorCode, RpcError, isEffortLevel } from './protocol.ts';
import { atomicWriteFileSync, isDirectory, readJsonSync } from './fsutil.ts';
import { expandHome } from './config.ts';
import { CronError, checkZone, describeAt, describeCron, localZone, nextRun, nextRuns, parseCron } from './cron.ts';

// What schedules.json holds for each: everything but whenText, which is
// worked out when it's sent.
type ScheduleRecord = Omit<Schedule, 'whenText'>;

export type ScheduleRunner = Pick<Runner, 'create' | 'send' | 'get' | 'hello' | 'onNotification' | 'publish'>;

export type CreateScheduleParams = {
  text: string;
  title?: string;
  at?: string;
  cron?: string;
  timezone?: string;
  threadId?: string;
  cwd?: string;
  accountId?: string;
  model?: string;
  effort?: EffortLevel;
  permissionMode?: PermissionMode;
  paused?: boolean;
  createdBy?: string;
};

export type UpdateScheduleParams = {
  scheduleId: string;
  title?: string;
  text?: string;
  at?: string;
  cron?: string;
  timezone?: string | null;
  paused?: boolean;
  cwd?: string;
  accountId?: string;
  model?: string | null;
  effort?: EffortLevel | null;
  permissionMode?: PermissionMode;
};

// The Mac sleeps and timers stop with it, so check often rather than
// trusting one long timer to wake up on time.
const TICK_MS = 30_000;
// A one-off that has run stays in the list this long, then goes.
const KEEP_FINISHED_MS = 7 * 86_400_000;
const BUSY = new Set(['starting', 'running', 'waiting']);

export class Scheduler {
  private runner: ScheduleRunner;
  private file: string;
  private clock: Clock;
  private log: Logger;
  private zone: () => string;
  private items = new Map<string, ScheduleRecord>();
  private timer?: TimerHandle;
  private stopped = false;
  private unlisten?: () => void;
  // Threads a draining runner still has (docs/protocol.md, "Handovers"):
  // they're real threads, just not loaded here yet.
  private elsewhere: (threadId: string) => boolean;

  constructor(deps: { runner: ScheduleRunner; home: string; clock: Clock; log: Logger; zone?: () => string; elsewhere?: (threadId: string) => boolean }) {
    this.runner = deps.runner;
    this.elsewhere = deps.elsewhere ?? (() => false);
    this.file = path.join(deps.home, 'schedules.json');
    this.clock = deps.clock;
    this.log = deps.log;
    this.zone = deps.zone ?? localZone;
  }

  start(): void {
    const saved = readJsonSync<{ schedules?: ScheduleRecord[] }>(this.file);
    if (!saved && fs.existsSync(this.file)) this.log.error('schedules.json could not be read; starting with none', { file: this.file });
    for (const s of saved?.schedules ?? []) {
      if (s && typeof s.id === 'string') this.items.set(s.id, s);
    }
    // A thread's schedules go with it.
    this.unlisten = this.runner.onNotification((n) => {
      if (n.method !== 'thread.deleted') return;
      let gone = false;
      for (const s of this.items.values()) {
        if (s.threadId === n.params.threadId) {
          this.items.delete(s.id);
          gone = true;
        }
      }
      if (gone) this.changed();
    });
    this.log.info('schedules loaded', { count: this.items.size });
    this.tick();
  }

  stop(): void {
    this.stopped = true;
    this.timer?.cancel();
    this.unlisten?.();
  }

  // ---------------------------------------------------------------- reads

  list(threadId?: string): Schedule[] {
    const rank = (s: ScheduleRecord): number => (s.nextRunAt && !s.paused ? 0 : s.finishedAt ? 2 : 1);
    return [...this.items.values()]
      .filter((s) => !threadId || s.threadId === threadId || s.createdBy === threadId)
      .sort((a, b) => {
        const r = rank(a) - rank(b);
        if (r) return r;
        if (a.nextRunAt && b.nextRunAt && !a.paused && !b.paused) return a.nextRunAt.localeCompare(b.nextRunAt);
        if (a.finishedAt && b.finishedAt) return b.finishedAt.localeCompare(a.finishedAt);
        return b.createdAt.localeCompare(a.createdAt);
      })
      .map((s) => this.view(s));
  }

  find(idOrPrefix: string): Schedule {
    return this.view(this.mustGet(idOrPrefix));
  }

  preview(p: { cron?: string; at?: string; timezone?: string; count?: number }): { whenText: string; runs: string[] } {
    const count = Math.min(Math.max(p.count ?? 5, 1), 20);
    const zone = p.timezone ? this.checkedZone(p.timezone) : undefined;
    if ((p.cron === undefined) === (p.at === undefined)) throw bad('Give either cron or at.');
    if (p.at !== undefined) {
      const t = this.parseAt(p.at);
      return { whenText: describeAt(t, zone ?? this.zone(), this.clock.now()), runs: [new Date(t).toISOString()] };
    }
    const spec = this.parsedCron(p.cron!);
    const runs = nextRuns(spec, this.clock.now(), zone ?? this.zone(), count);
    if (!runs.length) throw bad(`"${p.cron}" never runs.`);
    return { whenText: describeCron(spec, zone), runs: runs.map((t) => new Date(t).toISOString()) };
  }

  // ------------------------------------------------------------ mutations

  create(p: CreateScheduleParams): Schedule {
    const text = p.text?.trim();
    if (!text) throw bad('text is required');
    if ((p.cron === undefined) === (p.at === undefined)) throw bad('Give either at (once) or cron (repeating).');
    const now = this.iso();
    const rec: ScheduleRecord = {
      id: crypto.randomUUID(),
      title: p.title?.trim() ? p.title.trim().slice(0, 200) : firstLine(text),
      text,
      paused: Boolean(p.paused),
      createdAt: now,
      updatedAt: now,
      runs: 0,
    };
    if (p.timezone) rec.timezone = this.checkedZone(p.timezone);
    if (p.at !== undefined) rec.at = new Date(this.parseAt(p.at)).toISOString();
    else rec.cron = this.parsedCron(p.cron!).source;
    if (p.threadId) {
      // Throws thread not found for a bad id.
      rec.threadId = this.elsewhere(p.threadId) ? p.threadId : this.runner.get(p.threadId).id;
    } else {
      rec.cwd = this.checkedFolder(p.cwd);
      if (p.accountId) rec.accountId = this.checkedAccount(p.accountId);
      if (p.model) rec.model = p.model;
      if (p.effort) rec.effort = p.effort;
      if (p.permissionMode) rec.permissionMode = p.permissionMode;
    }
    if (p.createdBy) rec.createdBy = p.createdBy;
    this.plan(rec);
    this.items.set(rec.id, rec);
    this.changed();
    // An `at` that's already passed runs now rather than on the next tick.
    this.tick();
    return this.view(this.items.get(rec.id) ?? rec);
  }

  update(p: UpdateScheduleParams): Schedule {
    const rec = this.mustGet(p.scheduleId);
    let replan = false;
    if (p.title !== undefined) rec.title = p.title.trim() ? p.title.trim().slice(0, 200) : firstLine(rec.text);
    if (p.text !== undefined) {
      if (!p.text.trim()) throw bad('text cannot be empty');
      rec.text = p.text.trim();
    }
    if (p.at !== undefined && p.cron !== undefined) throw bad('Give at or cron, not both.');
    if (p.timezone !== undefined) {
      if (p.timezone === null || p.timezone === '') delete rec.timezone;
      else rec.timezone = this.checkedZone(p.timezone);
      replan = true;
    }
    if (p.at !== undefined) {
      rec.at = new Date(this.parseAt(p.at)).toISOString();
      delete rec.cron;
      delete rec.finishedAt;
      replan = true;
    }
    if (p.cron !== undefined) {
      rec.cron = this.parsedCron(p.cron).source;
      delete rec.at;
      delete rec.finishedAt;
      replan = true;
    }
    if (p.paused !== undefined && p.paused !== rec.paused) {
      rec.paused = p.paused;
      replan = true;
    }
    if (!rec.threadId) {
      if (p.cwd !== undefined) rec.cwd = this.checkedFolder(p.cwd);
      if (p.accountId !== undefined) rec.accountId = this.checkedAccount(p.accountId);
      if (p.model !== undefined) setOrDelete(rec, 'model', p.model);
      if (p.effort !== undefined) setOrDelete(rec, 'effort', p.effort);
      if (p.permissionMode !== undefined) rec.permissionMode = p.permissionMode;
    } else if ([p.cwd, p.accountId, p.model, p.effort, p.permissionMode].some((x) => x !== undefined)) {
      throw bad("This schedule sends to a thread, so it has no folder, account or model of its own; change the thread's.");
    }
    rec.updatedAt = this.iso();
    if (replan) this.plan(rec);
    this.changed();
    this.tick();
    return this.view(rec);
  }

  delete(scheduleId: string): Record<string, never> {
    const rec = this.mustGet(scheduleId);
    this.items.delete(rec.id);
    this.changed();
    return {};
  }

  // Runs it now, as if it were due. A repeating one keeps its next time.
  runNow(scheduleId: string): { schedule: Schedule; threadId: string; turnId: string } {
    const rec = this.mustGet(scheduleId);
    const res = this.send(rec, true);
    if (res.outcome !== 'sent') throw new RpcError(ErrorCode.other, res.note ?? "Couldn't run it.");
    if (rec.at) this.finish(rec);
    this.changed();
    return { schedule: this.view(rec), threadId: res.threadId!, turnId: res.turnId! };
  }

  // ------------------------------------------------------------------ runs

  private tick(): void {
    this.timer?.cancel();
    this.timer = undefined;
    if (this.stopped) return;
    const now = this.clock.now();
    let changed = this.prune(now);
    for (const rec of [...this.items.values()]) {
      if (rec.paused || !rec.nextRunAt || Date.parse(rec.nextRunAt) > now) continue;
      const res = this.send(rec, false);
      // The runner is restarting: leave it due for the next runner.
      if (res.outcome === 'retry') continue;
      if (rec.at) this.finish(rec);
      else this.plan(rec);
      changed = true;
    }
    if (changed) this.changed();
    let next = Infinity;
    for (const rec of this.items.values()) {
      if (!rec.paused && rec.nextRunAt) next = Math.min(next, Date.parse(rec.nextRunAt));
    }
    // Something still due (waiting out a restart) is tried again on the
    // next regular check, not straight away over and over.
    const wait = next <= now ? TICK_MS : Math.min(next - now, TICK_MS);
    this.timer = this.clock.setTimeout(() => this.tick(), wait);
  }

  private send(rec: ScheduleRecord, manual: boolean): { outcome: 'sent' | 'skipped' | 'failed' | 'retry'; threadId?: string; turnId?: string; note?: string } {
    const at = this.iso();
    const text = `[Scheduled: "${rec.title}", ${this.whenText(rec)}]\n\n${rec.text}`;
    const record = (outcome: 'sent' | 'skipped' | 'failed', threadId?: string, note?: string) => {
      rec.lastRun = { at, outcome, ...(threadId ? { threadId } : {}), ...(note ? { note } : {}) };
      if (outcome === 'sent') rec.runs += 1;
      this.log.info('schedule ran', { scheduleId: rec.id, outcome, threadId, note });
    };
    // Its thread is busy on a draining runner: it's sent once the thread
    // has come across, like a busy thread's queue.
    if (rec.threadId && this.elsewhere(rec.threadId)) {
      if (manual) throw new RpcError(ErrorCode.busy, 'That thread is finishing a turn on the old runner; try again in a moment.');
      return { outcome: 'retry' };
    }
    try {
      if (rec.threadId) {
        // queue: a busy thread finishes what it's doing first.
        const { turnId } = this.runner.send(rec.threadId, text, [], { origin: 'schedule', scheduleId: rec.id, queue: true });
        record('sent', rec.threadId);
        return { outcome: 'sent', threadId: rec.threadId, turnId };
      }
      // Don't pile up new threads behind one that's still going.
      const last = rec.lastRun?.outcome === 'sent' ? rec.lastRun.threadId : undefined;
      if (last && !manual && rec.cron && this.isBusy(last)) {
        const note = 'The thread from the last run was still going.';
        record('skipped', last, note);
        return { outcome: 'skipped', note };
      }
      const r = this.runner.create({
        text,
        title: rec.title,
        cwd: rec.cwd,
        accountId: rec.accountId,
        model: rec.model,
        effort: rec.effort,
        permissionMode: rec.permissionMode,
        origin: 'schedule',
        scheduleId: rec.id,
      });
      record('sent', r.thread.id);
      return { outcome: 'sent', threadId: r.thread.id, turnId: r.turnId };
    } catch (e) {
      if (e instanceof RpcError && e.code === ErrorCode.busy) {
        if (manual) throw e;
        return { outcome: 'retry' };
      }
      const note = (e as Error).message ?? String(e);
      record('failed', rec.threadId, note);
      this.log.warn('schedule could not run', { scheduleId: rec.id, error: note });
      return { outcome: 'failed', note };
    }
  }

  private isBusy(threadId: string): boolean {
    try {
      return BUSY.has(this.runner.get(threadId).status);
    } catch {
      return false;
    }
  }

  // Works out nextRunAt from now: a one-off's time (even if it's passed,
  // so it runs), or a cron's next time after now, however many it missed.
  private plan(rec: ScheduleRecord): void {
    delete rec.nextRunAt;
    if (rec.paused || rec.finishedAt) return;
    if (rec.at) {
      rec.nextRunAt = rec.at;
      return;
    }
    const t = nextRun(parseCron(rec.cron!), this.clock.now(), rec.timezone ?? this.zone());
    if (t !== undefined) rec.nextRunAt = new Date(t).toISOString();
  }

  private finish(rec: ScheduleRecord): void {
    rec.finishedAt = this.iso();
    delete rec.nextRunAt;
  }

  private prune(now: number): boolean {
    let gone = false;
    for (const rec of this.items.values()) {
      if (rec.finishedAt && now - Date.parse(rec.finishedAt) > KEEP_FINISHED_MS) {
        this.items.delete(rec.id);
        gone = true;
      }
    }
    return gone;
  }

  // -------------------------------------------------------------- helpers

  private changed(): void {
    const stored = [...this.items.values()];
    try {
      atomicWriteFileSync(this.file, `${JSON.stringify({ version: 1, schedules: stored }, null, 2)}\n`);
    } catch (e) {
      this.log.error('could not save schedules', { error: String(e) });
    }
    this.runner.publish({ method: 'schedules.updated', params: { schedules: this.list() } });
  }

  private view(rec: ScheduleRecord): Schedule {
    return { ...rec, whenText: this.whenText(rec) };
  }

  private whenText(rec: ScheduleRecord): string {
    if (rec.at) return describeAt(Date.parse(rec.at), rec.timezone ?? this.zone(), this.clock.now());
    try {
      return describeCron(parseCron(rec.cron ?? ''), rec.timezone);
    } catch {
      return `Cron ${rec.cron}`;
    }
  }

  private mustGet(idOrPrefix: string): ScheduleRecord {
    const exact = this.items.get(idOrPrefix);
    if (exact) return exact;
    const hits = idOrPrefix ? [...this.items.values()].filter((s) => s.id.startsWith(idOrPrefix)) : [];
    if (hits.length === 1) return hits[0];
    if (hits.length > 1) throw bad(`${idOrPrefix} matches ${hits.length} schedules; use more of the id.`);
    throw new RpcError(ErrorCode.scheduleNotFound, `No schedule ${idOrPrefix}`);
  }

  private parseAt(at: string): number {
    const t = Date.parse(at);
    if (Number.isNaN(t)) throw bad(`at must be an ISO time, not "${at}"`);
    return t;
  }

  private parsedCron(cron: string): ReturnType<typeof parseCron> {
    try {
      const spec = parseCron(cron);
      if (nextRun(spec, this.clock.now(), this.zone()) === undefined) throw new CronError(`"${cron}" never runs.`);
      return spec;
    } catch (e) {
      if (e instanceof CronError) throw bad(e.message);
      throw e;
    }
  }

  private checkedZone(zone: string): string {
    try {
      return checkZone(zone);
    } catch (e) {
      throw bad((e as Error).message);
    }
  }

  private checkedFolder(cwd: string | undefined): string {
    const dir = path.resolve(expandHome(cwd?.trim() ? cwd.trim() : this.runner.hello().defaults.cwd));
    if (!isDirectory(dir)) throw bad(`Folder not found: ${dir}`);
    return dir;
  }

  private checkedAccount(id: string): string {
    if (!this.runner.hello().accounts.some((a) => a.id === id)) throw new RpcError(ErrorCode.accountNotFound, `No account called ${id}`);
    return id;
  }

  private iso(): string {
    return new Date(this.clock.now()).toISOString();
  }
}

function bad(message: string): RpcError {
  return new RpcError(ErrorCode.badParams, message);
}

function firstLine(text: string): string {
  return (text.split('\n').map((l) => l.trim()).find(Boolean) ?? 'Scheduled message').slice(0, 80);
}

function setOrDelete<K extends 'model' | 'effort'>(rec: ScheduleRecord, key: K, v: ScheduleRecord[K] | null): void {
  if (v === null || v === undefined || v === '') delete rec[key];
  else rec[key] = v;
}

// ------------------------------------------------------------- the methods

export function scheduleMethods(s: Scheduler): Record<string, (p: Record<string, unknown>) => unknown> {
  return {
    'schedules.list': (p) => ({ schedules: s.list(str(p, 'threadId')) }),
    'schedules.create': (p) => ({
      schedule: s.create({
        text: str(p, 'text') ?? '',
        title: str(p, 'title'),
        at: str(p, 'at'),
        cron: str(p, 'cron'),
        timezone: str(p, 'timezone'),
        threadId: str(p, 'threadId'),
        cwd: str(p, 'cwd'),
        accountId: str(p, 'accountId'),
        model: str(p, 'model'),
        effort: effort(p.effort) ?? undefined,
        permissionMode: mode(p.permissionMode),
        paused: bool(p, 'paused'),
        createdBy: str(p, 'createdBy'),
      }),
    }),
    'schedules.update': (p) => {
      const scheduleId = str(p, 'scheduleId');
      if (!scheduleId) throw bad('scheduleId must be a string');
      const upd: UpdateScheduleParams = { scheduleId };
      for (const k of ['title', 'text', 'at', 'cron', 'cwd', 'accountId'] as const) {
        const v = str(p, k);
        if (v !== undefined) upd[k] = v;
      }
      if (p.timezone !== undefined) upd.timezone = p.timezone === null ? null : str(p, 'timezone');
      if (p.model !== undefined) upd.model = p.model === null ? null : str(p, 'model');
      if (p.effort !== undefined) upd.effort = effort(p.effort);
      if (p.permissionMode !== undefined) upd.permissionMode = mode(p.permissionMode);
      if (p.paused !== undefined) upd.paused = bool(p, 'paused');
      return { schedule: s.update(upd) };
    },
    'schedules.delete': (p) => s.delete(reqStr(p, 'scheduleId')),
    'schedules.run': (p) => s.runNow(reqStr(p, 'scheduleId')),
    'schedules.preview': (p) => {
      const count = p.count;
      if (count !== undefined && (typeof count !== 'number' || !Number.isInteger(count))) throw bad('count must be a whole number');
      return s.preview({ cron: str(p, 'cron'), at: str(p, 'at'), timezone: str(p, 'timezone'), count: count as number | undefined });
    },
  };
}

function str(p: Record<string, unknown>, k: string): string | undefined {
  const v = p[k];
  if (v === undefined || v === null) return undefined;
  if (typeof v !== 'string') throw bad(`${k} must be a string`);
  return v;
}

function reqStr(p: Record<string, unknown>, k: string): string {
  const v = str(p, k);
  if (v === undefined) throw bad(`${k} must be a string`);
  return v;
}

function bool(p: Record<string, unknown>, k: string): boolean | undefined {
  const v = p[k];
  if (v === undefined || v === null) return undefined;
  if (typeof v !== 'boolean') throw bad(`${k} must be a boolean`);
  return v;
}

function effort(v: unknown): EffortLevel | null | undefined {
  if (v === undefined) return undefined;
  if (v === null) return null;
  if (!isEffortLevel(v)) throw bad(`effort must be one of ${EFFORT_LEVELS.join(', ')}`);
  return v;
}

function mode(v: unknown): PermissionMode | undefined {
  if (v === undefined || v === null) return undefined;
  if (v !== 'full' && v !== 'ask') throw bad('permissionMode must be "full" or "ask"');
  return v;
}
