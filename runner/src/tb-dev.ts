// tb's commands for working on Threadbare from inside Threadbare
// (docs/dev-tools.md, section 3): the runner's state, the calling thread,
// restarts, a thread as plain text, the runner log, fixture exports for the
// mock runner, and raw calls. cli.ts hands these commands over; the
// formatting and export functions are pure enough to test on their own.
import fs from 'node:fs';
import path from 'node:path';
import { readToken, runnerUrl, type Config } from './config.ts';
import { RunnerClient, RpcClientError } from './client.ts';
import { ErrorCode, type ImageRef, type PersistedEvent, type ThreadSummary } from './protocol.ts';
import type { RunnerStatus } from './restart.ts';

export const DEV_HELP = `Working on Threadbare itself:
  tb status [--json]              the runner: version, live CLIs, busy threads, a pending restart
  tb self [--json]                the thread this command runs in (THREADBARE_THREAD_ID)
  tb restart [--now [--force]] [--resume "text"] [--reason "text"] [--thread ID]
                                  restart when every thread is idle (or now); --resume carries
                                  this thread (or --thread) on afterwards
  tb show <threadId> [--last N] [--tools]
                                  the thread as plain text; --last N turns; --tools adds results
  tb logs [-f] [-n 200] [--thread ID]
  tb export <threadId> [--out DIR]
                                  thread.json, events.ndjson and media/ for the mock runner,
                                  in app/.fixtures/threads/<id> by default
  tb rpc <method> ['{"json": "params"}']`;

export type Flags = Record<string, string | boolean | string[] | undefined>;
type Resolve = (prefix: string | undefined) => Promise<string>;

const ALL = ['inbox', 'snoozed', 'archived'];

// Returns undefined for a command that isn't one of these.
export async function runDev(client: RunnerClient, cmd: string, args: string[], f: Flags, resolveId: Resolve): Promise<number | undefined> {
  const env = process.env;
  switch (cmd) {
    case 'status': {
      const s = await client.call<RunnerStatus>('runner.status').catch(tooOld);
      if (!s) return TOO_OLD;
      if (f.json) return printJson(s);
      process.stdout.write(formatStatus(s, await listAll(client), Date.now()));
      return 0;
    }
    case 'self': {
      const id = env.THREADBARE_THREAD_ID;
      if (!id) {
        console.error("THREADBARE_THREAD_ID isn't set: tb self only works inside a Threadbare thread.");
        return 1;
      }
      const t = await threadById(client, id);
      if (f.json) return printJson(t);
      process.stdout.write(formatSelf(t));
      return 0;
    }
    case 'restart': {
      const inThread = env.THREADBARE_THREAD_ID;
      if (f.now && inThread && !f.force) {
        console.error("--now stops every turn, this thread's own included. Leave it out to restart once every thread is idle, or add --force.");
        return 1;
      }
      const params: Record<string, unknown> = { when: f.now ? 'now' : 'idle' };
      if (typeof f.reason === 'string') params.reason = f.reason;
      if (typeof f.resume === 'string') {
        const target = typeof f.thread === 'string' ? await resolveId(f.thread) : inThread;
        if (!target) {
          console.error('--resume needs a thread: run it inside one, or pass --thread ID.');
          return 1;
        }
        params.resume = { threadId: target, text: f.resume };
      }
      const r = await client.call<{ scheduled: boolean; waitingFor: string[] }>('runner.restart', params).catch(tooOld);
      if (!r) return TOO_OLD;
      if (r.waitingFor.length === 0) {
        console.log('Restarting now.');
        return 0;
      }
      const threads = await listAll(client);
      console.log(`The runner will restart when ${plural(r.waitingFor.length, 'thread finishes', 'threads finish')}:`);
      for (const id of r.waitingFor) console.log(`  ${threadLine(id, threads)}`);
      return 0;
    }
    case 'show': {
      const id = await resolveId(args[0]);
      const t = await threadById(client, id);
      const last = f.last !== undefined ? Number(f.last) : undefined;
      if (last !== undefined && !(Number.isInteger(last) && last > 0)) throw new Error('--last takes a whole number above 0');
      process.stdout.write(formatThread(t, await allEvents(client, id), { last, tools: Boolean(f.tools) }));
      return 0;
    }
    case 'export': {
      const id = await resolveId(args[0]);
      const t = await threadById(client, id);
      const out = typeof f.out === 'string' ? path.resolve(f.out) : defaultExportDir(id);
      const r = exportThread(t, await allEvents(client, id), out);
      console.log(`Exported ${plural(r.events, 'event', 'events')} and ${plural(r.media, 'image', 'images')} to ${out}`);
      // --fixtures loads just this one (and anything else exported beside
      // it), without the mock's own sample threads.
      const mock = path.join(findRepoRoot() ?? '.', 'app', 'Tools', 'mock-runner', 'server.mjs');
      console.log(`Load it with: node ${shQuote(mock)} --data-dir "$(mktemp -d)" --fixtures ${shQuote(path.dirname(out))}`);
      return 0;
    }
    case 'rpc': {
      if (!args[0]) throw new Error('method required');
      let params: unknown = {};
      if (args[1] !== undefined) {
        try {
          params = JSON.parse(args[1]);
        } catch {
          throw new Error(`Params aren't JSON: ${args[1]}`);
        }
      }
      if (!params || typeof params !== 'object' || Array.isArray(params)) throw new Error('Params must be a JSON object');
      return printJson(await client.call(args[0], params as Record<string, unknown>));
    }
    default:
      return undefined;
  }
}

