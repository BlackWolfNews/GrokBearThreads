#!/usr/bin/env node
// A stand-in runner for building and testing the app without the real one.
// It speaks docs/protocol.md over a WebSocket, serves fixture threads, fakes
// turns when you send a message, and can replay a 30 Hz stream on request.
//
// Usage:
//   node server.mjs --data-dir /tmp/tb-mock [--port 0] [--fixtures dir]... [--filler 16]
//                   [--ready-file FILE] [--exit-with-pid-file FILE] [--quiet]
//
// --exit-with-pid-file names a file holding the pid of the app it serves
// (Tools/dev-app.sh writes it): the mock exits once that app has quit, or
// once the file has been missing for two minutes (the instance was deleted
// or never started), so a debug app that's never stopped doesn't leave a
// mock behind.
//
// It writes <data-dir>/runner.json ({ port }) and <data-dir>/secrets/runner-token
// (random, 0600) so the app can point at it with --data-dir. Nothing touches
// the real runner's data folder unless you pass it, so don't.

import { WebSocketServer } from 'ws';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const args = parseArgs(process.argv.slice(2));
const dataDir = args['data-dir'];
if (!dataDir) {
  console.error('mock-runner: --data-dir is required (use a temp folder)');
  process.exit(2);
}
const realDataDir = path.join(process.env.HOME ?? '', 'Library/Application Support/Threadbare');
if (path.resolve(dataDir) === path.resolve(realDataDir)) {
  console.error('mock-runner: refusing to use the real runner data folder');
  process.exit(2);
}
// Resolved to absolute paths: image paths in events are built from these and
// the app reads them from its own working folder.
const fixtureDirs = (args.fixtures.length ? args.fixtures : defaultFixtureDirs()).map((dir) => path.resolve(dir));
const fillerCount = Number(args.filler ?? 0);
const quiet = Boolean(args.quiet);

// The model list a real runner learns from each account's CLI, and the
// default its settings name.
const EFFORTS = ['low', 'medium', 'high', 'xhigh', 'max'];
const models = [
  { id: 'opus', model: 'claude-opus-5-5', title: 'Opus 5.5', description: 'For complex work and everyday tasks', effortLevels: EFFORTS },
  { id: 'claude-fable-5-1[1m]', model: 'claude-fable-5-1', title: 'Fable 5.1', description: 'For your toughest challenges', effortLevels: EFFORTS },
  { id: 'sonnet', model: 'claude-sonnet-5-5', title: 'Sonnet 5.5', description: 'Most efficient for simpler tasks', effortLevels: EFFORTS },
  { id: 'haiku', model: 'claude-haiku-5-5', title: 'Haiku 5.5', description: 'Fastest for quick answers', effortLevels: EFFORTS },
  { id: 'claude-haiku-4-5-20251001', model: 'claude-haiku-4-5-20251001', title: 'Haiku 4.5', description: 'Fastest for quick answers' },
  { id: 'claude-opus-5', model: 'claude-opus-5', title: 'Opus 5', description: 'Best for everyday, complex tasks', effortLevels: EFFORTS },
];
const accounts = [
  { id: 'claude-main', provider: 'claude', title: 'mike@example.com', configDir: '~/.claude', defaultModel: 'claude-fable-5-1', models },
  { id: 'claude-3', provider: 'claude', title: 'mike+3@example.com', configDir: '~/Library/Application Support/Token Stats/Accounts/claude-3', defaultModel: 'claude-fable-5-1', models },
];
// The synthetic fixtures live under a made-up /Users/mike, so the default
// folder does too: the app only shows a folder chip away from the default.
const defaults = { cwd: '/Users/mike/dev/me/misc', accountId: 'claude-main' };
// The Settings window's settings, as a runner with a key set and a little
// spent would have them, so a shot of it has something in every row.
const settings = {
  defaultCwd: defaults.cwd, idleMinutes: 30, maxLiveCLIs: 6, followMain: true,
  models: {
    openRouterKey: { set: true, hint: 'f3a9' }, dailyBudgetUsd: 1, spentTodayUsd: 0.0123, spentMonthUsd: 0.4187,
    privateFolders: ['~/dev/clients/acme'],
  },
};

/** threadId -> { summary, events: [], inProgress: Map(itemId -> {type,text}), timers: [] } */
const threads = new Map();
loadFixtures();
addFillers(fillerCount);
addDemoPanels();
addDemoSubagents();
/** The schedules (docs/protocol.md, "Schedules"), soonest first. */
let schedules = [];
addDemoSchedules();

const token = crypto.randomBytes(24).toString('hex');
fs.mkdirSync(path.join(dataDir, 'secrets'), { recursive: true });
fs.mkdirSync(path.join(dataDir, 'inbox'), { recursive: true });
fs.writeFileSync(path.join(dataDir, 'secrets/runner-token'), token + '\n', { mode: 0o600 });

// What `hello` and `runner.status` report. mock.restart bumps the version,
// as a deploy would, so the app's "Runner restarted" note has two to name.
let runnerVersion = '0.0.0-mock';
let restarts = 0;
const startedAt = iso();
// A restart waiting for threads (mock.restartPending): { when, reason?,
// resumeThreadId?, requestedAt, waitingFor: string[] }.
let pendingRestart;

/** @type {Set<{ws: any, subs: Set<string>, authed: boolean}>} */
const clients = new Set();

let wss = listen(Number(args.port ?? 0));

// The WebSocket server, on its own so mock.restart can close it and listen
// again on the same port, the way the real runner goes away and comes back.
function listen(port) {
  const server = new WebSocketServer({ host: '127.0.0.1', port, path: '/rpc', maxPayload: 64 * 1024 * 1024 });
  server.on('listening', () => {
    const { port } = server.address();
    fs.writeFileSync(path.join(dataDir, 'runner.json'), JSON.stringify({ port, mock: true }, null, 2));
    log(`listening on ws://127.0.0.1:${port}/rpc with ${threads.size} threads`);
    // Written whole and renamed into place, so a reader never sees it empty.
    if (args['ready-file']) {
      fs.writeFileSync(`${args['ready-file']}.tmp`, String(port));
      fs.renameSync(`${args['ready-file']}.tmp`, args['ready-file']);
    }
  });
  server.on('connection', onConnection);
  return server;
}

function onConnection(ws, request) {
  const header = request.headers['authorization'] ?? '';
  const client = { ws, subs: new Set(), authed: header === `Bearer ${token}` };
  clients.add(client);
  ws.on('close', () => clients.delete(client));
  ws.on('message', (raw) => {
    let message;
    try {
      message = JSON.parse(raw.toString());
    } catch {
      return reply(client, null, null, { code: -32700, message: 'Parse error' });
    }
    if (!client.authed) {
      if (message.method === 'auth' && message.params?.token === token) {
        client.authed = true;
        return reply(client, message.id, {});
      }
      return ws.close(4401, 'unauthorized');
    }
    handle(client, message).catch((error) => {
      reply(client, message.id, null, { code: error.code ?? -32000, message: error.message });
    });
  });
}

async function handle(client, { id, method, params = {} }) {
  const result = await dispatch(client, method, params);
  if (id !== undefined && id !== null) reply(client, id, result ?? {});
  // Like the real runner: a client that says hello hears about a restart
  // that's waiting, straight after the hello result.
  if (method === 'hello' && pendingRestart) {
    const onYou = pendingRestart.waitingFor.filter((id) => threads.get(id)?.summary.status === 'waiting').length;
    notice(client, 'info', pendingMessage(pendingRestart.waitingFor.length, onYou));
  }
}

