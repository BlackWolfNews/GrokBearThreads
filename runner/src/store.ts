import type { HighlightState } from './highlights.ts';
import fs from 'node:fs';
import path from 'node:path';
import type { DesignReview, ReviewDraft, EffortLevel, MessageOrigin, PermissionMode, PersistedEvent, Provider, Subagent, ThreadProject, ThreadStatus, ImageRef } from './protocol.ts';
import { atomicWriteFileSync, readJsonSync } from './fsutil.ts';
import { paths } from './config.ts';

export type QueuedSend = { turnId: string; text: string; images: ImageRef[]; origin?: MessageOrigin; scheduleId?: string; reviewId?: string; reviewResponse?: ReviewDraft };

// What thread.json holds: the public summary fields plus a few internal ones.
export type ThreadRecord = {
  id: string;
  title: string;
  cwd: string;
  accountId: string;
  provider: Provider;
  model?: string;
  effort?: EffortLevel;
  modelInUse?: string; // full id the CLI ran the last turn on
  effortInUse?: EffortLevel; // the level the CLI reported for the last turn
  permissionMode: PermissionMode;
  status: ThreadStatus;
  createdAt: string;
  updatedAt: string;
  lastActivityAt: string;
  snoozedUntil?: string;
  snoozedUntilRestart?: boolean; // snoozedUntil is UNTIL_RESTART; start() wakes it
  archivedAt?: string;
  preview: string;
  lastSeq: number;
  lastSeenSeq: number;
  nativeSessionId?: string;
  contextTokens?: number;
  contextWindow?: number; // the model's window, when the CLI reports it
  costUsd?: number;
  reviews?: DesignReview[];
  reviewDeliveries?: string[]; // review IDs whose reply reached session.send
  // Internal.
  // The version of the CLI that ran the thread's last session, so a new
  // session on another version can say so ("Codex 0.165.0 from this turn
  // on (was 0.164.0)") even after an idle release.
  cliVersion?: string;
  // Set when a same-account folder move on an adapter that moves folders
  // itself (Codex) is waiting for the next turn, which says so. The
  // session carries on; there's no handoff.
  moved?: { fromCwd: string };
  sessionUsed?: boolean; // nativeSessionId has a transcript, so the next start resumes it
  sessionCostTotal?: number; // the CLI's running total_cost_usd for this native session
  lastTurnCompletedSeq: number;
  forceUnread?: boolean; // set when a snooze ends
  // Set when the folder or account changes, or the record had to be
  // rebuilt; the next turn starts a new native session with a note.
  // lost: the session to resume couldn't be found (never saved; only set
  // while the fresh session's first message is put together).
  handoff?: { fromCwd: string; fromAccountId: string; rebuilt?: boolean; lost?: boolean };
  allowRules?: string[]; // "Always allow" rules, in the CLI's syntax
  queue: QueuedSend[];
  pendingApprovals: string[];
  turnId?: string; // turn in progress when the record was saved
  titleSet?: boolean;
  subagents?: SubagentRecord[]; // newest last, at most SUBAGENTS_KEPT
  // The projects the thread is in (projects.ts), oldest first; titles come
  // from the project list when the summary is made.
  projects?: ThreadProjectRecord[];
  // Projects Mike took the thread out of: the librarian never puts it back.
  projectsLeft?: string[];
  // The projects the native session has been told about (the brief, or a
  // line when it joined one), so it hears about each once.
  projectsTold?: string[];
  // Highlights (highlights.ts): what's been found and pinned, and the
  // event it had read up to. Brought up to date when a client asks.
  highlights?: HighlightState;
  highlightsAt?: string; // a pin, a removal or a new brief
  brief?: { text: string; at: string }; // the librarian's line on where the thread is up to
};

export type ThreadProjectRecord = Omit<ThreadProject, 'title'>;

// A sub-agent as the summary shows it, plus where its transcript is: the
// thread can change folder, account or session after it ran.
export type SubagentRecord = Subagent & { sessionId?: string; cwd?: string; accountId?: string };

// Append-only events.ndjson with a byte-offset index, so a page of a
// 4,000-event thread is one read of the bytes it needs. seq N is line N.
export class EventLog {
  readonly file: string;
  private offsets: number[] = [];
  private size = 0;

  constructor(file: string) {
    this.file = file;
    this.load();
  }

  private load(): void {
    let buf: Buffer;
    try {
      buf = fs.readFileSync(this.file);
    } catch {
      this.offsets = [];
      this.size = 0;
      return;
    }
    const offsets: number[] = [];
    let start = 0;
    for (let i = 0; i < buf.length; i++) {
      if (buf[i] === 0x0a) {
        offsets.push(start);
        start = i + 1;
      }
    }
    if (start < buf.length) {
      // A crash mid-append left half a line. Drop it so seq stays gapless.
      fs.truncateSync(this.file, start);
    }
    this.offsets = offsets;
    this.size = start;
  }

  get lastSeq(): number {
    return this.offsets.length;
  }