// For commands printed to paste into a shell; the default data dir has a space.
function shQuote(s: string): string {
  return /^[\w@%+=:,./-]+$/.test(s) ? s : `'${s.replace(/'/g, `'\\''`)}'`;
}

function printJson(v: unknown): number {
  console.log(JSON.stringify(v, null, 2));
  return 0;
}

// A runner from before runner.status and runner.restart answers "method
// not found". tb says so and exits 3, so deploy-runner.sh can fall back to
// waiting for idle and restarting it from launchd.
const TOO_OLD = 3;

function tooOld(e: unknown): undefined {
  if (e instanceof RpcClientError && e.code === ErrorCode.methodNotFound) {
    console.error("This runner is too old for runner.status and runner.restart; it has to be restarted from launchd.");
    return undefined;
  }
  throw e;
}

async function listAll(client: RunnerClient): Promise<ThreadSummary[]> {
  return (await client.call<{ threads: ThreadSummary[] }>('threads.list', { include: ALL })).threads;
}

async function threadById(client: RunnerClient, id: string): Promise<ThreadSummary> {
  const t = (await listAll(client)).find((x) => x.id === id);
  if (!t) throw new Error(`Thread not found: ${id}`);
  return t;
}

// Every event, a page at a time (the runner gives at most 10,000 a call).
export async function allEvents(client: RunnerClient, threadId: string): Promise<PersistedEvent[]> {
  const out: PersistedEvent[] = [];
  const limit = 10_000;
  for (let after = 0; ; ) {
    const r = await client.call<{ events: PersistedEvent[] }>('threads.events', { threadId, afterSeq: after, limit });
    out.push(...r.events);
    if (r.events.length < limit) return out;
    after = r.events[r.events.length - 1].seq;
  }
}

// ------------------------------------------------------------- formatting

function plural(n: number, one: string, many: string): string {
  return `${n} ${n === 1 ? one : many}`;
}

export function duration(ms: number): string {
  const s = Math.max(0, Math.floor(ms / 1000));
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ${m % 60}m`;
  return `${Math.floor(h / 24)}d ${h % 24}h`;
}

function threadLine(id: string, threads: ThreadSummary[]): string {
  const t = threads.find((x) => x.id === id);
  return t ? `${id.slice(0, 8)}  ${t.title}  [${t.status}]` : id.slice(0, 8);
}

export function formatStatus(s: RunnerStatus, threads: ThreadSummary[], now: number): string {
  const lines = [`Runner ${s.version}, pid ${s.pid}, up ${duration(now - Date.parse(s.startedAt))}`, `Data dir: ${s.home}`];
  if (s.logFile) lines.push(`Log: ${s.logFile}`);
  lines.push(`Live CLIs: ${s.liveClis}`);
  lines.push(s.running.length ? `Busy threads: ${s.running.length}` : 'Busy threads: none');
  for (const id of s.running) lines.push(`  ${threadLine(id, threads)}`);
  const p = s.pendingRestart;
  if (p) {
    const waiting = p.waitingFor?.length ?? 0;
    let line = `Restart pending: ${p.when === 'now' ? 'now' : 'when idle'}, asked ${duration(now - Date.parse(p.requestedAt))} ago`;
    if (waiting) line += `, waiting for ${plural(waiting, 'thread', 'threads')}`;
    lines.push(line);
    if (p.reason) lines.push(`  Reason: ${p.reason}`);
    if (p.resumeThreadId) lines.push(`  Then carries on: ${threadLine(p.resumeThreadId, threads)}`);
  }
  return lines.join('\n') + '\n';
}

