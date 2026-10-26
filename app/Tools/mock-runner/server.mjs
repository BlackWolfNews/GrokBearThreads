#!/usr/bin/env node
// A stand-in runner for building and testing the app without the real one.
// It speaks docs/protocol.md over a WebSocket, serves fixture threads, fakes
// turns when you send a message, and can replay a 30 Hz stream on request.
//
// Usage:
//   node server.mjs --data-dir /tmp/tb-mock [--port 0] [--fixtures dir]... [--filler 16]
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

const accounts = [
  { id: 'claude-main', provider: 'claude', title: 'mike@example.com', configDir: '~/.claude' },
  { id: 'claude-3', provider: 'claude', title: 'mike+3@example.com', configDir: '~/Library/Application Support/Token Stats/Accounts/claude-3' },
];
// The synthetic fixtures live under a made-up /Users/mike, so the default
// folder does too: the app only shows a folder chip away from the default.
const defaults = { cwd: '/Users/mike/dev/me/misc', accountId: 'claude-main' };

/** threadId -> { summary, events: [], inProgress: Map(itemId -> {type,text}), timers: [] } */
const threads = new Map();
loadFixtures();
addFillers(fillerCount);

const token = crypto.randomBytes(24).toString('hex');
fs.mkdirSync(path.join(dataDir, 'secrets'), { recursive: true });
fs.mkdirSync(path.join(dataDir, 'inbox'), { recursive: true });
fs.writeFileSync(path.join(dataDir, 'secrets/runner-token'), token + '\n', { mode: 0o600 });

const wss = new WebSocketServer({ host: '127.0.0.1', port: Number(args.port ?? 0), path: '/rpc', maxPayload: 64 * 1024 * 1024 });
wss.on('listening', () => {
  const { port } = wss.address();
  fs.writeFileSync(path.join(dataDir, 'runner.json'), JSON.stringify({ port, mock: true }, null, 2));
  log(`listening on ws://127.0.0.1:${port}/rpc with ${threads.size} threads`);
  // Written whole and renamed into place, so a reader never sees it empty.
  if (args['ready-file']) {
    fs.writeFileSync(`${args['ready-file']}.tmp`, String(port));
    fs.renameSync(`${args['ready-file']}.tmp`, args['ready-file']);
  }
});

/** @type {Set<{ws: any, subs: Set<string>, authed: boolean}>} */
const clients = new Set();

wss.on('connection', (ws, request) => {
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
});

async function handle(client, { id, method, params = {} }) {
  const result = await dispatch(client, method, params);
  if (id !== undefined && id !== null) reply(client, id, result ?? {});
}

async function dispatch(client, method, p) {
  switch (method) {
    case 'hello':
      return { runnerVersion: '0.0.0-mock', protocol: 1, accounts, defaults };
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
        accountId: p.accountId ?? defaults.accountId, provider: 'claude', model: p.model,
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
    case 'media.import': {
      const source = String(p.path ?? '');
      if (!fs.existsSync(source)) throw rpcError(-32602, `No file at ${source}`);
      const ext = path.extname(source).toLowerCase() || '.png';
      const dest = path.join(dataDir, 'inbox', crypto.randomBytes(8).toString('hex') + ext);
      fs.copyFileSync(source, dest);
      const size = imageSize(dest);
      return { image: { path: dest, mediaType: mediaType(ext), ...size } };
    }
    // Mock-only helpers for perf runs and demos.
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

async function fakeTurn(threadId, text, images, turnId = 'turn_' + crypto.randomBytes(4).toString('hex')) {
  const t = threads.get(threadId);
  if (!t) return;
  let interrupted = false;
  t.interrupt = () => { interrupted = true; };
  const started = Date.now();
  persist(threadId, { type: 'user.message', text, images }, turnId);
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

// ---------------------------------------------------------------- fixtures

function defaultFixtureDirs() {
  const dirs = [path.join(here, 'fixtures')];
  const privateDir = path.resolve(here, '../../.fixtures');
  if (fs.existsSync(privateDir)) dirs.push(privateDir);
  // Not .fixtures/threads, where `tb export` puts Mike's real threads: they'd
  // sort above the demo threads in every screenshot. Pass --fixtures for them.
  return dirs;
}

function loadFixtures() {
  for (const root of fixtureDirs) {
    if (!fs.existsSync(root)) continue;
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
      threads.set(summary.id, { summary, events, inProgress: new Map(), timers: [], dir });
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

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    wss.close();
    process.exit(0);
  });
}