async function dispatch(client, method, p) {
  switch (method) {
    case 'hello':
      return { runnerVersion, protocol: 1, accounts, defaults };
    case 'runner.status': {
      const all = [...threads.values()].map((t) => t.summary);
      const status = {
        version: runnerVersion, pid: process.pid, startedAt, home: dataDir, logFile: path.join(dataDir, 'runner.log'),
        liveClis: all.filter((s) => s.live).length,
        running: all.filter((s) => ['starting', 'running', 'waiting'].includes(s.status)).map((s) => s.id),
        background: all.filter((s) => s.background?.length).map((s) => ({ threadId: s.id, tasks: s.background.map((b) => b.description || b.kind) })),
      };
      if (pendingRestart) status.pendingRestart = pendingRestart;
      return status;
    }
    case 'threads.list': {
      const include = new Set(p.include ?? ['inbox']);
      const now = Date.now();
      const list = [...threads.values()].map((t) => t.summary).filter((s) => {
        if (s.archivedAt) return include.has('archived');
        if (s.snoozedUntil && Date.parse(s.snoozedUntil) > now) return include.has('snoozed');
        return include.has('inbox');
      });
      return { threads: newestFirst(list) };
    }
    case 'threads.search': {
      const q = String(p.query ?? '').toLowerCase();
      const list = [...threads.values()].map((t) => t.summary)
        .filter((s) => s.title.toLowerCase().includes(q) || s.preview.toLowerCase().includes(q));
      return { threads: newestFirst(list).slice(0, p.limit ?? 50) };
    }
    case 'threads.create': {
      if (!p.text) throw rpcError(-32602, 'text is required');
      const threadId = 'th_' + crypto.randomBytes(6).toString('hex');
      const now = iso();
      const summary = {
        id: threadId, title: (p.title ?? p.text.split('\n')[0]).slice(0, 60), cwd: p.cwd ?? defaults.cwd,
        accountId: p.accountId ?? defaults.accountId, provider: 'claude', model: p.model, effort: p.effort,
        permissionMode: p.permissionMode ?? 'full', status: 'starting', live: true, needsYou: false,
        createdAt: now, updatedAt: now, lastActivityAt: now, preview: '', lastSeq: 0, lastSeenSeq: 0,
      };
      threads.set(threadId, { summary, events: [], inProgress: new Map(), timers: [] });
      broadcastSummary(threadId);
      setTimeout(() => fakeTurn(threadId, p.text, p.images ?? []), 10);
      return { thread: summary };
    }
    case 'threads.send': {
      const t = need(p.threadId);
      const turnId = 'turn_' + crypto.randomBytes(4).toString('hex');
      setTimeout(() => fakeTurn(t.summary.id, p.text ?? '', p.images ?? [], turnId), 10);
      return { turnId };
    }
    case 'threads.interrupt': {
      const t = need(p.threadId);
      if (t.interrupt) t.interrupt();
      return {};
    }
    case 'threads.update': {
      const t = need(p.threadId);
      const s = t.summary;
      for (const key of ['title', 'cwd', 'accountId', 'permissionMode']) if (p[key] !== undefined) s[key] = p[key];
      if (p.model !== undefined) s.model = p.model ?? undefined;
      if (p.effort !== undefined) s.effort = p.effort ?? undefined;
      if (p.snoozedUntil !== undefined) {
        s.snoozedUntil = p.snoozedUntil ?? undefined;
        if (s.snoozedUntil) { s.live = false; scheduleWake(s.id); }
      }
      if (p.archived !== undefined) {
        s.archivedAt = p.archived ? iso() : undefined;
        if (p.archived) s.live = false;
      }
      s.updatedAt = iso();
      broadcastSummary(s.id);
      return { thread: s };
    }
    case 'threads.events': {
      const t = need(p.threadId);
      let events = t.events;
      if (p.afterSeq !== undefined) events = events.filter((e) => e.seq > p.afterSeq);
      if (p.beforeSeq !== undefined) events = events.filter((e) => e.seq < p.beforeSeq);
      const limit = p.limit ?? 500;
      events = p.afterSeq !== undefined ? events.slice(0, limit) : events.slice(-limit);
      const inProgress = [...t.inProgress.entries()].map(([itemId, v]) => ({ itemId, type: v.type, text: v.text }));
      return { events, firstSeq: events[0]?.seq ?? 0, lastSeq: t.summary.lastSeq, inProgress };
    }
    case 'threads.subscribe': {
      const t = need(p.threadId);
      client.subs.add(t.summary.id);
      const after = p.afterSeq ?? t.summary.lastSeq;
      const inProgress = [...t.inProgress.entries()].map(([itemId, v]) => ({ itemId, type: v.type, text: v.text }));
      return { events: t.events.filter((e) => e.seq > after), inProgress };
    }
    case 'threads.subagent': {
      const t = need(p.threadId);
      const subagent = (t.summary.subagents ?? []).find((s) => s.id === p.subagentId);
      const events = t.subagentEvents?.get(p.subagentId);
      if (!events) throw rpcError(-32006, 'No record of that sub-agent');
      return { ...(subagent ? { subagent } : {}), events: events.map((e) => ({ ...e, threadId: t.summary.id })) };
    }
    case 'threads.unsubscribe':
      client.subs.delete(p.threadId);
      return {};
    case 'threads.markSeen': {
      const t = need(p.threadId);
      t.summary.lastSeenSeq = Math.max(t.summary.lastSeenSeq, p.seq ?? 0);
      if (t.summary.status !== 'waiting') t.summary.needsYou = false;
      broadcastSummary(t.summary.id);
      return { thread: t.summary };
    }
    case 'approvals.respond': {
      const t = need(p.threadId);
      const waiter = t.approvalWaiters?.get(p.approvalId);
      persist(t.summary.id, { type: 'approval.resolved', approvalId: p.approvalId, decision: p.decision, message: p.message });
      if (waiter) {
        t.approvalWaiters.delete(p.approvalId);
        waiter(p);
      } else {
        // A fixture's approval with no fake turn behind it: finish the turn.
        const text = p.decision === 'deny' ? 'OK, I left it alone.' : p.decision === 'answered' ? `Going with ${Object.values(p.answers ?? {}).join(', ') || 'that'}.` : 'Done.';
        persist(t.summary.id, { type: 'assistant.text', itemId: 'm_' + crypto.randomBytes(4).toString('hex'), text });
        persist(t.summary.id, { type: 'turn.completed', turnId: 'turn_resolved', outcome: 'completed', durationMs: 1200 });
        t.summary.needsYou = true;
        setStatus(t.summary.id, 'idle');
      }
      return {};
    }
    case 'actions.run': {
      // A command action "runs" for a moment and its output lands in the
      // transcript; a prompt action is a message, as in the real runner.
      const t = need(p.threadId);
      const action = (t.summary.actions ?? []).find((x) => x.id === p.actionId);
      if (!action) throw rpcError(-32602, `This thread has no action called ${p.actionId}`);
      if (action.kind === 'prompt') return dispatch(client, 'threads.send', { threadId: t.summary.id, text: action.prompt });
      await new Promise((r) => setTimeout(r, 900));
      const ok = action.id !== 'tools.typecheck';
      const text = ok
        ? `$ ${action.command}\nDone in 2.1s.\n`
        : 'src/dashboard/UsageCard.tsx(42,7): error TS2322: Type \'string\' is not assignable to type \'number\'.\n\nFound 1 error in src/dashboard/UsageCard.tsx:42\n';
      const event = persist(t.summary.id, {
        type: 'action.run', actionId: action.id, patch: action.patch, title: action.title, command: action.command,
        ok, exitCode: ok ? 0 : 2, text, truncated: false, durationMs: 2100,
      });
      return { ok, exitCode: ok ? 0 : 2, durationMs: 2100, seq: event.seq };
    }
    case 'panels.render': {
      // The Simulator panel's picture: a fixture image, as if simctl took it.
      const t = need(p.threadId);
      const panel = (t.summary.panels ?? []).find((x) => x.id === p.panelId);
      if (!panel) throw rpcError(-32602, `This thread has no panel called ${p.panelId}`);
      if (panel.kind !== 'image') return { note: 'This panel has nothing to render.' };
      const file = path.join(here, 'fixtures/demo-upload-resume/media/progress-after.png');
      await new Promise((r) => setTimeout(r, 300));
      return { image: { path: file, mediaType: 'image/png', ...imageSize(file) } };
    }
    case 'media.import': {
      const source = String(p.path ?? '');
      if (!fs.existsSync(source)) throw rpcError(-32602, `No file at ${source}`);
      const ext = path.extname(source).toLowerCase() || '.png';
      const dest = path.join(dataDir, 'inbox', crypto.randomBytes(8).toString('hex') + ext);
      fs.copyFileSync(source, dest);
      const size = imageSize(dest);
      return { image: { path: dest, mediaType: mediaType(ext), ...size } };
    }
    case 'schedules.list': {
      const list = sortedSchedules();
      return { schedules: p.threadId ? list.filter((x) => x.threadId === p.threadId || x.createdBy === p.threadId) : list };
    }
    case 'schedules.create': {
      if (!p.text) throw rpcError(-32602, 'text is required');
      if (Boolean(p.at) === Boolean(p.cron)) throw rpcError(-32602, 'Give exactly one of at and cron');
      if (p.threadId) need(p.threadId);
      const when = readWhen(p);
      const now = iso();
      const schedule = {
        id: 'sc_' + crypto.randomBytes(5).toString('hex'), title: p.title || p.text.split('\n')[0].slice(0, 60), text: p.text,
        ...(p.at ? { at: new Date(p.at).toISOString() } : { cron: p.cron }), whenText: when.whenText,
        ...(p.threadId ? { threadId: p.threadId } : { cwd: p.cwd ?? defaults.cwd, accountId: p.accountId ?? defaults.accountId, model: p.model, effort: p.effort, permissionMode: p.permissionMode ?? 'full' }),
        paused: Boolean(p.paused), createdAt: now, updatedAt: now, ...(p.createdBy ? { createdBy: p.createdBy } : {}), runs: 0,
      };
      if (!schedule.paused) schedule.nextRunAt = when.runs[0];
      schedules.push(schedule);
      broadcastSchedules();
      return { schedule };
    }
    case 'schedules.update': {
      const schedule = needSchedule(p.scheduleId);
      for (const key of ['title', 'text', 'cwd', 'accountId', 'permissionMode']) if (p[key] !== undefined) schedule[key] = p[key];
      for (const key of ['model', 'effort', 'timezone']) if (p[key] !== undefined) schedule[key] = p[key] ?? undefined;
      if (p.at || p.cron) {
        const when = readWhen(p);
        if (p.at) { schedule.at = new Date(p.at).toISOString(); delete schedule.cron; delete schedule.finishedAt; }
        else { schedule.cron = p.cron; delete schedule.at; }
        schedule.whenText = when.whenText;
      }
      if (p.paused !== undefined) schedule.paused = Boolean(p.paused);
      schedule.nextRunAt = schedule.paused || schedule.finishedAt ? undefined : readWhen(schedule).runs[0];
      schedule.updatedAt = iso();
      broadcastSchedules();
      return { schedule };
    }
    case 'schedules.delete':
      needSchedule(p.scheduleId);
      schedules = schedules.filter((x) => x.id !== p.scheduleId);
      broadcastSchedules();
      return {};
    case 'schedules.run':
      return runSchedule(needSchedule(p.scheduleId));
    case 'schedules.preview': {
      const when = readWhen(p, Math.min(20, p.count ?? 5));
      return { whenText: when.whenText, runs: when.runs };
    }
    // Settings (docs/protocol.md, "Settings and models"), kept in memory.
    // Like the real runner, the key itself is never kept or sent back:
    // only whether one is set and its last 4 characters.
    case 'settings.get':
      return { settings };
    case 'settings.update': {
      if (p.defaultCwd !== undefined) {
        if (typeof p.defaultCwd !== 'string' || !p.defaultCwd.trim()) throw rpcError(-32602, 'defaultCwd must be a folder');
        settings.defaultCwd = p.defaultCwd;
        defaults.cwd = p.defaultCwd;
      }
      if (p.idleMinutes !== undefined) {
        if (!Number.isInteger(p.idleMinutes) || p.idleMinutes < 1) throw rpcError(-32602, 'idleMinutes must be a whole number of minutes, at least 1');
        settings.idleMinutes = p.idleMinutes;
      }
      if (p.maxLiveCLIs !== undefined) {
        if (!Number.isInteger(p.maxLiveCLIs) || p.maxLiveCLIs < 1 || p.maxLiveCLIs > 20) throw rpcError(-32602, 'maxLiveCLIs must be 1 to 20');
        settings.maxLiveCLIs = p.maxLiveCLIs;
      }
      if (p.followMain !== undefined) settings.followMain = Boolean(p.followMain);
      const m = p.models ?? {};
      if (m.dailyBudgetUsd !== undefined) {
        if (typeof m.dailyBudgetUsd !== 'number' || m.dailyBudgetUsd < 0 || m.dailyBudgetUsd > 100) throw rpcError(-32602, 'The daily budget must be between $0 and $100');
        settings.models.dailyBudgetUsd = m.dailyBudgetUsd;
      }
      if (m.privateFolders !== undefined) {
        if (!Array.isArray(m.privateFolders) || m.privateFolders.some((f) => typeof f !== 'string')) throw rpcError(-32602, 'privateFolders must be a list of folders');
        settings.models.privateFolders = m.privateFolders;
      }
      broadcastSettings();
      return { settings };
    }
    case 'settings.setKey': {
      if (p.provider !== 'openrouter') throw rpcError(-32602, 'provider must be "openrouter"');
      if (p.key === null) {
        settings.models.openRouterKey = { set: false };
      } else {
        const key = typeof p.key === 'string' ? p.key.trim() : '';
        if (key.length < 20 || /\s/.test(key)) throw rpcError(-32602, "That doesn't look like an OpenRouter key");
        settings.models.openRouterKey = { set: true, hint: key.slice(-4) };
      }
      broadcastSettings();
      return { settings };
    }
    // Mock-only helpers for perf runs, demos and screenshots.
    case 'mock.restartPending': {
      // A restart waiting for threads, as `runner.restart` leaves one:
      // runner.status shows it and every client gets the notice. By default
      // it waits for the threads that are busy (as the real runner would);
      // `waitingFor` names them, `cancel: true` withdraws it.
      if (p.cancel) {
        pendingRestart = undefined;
        broadcastNotice('info', 'The pending runner restart was cancelled.');
        return { scheduled: false, waitingFor: [] };
      }
      const busy = [...threads.values()].map((t) => t.summary).filter((s) => ['starting', 'running', 'waiting'].includes(s.status)).map((s) => s.id);
      const waitingFor = Array.isArray(p.waitingFor) ? p.waitingFor.filter((id) => threads.has(id)) : busy;
      pendingRestart = { when: 'idle', requestedAt: iso(), waitingFor };
      if (p.reason) pendingRestart.reason = p.reason;
      if (p.resume?.threadId) pendingRestart.resumeThreadId = p.resume.threadId;
      const onYou = waitingFor.filter((id) => threads.get(id)?.summary.status === 'waiting').length;
      broadcastNotice('info', pendingMessage(waitingFor.length, onYou));
      return { scheduled: true, waitingFor };
    }
    case 'mock.background': {
      // What a thread's CLI is running in the background, as the real
      // runner reports it between turns: `tasks` is the summary's
      // `background` list ([{ kind, description, finished? }]); empty or
      // missing clears it.
      const t = need(p.threadId);
      const tasks = Array.isArray(p.tasks) ? p.tasks.filter((b) => b && typeof b === 'object').map((b) => ({
        kind: ['agent', 'shell', 'monitor', 'other'].includes(b.kind) ? b.kind : 'other',
        description: String(b.description ?? ''),
        ...(b.finished ? { finished: true } : {}),
      })) : [];
      if (tasks.length) t.summary.background = tasks;
      else delete t.summary.background;
      t.summary.live = tasks.length > 0 || t.summary.live;
      broadcastSummary(t.summary.id);
      return { thread: t.summary };
    }
    case 'mock.restart':
      return restartNow(p);
    case 'mock.stream':
      return startStream(need(p.threadId).summary.id, p);
    case 'mock.approval': {
      const t = need(p.threadId);
      const approvalId = 'ap_' + crypto.randomBytes(4).toString('hex');
      persist(t.summary.id, { type: 'approval.requested', approvalId, name: 'Bash', title: p.title ?? 'rm -rf build/', input: { command: p.title ?? 'rm -rf build/' }, options: ['allow', 'allowAlways', 'deny'] });
      setStatus(t.summary.id, 'waiting', true);
      t.approvalWaiters ??= new Map();
      t.approvalWaiters.set(approvalId, () => setStatus(t.summary.id, 'idle', false));
      return { approvalId };
    }
    default:
      throw rpcError(-32601, `Unknown method ${method}`);
  }
}

