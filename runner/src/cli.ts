// tb: a small command line client for testing and scripting the runner.
import { parseArgs } from 'node:util';
import path from 'node:path';
import { loadConfig, readToken, runnerUrl } from './config.ts';
import { RunnerClient } from './client.ts';
import type { ImageRef, PersistedEvent, ThreadSummary } from './protocol.ts';
import { DEV_HELP, logsCommand, runDev } from './tb-dev.ts';

const HELP = `tb: talk to the Threadbare runner

  tb new "text" [--cwd DIR] [--account ID] [--model M] [--ask] [--image FILE]... [--wait]
  tb send <threadId> "text" [--image FILE]... [--wait]
  tb list [--snoozed] [--archived] [--all] [--json]
  tb search "words" [--json]
  tb tail <threadId> [--from SEQ] [--json] [--until-done]
  tb events <threadId> [--json]
  tb interrupt <threadId>
  tb approve <threadId> <approvalId> [allow|allowAlways|deny]
  tb answer <threadId> <approvalId> "answer"
  tb snooze <threadId> <ISO time or 30m, 2h, 1d>
  tb archive <threadId>      tb unarchive <threadId>
  tb accounts

Thread ids can be shortened to any unique prefix.
Uses THREADBARE_HOME and THREADBARE_PORT like the runner does.

${DEV_HELP}`;

async function main(argv: string[]): Promise<number> {
  const { values, positionals } = parseArgs({
    args: argv,
    allowPositionals: true,
    options: {
      cwd: { type: 'string' },
      account: { type: 'string' },
      model: { type: 'string' },
      ask: { type: 'boolean' },
      image: { type: 'string', multiple: true },
      wait: { type: 'boolean' },
      json: { type: 'boolean' },
      snoozed: { type: 'boolean' },
      archived: { type: 'boolean' },
      all: { type: 'boolean' },
      from: { type: 'string' },
      'until-done': { type: 'boolean' },
      // tb-dev.ts
      last: { type: 'string' },
      tools: { type: 'boolean' },
      out: { type: 'string' },
      now: { type: 'boolean' },
      force: { type: 'boolean' },
      resume: { type: 'string' },
      'no-resume': { type: 'boolean' },
      cancel: { type: 'boolean' },
      reason: { type: 'string' },
      thread: { type: 'string' },
      lines: { type: 'string', short: 'n' },
      follow: { type: 'boolean', short: 'f' },
      help: { type: 'boolean', short: 'h' },
    },
  });
  const [cmd, ...args] = positionals;
  if (!cmd || values.help) {
    console.log(HELP);
    return cmd ? 0 : 1;
  }
  const cfg = loadConfig();
  if (cmd === 'logs') return logsCommand(cfg, values);
  const url = runnerUrl(cfg);
  let client: RunnerClient;
  try {
    client = await RunnerClient.connect(url, readToken(cfg.home));
  } catch (e) {
    console.error(`Couldn't reach the runner at ${url}: ${(e as Error).message}`);
    return 2;
  }
  try {
    await client.call('hello', { client: 'tb', version: '1' });
    return await run(client, cmd, args, values);
  } catch (e) {
    console.error((e as Error).message);
    return 1;
  } finally {
    client.close();
  }
}

type Flags = Record<string, string | boolean | string[] | undefined>;

