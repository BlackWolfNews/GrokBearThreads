import { test } from 'node:test';
import assert from 'node:assert/strict';
import { makeHarness } from '../helpers/fakes.ts';
import { RpcServer } from '../../src/rpc.ts';
import { RunnerClient } from '../../src/client.ts';
import { RpcError } from '../../src/protocol.ts';
import { nullLogger } from '../../src/log.ts';
import { checkSequence, checkSummary } from '../helpers/protocol-check.ts';
import { patiently } from '../helpers/patience.ts';

const TOKEN = 'test-token-0123456789';

async function serve(extra: Partial<ConstructorParameters<typeof RpcServer>[0]> = {}) {
  const h = makeHarness();
  const server = new RpcServer({ host: '127.0.0.1', port: 0, token: TOKEN, runner: h.runner, log: nullLogger, ...extra });
  const { port } = await server.listen();
  const url = `ws://127.0.0.1:${port}/rpc`;
  return { h, server, url, port };
}

test('bearer header auth, hello, and JSON-RPC errors', async () => {
  const { server, url } = await serve();
  const c = await RunnerClient.connect(url, TOKEN);
  const hello = await c.call('hello', { client: 'test', version: '1' });
  assert.equal(hello.protocol, 1);
  assert.deepEqual(hello.accounts.map((a: { id: string }) => a.id), ['claude-main', 'claude-3']);
  assert.ok(hello.defaults.cwd);
  await assert.rejects(c.call('threads.events', { threadId: 'missing' }), (e: { code: number }) => e.code === -32004);
  await assert.rejects(c.call('threads.create', { text: 1 }), (e: { code: number }) => e.code === -32602);
  await assert.rejects(c.call('threads.create', { text: 'x', accountId: 'claude-42' }), (e: { code: number }) => e.code === -32010);
  await assert.rejects(c.call('threads.create', { text: 'x', effort: 'huge' }), (e: { code: number; message: string }) => e.code === -32602 && /effort must be one of/.test(e.message));
  await assert.rejects(c.call('nope.method'), (e: { code: number }) => e.code === -32601);
  c.close();
  await server.close();
});

test('first-message auth works; anything else first closes with 4401', async () => {
  const { server, url } = await serve();
  const ok = new RunnerClient(url, undefined);
  await ok.opened;
  assert.deepEqual(await ok.call('auth', { token: TOKEN }), {});
  assert.equal((await ok.call('hello', { client: 't', version: '1' })).protocol, 1);
  ok.close();

  const bad = new RunnerClient(url, undefined);
  await bad.opened;
  bad.sendRaw({ jsonrpc: '2.0', id: 1, method: 'threads.list', params: {} });
  assert.equal((await bad.waitClosed()).code, 4401);

  const wrong = new RunnerClient(url, 'wrong-token');
  await wrong.opened;
  wrong.sendRaw({ jsonrpc: '2.0', id: 1, method: 'hello', params: {} });
  assert.equal((await wrong.waitClosed()).code, 4401);
  await server.close();
});

test('health endpoint answers without a token', async () => {
  const { server, port } = await serve();
  const res = await fetch(`http://127.0.0.1:${port}/health`);
  assert.deepEqual(await res.json(), { ok: true });
  await server.close();
});