// ---------------------------------------------------------------- turns

async function fakeTurn(threadId, text, images, turnId = 'turn_' + crypto.randomBytes(4).toString('hex'), origin, extra = {}) {
  const t = threads.get(threadId);
  if (!t) return;
  let interrupted = false;
  t.interrupt = () => { interrupted = true; };
  const started = Date.now();
  persist(threadId, { type: 'user.message', text, images, ...(origin ? { origin } : {}), ...extra }, turnId);
  persist(threadId, { type: 'turn.started', turnId }, turnId);
  setStatus(threadId, 'running');

  const thinkId = 'r_' + crypto.randomBytes(4).toString('hex');
  persist(threadId, { type: 'reasoning', itemId: thinkId, text: 'Checking what the message asks for before answering.' }, turnId);

  if (/approval|ask me/i.test(text) || t.summary.permissionMode === 'ask') {
    const approvalId = 'ap_' + crypto.randomBytes(4).toString('hex');
    persist(threadId, { type: 'approval.requested', approvalId, name: 'Bash', title: 'ls -la', input: { command: 'ls -la' }, options: ['allow', 'allowAlways', 'deny'] }, turnId);
    setStatus(threadId, 'waiting', true);
    t.approvalWaiters ??= new Map();
    const decision = await new Promise((resolve) => t.approvalWaiters.set(approvalId, resolve));
    setStatus(threadId, 'running', false);
    if (decision.decision === 'deny') {
      persist(threadId, { type: 'assistant.text', itemId: 'm_' + crypto.randomBytes(4).toString('hex'), text: 'OK, I left it alone.' }, turnId);
      return finishTurn(threadId, turnId, started, 'completed');
    }
  }
  if (/question/i.test(text)) {
    const approvalId = 'q_' + crypto.randomBytes(4).toString('hex');
    persist(threadId, { type: 'question.requested', approvalId, questions: [{ question: 'Which colour should the button be?', header: 'Colour', multiSelect: false, options: [{ label: 'Blue', description: 'Matches the sidebar' }, { label: 'Green' }, { label: 'Orange', description: 'Stands out more' }] }] }, turnId);
    setStatus(threadId, 'waiting', true);
    t.approvalWaiters ??= new Map();
    await new Promise((resolve) => t.approvalWaiters.set(approvalId, resolve));
    setStatus(threadId, 'running', false);
  }

  const toolId = 'c_' + crypto.randomBytes(4).toString('hex');
  persist(threadId, { type: 'tool.call', itemId: toolId, name: 'Bash', kind: 'command', title: 'ls ~/dev/me/misc', input: { command: 'ls ~/dev/me/misc' } }, turnId);
  await sleep(300);
  persist(threadId, { type: 'tool.result', itemId: toolId, ok: true, text: 'notes.md\nscratch.swift\ntodo.txt', truncated: false, images: [] }, turnId);

  const reply = `You said: "${text.slice(0, 80)}"${images.length ? ` with ${images.length} image${images.length > 1 ? 's' : ''}` : ''}.\n\nThis is the **mock runner**, so here is a canned answer:\n\n1. It streams in small pieces.\n2. Code blocks render in a monospaced box:\n\n\`\`\`swift\nlet greeting = "Hello"\nprint(greeting)\n\`\`\`\n\nThat's all.`;
  const itemId = 'm_' + crypto.randomBytes(4).toString('hex');
  t.inProgress.set(itemId, { type: 'assistant.text', text: '' });
  for (let i = 0; i < reply.length && !interrupted; i += 6) {
    const chunk = reply.slice(i, i + 6);
    t.inProgress.get(itemId).text += chunk;
    transient(threadId, { type: 'assistant.text.delta', itemId, text: chunk }, turnId);
    await sleep(33);
  }
  const finalText = t.inProgress.get(itemId).text;
  t.inProgress.delete(itemId);
  persist(threadId, { type: 'assistant.text', itemId, text: finalText }, turnId);
  finishTurn(threadId, turnId, started, interrupted ? 'interrupted' : 'completed');
}