async function run(client: RunnerClient, cmd: string, args: string[], f: Flags): Promise<number> {
  const images = async (): Promise<ImageRef[]> => {
    const out: ImageRef[] = [];
    for (const p of (f.image as string[] | undefined) ?? []) {
      const r = await client.call<{ image: ImageRef }>('media.import', { path: path.resolve(p) });
      out.push(r.image);
    }
    return out;
  };
  switch (cmd) {
    case 'new': {
      const params: Record<string, unknown> = { text: args[0] ?? '', images: await images() };
      if (f.cwd) params.cwd = path.resolve(String(f.cwd));
      if (f.account) params.accountId = f.account;
      if (f.model) params.model = f.model;
      if (f.ask) params.permissionMode = 'ask';
      const r = await client.call<{ thread: ThreadSummary; turnId: string }>('threads.create', params);
      console.log(r.thread.id);
      if (f.wait) return tail(client, r.thread.id, { from: 0, json: Boolean(f.json), untilTurn: r.turnId });
      return 0;
    }
    case 'send': {
      const id = await resolveId(client, args[0]);
      // The newest seq before sending, so the tail starts with this message.
      // (threads.events, not markSeen, which would mark the thread read.)
      const before = f.wait ? (await client.call<{ lastSeq: number }>('threads.events', { threadId: id, limit: 1 })).lastSeq : 0;
      const r = await client.call<{ turnId: string }>('threads.send', { threadId: id, text: args[1] ?? '', images: await images() });
      if (f.wait) return tail(client, id, { from: before, json: Boolean(f.json), untilTurn: r.turnId });
      console.log(r.turnId);
      return 0;
    }
    case 'list': {
      const include = f.all ? ['inbox', 'snoozed', 'archived'] : f.archived ? ['archived'] : f.snoozed ? ['snoozed'] : ['inbox'];
      const r = await client.call<{ threads: ThreadSummary[] }>('threads.list', { include });
      printThreads(r.threads, Boolean(f.json));
      return 0;
    }
    case 'search': {
      const r = await client.call<{ threads: ThreadSummary[] }>('threads.search', { query: args.join(' ') });
      printThreads(r.threads, Boolean(f.json));
      return 0;
    }
    case 'tail': {
      const id = await resolveId(client, args[0]);
      return tail(client, id, { from: f.from !== undefined ? Number(f.from) : undefined, json: Boolean(f.json), untilDone: Boolean(f['until-done']) });
    }
    case 'events': {
      const id = await resolveId(client, args[0]);
      const r = await client.call<{ events: PersistedEvent[] }>('threads.events', { threadId: id, limit: 10_000 });
      for (const e of r.events) printEvent(e, Boolean(f.json));
      return 0;
    }
    case 'interrupt':
      await client.call('threads.interrupt', { threadId: await resolveId(client, args[0]) });
      return 0;
    case 'approve':
    case 'answer': {
      const threadId = await resolveId(client, args[0]);
      const params: Record<string, unknown> = { threadId, approvalId: await resolveApproval(client, threadId, args[1]) };
      if (cmd === 'approve') params.decision = args[2] ?? 'allow';
      else Object.assign(params, { decision: 'answered', answers: { '0': args[2] ?? '' } });
      await client.call('approvals.respond', params);
      return 0;
    }
    case 'snooze': {
      const id = await resolveId(client, args[0]);
      const until = parseWhen(args[1] ?? '1h');
      const r = await client.call<{ thread: ThreadSummary }>('threads.update', { threadId: id, snoozedUntil: until });
      console.log(`snoozed until ${r.thread.snoozedUntil}`);
      return 0;
    }
    case 'archive':
    case 'unarchive':
      await client.call('threads.update', { threadId: await resolveId(client, args[0]), archived: cmd === 'archive' });
      return 0;
    case 'accounts': {
      const r = await client.call<{ accounts: { id: string; title: string }[]; defaults: { accountId: string; cwd: string } }>('hello', {
        client: 'tb',
        version: '1',
      });
      for (const a of r.accounts) console.log(`${a.id === r.defaults.accountId ? '*' : ' '} ${a.id.padEnd(12)} ${a.title}`);
      return 0;
    }
    default: {
      const code = await runDev(client, cmd, args, f, (prefix) => resolveId(client, prefix));
      if (code !== undefined) return code;
      console.error(`Unknown command: ${cmd}\n\n${HELP}`);
      return 1;
    }
  }
}

async function resolveId(client: RunnerClient, prefix: string | undefined): Promise<string> {
  if (!prefix) throw new Error('thread id required');
  const r = await client.call<{ threads: ThreadSummary[] }>('threads.list', { include: ['inbox', 'snoozed', 'archived'] });
  const hits = r.threads.filter((t) => t.id.startsWith(prefix));
  if (hits.length === 1) return hits[0].id;
  if (hits.length === 0) return prefix;
  throw new Error(`${prefix} matches ${hits.length} threads`);
}

// An approval id, or the start of one (tb show prints the first 8
// characters), among the thread's approvals that haven't been answered.
async function resolveApproval(client: RunnerClient, threadId: string, prefix: string | undefined): Promise<string> {
  if (!prefix) throw new Error('approval id required');
  const { events } = await client.call<{ events: PersistedEvent[] }>('threads.events', { threadId, limit: 10_000 });
  const resolved = new Set(events.flatMap((e) => (e.type === 'approval.resolved' ? [e.approvalId] : [])));
  const open = events.flatMap((e) => ((e.type === 'approval.requested' || e.type === 'question.requested') && !resolved.has(e.approvalId) ? [e.approvalId] : []));
  if (open.includes(prefix)) return prefix;
  const hits = open.filter((id) => id.startsWith(prefix));
  if (hits.length === 1) return hits[0];
  if (hits.length > 1) throw new Error(`${prefix} matches ${hits.length} open approvals`);
  return prefix;
}

function parseWhen(s: string): string {
  const m = /^(\d+)([mhd])$/.exec(s);
  if (m) {
    const ms = Number(m[1]) * { m: 60_000, h: 3_600_000, d: 86_400_000 }[m[2] as 'm' | 'h' | 'd'];
    return new Date(Date.now() + ms).toISOString();
  }
  const t = Date.parse(s);
  if (Number.isNaN(t)) throw new Error(`Can't read the time ${s}`);
  return new Date(t).toISOString();
}

function printThreads(threads: ThreadSummary[], json: boolean): void {
  if (json) {
    console.log(JSON.stringify(threads, null, 2));
    return;
  }
  for (const t of threads) {
    const flags = [t.status, t.live ? 'live' : '', t.needsYou ? 'needs you' : ''].filter(Boolean).join(', ');
    console.log(`${t.id.slice(0, 8)}  ${t.title}  [${flags}]  ${t.accountId}`);
    if (t.preview) console.log(`          ${t.preview}`);
  }
}