test('subscribe replays the gap then streams; thread.updated goes to everyone', async () => {
  const { h, server, url } = await serve();
  const a = await RunnerClient.connect(url, TOKEN);
  const b = await RunnerClient.connect(url, TOKEN);
  const aNotes: { method: string; params: any }[] = [];
  const bNotes: { method: string; params: any }[] = [];
  a.onNotification((method, params) => aNotes.push({ method, params }));
  b.onNotification((method, params) => bNotes.push({ method, params }));

  const created = await a.call('threads.create', { text: 'hello', accountId: 'claude-3' });
  assert.deepEqual(checkSummary(created.thread), []);
  const id = created.thread.id;
  const s = h.adapter.last;
  s.init();
  s.text('m1:0', 'first');

  const sub = await a.call('threads.subscribe', { threadId: id, afterSeq: 1 });
  assert.deepEqual(sub.events.map((e: { seq: number }) => e.seq), [2, 3]);
  s.delta('m2:0', 'str');
  h.clock.advance(40);
  s.text('m2:0', 'streamed');
  s.result('completed', 0.001);
  // Wait for them to arrive: a fixed 50 ms wasn't always enough on a
  // busy Mac (29 Oct).
  const arrived = () => aNotes.filter((n) => n.method === 'thread.event').length >= 3 && bNotes.some((n) => n.method === 'thread.updated');
  await patiently(arrived);

  const live = aNotes.filter((n) => n.method === 'thread.event').map((n) => n.params.event);
  assert.deepEqual(checkSequence([...sub.events, ...live], 1), []);
  assert.deepEqual(live.map((e) => e.type), ['assistant.text.delta', 'assistant.text', 'turn.completed']);
  assert.equal(bNotes.filter((n) => n.method === 'thread.event').length, 0, 'b never subscribed');
  assert.ok(bNotes.some((n) => n.method === 'thread.updated' && n.params.thread.id === id));
  for (const n of bNotes) if (n.method === 'thread.updated') assert.deepEqual(checkSummary(n.params.thread), []);

  await a.call('threads.unsubscribe', { threadId: id });
  await b.call('threads.send', { threadId: id, text: 'again' });
  await new Promise((r) => setTimeout(r, 30));
  assert.equal(aNotes.filter((n) => n.method === 'thread.event').length, live.length, 'no events after unsubscribe');

  const page = await b.call('threads.events', { threadId: id });
  assert.equal(page.firstSeq, 1);
  assert.equal(page.lastSeq, page.events.at(-1).seq);
  assert.deepEqual(page.inProgress, []);
  const seen = await b.call('threads.markSeen', { threadId: id, seq: page.lastSeq });
  assert.equal(seen.thread.lastSeenSeq, page.lastSeq);
  const list = await b.call('threads.list', { include: ['inbox', 'snoozed', 'archived'] });
  assert.deepEqual(list.threads.map((t: { id: string }) => t.id), [id]);
  await assert.rejects(b.call('threads.list', { include: ['bogus'] }), (e: { code: number }) => e.code === -32602);
  await assert.rejects(b.call('threads.send', { threadId: id, text: 'x', answers: [{ action: 'a' }] }), (e: { code: number }) => e.code === -32602);
  // A phone command the primary passed on keeps its origin; nothing else
  // can be claimed.
  await b.call('threads.send', { threadId: id, text: 'from the phone', origin: 'phone' });
  await new Promise((r) => setTimeout(r, 30));
  const phoned = (await b.call('threads.events', { threadId: id })).events.find((e: { type: string; text?: string }) => e.type === 'user.message' && e.text === 'from the phone');
  assert.equal(phoned?.origin, 'phone');
  await assert.rejects(b.call('threads.send', { threadId: id, text: 'x', origin: 'runner' }), (e: { code: number }) => e.code === -32602);
  a.close();
  b.close();
  await server.close();
});

test('unauthenticated sockets are dropped: silence past the timeout, or a binary frame', async () => {
  const { server, url } = await serve({ authTimeoutMs: 200 });
  const quiet = new RunnerClient(url, undefined);
  await quiet.opened;
  assert.equal((await quiet.waitClosed()).code, 4401);
  const binary = new RunnerClient(url, undefined);
  await binary.opened;
  (binary as any).ws.send(Buffer.from([1, 2, 3]));
  assert.equal((await binary.waitClosed()).code, 4401);
  // An authenticated client isn't affected by the timer.
  const ok = await RunnerClient.connect(url, TOKEN);
  await new Promise((r) => setTimeout(r, 300));
  assert.equal((await ok.call('hello', { client: 't', version: '1' })).protocol, 1);
  ok.close();
  await server.close();
});