function finishTurn(threadId, turnId, started, outcome) {
  const t = threads.get(threadId);
  persist(threadId, { type: 'turn.completed', turnId, outcome, durationMs: Date.now() - started, costUsd: 0.0123 }, turnId);
  t.interrupt = undefined;
  t.summary.needsYou = true;
  setStatus(threadId, 'idle');
}

/**
 * Streams `seconds` of deltas at `hz` into an assistant item, then persists
 * it. With `tools: true` it behaves more like a real turn: every 1.5 s the
 * text so far is persisted, a tool call and its result are persisted (each
 * persisted event also sends thread.updated), and a new text item starts.
 */
function startStream(threadId, p) {
  const t = threads.get(threadId);
  const hz = Number(p.hz ?? 30);
  const seconds = Number(p.seconds ?? 60);
  const tools = Boolean(p.tools);
  const turnId = 'turn_stream';
  const newItem = () => 'm_stream_' + crypto.randomBytes(3).toString('hex');
  let itemId = newItem();
  const source = streamText();
  let offset = 0;
  let ticks = 0;
  let toolCount = 0;
  const total = Math.round(hz * seconds);
  const toolEvery = Math.max(1, Math.round(hz * 1.5));
  t.inProgress.set(itemId, { type: 'assistant.text', text: '' });
  setStatus(threadId, 'running');
  // Like a real turn, so the app shows it as running ("Working for 3s").
  persist(threadId, { type: 'turn.started', turnId }, turnId);
  const started = Date.now();
  const finishText = () => {
    const text = t.inProgress.get(itemId)?.text ?? '';
    t.inProgress.delete(itemId);
    if (text) persist(threadId, { type: 'assistant.text', itemId, text }, turnId);
  };
  const timer = setInterval(() => {
    // Roughly what Claude streams: 2 to 12 characters per delta.
    const size = 2 + (ticks % 11);
    // From the text twice over, so a chunk that runs past the end wraps
    // to the start instead of coming up short (which dropped letters and
    // started paragraphs mid-word: "re is how...").
    const at = offset % source.length;
    let chunk = (source + source).slice(at, at + size);
    if (!chunk) chunk = ' ';
    offset += size;
    ticks += 1;
    t.inProgress.get(itemId).text += chunk;
    transient(threadId, { type: 'assistant.text.delta', itemId, text: chunk }, turnId);
    if (tools && ticks % toolEvery === 0 && ticks < total) {
      finishText();
      const toolId = `c_stream_${toolCount++}_` + crypto.randomBytes(2).toString('hex');
      persist(threadId, { type: 'tool.call', itemId: toolId, name: 'Bash', kind: 'command', title: 'npm test', input: { command: 'npm test' } }, turnId);
      persist(threadId, { type: 'tool.result', itemId: toolId, ok: true, text: 'PASS src/upload.test.ts\n  12 passed', truncated: false, images: [] }, turnId);
      itemId = newItem();
      t.inProgress.set(itemId, { type: 'assistant.text', text: '' });
    }
    if (ticks >= total) {
      clearInterval(timer);
      finishText();
      persist(threadId, { type: 'turn.completed', turnId, outcome: 'completed', durationMs: Date.now() - started }, turnId);
      setStatus(threadId, 'idle');
    }
  }, 1000 / hz);
  return { itemId, ticks: total };
}

function streamText() {
  return [
    'Here is how the upload pipeline fits together, step by step.\n\n',
    '## Reading the file\n\nThe app reads the file in **64 KB chunks** so memory stays flat even for large videos. ',
    'Each chunk is hashed as it goes, which means the final checksum is ready the moment the last byte is read.\n\n',
    '```swift\nfor try await chunk in reader.chunks(of: 65_536) {\n    hasher.update(data: chunk)\n    try await upload.send(chunk)\n}\n```\n\n',
    '- Retries use exponential backoff starting at 250 ms.\n- A failed chunk is re-sent on its own, not the whole file.\n- Progress is reported per chunk.\n\n',
    'Then the server confirms the checksum and the upload is marked complete. `UploadStore` keeps the state so a crash mid-way resumes where it left off.\n\n',
  ].join('');
}

// ---------------------------------------------------------------- restarts

// The runner's sentences (pendingMessage in runner/src/restart.ts), which
// the app reads: onYou of the waiting threads wait on an answer from you.
function pendingMessage(waiting, onYou = 0) {
  if (waiting === 0) return 'The runner is restarting now.';
  const answer = Math.min(Math.max(0, onYou), waiting);
  const finishing = waiting - answer;
  const finish = finishing === 1 ? '1 thread finishes' : `${finishing} threads finish`;
  if (answer === 0) return `The runner will restart when ${finish}.`;
  if (finishing === 0) return `The runner will restart when you answer ${answer === 1 ? '1 thread' : `${answer} threads`}.`;
  return `The runner will restart when ${finish} and you answer ${answer}.`;
}

/**
 * Restarts the way the real runner does after `runner.restart`: the notice,
 * every connection dropped and the port closed for `downMs` (default 3 s),
 * then back on the same port with a new version. With `resume` (or a
 * resume given to mock.restartPending) that thread gets the "Runner
 * restarted" note and the resume text as a turn sent by the runner
 * (`origin: "runner"`). The reply goes out before anything closes.
 */