function access(t: ThreadSummary): string {
  return t.permissionMode === 'ask' ? 'asks before edits' : 'full access';
}

export function formatSelf(t: ThreadSummary): string {
  const lines = [
    t.id,
    t.title,
    `Status: ${t.status}${t.live ? ', CLI live' : ''}`,
    `Account: ${t.accountId}, ${t.model ? `model ${t.model}` : 'default model'}, ${access(t)}`,
    `Folder: ${t.cwd}`,
    `Events: ${t.lastSeq}`,
  ];
  if (t.costUsd !== undefined) lines.push(`Cost so far: $${t.costUsd.toFixed(4)}`);
  if (t.contextTokens !== undefined) lines.push(`Context: ${t.contextTokens} tokens`);
  return lines.join('\n') + '\n';
}

// The last n turns, with any notes just before the first of them (the
// "Runner restarted" note sits right before the turn it explains).
export function lastTurns(events: PersistedEvent[], n: number): { events: PersistedEvent[]; hidden: number } {
  const starts: number[] = [];
  const seen = new Set<string>();
  events.forEach((e, i) => {
    if (e.turnId && !seen.has(e.turnId)) {
      seen.add(e.turnId);
      starts.push(i);
    }
  });
  if (starts.length <= n) return { events, hidden: 0 };
  let from = starts[starts.length - n];
  while (from > 0 && !events[from - 1].turnId) from--;
  return { events: events.slice(from), hidden: starts.length - n };
}

const RESULT_LINES = 20;
const DIFF_LINES = 40;

function block(label: string, text: string, indent: string): string[] {
  const [first, ...rest] = text.split('\n');
  return [`${label}${first}`, ...rest.map((l) => (l ? indent + l : ''))];
}

function capped(lines: string[], max: number, indent: string): string[] {
  const out = lines.slice(0, max).map((l) => indent + l);
  if (lines.length > max) out.push(`${indent}... ${plural(lines.length - max, 'more line', 'more lines')}`);
  return out;
}

function imageLine(img: ImageRef, indent: string): string {
  return `${indent}[image: ${img.path}${img.width && img.height ? `, ${img.width}x${img.height}` : ''}]`;
}

const DECISIONS: Record<string, string> = {
  allow: 'allowed',
  allowAlways: 'always allowed',
  deny: 'denied',
  answered: 'answered',
  expired: 'expired',
};