  append(event: PersistedEvent): void {
    if (event.seq !== this.offsets.length + 1) {
      throw new Error(`event seq ${event.seq} out of order (last ${this.offsets.length})`);
    }
    const line = Buffer.from(JSON.stringify(event) + '\n', 'utf8');
    fs.mkdirSync(path.dirname(this.file), { recursive: true });
    try {
      fs.appendFileSync(this.file, line);
    } catch (e) {
      // A write that failed part way (disk full) would leave half a line
      // for the next append to run into; cut it off.
      try {
        if (fs.statSync(this.file).size > this.size) fs.truncateSync(this.file, this.size);
      } catch {
        // can't fix it now; load() drops a half line on the next start
      }
      throw e;
    }
    this.offsets.push(this.size);
    this.size += line.length;
  }

  // Events with fromSeq <= seq <= toSeq.
  read(fromSeq: number, toSeq: number): PersistedEvent[] {
    const from = Math.max(1, fromSeq);
    const to = Math.min(this.offsets.length, toSeq);
    if (to < from) return [];
    const startByte = this.offsets[from - 1];
    const endByte = to < this.offsets.length ? this.offsets[to] : this.size;
    const buf = Buffer.alloc(endByte - startByte);
    const fd = fs.openSync(this.file, 'r');
    try {
      fs.readSync(fd, buf, 0, buf.length, startByte);
    } finally {
      fs.closeSync(fd);
    }
    const out: PersistedEvent[] = [];
    for (const line of buf.toString('utf8').split('\n')) {
      if (!line) continue;
      try {
        out.push(JSON.parse(line) as PersistedEvent);
      } catch {
        // Skip a corrupt line rather than failing the whole page.
      }
    }
    return out;
  }
}

export class ThreadStore {
  readonly home: string;
  private logs = new Map<string, EventLog>();

  constructor(home: string) {
    this.home = home;
  }

  threadDir(id: string): string {
    return paths.thread(this.home, id);
  }

  mediaDir(id: string): string {
    return paths.media(this.home, id);
  }

  blobsDir(id: string): string {
    return paths.blobs(this.home, id);
  }

  // Every thread on disk. `broken` lists folders that have an event log but
  // no readable thread.json, so the runner can rebuild them rather than
  // have the thread vanish.
  loadAll(): { records: ThreadRecord[]; broken: string[] } {
    const dir = paths.threads(this.home);
    let names: string[] = [];
    try {
      names = fs.readdirSync(dir);
    } catch {
      return { records: [], broken: [] };
    }
    const records: ThreadRecord[] = [];
    const broken: string[] = [];
    for (const name of names) {
      if (name.startsWith('.')) continue;
      const rec = this.load(name);
      if (!rec) {
        if (fs.existsSync(path.join(dir, name, 'events.ndjson'))) broken.push(name);
        continue;
      }
      records.push(rec);
    }
    return { records, broken };
  }

  // One thread's record, or undefined when thread.json is missing or isn't
  // that thread's.
  load(id: string): ThreadRecord | undefined {
    const rec = readJsonSync<ThreadRecord>(path.join(paths.threads(this.home), id, 'thread.json'));
    if (!rec || !rec.id || rec.id !== id) return undefined;
    rec.provider ??= 'claude'; // records from before Codex
    rec.queue ??= [];
    rec.pendingApprovals ??= [];
    rec.lastTurnCompletedSeq ??= 0;
    return rec;
  }

  // Drops the cached event log, so the next log() reads the file again:
  // another runner (a draining one, docs/protocol.md "Handovers") may have
  // written to it since.
  forget(id: string): void {
    this.logs.delete(id);
  }

  // Keeps an unreadable thread.json for a look later, out of the way.
  setAside(id: string): void {
    const file = path.join(this.threadDir(id), 'thread.json');
    try {
      if (fs.existsSync(file)) fs.renameSync(file, `${file}.unreadable-${Date.now()}`);
    } catch {
      // nothing to keep
    }
  }

  create(rec: ThreadRecord): void {
    fs.mkdirSync(this.mediaDir(rec.id), { recursive: true });
    fs.mkdirSync(this.blobsDir(rec.id), { recursive: true });
    this.save(rec);
  }

  save(rec: ThreadRecord): void {
    atomicWriteFileSync(path.join(this.threadDir(rec.id), 'thread.json'), JSON.stringify(rec, null, 1) + '\n');
  }

  // Moves a thread's folder to trash/<id>-<time> so it's out of the list but
  // can still be put back by hand.
  trash(id: string, now: number): void {
    const dir = this.threadDir(id);
    if (!fs.existsSync(dir)) return;
    const bin = path.join(this.home, 'trash');
    fs.mkdirSync(bin, { recursive: true });
    fs.renameSync(dir, path.join(bin, `${id}-${now}`));
    this.logs.delete(id);
  }

  log(id: string): EventLog {
    let log = this.logs.get(id);
    if (!log) {
      log = new EventLog(path.join(this.threadDir(id), 'events.ndjson'));
      this.logs.set(id, log);
    }
    return log;
  }
}