test('seqs and limits must be whole numbers', async () => {
  const { server, url } = await serve();
  const c = await RunnerClient.connect(url, TOKEN);
  const { thread } = await c.call('threads.create', { text: 'hi', accountId: 'claude-3' });
  for (const [method, params] of [
    ['threads.events', { threadId: thread.id, afterSeq: 1.5 }],
    ['threads.events', { threadId: thread.id, beforeSeq: 2.5 }],
    ['threads.events', { threadId: thread.id, limit: 0.5 }],
    ['threads.subscribe', { threadId: thread.id, afterSeq: 1.5 }],
    ['threads.search', { query: 'hi', limit: 1.5 }],
  ] as const) {
    await assert.rejects(c.call(method, params), (e: { code: number }) => e.code === -32602, `${method} ${JSON.stringify(params)}`);
  }
  c.close();
  await server.close();
});

test('hello is followed by notices the client missed, such as a missing claude binary', async () => {
  const { server, url } = await serve();
  const c = await RunnerClient.connect(url, TOKEN);
  const notices: any[] = [];
  c.onNotification((method, params) => {
    if (method === 'runner.notice') notices.push(params);
  });
  await c.call('hello', { client: 't', version: '1' });
  await new Promise((r) => setTimeout(r, 50));
  assert.ok(notices.some((n) => n.level === 'error' && /claude CLI isn't at/.test(n.message)));
  c.close();
  await server.close();
});

test('a subscriber that stops reading loses deltas, then is disconnected', async () => {
  const { h, server, url } = await serve({ skipDeltasBytes: 64 * 1024, closeBytes: 1024 * 1024 });
  const reader = await RunnerClient.connect(url, TOKEN);
  const stalled = await RunnerClient.connect(url, TOKEN);
  const { thread } = await reader.call('threads.create', { text: 'hi', accountId: 'claude-3' });
  await stalled.call('threads.subscribe', { threadId: thread.id });
  (stalled as any).ws._socket.pause();
  const s = h.adapter.last;
  s.init();
  const big = 'x'.repeat(256 * 1024);
  // Until the server drops it from its clients. The stalled client can't see
  // its close while paused, and ws gives it 30 s to answer before cutting it
  // off with a 1006, which more of these writes outlasted at background
  // priority (2 Nov).
  const clients = (server as any).conns as Set<unknown>;
  for (let i = 0; i < 400 && clients.size === 2; i++) {
    s.text(`m${i}:0`, big);
    await new Promise((r) => setImmediate(r));
  }
  (stalled as any).ws._socket.resume();
  const closed = await stalled.waitClosed();
  assert.equal(closed.code, 4408);
  // Everyone else is fine, and the stalled client can catch up from its seq.
  assert.equal((await reader.call('hello', { client: 't', version: '1' })).protocol, 1);
  reader.close();
  await server.close();
});

test('close does not wait long for a client that never answers the close', async () => {
  const { server, url } = await serve({ closeGraceMs: 200 });
  const ok = await RunnerClient.connect(url, TOKEN);
  // Stops reading, so it never answers the runner's close frame; ws alone
  // would wait 30 s for it.
  const silent = await RunnerClient.connect(url, TOKEN);
  (silent as any).ws._socket.pause();
  const started = Date.now();
  await server.close();
  assert.ok(Date.now() - started < 5000, `close took ${Date.now() - started} ms`);
  assert.equal((await ok.waitClosed()).code, 1001);
  (silent as any).ws._socket.resume();
  await silent.waitClosed();
});

test('panels.render answers after the screenshot, with an image or a note; unknown panels are bad params', async () => {
  const root = (await import('../helpers/fakes.ts')).tmpDir();
  const project = `${root}/Walkies`;
  const fs = await import('node:fs');
  fs.mkdirSync(`${project}/Walkies.xcodeproj`, { recursive: true });
  let shots = 0;
  const h = makeHarness(undefined, {}, {
    panelsRoot: root,
    screenshot: async (file: string) => {
      shots++;
      if (shots > 1) throw new Error('No devices are booted.');
      fs.writeFileSync(file, (await import('../helpers/png.ts')).makePng(20, 10));
    },
  });
  const server = new RpcServer({ host: '127.0.0.1', port: 0, token: TOKEN, runner: h.runner, log: nullLogger });
  const { port } = await server.listen();
  const c = await RunnerClient.connect(`ws://127.0.0.1:${port}/rpc`, TOKEN);
  const { thread } = await c.call('threads.create', { text: 'hi', cwd: project });
  assert.deepEqual(thread.panels.map((p: { id: string }) => p.id), ['xcode.simulator']);
  const first = await c.call('panels.render', { threadId: thread.id, panelId: 'xcode.simulator' });
  assert.equal(first.image.width, 20);
  assert.equal(first.note, undefined);
  const second = await c.call('panels.render', { threadId: thread.id, panelId: 'xcode.simulator' });
  assert.equal(second.image, undefined);
  assert.match(second.note, /No simulator is booted/);
  await assert.rejects(c.call('panels.render', { threadId: thread.id, panelId: 'nope' }), (e: { code: number }) => e.code === -32602);
  await assert.rejects(c.call('panels.render', { threadId: 'missing', panelId: 'nope' }), (e: { code: number }) => e.code === -32004);
  c.close();
  await server.close();
});

test('clis.* call CliUpdates and return at once; without it they are -32601; clis.updated reaches every client', async () => {
  const calls: unknown[][] = [];
  const status = [{ provider: 'codex', path: '/t/codex', managedBy: 'threadbear', installedVersion: '0.164.0', status: 'current', policy: 'auto', inUse: [] }] as never[];
  let changed: (c: never[]) => void = () => {};
  const clis = {
    list: () => (calls.push(['list']), status),
    check: (p?: string) => (calls.push(['check', p]), status),
    update: (p: string, o?: object) => (calls.push(['update', p, o]), status),
    setPolicy: (p: string, policy: string) => (calls.push(['setPolicy', p, policy]), status),
    onChange: (fn: (c: never[]) => void) => ((changed = fn), () => {}),
  };
  const { h, server, url } = await serve({ clis });
  h.runner.attachClis(clis);
  const c = await RunnerClient.connect(url, TOKEN);
  const got: { method: string; params: any }[] = [];
  c.onNotification((method, params) => got.push({ method, params }));
  const hello = await c.call('hello', { client: 'test', version: '1' });
  assert.equal(hello.clis[0].installedVersion, '0.164.0');
  assert.deepEqual(await c.call('clis.list'), { clis: status });
  await c.call('clis.check', {});
  await c.call('clis.check', { provider: 'claude' });
  await c.call('clis.update', { provider: 'codex', version: '0.164.0', force: true });
  await c.call('clis.update', { provider: 'claude' });
  await c.call('clis.setPolicy', { provider: 'codex', policy: 'notify' });
  assert.deepEqual(calls.filter((x) => x[0] !== 'list'), [
    ['check', undefined],
    ['check', 'claude'],
    ['update', 'codex', { version: '0.164.0', force: true }],
    ['update', 'claude', {}],
    ['setPolicy', 'codex', 'notify'],
  ]);
  const badParams = (e: { code: number }) => e.code === -32602;
  await assert.rejects(c.call('clis.update', { provider: 'grok' }), badParams);
  await assert.rejects(c.call('clis.update', {}), badParams);
  await assert.rejects(c.call('clis.update', { provider: 'codex', version: '../../evil' }), badParams);
  await assert.rejects(c.call('clis.update', { provider: 'codex', force: 'yes' }), badParams);
  await assert.rejects(c.call('clis.setPolicy', { provider: 'codex', policy: 'sometimes' }), badParams);
  await assert.rejects(c.call('clis.check', { provider: 3 }), badParams);
  changed(status);
  // Wait for it, not a fixed time: the whole suite runs at once.
  await patiently(() => got.some((n) => n.method === 'clis.updated'));
  assert.deepEqual(got.find((n) => n.method === 'clis.updated')?.params, { clis: status });
  c.close();
  await server.close();

  const old = await serve();
  const o = await RunnerClient.connect(old.url, TOKEN);
  for (const m of ['clis.list', 'clis.check', 'clis.update', 'clis.setPolicy']) {
    await assert.rejects(o.call(m, { provider: 'codex', policy: 'auto' }), (e: { code: number }) => e.code === -32601, m);
  }
  assert.equal((await o.call('hello', { client: 'test', version: '1' })).clis, undefined);
  o.close();
  await old.server.close();
});

// Handovers (docs/protocol.md): the primary passes a request about a
// draining runner's thread to it, lists its threads with its own, and
// handles the request itself if that thread has just come across.
test('threads.panelShown clears the thread\'s panel request, and goes to a draining runner that has the thread', async () => {
  const away = { id: 'away-2', title: 'Busy elsewhere', status: 'running', lastActivityAt: '2099-01-01T00:00:00.000Z' } as any;
  const calls: { threadId: string; method: string }[] = [];
  const remote = {
    owns: (id: string) => id === away.id,
    call: async (threadId: string, method: string) => {
      calls.push({ threadId, method });
      return { thread: away };
    },
    summaries: () => [away],
    search: async () => [away],
  };
  const { h, server, url } = await serve({ remote: remote as any });
  const { thread } = h.runner.create({ text: 'here', accountId: 'claude-3' });
  const c = await RunnerClient.connect(url, TOKEN);
  try {
    const shown = h.runner.showPanel(thread.id, { panel: 'usage' });
    const request = h.runner.get(thread.id).panelRequest!;
    const res = await c.call('threads.panelShown', { threadId: thread.id, requestId: request.id });
    assert.deepEqual(checkSummary(res.thread), []);
    assert.equal(res.thread.panelRequest, undefined);
    assert.equal((await shown).shown, true);
    await assert.rejects(c.call('threads.panelShown', { threadId: thread.id }), (e: { code: number }) => e.code === -32602);
    await c.call('threads.panelShown', { threadId: away.id, requestId: 'r1' });
    assert.deepEqual(calls, [{ threadId: away.id, method: 'threads.panelShown' }]);
  } finally {
    c.close();
    await server.close();
  }
});

test('requests about a draining runner\'s thread go to it; a moved answer is handled here', async () => {
  const away = { id: 'away-1', title: 'Busy elsewhere', status: 'running', lastActivityAt: '2099-01-01T00:00:00.000Z' } as any;
  const calls: { threadId: string; method: string }[] = [];
  let owns = true;
  const remote = {
    owns: (id: string) => owns && id === away.id,
    call: async (threadId: string, method: string) => {
      calls.push({ threadId, method });
      if (method === 'threads.send') return { turnId: 'remote-turn' };
      if (method === 'threads.subscribe') return { events: [], inProgress: [] };
      throw new RpcError(-32030, 'That thread has moved.');
    },
    summaries: () => (owns ? [away] : []),
    search: async () => (owns ? [away] : []),
  };
  const { h, server, url } = await serve({ remote: remote as any });
  const local = h.runner.create({ text: 'here', accountId: 'claude-3' }).thread;
  const c = await RunnerClient.connect(url, TOKEN);
  try {
    const { threads } = await c.call('threads.list', {});
    assert.deepEqual(threads.map((t: { id: string }) => t.id), [away.id, local.id]);
    assert.deepEqual((await c.call('threads.search', { query: 'busy' })).threads.map((t: { id: string }) => t.id), [away.id]);
    assert.deepEqual(await c.call('threads.send', { threadId: away.id, text: 'hi' }), { turnId: 'remote-turn' });
    await c.call('threads.subscribe', { threadId: away.id });
    // Its live events now reach this client through the primary.
    const got: unknown[] = [];
    c.onNotification((m, p) => m === 'thread.event' && got.push(p));
    h.runner.publish({ method: 'thread.event', params: { threadId: away.id, event: { type: 'system.note', text: 'from over there', seq: 9, ts: '' } } } as any);
    await new Promise((r) => setTimeout(r, 50));
    assert.equal(got.length, 1);
    // Requests about this runner's own threads stay here.
    await c.call('threads.markSeen', { threadId: local.id, seq: 1 });
    assert.ok(!calls.some((x) => x.threadId === local.id));
    // An error from the draining runner comes back with its code...
    await assert.rejects(c.call('threads.interrupt', { threadId: away.id }), (e: { code: number }) => e.code === -32030);
    // ...unless the thread has come across meanwhile: then it's handled here.
    owns = false;
    await assert.rejects(c.call('threads.interrupt', { threadId: away.id }), (e: { code: number }) => e.code === -32004);
  } finally {
    c.close();
    await server.close();
  }
});