function restartNow(p) {
  const downMs = Number(p.downMs ?? 3000);
  const resumeId = p.resume?.threadId ?? pendingRestart?.resumeThreadId;
  if (resumeId) need(resumeId);
  const oldVersion = runnerVersion;
  const newVersion = `0.0.0-mock+r${restarts + 1}`;
  const text = p.resume?.text ?? 'The runner restarted on release 20261027T101500Z-abc1234. Check that your change works, then carry on.';
  // The real runner never restarts with a turn running: an idle restart
  // waits for the threads it named, and "now" stops them. A pending idle
  // restart's threads finish first here (as if they just had), anything
  // else busy is stopped. Before, the CI demo thread stayed Running through
  // the restart in the design shots.
  const waited = new Set(pendingRestart?.when === 'idle' ? pendingRestart.waitingFor : []);
  for (const [id, t] of threads) {
    const s = t.summary;
    if (!['starting', 'running', 'waiting'].includes(s.status)) continue;
    const turnId = t.events.findLast((e) => e.type === 'turn.started')?.turnId;
    const startedAt = Date.parse(t.events.findLast((e) => e.type === 'turn.started')?.ts ?? '') || Date.now();
    if (waited.has(id) && s.status !== 'waiting') {
      persist(id, { type: 'turn.completed', outcome: 'completed', durationMs: Date.now() - startedAt }, turnId);
      setStatus(id, 'idle', true);
    } else if (!waited.has(id)) {
      // Cards still open expire, as the real runner's do when it stops.
      const answered = new Set(t.events.filter((e) => e.type === 'approval.resolved').map((e) => e.approvalId));
      for (const e of t.events.filter((e) => (e.type === 'approval.requested' || e.type === 'question.requested') && !answered.has(e.approvalId))) {
        persist(id, { type: 'approval.resolved', approvalId: e.approvalId, decision: 'expired' }, turnId);
      }
      persist(id, { type: 'turn.completed', outcome: 'interrupted', durationMs: Date.now() - startedAt }, turnId);
      setStatus(id, 'stopped', false);
    }
  }
  broadcastNotice('info', pendingMessage(0));
  pendingRestart = { when: 'now', requestedAt: iso(), waitingFor: [] };
  setTimeout(() => {
    const port = wss.address()?.port;
    wss.close();
    for (const client of clients) client.ws.terminate();
    clients.clear();
    log(`restarting: down for ${downMs} ms`);
    setTimeout(() => {
      restarts += 1;
      runnerVersion = newVersion;
      pendingRestart = undefined;
      wss = listen(port);
      if (resumeId) {
        persist(resumeId, { type: 'system.note', text: `Runner restarted: ${oldVersion} to ${newVersion}` });
        setTimeout(() => fakeTurn(resumeId, text, [], undefined, 'runner'), 10);
      }
    }, downMs);
  }, 100);
  return { scheduled: true, waitingFor: [], version: newVersion };
}

function notice(client, level, message) {
  if (client.authed && client.ws.readyState === 1) {
    client.ws.send(JSON.stringify({ jsonrpc: '2.0', method: 'runner.notice', params: { level, message } }));
  }
}

function broadcastNotice(level, message) {
  for (const client of clients) notice(client, level, message);
}

// ---------------------------------------------------------------- events

function persist(threadId, fields, turnId) {
  const t = threads.get(threadId);
  const s = t.summary;
  const event = { seq: s.lastSeq + 1, ts: iso(), threadId, ...(turnId ? { turnId } : {}), ...fields };
  t.events.push(event);
  s.lastSeq = event.seq;
  // Like the real runner: activity is a message, or a turn starting or
  // ending, not every event. The app reads a running thread's
  // lastActivityAt as when its turn started.
  if (['user.message', 'turn.started', 'turn.completed'].includes(fields.type)) s.lastActivityAt = event.ts;
  s.updatedAt = event.ts;
  if (fields.type === 'assistant.text') s.preview = fields.text.replace(/\s+/g, ' ').slice(0, 140);
  sendEvent(threadId, event);
  broadcastSummary(threadId);
  return event;
}

function transient(threadId, fields, turnId) {
  const t = threads.get(threadId);
  const event = { seq: t.summary.lastSeq, ts: iso(), threadId, ...(turnId ? { turnId } : {}), ...fields };
  sendEvent(threadId, event);
}

function sendEvent(threadId, event) {
  const text = JSON.stringify({ jsonrpc: '2.0', method: 'thread.event', params: { threadId, event } });
  for (const client of clients) if (client.authed && client.subs.has(threadId)) client.ws.send(text);
}

function setStatus(threadId, status, needsYou) {
  const s = threads.get(threadId).summary;
  s.status = status;
  s.live = true;
  if (needsYou !== undefined) s.needsYou = needsYou;
  broadcastSummary(threadId);
}

function broadcastSummary(threadId) {
  const text = JSON.stringify({ jsonrpc: '2.0', method: 'thread.updated', params: { thread: threads.get(threadId).summary } });
  for (const client of clients) if (client.authed) client.ws.send(text);
}

function scheduleWake(threadId) {
  const t = threads.get(threadId);
  const delay = Date.parse(t.summary.snoozedUntil) - Date.now();
  if (!(delay > 0) || delay > 2 ** 31 - 1) return;
  setTimeout(() => {
    const s = t.summary;
    if (s.snoozedUntil && Date.parse(s.snoozedUntil) <= Date.now()) {
      s.snoozedUntil = undefined;
      s.needsYou = true;
      broadcastSummary(threadId);
    }
  }, delay + 50);
}

// ---------------------------------------------------------------- schedules

// The mock's cron is deliberately small: the five fields with *, lists,
// ranges and steps (no names, no @daily), stepped a minute at a time. The
// real runner's is the one to trust. (Constants inside the functions:
// addDemoSchedules runs while the module is still loading.)
function parseCron(cron) {
  const CRON_FIELDS = [['minute', 0, 59], ['hour', 0, 23], ['day of the month', 1, 31], ['month', 1, 12], ['day of the week', 0, 7]];
  const parts = String(cron).trim().split(/\s+/);
  if (parts.length !== 5) throw rpcError(-32602, `A cron has five fields (minute hour day month weekday); "${cron}" has ${parts.length}`);
  return parts.map((part, index) => {
    const [name, min, max] = CRON_FIELDS[index];
    const values = new Set();
    for (const piece of part.split(',')) {
      const match = /^(\*|(\d+)(?:-(\d+))?)(?:\/(\d+))?$/.exec(piece);
      if (!match) throw rpcError(-32602, `Can't read the ${name} field: "${piece}"`);
      const from = match[1] === '*' ? min : Number(match[2]);
      const to = match[1] === '*' ? max : match[3] !== undefined ? Number(match[3]) : match[4] ? max : from;
      const step = Number(match[4] ?? 1);
      if (from < min || to > max || from > to || step < 1) throw rpcError(-32602, `The ${name} field "${piece}" is out of range (${min}-${max})`);
      for (let v = from; v <= to; v += step) values.add(index === 4 ? v % 7 : v);
    }
    return { values, any: part === '*' };
  });
}

function cronRuns(cron, count, after = new Date()) {
  const [minute, hour, dom, month, dow] = parseCron(cron);
  const runs = [];
  const t = new Date(after);
  t.setSeconds(0, 0);
  t.setMinutes(t.getMinutes() + 1);
  for (let i = 0; i < 400 * 24 * 60 && runs.length < count; i++, t.setMinutes(t.getMinutes() + 1)) {
    if (!minute.values.has(t.getMinutes()) || !hour.values.has(t.getHours()) || !month.values.has(t.getMonth() + 1)) continue;
    const domOk = dom.values.has(t.getDate());
    const dowOk = dow.values.has(t.getDay());
    // Both day fields restricted: either one is enough, as in cron.
    if (dom.any || dow.any ? domOk && dowOk : domOk || dowOk) runs.push(t.toISOString());
  }
  return runs;
}

function clock(h, m) {
  return `${h}:${String(m).padStart(2, '0')}`;
}

/** Canned words for the app's own presets; anything else is the cron itself. */
function cronWords(cron) {
  const DAYS = ['Sundays', 'Mondays', 'Tuesdays', 'Wednesdays', 'Thursdays', 'Fridays', 'Saturdays'];
  const [m, h, dom, mon, dow] = String(cron).trim().split(/\s+/);
  if (m === '0' && h === '*' && dom === '*' && mon === '*' && dow === '*') return 'Every hour';
  if (!/^\d+$/.test(m) || !/^\d+$/.test(h) || mon !== '*') return `On the cron ${cron}`;
  const at = clock(Number(h), Number(m));
  if (dom === '*' && dow === '*') return `Every day at ${at}`;
  if (dom === '*' && dow === '1-5') return `Weekdays at ${at}`;
  if (dom === '*' && /^[0-7]$/.test(dow)) return `${DAYS[Number(dow) % 7]} at ${at}`;
  if (/^\d+$/.test(dom) && dow === '*') return `Every month on day ${dom} at ${at}`;
  return `On the cron ${cron}`;
}