// The thread as plain text, for an agent (or Mike) to read: messages, one
// line per tool call, approvals, notes and turn footers. tools adds tool
// results, diffs and thinking summaries.
export function formatThread(t: ThreadSummary, events: PersistedEvent[], opts: { last?: number; tools?: boolean } = {}): string {
  const lines = [t.title, `${t.id}, ${t.status}, ${t.accountId}${t.model ? `, ${t.model}` : ''}, ${access(t)}, in ${t.cwd}`];
  const { events: shown, hidden } = opts.last ? lastTurns(events, opts.last) : { events, hidden: 0 };
  if (hidden) lines.push(`(${plural(hidden, 'earlier turn', 'earlier turns')} not shown)`);
  const results = new Map<string, Extract<PersistedEvent, { type: 'tool.result' }>>();
  for (const e of shown) if (e.type === 'tool.result') results.set(e.itemId, e);
  for (const e of shown) {
    switch (e.type) {
      case 'user.message':
        lines.push('', ...block(e.origin === 'runner' ? 'Runner: ' : 'User: ', e.text, '  '));
        for (const img of e.images ?? []) lines.push(imageLine(img, '  '));
        break;
      case 'assistant.text':
        lines.push('', ...block('Assistant: ', e.text, '  '));
        break;
      case 'reasoning':
        if (opts.tools) lines.push(`  (thinking) ${e.text.split('\n')[0].slice(0, 200)}`);
        break;
      case 'tool.call': {
        const r = results.get(e.itemId);
        lines.push(`  - ${e.title}${r && !r.ok ? ' (failed)' : ''}`);
        break;
      }
      case 'tool.result':
        if (!opts.tools) break;
        lines.push(...capped((e.text || '(no output)').split('\n'), RESULT_LINES, '      '));
        if (e.truncated) lines.push(`      (cut short${e.blobPath ? `; all of it is in ${e.blobPath}` : ''})`);
        for (const img of e.images ?? []) lines.push(imageLine(img, '      '));
        break;
      case 'edit.diff':
        if (opts.tools) lines.push(...capped(e.hunks.flatMap((h) => h.lines), DIFF_LINES, '      '));
        break;
      case 'approval.requested':
        lines.push(`  Approval asked: ${e.title}`);
        break;
      case 'question.requested':
        for (const q of e.questions) {
          lines.push(`  Question: ${q.question}${q.options.length ? ` (${q.options.map((o) => o.label).join(' / ')})` : ''}`);
        }
        break;
      case 'approval.resolved':
        lines.push(`  Answer: ${DECISIONS[e.decision] ?? e.decision}${e.message ? `: ${e.message}` : ''}`);
        break;
      case 'plan.updated':
        lines.push('  Plan:');
        for (const x of e.entries) lines.push(`    [${x.status === 'completed' ? 'x' : x.status === 'in_progress' ? '>' : ' '}] ${x.text}`);
        break;
      case 'turn.started':
        break;
      case 'turn.completed': {
        const cost = e.costUsd !== undefined ? `, $${e.costUsd.toFixed(4)}` : '';
        lines.push(`  (${e.outcome}, ${(e.durationMs / 1000).toFixed(1)}s${cost}${e.error ? `: ${e.error}` : ''})`);
        break;
      }
      case 'system.note':
        lines.push(...block('  Note: ', e.text, '    '));
        break;
      case 'error':
        lines.push(...block('  Error: ', e.message, '    '));
        break;
      default:
        lines.push(`  (${(e as { type: string }).type})`);
    }
  }
  return lines.join('\n') + '\n';
}

// ----------------------------------------------------------------- export

// The checkout to put fixtures in: the one the command runs in, else the
// one this tb belongs to (a release snapshot has no app/ folder).
export function findRepoRoot(starts: string[] = [process.cwd(), path.resolve(import.meta.dirname, '..', '..')]): string | undefined {
  for (const start of starts) {
    for (let d = path.resolve(start); ; d = path.dirname(d)) {
      if (fs.existsSync(path.join(d, 'app', 'Tools', 'mock-runner', 'server.mjs'))) return d;
      if (path.dirname(d) === d) break;
    }
  }
  return undefined;
}

function defaultExportDir(id: string): string {
  const root = findRepoRoot();
  if (!root) throw new Error("Couldn't find a Threadbare checkout to export into; pass --out DIR.");
  return path.join(root, 'app', '.fixtures', 'threads', id);
}

// Writes the thread the way app/Tools/mock-runner/server.mjs reads a
// fixture: thread.json (the summary), events.ndjson, and the images under
// media/ with paths relative to the fixture folder. Images that are gone
// keep their old path.
export function exportThread(t: ThreadSummary, events: PersistedEvent[], out: string): { events: number; media: number } {
  const mediaDir = path.join(out, 'media');
  fs.mkdirSync(mediaDir, { recursive: true });
  const copied = new Map<string, string>();
  const names = new Set<string>();
  const localise = (img: ImageRef): ImageRef => {
    if (!img?.path || !path.isAbsolute(img.path)) return img;
    let rel = copied.get(img.path);
    if (!rel) {
      if (!fs.existsSync(img.path)) return img;
      const base = path.basename(img.path);
      let name = base;
      for (let i = 2; names.has(name); i++) name = `${i}-${base}`;
      names.add(name);
      fs.copyFileSync(img.path, path.join(mediaDir, name));
      rel = `media/${name}`;
      copied.set(img.path, rel);
    }
    return { ...img, path: rel };
  };
  const lines = events.map((e) => {
    const images = (e as { images?: ImageRef[] }).images;
    return JSON.stringify(Array.isArray(images) ? { ...e, images: images.map(localise) } : e);
  });
  fs.writeFileSync(path.join(out, 'events.ndjson'), lines.map((l) => l + '\n').join(''));
  // The mock has no CLI behind it.
  fs.writeFileSync(path.join(out, 'thread.json'), JSON.stringify({ ...t, live: false }, null, 2) + '\n');
  return { events: events.length, media: copied.size };
}

