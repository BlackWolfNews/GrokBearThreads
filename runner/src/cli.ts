// tb: a small command line client for testing and scripting the runner.
import { parseArgs } from 'node:util';
import path from 'node:path';
import { loadConfig, readToken, runnerUrl } from './config.ts';
import { RunnerClient } from './client.ts';
import type { ImageRef, PersistedEvent, ThreadSummary } from './protocol.ts';
import { DEV_HELP, logsCommand, runDev } from './tb-dev.ts';

const OPTIONS = {
  cwd: { type: 'string' },
  account: { type: 'string' },
  model: { type: 'string' },
  effort: { type: 'string' },
  ask: { type: 'boolean' },
  image: { type: 'string', multiple: true },
  wait: { type: 'boolean' },
  json: { type: 'boolean' },
  snoozed: { type: 'boolean' },
  archived: { type: 'boolean' },
  all: { type: 'boolean' },
  from: { type: 'string' },
  to: { type: 'string' },
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
  'max-wait': { type: 'string' },
  lines: { type: 'string', short: 'n' },
  follow: { type: 'boolean', short: 'f' },
  help: { type: 'boolean', short: 'h' },
} as const;

const HELP = `tb: talk to the Threadbare runner

  tb new "text" [--cwd DIR] [--account ID] [--model M] [--effort L] [--ask] [--image FILE]... [--wait]
  tb send <threadId> "text" [--image FILE]... [--wait]
  tb list [--snoozed] [--archived] [--all] [--json]
  tb search "words" [--json]
  tb tail <threadId> [--from SEQ] [--json] [--until-done]
  tb events <threadId> [--from SEQ] [--to SEQ] [--json]
                                  each event with its seq first (Copy debug info's "events: 5-9")
  tb interrupt <threadId>
  tb approve <threadId> <approvalId> [allow|allowAlways|deny]
  tb answer <threadId> <approvalId> "answer"
  tb snooze <threadId> <ISO time or 30m, 2h, 1d>
  tb archive <threadId>      tb unarchive <threadId>
  tb move <threadId> <folder>
  tb delete <threadId>
  tb accounts
  tb actions <threadId> [--json]  the thread's actions, panels and patches (from its folder)
  tb run <threadId> <actionId>    run one: a command's output is printed and goes into the thread

Thread ids can be shortened to any unique prefix.
Uses THREADBARE_HOME and THREADBARE_PORT like the runner does.

${DEV_HELP}`;

// The flags each command reads. Any other is refused rather than ignored:
// `tb events <id> --from 3` used to print every event as if it had worked.
const COMMAND_FLAGS: Record<string, string[]> = {
  new: ['cwd', 'account', 'model', 'effort', 'ask', 'image', 'wait', 'json'],
  send: ['image', 'wait', 'json'],
  list: ['snoozed', 'archived', 'all', 'json'],
  search: ['json'],
  tail: ['from', 'json', 'until-done'],
  events: ['from', 'to', 'json'],
  interrupt: [],
  approve: [],
  answer: [],
  snooze: [],
  archive: [],
  unarchive: [],
  move: [],
  delete: [],
  accounts: [],
  status: ['json'],
  self: ['json'],
  restart: ['now', 'force', 'resume', 'no-resume', 'cancel', 'reason', 'thread', 'max-wait'],
  show: ['last', 'tools'],
  logs: ['lines', 'follow', 'thread'],
  export: ['out'],
  rpc: [],
};

// Read but never listed when a command refuses a flag: an agent that sees
// --force in "It takes ..." learns to cut every thread's work short (tb
// restart --now --force) or withdraw someone else's deploy.
const HIDDEN_FLAGS = new Set(['force']);

// `tb show --help`: the help lines for that command (its usage line and
// the indented lines under it), or undefined for a command it doesn't know.
function commandHelp(cmd: string, help = HELP): string | undefined {
  const lines = help.split('\n');
  const out: string[] = [];
  for (let i = 0; i < lines.length; i++) {
    const name = cmd.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    if (!new RegExp(`^\\s*tb ${name}(\\s|$)`).test(lines[i]) && !lines[i].includes(`tb ${cmd} <`)) continue;
    out.push(lines[i]);
    // The lines that carry on its description are indented past the usage.
    while (i + 1 < lines.length && /^ {6,}\S/.test(lines[i + 1]) && !/^\s*tb /.test(lines[i + 1])) out.push(lines[++i]);
  }
  return out.length ? out.join('\n') : undefined;
}