function onceWords(date) {
  const d = new Date(date);
  return `Once, ${d.toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' }).replace(',', '')} at ${clock(d.getHours(), d.getMinutes())}`;
}

/** { whenText, runs } for { at } or { cron }. */
function readWhen(p, count = 5) {
  if (p.at) {
    const at = new Date(p.at);
    if (Number.isNaN(at.getTime())) throw rpcError(-32602, `Can't read the time "${p.at}"`);
    return { whenText: onceWords(at), runs: at > new Date() ? [at.toISOString()] : [] };
  }
  if (p.cron) return { whenText: cronWords(p.cron), runs: cronRuns(p.cron, count) };
  throw rpcError(-32602, 'Give at or cron');
}

function needSchedule(id) {
  const schedule = schedules.find((x) => x.id === id);
  if (!schedule) throw rpcError(-32005, 'Schedule not found');
  return schedule;
}

function sortedSchedules() {
  const rank = (x) => (x.nextRunAt ? Date.parse(x.nextRunAt) : Infinity);
  return [...schedules].sort((a, b) => rank(a) - rank(b));
}

function broadcastSettings() {
  const text = JSON.stringify({ jsonrpc: '2.0', method: 'settings.updated', params: { settings } });
  for (const client of clients) if (client.authed) client.ws.send(text);
}

function broadcastSchedules() {
  const text = JSON.stringify({ jsonrpc: '2.0', method: 'schedules.updated', params: { schedules: sortedSchedules() } });
  for (const client of clients) if (client.authed) client.ws.send(text);
}

/** Sends the schedule's message now, to its thread or a new one. */
function runSchedule(schedule) {
  const text = `[Scheduled: "${schedule.title}", ${schedule.whenText}]\n${schedule.text}`;
  const turnId = 'turn_' + crypto.randomBytes(4).toString('hex');
  let threadId = schedule.threadId;
  if (!threadId) {
    threadId = 'th_' + crypto.randomBytes(6).toString('hex');
    const now = iso();
    threads.set(threadId, { summary: {
      id: threadId, title: schedule.title, cwd: schedule.cwd ?? defaults.cwd, accountId: schedule.accountId ?? defaults.accountId,
      provider: 'claude', model: schedule.model, effort: schedule.effort, permissionMode: schedule.permissionMode ?? 'full',
      status: 'starting', live: true, needsYou: false, createdAt: now, updatedAt: now, lastActivityAt: now, preview: '', lastSeq: 0, lastSeenSeq: 0,
    }, events: [], inProgress: new Map(), timers: [] });
    broadcastSummary(threadId);
  }
  setTimeout(() => fakeTurn(threadId, text, [], turnId, 'schedule', { scheduleId: schedule.id }), 10);
  schedule.runs += 1;
  schedule.lastRun = { at: iso(), outcome: 'sent', threadId };
  if (!schedule.cron) { schedule.finishedAt = iso(); delete schedule.nextRunAt; }
  schedule.updatedAt = iso();
  broadcastSchedules();
  return { schedule, threadId, turnId };
}

// A few schedules for the demo threads, and one message a schedule sent
// already, so the Scheduled view, the line over a thread's composer and
// the transcript's note all have something to show. They don't fire by
// themselves; schedules.run sends one.
function addDemoSchedules() {
  const now = Date.now();
  const ago = (minutes) => new Date(now - minutes * 60_000).toISOString();
  const make = (fields) => {
    const when = readWhen(fields);
    const schedule = { createdAt: ago(60 * 24 * 3), updatedAt: ago(60 * 24), runs: 0, paused: false, whenText: when.whenText, ...fields };
    if (!schedule.paused && !schedule.finishedAt) schedule.nextRunAt = when.runs[0];
    schedules.push(schedule);
    return schedule;
  };
  if (threads.has('demo_release_notes')) {
    make({ id: 'sc_demo_prs', title: 'Merged PRs into the notes', text: 'List the PRs merged since yesterday and add any that matter to the 0.4 notes.',
      cron: '0 9 * * 1-5', threadId: 'demo_release_notes', runs: 4, lastRun: { at: ago(60 * 5), outcome: 'sent', threadId: 'demo_release_notes' } });
  }
  if (threads.has('demo_ci_slow')) {
    make({ id: 'sc_demo_ci', title: 'Check the CI run again', text: 'Check whether the cache change made the CI build faster.',
      at: new Date(now + 40 * 60_000).toISOString(), threadId: 'demo_ci_slow', createdBy: 'demo_ci_slow' });
  }
  make({ id: 'sc_demo_deps', title: 'Weekly dependency check', text: 'Look for outdated npm and Swift packages in ~/dev/me and list the ones worth updating.',
    cron: '0 10 * * 1', cwd: defaults.cwd, accountId: defaults.accountId, permissionMode: 'full', runs: 6,
    lastRun: { at: ago(60 * 24 * 6), outcome: 'skipped', note: 'the last thread it started was still running' } });
  make({ id: 'sc_demo_backup', title: 'Nightly backup report', text: 'Summarise last night\'s Backblaze log and say if anything failed.',
    cron: '0 2 * * *', cwd: '/Users/mike/dev/old-backups', accountId: defaults.accountId, paused: true, runs: 21,
    lastRun: { at: ago(60 * 30), outcome: 'failed', note: 'the folder /Users/mike/dev/old-backups is gone' } });

  // What a schedule's message looks like once sent: at the end of the
  // release notes thread, without moving it in the sidebar.
  const t = threads.get('demo_release_notes');
  if (t) {
    let seq = t.summary.lastSeq;
    const ts = t.events.at(-1)?.ts ?? ago(5);
    const push = (fields) => t.events.push({ seq: ++seq, ts, threadId: t.summary.id, turnId: 'turn_sched', ...fields });
    push({ type: 'user.message', origin: 'schedule', scheduleId: 'sc_demo_prs', images: [],
      text: '[Scheduled: "Merged PRs into the notes", Weekdays at 9:00]\nList the PRs merged since yesterday and add any that matter to the 0.4 notes.' });
    push({ type: 'turn.started' });
    push({ type: 'assistant.text', itemId: 'm_sched', text: 'Two PRs merged since yesterday: **#212** (faster thread switching) and **#214** (fix for pasted images). I added both under *Improvements*.' });
    push({ type: 'turn.completed', outcome: 'completed', durationMs: 8400, costUsd: 0.02 });
    t.summary.lastSeq = seq;
    t.summary.lastSeenSeq = seq;
  }
}

// ---------------------------------------------------------------- fixtures

function defaultFixtureDirs() {
  const dirs = [path.join(here, 'fixtures')];
  const privateDir = path.resolve(here, '../../.fixtures');
  if (fs.existsSync(privateDir)) dirs.push(privateDir);
  // Not .fixtures/threads, where `tb export` puts Mike's real threads: they'd
  // sort above the demo threads in every screenshot. Pass --fixtures for them.
  return dirs;
}

// The demo threads were made with times "n minutes ago" (make-synthetic.mjs,
// newest a minute old). Moved so that's true whenever the mock runs: fixed
// times aged every design shot by the hour, and the sidebar's truncation
// changed with them, so shots never matched their baseline. Real exports
// keep their times. (Functions, not module constants: loadFixtures runs
// while the module is still loading.)
function shiftToNow(loaded) {
  const TIME_FIELDS = ['createdAt', 'updatedAt', 'lastActivityAt', 'snoozedUntil', 'archivedAt'];
  const newest = Math.max(...loaded.map((t) => Date.parse(t.summary.lastActivityAt)).filter(Number.isFinite));
  if (!Number.isFinite(newest)) return;
  const by = Date.now() - 60_000 - newest;
  const move = (iso) => (typeof iso === 'string' && Number.isFinite(Date.parse(iso)) ? new Date(Date.parse(iso) + by).toISOString() : iso);
  for (const t of loaded) {
    for (const k of TIME_FIELDS) if (t.summary[k] !== undefined) t.summary[k] = move(t.summary[k]);
    for (const e of t.events) e.ts = move(e.ts);
  }
}

