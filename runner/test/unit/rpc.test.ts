import { test } from 'node:test';
import assert from 'node:assert/strict';
import { makeHarness } from '../helpers/fakes.ts';
import { RpcServer } from '../../src/rpc.ts';
import { RunnerClient } from '../../src/client.ts';
import { nullLogger } from '../../src/log.ts';
import { checkSequence, checkSummary } from '../helpers/protocol-check.ts';

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
  await new Promise((r) => setTimeout(r, 50));

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
  for (let i = 0; i < 400 && !stalled.closeInfo; i++) {
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