// ------------------------------------------------------------------- logs

// tb logs works with the runner down (that's when it's needed most), so it
// runs before tb connects. The file is THREADBARE_LOG, else the one the
// runner says it writes, else the default.
export async function logsCommand(cfg: Config, f: Flags): Promise<number> {
  const file = process.env.THREADBARE_LOG ? cfg.logFile : ((await runnerLogFile(cfg)) ?? cfg.logFile);
  const n = f.lines !== undefined ? Number(f.lines) : 200;
  if (!Number.isInteger(n) || n < 0) throw new Error('-n takes a whole number');
  const filter = typeof f.thread === 'string' && f.thread ? f.thread : undefined;
  if (!fs.existsSync(file)) {
    if (!f.follow) {
      console.error(`No log at ${file}`);
      return 1;
    }
  } else {
    for (const line of lastLines(file, n, filter)) console.log(line);
  }
  if (!f.follow) return 0;
  await follow(file, filter);
  return 0;
}

async function runnerLogFile(cfg: Config): Promise<string | undefined> {
  const url = runnerUrl(cfg);
  let client: RunnerClient | undefined;
  let timer: NodeJS.Timeout | undefined;
  try {
    client = new RunnerClient(url, readToken(cfg.home));
    const c = client;
    const timeout = new Promise<never>((_, reject) => (timer = setTimeout(() => reject(new Error('timeout')), 1500)));
    const s = await Promise.race([c.opened.then(() => c.call<RunnerStatus>('runner.status')), timeout]);
    return typeof s.logFile === 'string' ? s.logFile : undefined;
  } catch {
    return undefined;
  } finally {
    clearTimeout(timer);
    client?.close();
  }
}

// The last n lines (that contain filter, if given), reading back from the
// end a block at a time so a big log isn't read whole.
export function lastLines(file: string, n: number, filter?: string): string[] {
  if (n === 0) return [];
  const fd = fs.openSync(file, 'r');
  try {
    let pos = fs.fstatSync(fd).size;
    let tail = '';
    let found: string[] = [];
    const BLOCK = 64 * 1024;
    while (pos > 0) {
      const len = Math.min(BLOCK, pos);
      pos -= len;
      const buf = Buffer.alloc(len);
      fs.readSync(fd, buf, 0, len, pos);
      // latin1 keeps one char per byte, so a UTF-8 character split across
      // two blocks comes back whole when the line is decoded at the end.
      const parts = (buf.toString('latin1') + tail).split('\n');
      // The first piece may be the end of a line that starts further back.
      tail = pos > 0 ? parts.shift()! : '';
      found = parts.filter((l) => l && (!filter || l.includes(filter))).concat(found);
      if (found.length >= n) break;
    }
    return found.slice(-n).map((l) => Buffer.from(l, 'latin1').toString('utf8'));
  } finally {
    fs.closeSync(fd);
  }
}

// Prints lines as they're added, until interrupted. A log that shrinks
// (rotated or cleared) is read again from the start.
function follow(file: string, filter?: string): Promise<void> {
  let pos = fs.existsSync(file) ? fs.statSync(file).size : 0;
  let partial = '';
  return new Promise((resolve) => {
    const timer = setInterval(() => {
      let size: number;
      try {
        size = fs.statSync(file).size;
      } catch {
        return;
      }
      if (size < pos) {
        pos = 0;
        partial = '';
      }
      if (size === pos) return;
      const fd = fs.openSync(file, 'r');
      try {
        const buf = Buffer.alloc(size - pos);
        fs.readSync(fd, buf, 0, buf.length, pos);
        pos = size;
        const parts = (partial + buf.toString('utf8')).split('\n');
        partial = parts.pop() ?? '';
        for (const l of parts) if (l && (!filter || l.includes(filter))) console.log(l);
      } finally {
        fs.closeSync(fd);
      }
    }, 250);
    const stop = () => {
      clearInterval(timer);
      resolve();
    };
    process.once('SIGINT', stop);
    process.once('SIGTERM', stop);
  });
}