// Two demo threads get panels, as the real runner gives a thread in a
// Convex or Xcode project: a page (a small one of our own, so screenshots
// need no network or login) and the Simulator picture.
// Sub-agents for the running CI thread (docs/protocol.md, Subagent): one
// still going whose transcript grows every few seconds, one it started
// itself, one that has reported back and one that failed. Their
// transcripts are what threads.subagent answers with.
function addDemoSubagents() {
  const t = threads.get('demo_ci_slow');
  if (!t) return;
  const now = Date.now();
  const at = (secondsAgo) => new Date(now - secondsAgo * 1000).toISOString();
  t.summary.subagents = [
    { id: 'a_cache', itemId: 'agent_cache', description: 'Compare the cache keys', agentType: 'Explore', status: 'completed', background: false,
      summary: 'The lockfile hash changed on 21 Oct, so every run since misses the cache.', toolUses: 4, startedAt: at(200), endedAt: at(150) },
    { id: 'a_bisect', itemId: 'agent_bisect', description: 'Find the commit that slowed the build', agentType: 'general-purpose', status: 'running', background: true,
      activity: 'Running git bisect on the last 40 commits', toolUses: 2, startedAt: at(95) },
    { id: 'a_bisect_tests', parentId: 'a_bisect', description: 'Time the test step on each commit', agentType: 'fork', status: 'running', background: false,
      activity: 'Reading run-845.log', toolUses: 1, startedAt: at(40) },
    { id: 'a_docker', itemId: 'agent_docker', description: 'Check the Docker layer cache', agentType: 'Explore', status: 'failed', background: true,
      summary: 'Couldn\'t reach the registry.', toolUses: 1, startedAt: at(180), endedAt: at(170) },
  ];
  const ev = (list) => list.map((e, i) => ({ seq: i + 1, ts: at(90 - i * 5), ...e }));
  t.subagentEvents = new Map([
    ['a_cache', ev([
      { type: 'user.message', text: 'Compare the cache keys in run-812.log and run-845.log and say why the second one missed.', images: [] },
      { type: 'tool.call', itemId: 'c1', name: 'Bash', kind: 'command', title: 'grep "cache key" run-812.log run-845.log', input: { command: 'grep "cache key" run-812.log run-845.log' } },
      { type: 'tool.result', itemId: 'c1', ok: true, text: 'run-812.log: cache key node-modules-9f2c\nrun-845.log: cache key node-modules-41ab', truncated: false, images: [] },
      { type: 'tool.call', itemId: 'c2', name: 'Bash', kind: 'command', title: 'git log -p package-lock.json', input: { command: 'git log --since=2026-10-20 -p package-lock.json | head -40' } },
      { type: 'tool.result', itemId: 'c2', ok: true, text: 'commit 7d1e2a0 (21 Oct)\n    Bump sharp to 0.34', truncated: false, images: [] },
      { type: 'assistant.text', itemId: 'm1', text: 'The keys differ because **package-lock.json** changed on 21 Oct (`7d1e2a0`, the sharp bump). The cache is keyed on the lockfile hash, so every run since misses it and installs from scratch.' },
    ])],
    ['a_bisect', ev([
      { type: 'user.message', text: 'Find which commit made the CI build slow. Bisect the last 40 commits on main, timing `npm run build` on each.', images: [] },
      { type: 'reasoning', itemId: 'r1', text: 'Forty commits is about six steps of bisect. The test step looks like the slow part, so I\'ll have a fork time that in parallel.' },
      { type: 'tool.call', itemId: 'b1', name: 'Bash', kind: 'command', title: 'git bisect start main 7d1e2a0~5', input: { command: 'git bisect start main 7d1e2a0~5' } },
      { type: 'tool.result', itemId: 'b1', ok: true, text: 'Bisecting: 20 revisions left to test after this (roughly 4 steps)', truncated: false, images: [] },
      { type: 'tool.call', itemId: 'b2', name: 'Agent', kind: 'task', title: 'Time the test step on each commit', input: { description: 'Time the test step on each commit', subagent_type: 'fork' } },
    ])],
    ['a_bisect_tests', ev([
      { type: 'user.message', text: 'Time the test step on each commit the bisect stops at.', images: [] },
      { type: 'tool.call', itemId: 't1', name: 'Read', kind: 'read', title: 'Read run-845.log', input: { file_path: '/Users/mike/dev/photo-sync/run-845.log' } },
    ])],
    ['a_docker', ev([
      { type: 'user.message', text: 'Check whether the Docker layer cache is being used on CI.', images: [] },
      { type: 'tool.call', itemId: 'd1', name: 'Bash', kind: 'command', title: 'docker buildx du --builder ci', input: { command: 'docker buildx du --builder ci' } },
      { type: 'tool.result', itemId: 'd1', ok: false, text: 'error: dial tcp registry.internal:443: i/o timeout', truncated: false, images: [] },
      { type: 'assistant.text', itemId: 'm1', text: 'I couldn\'t reach the registry, so I can\'t say whether the layer cache is used.' },
    ])],
  ]);
  // The running one does a few more things, so an open transcript has
  // something to pick up.
  const steps = [
    { activity: 'Running npm run build on 3f9c2d1', call: { name: 'Bash', kind: 'command', title: 'npm run build', input: { command: 'npm run build' } }, result: 'Built in 4m 58s' },
    { activity: 'Marking 3f9c2d1 good', call: { name: 'Bash', kind: 'command', title: 'git bisect good', input: { command: 'git bisect good' } }, result: 'Bisecting: 10 revisions left to test after this (roughly 3 steps)' },
    { activity: 'Running npm run build on 7d1e2a0', call: { name: 'Bash', kind: 'command', title: 'npm run build', input: { command: 'npm run build' } }, result: 'Built in 13m 02s' },
  ];
  steps.forEach((step, i) => {
    const timer = setTimeout(() => {
      const list = t.subagentEvents.get('a_bisect');
      const itemId = `b${3 + i}`;
      list.push({ seq: list.length + 1, ts: iso(), type: 'tool.call', itemId, ...step.call });
      list.push({ seq: list.length + 1, ts: iso(), type: 'tool.result', itemId, ok: true, text: step.result, truncated: false, images: [] });
      const s = t.summary.subagents.find((x) => x.id === 'a_bisect');
      s.activity = step.activity;
      s.toolUses += 1;
      broadcastSummary(t.summary.id);
    }, 6000 * (i + 1));
    timer.unref?.();
    t.timers.push(timer);
  });
}

function addDemoPanels() {
  const page = `<!doctype html><meta charset="utf-8"><title>Convex dashboard</title>
<style>body{margin:0;font:13px -apple-system,system-ui;background:#1b1b1d;color:#d8d8dc;display:flex;height:100vh}
nav{width:150px;border-right:1px solid #2b2b2e;padding:14px 0}nav div{padding:6px 16px;color:#9a9aa0}nav .on{background:#28282b;color:#e8e8ec;border-radius:6px;margin:0 8px;padding:6px 8px}
main{flex:1;padding:16px 18px}h1{font-size:14px;margin:0 0 12px;display:flex;gap:8px;align-items:center}
.tag{font-size:11px;color:#9a9aa0;border:1px solid #39393d;border-radius:10px;padding:1px 7px;font-weight:400}
table{border-collapse:collapse;font:12px ui-monospace,Menlo,monospace;color:#c8c8cc}td,th{text-align:left;padding:4px 10px 4px 0;border-bottom:1px solid #2b2b2e}th{color:#8a8a90;font-weight:500}
p{color:#8a8a90;font-size:12px;line-height:1.5;margin-top:18px}
@media (prefers-color-scheme: light){body{background:#fff;color:#222}nav{border-color:#e6e6e8}nav div{color:#666}nav .on{background:#f0f0f2;color:#111}table{color:#333}td,th{border-color:#ececef}th,p,.tag{color:#777}.tag{border-color:#ddd}}</style>
<nav><div>dashboard</div><div>notes</div><div>scratchpad</div><div>snapshots</div><div class="on">usage</div><div>videos</div></nav>
<main><h1>usage <span class="tag">dev</span><span class="tag">1 document</span></h1>
<table><tr><th>_id</th><th>month</th><th>spendUsd</th><th>limitUsd</th></tr><tr><td>j57c…9m2</td><td>"2026-10"</td><td>41.8</td><td>80</td></tr></table>
<p>The mock runner's stand-in for the Convex dashboard. A real thread in a Convex project gets dashboard.convex.dev for its deployment here.</p></main>`;
  const convex = threads.get('demo_dark_mode');
  if (convex) {
    convex.summary.panels = [{
      id: 'convex.dashboard', title: 'Convex', kind: 'url', patch: 'convex',
      url: 'data:text/html;charset=utf-8,' + encodeURIComponent(page), note: 'happy-otter-123 (dev)',
    }];
    // As a project's .threadbear/patches/tools.ts would give it.
    convex.summary.actions = [
      { id: 'tools.typecheck', title: 'Typecheck', kind: 'command', command: 'npx tsc --noEmit', patch: 'tools' },
      { id: 'tools.open-logs', title: 'Open logs', kind: 'prompt', prompt: 'Tail the Convex logs and tell me about any errors.', patch: 'tools' },
      { id: 'tools.deploy-to-prod', title: 'Deploy to prod', kind: 'command', command: 'npx convex deploy', patch: 'tools', note: 'Asks nothing; be sure' },
      { id: 'tools.reseed-dev-db', title: 'Reseed dev DB', kind: 'command', command: 'npx convex run seed:reset && npx convex import --replace fixtures/dev.zip', patch: 'tools' },
    ];
    convex.summary.patches = [
      { id: 'convex', source: 'builtin' },
      { id: 'tools', source: 'project', file: '/Users/mike/dev/me/misc/.threadbear/patches/tools.ts' },
    ];
  }
  const ios = threads.get('demo_button_colour');
  if (ios) {
    ios.summary.panels = [
      { id: 'xcode.simulator', title: 'Simulator', kind: 'image', patch: 'xcode', note: 'Walkies' },
      { id: 'convex.dashboard', title: 'Convex', kind: 'url', patch: 'convex', url: 'data:text/html;charset=utf-8,' + encodeURIComponent(page), note: 'walkies-dev (dev)' },
    ];
  }
}