let midLine = false;
const streamed = new Set<string>();

function printEvent(e: any, json: boolean): void {
  if (json) {
    console.log(JSON.stringify(e));
    return;
  }
  const out = (s: string) => {
    if (midLine) process.stdout.write('\n');
    midLine = false;
    console.log(s);
  };
  switch (e.type) {
    case 'assistant.text.delta':
      process.stdout.write(e.text);
      streamed.add(e.itemId);
      midLine = true;
      return;
    case 'reasoning.delta':
      return;
    case 'user.message':
      return out(`\n> ${e.text}${e.images?.length ? ` [${e.images.length} image(s)]` : ''}`);
    case 'assistant.text':
      // Already shown as it streamed.
      if (streamed.has(e.itemId)) {
        if (midLine) process.stdout.write('\n');
        midLine = false;
        return;
      }
      return out(e.text);
    case 'reasoning':
      return out(`(thinking) ${e.text.split('\n')[0]}`);
    case 'tool.call':
      return out(`- ${e.title}`);
    case 'tool.result':
      return out(`  ${e.ok ? 'ok' : 'failed'}: ${String(e.text).split('\n')[0].slice(0, 120)}${e.images?.length ? ` [${e.images.length} image(s)]` : ''}`);
    case 'edit.diff':
      return out(e.hunks.flatMap((h: { lines: string[] }) => h.lines).map((l: string) => `  ${l}`).join('\n'));
    case 'approval.requested':
      return out(`? approve ${e.title}: tb approve ${e.threadId.slice(0, 8)} ${e.approvalId} allow|deny`);
    case 'question.requested':
      return out(`? ${e.questions.map((q: { question: string }) => q.question).join(' / ')}: tb answer ${e.threadId.slice(0, 8)} ${e.approvalId} "..."`);
    case 'approval.resolved':
      return out(`  (${e.decision})`);
    case 'plan.updated':
      return out(e.entries.map((x: { status: string; text: string }) => `  [${x.status === 'completed' ? 'x' : x.status === 'in_progress' ? '>' : ' '}] ${x.text}`).join('\n'));
    case 'turn.started':
      return;
    case 'turn.completed':
      return out(`(${e.outcome}, ${(e.durationMs / 1000).toFixed(1)}s${e.costUsd !== undefined ? `, $${e.costUsd.toFixed(4)}` : ''}${e.error ? `: ${e.error}` : ''})`);
    case 'system.note':
      return out(`(${e.text})`);
    case 'error':
      return out(`error: ${e.message}`);
    default:
      return out(`(${e.type})`);
  }
}

async function tail(
  client: RunnerClient,
  threadId: string,
  opts: { from?: number; json: boolean; untilTurn?: string; untilDone?: boolean },
): Promise<number> {
  return new Promise((resolve) => {
    const done = (code: number) => {
      if (midLine) process.stdout.write('\n');
      resolve(code);
    };
    // --until-done waits for the turn running now, so an old
    // turn.completed in the backlog doesn't end the tail; with no turn
    // running it stops after the backlog.
    let running: string | undefined;
    let backlogDone = false;
    const check = (e: any, live: boolean) => {
      if (e.type === 'turn.started') running = e.turnId;
      if (e.type !== 'turn.completed') return;
      if (e.turnId === running) running = undefined;
      const end = opts.untilTurn ? e.turnId === opts.untilTurn : opts.untilDone && (live || backlogDone) && !running;
      if (end) done(e.outcome === 'failed' ? 1 : 0);
    };
    const held: any[] = [];
    client.onNotification((method, params) => {
      if (method !== 'thread.event' || params.threadId !== threadId) return;
      // Live events can land before the subscribe reply; keep them in order.
      if (!backlogDone) return void held.push(params.event);
      printEvent(params.event, opts.json);
      check(params.event, true);
    });
    client
      .call<{ events: PersistedEvent[] }>('threads.subscribe', { threadId, afterSeq: opts.from ?? 0 })
      .then(async (r) => {
        for (const e of r.events) {
          printEvent(e, opts.json);
          check(e, false);
        }
        const last = r.events.at(-1)?.seq ?? opts.from ?? 0;
        backlogDone = true;
        for (const e of held) {
          // Already in the backlog (a delta older than the backlog's last
          // event belongs to an item the backlog already holds).
          if (e.type.endsWith('.delta') ? e.seq < last : e.seq <= last) continue;
          printEvent(e, opts.json);
          check(e, true);
        }
        held.length = 0;
        if (opts.untilDone && !opts.untilTurn && !running) {
          // Nothing running: is the thread busy at all?
          const t = (await client.call<{ threads: ThreadSummary[] }>('threads.list', { include: ['inbox', 'snoozed', 'archived'] })).threads.find((x) => x.id === threadId);
          if (!t || !['starting', 'running', 'waiting'].includes(t.status)) done(0);
        }
      })
      .catch((e: Error) => {
        console.error(e.message);
        done(1);
      });
  });
}

main(process.argv.slice(2)).then((code) => process.exit(code));