async function main(argv: string[]): Promise<number> {
  let parsed;
  try {
    parsed = parseArgs({ args: argv, allowPositionals: true, options: OPTIONS });
  } catch (e) {
    // A typo or a flag with no value: say which, not a stack trace.
    console.error(`${(e as Error).message}\nSee tb --help.`);
    return 2;
  }
  const { values, positionals } = parsed;
  const [cmd, ...args] = positionals;
  if (!cmd || values.help) {
    console.log((cmd && commandHelp(cmd)) || HELP);
    return cmd ? 0 : 1;
  }
  const allowed = COMMAND_FLAGS[cmd];
  if (allowed) {
    const wrong = Object.keys(values).filter((k) => values[k as keyof typeof values] !== undefined && !allowed.includes(k));
    if (wrong.length) {
      const names = wrong.map((k) => `--${k}`).join(', ');
      const shown = allowed.filter((k) => !HIDDEN_FLAGS.has(k));
      console.error(`tb ${cmd} doesn't take ${names}.${shown.length ? ` It takes ${shown.map((k) => `--${k}`).join(', ')}.` : ''}\nSee tb ${cmd} --help.`);
      return 2;
    }
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
      if (f.effort) params.effort = f.effort;
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
      const from = seqFlag(f.from, '--from');
      const to = seqFlag(f.to, '--to');
      if (from !== undefined && to !== undefined && to < from) throw new Error('--to is before --from');
      const params: Record<string, unknown> = { threadId: id, limit: 10_000 };
      if (from !== undefined) params.afterSeq = from - 1;
      if (to !== undefined) params.beforeSeq = to + 1;
      const r = await client.call<{ events: PersistedEvent[] }>('threads.events', params);
      // Each line starts with its seq, so the seqs in Copy debug info and
      // an export's events.ndjson can be matched up.
      for (const e of r.events) printEvent(e, Boolean(f.json), f.json ? '' : `${String(e.seq).padStart(5)}  `);
      return 0;
    }
    case 'interrupt': {
      const id = notSelf(await resolveId(client, args[0]), "That's the thread this runs in. Just end the turn.");
      await client.call('threads.interrupt', { threadId: id });
      return 0;
    }
    case 'approve':
    case 'answer': {
      // Its own cards are Mike's to answer: delete_thread always asks him,
      // and an edit in an ask-before-edits thread waits for him.
      const threadId = notSelf(await resolveId(client, args[0]), "That's this thread's own card; Mike answers it.");
      const params: Record<string, unknown> = { threadId, approvalId: await resolveApproval(client, threadId, args[1]) };
      if (cmd === 'approve') params.decision = args[2] ?? 'allow';
      else Object.assign(params, { decision: 'answered', answers: { '0': args[2] ?? '' } });
      await client.call('approvals.respond', params);
      return 0;
    }
    case 'move': {
      const id = await resolveId(client, args[0]);
      if (!args[1]) throw new Error('folder required');
      const r = await client.call<{ thread: ThreadSummary }>('threads.update', { threadId: id, cwd: path.resolve(args[1]) });
      console.log(`moved to ${r.thread.cwd} (from the next message)`);
      return 0;
    }
    case 'delete': {
      const id = notSelf(await resolveId(client, args[0]), "A thread can't delete itself. Ask Mike to.");
      await client.call('threads.delete', { threadId: id });
      console.log(`deleted ${id}`);
      return 0;
    }
    case 'snooze': {
      const id = notSelf(await resolveId(client, args[0]), STOPS_SELF);
      const until = parseWhen(args[1] ?? '1h');
      const r = await client.call<{ thread: ThreadSummary }>('threads.update', { threadId: id, snoozedUntil: until });
      console.log(`snoozed until ${r.thread.snoozedUntil}`);
      return 0;
    }
    case 'archive':
    case 'unarchive': {
      const id = await resolveId(client, args[0]);
      if (cmd === 'archive') notSelf(id, STOPS_SELF);
      await client.call('threads.update', { threadId: id, archived: cmd === 'archive' });
      return 0;
    }
    case 'actions': {
      const id = await resolveId(client, args[0]);
      const thread = (await client.call<{ threads: ThreadSummary[] }>('threads.list', { include: ['inbox', 'snoozed', 'archived'] })).threads.find((x) => x.id === id);
      if (!thread) throw new Error(`No thread ${id}`);
      if (f.json) {
        console.log(JSON.stringify({ actions: thread.actions ?? [], panels: thread.panels ?? [], patches: thread.patches ?? [] }, null, 2));
        return 0;
      }
      const actions = thread.actions ?? [];
      const panels = thread.panels ?? [];
      const patches = thread.patches ?? [];
      if (!actions.length && !panels.length && !patches.length) {
        console.log(`No patches apply to ${thread.cwd}. Add .threadbear/patches/<name>.ts there (see docs/protocol.md, Patches).`);
        return 0;
      }
      if (actions.length) {
        console.log('Actions:');
        for (const a of actions) console.log(`  ${a.id.padEnd(32)} ${a.title}${a.kind === 'prompt' ? '  (prompt)' : `  $ ${a.command}`}`);
      }
      if (panels.length) {
        console.log('Panels:');
        for (const p of panels) console.log(`  ${p.id.padEnd(32)} ${p.title}${p.url ? `  ${p.url}` : '  (image)'}${p.note ? `  ${p.note}` : ''}`);
      }
      console.log('Patches:');
      for (const p of patches) console.log(`  ${p.id.padEnd(32)} ${p.source}${p.file ? `  ${p.file}` : ''}${p.error ? `  ERROR ${p.error}` : ''}`);
      return 0;
    }
    case 'run': {
      const id = await resolveId(client, args[0]);
      if (!args[1]) throw new Error('Which action? tb actions <threadId> lists them.');
      const before = (await client.call<{ lastSeq: number }>('threads.events', { threadId: id, limit: 1 })).lastSeq;
      // No client-side timeout: the runner stops a command after its own limit.
      const r = await client.call<{ turnId?: string; ok?: boolean; exitCode?: number; durationMs?: number; seq?: number }>('actions.run', { threadId: id, actionId: args[1] });
      if (r.turnId) {
        console.log(`Sent as a message; turn ${r.turnId}.`);
        return 0;
      }
      if (r.seq !== undefined) {
        const page = await client.call<{ events: { seq: number; type: string; text?: string }[] }>('threads.events', { threadId: id, afterSeq: Math.max(before, r.seq - 1), limit: 1 });
        const ev = page.events.find((e) => e.seq === r.seq);
        if (ev?.text) console.log(ev.text.trimEnd());
      }
      console.log(`(${r.ok ? 'ok' : 'failed'}${r.exitCode !== undefined ? `, exit ${r.exitCode}` : ''}, ${((r.durationMs ?? 0) / 1000).toFixed(1)}s)`);
      return r.ok ? 0 : 1;
    }
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

// Inside a thread, tb won't stop the thread it runs in, as the threadbare
// MCP tools won't (threadbare-mcp.ts): it would end this very turn.
// THREADBARE_THREAD_ID is only set in a thread's own CLI and what it runs.
const STOPS_SELF = "Can't snooze or archive the thread this runs in from inside its own turn. Ask Mike to, or do it when the work is done.";

function notSelf(id: string, message: string): string {
  if (id === process.env.THREADBARE_THREAD_ID) throw new Error(message);
  return id;
}

function seqFlag(v: string | boolean | string[] | undefined, name: string): number | undefined {
  if (v === undefined) return undefined;
  const n = Number(v);
  if (!Number.isInteger(n) || n < 1) throw new Error(`${name} takes a seq, a whole number from 1`);
  return n;
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

// prefix (tb events' seq) goes before the event's first line.
function printEvent(e: any, json: boolean, prefix = ''): void {
  if (json) {
    console.log(JSON.stringify(e));
    return;
  }
  const out = (s: string) => {
    if (midLine) process.stdout.write('\n');
    midLine = false;
    console.log(prefix ? prefix + s.replace(/^\n+/, '') : s);
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
      // tb events lists every event, so its seqs have no gaps.
      return prefix ? out('(turn started)') : undefined;
    case 'turn.completed':
      return out(`(${e.outcome}, ${(e.durationMs / 1000).toFixed(1)}s${e.costUsd !== undefined ? `, $${e.costUsd.toFixed(4)}` : ''}${e.error ? `: ${e.error}` : ''})`);
    case 'system.note':
      return out(`(${e.text})`);
    case 'action.run':
      return out(`- ${e.title} (action, ${e.ok ? 'ok' : 'failed'}, ${(e.durationMs / 1000).toFixed(1)}s)${e.text ? `\n  ${String(e.text).split('\n')[0].slice(0, 120)}` : ''}`);
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