function loadFixtures() {
  for (const root of fixtureDirs) {
    if (!fs.existsSync(root)) continue;
    const loaded = [];
    // A folder of fixtures, or one fixture itself (what `tb export` prints).
    const names = fs.existsSync(path.join(root, 'thread.json')) ? ['.'] : fs.readdirSync(root).sort();
    for (const name of names) {
      const dir = path.join(root, name);
      const threadFile = path.join(dir, 'thread.json');
      const eventsFile = path.join(dir, 'events.ndjson');
      if (!fs.existsSync(threadFile) || !fs.existsSync(eventsFile)) continue;
      const summary = JSON.parse(fs.readFileSync(threadFile, 'utf8'));
      // Media paths in fixtures are relative to the fixture folder.
      const fixPaths = (images) => (images ?? []).map((img) => ({ ...img, path: path.isAbsolute(img.path) ? img.path : path.join(dir, img.path) }));
      const events = fs.readFileSync(eventsFile, 'utf8').split('\n').filter(Boolean).map((line) => {
        const event = JSON.parse(line);
        event.threadId = summary.id;
        if (event.images) event.images = fixPaths(event.images);
        return event;
      });
      summary.lastSeq = events.at(-1)?.seq ?? 0;
      summary.lastSeenSeq ??= summary.lastSeq;
      loaded.push({ summary, events, inProgress: new Map(), timers: [], dir });
    }
    // Real paths: /tmp is /private/tmp, and dev-app.sh passes the one,
    // the module's own path is the other.
    if (fs.realpathSync(root) === fs.realpathSync(path.join(here, 'fixtures'))) shiftToNow(loaded);
    for (const t of loaded) {
      const { summary, events } = t;
      // A fixture caught mid-turn: start its clock a few seconds ago, so the
      // app's "Working for" line reads like a live turn whenever it's run.
      if (summary.status === 'running') {
        const started = events.findLast((e) => e.type === 'turn.started');
        if (started) {
          started.ts = new Date(Date.now() - 14_000).toISOString();
          summary.lastActivityAt = started.ts;
        }
      }
      // Keep a fixture's waiting or running status so the sidebar has
      // something in every section; tb export makes real ones idle.
      summary.status ??= 'idle';
      summary.live = false;
      threads.set(summary.id, t);
    }
  }
}

function addFillers(count) {
  const now = Date.now();
  for (let i = 0; i < count; i++) {
    const id = `th_filler_${i}`;
    const ts = new Date(now - (i + 5) * 3_600_000).toISOString();
    const summary = {
      id, title: `Filler thread ${i + 1}`, cwd: defaults.cwd, accountId: 'claude-main', provider: 'claude',
      permissionMode: 'full', status: 'idle', live: false, needsYou: false, createdAt: ts, updatedAt: ts, lastActivityAt: ts,
      preview: 'A short synthetic thread for memory tests.', lastSeq: 0, lastSeenSeq: 0,
    };
    const events = [];
    let seq = 0;
    const push = (fields) => events.push({ seq: ++seq, ts, threadId: id, turnId: `t${Math.floor(seq / 12)}`, ...fields });
    for (let turn = 0; turn < 40; turn++) {
      push({ type: 'user.message', text: `Question ${turn + 1}: can you check the build log for warnings?`, images: [] });
      push({ type: 'tool.call', itemId: `c${turn}`, name: 'Bash', kind: 'command', title: 'swift build 2>&1 | grep warning', input: { command: 'swift build' } });
      push({ type: 'tool.result', itemId: `c${turn}`, ok: true, text: 'warning: unused variable `x`\n'.repeat(20), truncated: false, images: [] });
      push({ type: 'assistant.text', itemId: `m${turn}`, text: `There are **20 warnings**, all the same unused variable. Here's the fix:\n\n\`\`\`swift\n_ = compute()\n\`\`\`\n\nWant me to apply it?` });
      push({ type: 'turn.completed', turnId: `t${turn}`, outcome: 'completed', durationMs: 4200 + turn, costUsd: 0.01 });
    }
    summary.lastSeq = seq;
    summary.lastSeenSeq = seq;
    threads.set(id, { summary, events, inProgress: new Map(), timers: [] });
  }
}

// ---------------------------------------------------------------- helpers

function need(threadId) {
  const t = threads.get(threadId);
  if (!t) throw rpcError(-32004, 'Thread not found');
  return t;
}

function newestFirst(list) {
  return [...list].sort((a, b) => Date.parse(b.lastActivityAt) - Date.parse(a.lastActivityAt));
}

function reply(client, id, result, error) {
  if (client.ws.readyState !== 1) return;
  client.ws.send(JSON.stringify(error ? { jsonrpc: '2.0', id, error } : { jsonrpc: '2.0', id, result }));
}

function rpcError(code, message) {
  const error = new Error(message);
  error.code = code;
  return error;
}

function iso() {
  return new Date().toISOString();
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function mediaType(ext) {
  return { '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.gif': 'image/gif', '.webp': 'image/webp' }[ext] ?? 'image/png';
}

function imageSize(file) {
  const b = fs.readFileSync(file).subarray(0, 64 * 1024);
  if (b[0] === 0x89 && b[1] === 0x50) return { width: b.readUInt32BE(16), height: b.readUInt32BE(20) };
  if (b[0] === 0x47 && b[1] === 0x49) return { width: b.readUInt16LE(6), height: b.readUInt16LE(8) };
  if (b[0] === 0xff && b[1] === 0xd8) {
    let i = 2;
    while (i + 9 < b.length) {
      if (b[i] !== 0xff) { i++; continue; }
      const marker = b[i + 1];
      const length = b.readUInt16BE(i + 2);
      if (marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker)) {
        return { width: b.readUInt16BE(i + 7), height: b.readUInt16BE(i + 5) };
      }
      i += 2 + length;
    }
  }
  return {};
}

function parseArgs(argv) {
  const out = { fixtures: [] };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (!arg.startsWith('--')) continue;
    const key = arg.slice(2);
    const next = argv[i + 1];
    const value = next && !next.startsWith('--') ? (i++, next) : true;
    if (key === 'fixtures') out.fixtures.push(value);
    else out[key] = value;
  }
  return out;
}

function log(message) {
  if (!quiet) console.log(`mock-runner: ${message}`);
}

if (typeof args['exit-with-pid-file'] === 'string') watchOwner(args['exit-with-pid-file']);

function watchOwner(file) {
  // A missing file is allowed for a while: the app isn't started yet, or
  // dev-app.sh rebuild is between quitting it and starting the new build.
  let missingSince = Date.now();
  const timer = setInterval(() => {
    let pid = NaN;
    try {
      pid = Number(fs.readFileSync(file, 'utf8').trim());
    } catch {
      if (!fs.existsSync(path.dirname(file)) || Date.now() - missingSince > 120_000) stop('its pid file is gone');
      return;
    }
    missingSince = Date.now();
    if (!Number.isInteger(pid) || pid <= 0) return;
    try {
      process.kill(pid, 0);
    } catch (e) {
      // EPERM means it's there but not ours to signal.
      if (e.code === 'ESRCH') stop(`the app (pid ${pid}) quit`);
    }
  }, 2000);
  timer.unref();
  function stop(why) {
    log(`exiting: ${why}`);
    wss.close();
    process.exit(0);
  }
}

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    wss.close();
    process.exit(0);
  });
}
