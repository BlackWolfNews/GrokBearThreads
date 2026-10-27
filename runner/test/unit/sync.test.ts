// The Convex mirror (src/sync.ts) against a fake deployment: what it
// writes, when it coalesces, and how it carries on when Convex is away.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { makeHarness, tick, tmpDir } from '../helpers/fakes.ts';
import { ConvexSync, SYNC_COALESCE_MS, HEARTBEAT_MS, SYNC_BATCH, ensureRunnerId, toThreadDoc, convexPoster, type ThreadDoc } from '../../src/sync.ts';
import { nullLogger } from '../../src/log.ts';
import { readRunnerJson } from '../../src/config.ts';

type Call = { kind: string; fn: string; args: Record<string, unknown> };

function setup(opts: { fail?: () => Error | undefined; config?: Partial<ConstructorParameters<typeof ConvexSync>[0]['config']>; key?: string } = {}) {
  const h = makeHarness();
  const calls: Call[] = [];
  const post = async (kind: 'mutation' | 'query', fn: string, args: Record<string, unknown>) => {
    const err = opts.fail?.();
    if (err) throw err;
    calls.push({ kind, fn, args });
    return null;
  };
  const sync = new ConvexSync({
    config: { enabled: true, url: 'https://x.convex.cloud', name: 'TestMac', runnerId: 'r1', ...opts.config },
    key: 'key' in opts ? opts.key : 'k',
    runner: h.runner,
    version: '0.1.0+test',
    release: 'rel1',
    startedAt: '2026-10-27T00:00:00.000Z',
    clock: h.clock,
    log: nullLogger,
    post,
  });
  const upserts = () => calls.filter((c) => c.fn === 'sync:upsertThreads');
  const docs = () => upserts().flatMap((c) => c.args.threads as ThreadDoc[]);
  return { h, sync, calls, upserts, docs };
}

test('start writes every thread once, prunes the rest, and says hello', async () => {
  const { h, sync, calls, docs } = setup();
  const a = h.runner.create({ text: 'one', cwd: h.cfg.defaults.cwd, accountId: 'claude-3' }).thread;
  const b = h.runner.create({ text: 'two', cwd: h.cfg.defaults.cwd, accountId: 'claude-3' }).thread;
  sync.start();
  await sync.flushNow();
  const ids = docs().map((d) => d.threadId).sort();
  assert.deepEqual(ids, [a.id, b.id].sort());
  for (const d of docs()) {
    assert.equal(d.runnerId, 'r1');
    assert.equal(d.view, 'inbox');
    assert.equal(typeof d.lastActivityMs, 'number');
  }
  const prune = calls.find((c) => c.fn === 'sync:prune')!;
  assert.deepEqual((prune.args.keep as string[]).sort(), ids);
  assert.equal(prune.args.runnerId, 'r1');
  const hb = calls.find((c) => c.fn === 'sync:heartbeat')!;
  assert.deepEqual(hb.args.runner, { runnerId: 'r1', name: 'TestMac', version: '0.1.0+test', release: 'rel1', startedAt: '2026-10-27T00:00:00.000Z', draining: false, threadCount: 2 });
  assert.equal(hb.args.key, 'k');
  // Every call carries the key and nothing else secret.
  for (const c of calls) assert.equal(c.args.key, 'k');
  assert.equal(sync.status().state, 'ok');
  assert.equal(sync.status().threads, 2);
});

test('changes within the coalescing window go out as one write with the latest state', async () => {
  const { h, sync, upserts, docs } = setup();
  sync.start();
  await sync.flushNow();
  // A while after the last write, a change goes out straight away.
  h.clock.advance(SYNC_COALESCE_MS);
  const t = h.runner.create({ text: 'hello', cwd: h.cfg.defaults.cwd, accountId: 'claude-3' }).thread;
  h.clock.advance(0);
  await tick();
  assert.equal(docs().filter((d) => d.threadId === t.id).length, 1);
  const before = upserts().length;
  // Changes right after it wait for the window, and go out as one.
  h.runner.update({ threadId: t.id, title: 'First' });
  h.runner.update({ threadId: t.id, title: 'Second' });
  h.runner.update({ threadId: t.id, title: 'Third' });
  h.clock.advance(SYNC_COALESCE_MS - 1);
  await tick();
  assert.equal(upserts().length, before, 'nothing yet: within the window');
  h.clock.advance(1);
  await tick();
  assert.equal(upserts().length, before + 1);
  const last = docs().at(-1)!;
  assert.equal(last.title, 'Third');
});

test('a summary that changed nothing the phone sees is not written', async () => {
  const { h, sync, upserts } = setup();
  const t = h.runner.create({ text: 'hello', cwd: h.cfg.defaults.cwd, accountId: 'claude-3' }).thread;
  sync.start();
  await sync.flushNow();
  const before = upserts().length;
  // The same summary again (what a patches refresh or lastSeq bump does).
  h.runner.publish({ method: 'thread.updated', params: { thread: h.runner.get(t.id) } });
  h.clock.advance(SYNC_COALESCE_MS);
  await tick();
  assert.equal(upserts().length, before);
  assert.equal(sync.status().pending, 0);
});

test('view follows hibernate and den; cost is to the cent; working comes from background', () => {
  const now = Date.parse('2026-10-27T10:00:00.000Z');
  const base = {
    id: 't1', title: 'T', cwd: '/w', accountId: 'claude-3', provider: 'claude' as const, permissionMode: 'full' as const, status: 'idle' as const, live: false, needsYou: false,
    createdAt: '2026-10-27T09:00:00.000Z', updatedAt: '2026-10-27T09:30:00.000Z', lastActivityAt: '2026-10-27T09:30:00.000Z', preview: 'p', lastSeq: 3, lastSeenSeq: 1, costUsd: 0.123456,
    background: [{ kind: 'shell' as const, description: 'npm test', finished: false }],
    projects: [{ id: 'p1', title: 'Threadbear', by: 'mike' as const, at: '2026-10-27T09:10:00.000Z' }],
  };
  const inbox = toThreadDoc(base, 'r', now);
  assert.equal(inbox.view, 'inbox');
  assert.equal(inbox.unread, true);
  assert.equal(inbox.costUsd, 0.12);
  assert.equal(inbox.working, 'npm test');
  assert.deepEqual(inbox.projects, [{ id: 'p1', title: 'Threadbear' }]);
  assert.equal(toThreadDoc({ ...base, snoozedUntil: '2026-10-27T18:00:00.000Z' }, 'r', now).view, 'hibernating');
  assert.equal(toThreadDoc({ ...base, snoozedUntil: '2026-10-27T09:00:00.000Z' }, 'r', now).view, 'inbox', 'a snooze that has passed');
  assert.equal(toThreadDoc({ ...base, archivedAt: '2026-10-27T09:40:00.000Z' }, 'r', now).view, 'den');
  // Nothing the phone doesn't need.
  assert.ok(!('lastSeq' in inbox) && !('contextTokens' in inbox) && !('panels' in inbox));
});

test('a deleted thread is removed', async () => {
  const { h, sync, calls } = setup();
  const t = h.runner.create({ text: 'hello', cwd: h.cfg.defaults.cwd, accountId: 'claude-3' }).thread;
  sync.start();
  await sync.flushNow();
  h.runner.delete(t.id);
  h.clock.advance(SYNC_COALESCE_MS);
  await tick();
  const rm = calls.find((c) => c.fn === 'sync:removeThreads')!;
  assert.deepEqual(rm.args.threadIds, [t.id]);
});

test('a failed write is kept and retried with backoff; status says so', async () => {
  let failing = true;
  const { h, sync, docs } = setup({ fail: () => (failing ? new Error('HTTP 503') : undefined) });
  const t = h.runner.create({ text: 'hello', cwd: h.cfg.defaults.cwd, accountId: 'claude-3' }).thread;
  sync.start();
  await sync.flushNow();
  assert.equal(docs().length, 0);
  const s = sync.status();
  assert.equal(s.state, 'error');
  assert.equal(s.lastError, 'HTTP 503');
  assert.equal(s.pending, 1);
  assert.ok(s.retryAt);
  // Not before the retry time.
  h.clock.advance(1000);
  await tick();
  assert.equal(docs().length, 0);
  failing = false;
  h.clock.advance(Date.parse(s.retryAt!) - h.clock.now());
  await tick();
  assert.equal(docs().length, 1);
  assert.equal(docs()[0]!.threadId, t.id);
  assert.equal(sync.status().state, 'ok');
  assert.equal(sync.status().pending, 0);
});

test('a change while the retry waits replaces the one waiting', async () => {
  let failing = true;
  const { h, sync, docs } = setup({ fail: () => (failing ? new Error('down') : undefined) });
  const t = h.runner.create({ text: 'hello', cwd: h.cfg.defaults.cwd, accountId: 'claude-3' }).thread;
  sync.start();
  await sync.flushNow();
  h.runner.update({ threadId: t.id, title: 'Newer' });
  failing = false;
  h.clock.advance(60_000);
  await tick();
  const mine = docs().filter((d) => d.threadId === t.id);
  assert.equal(mine.length, 1);
  assert.equal(mine[0]!.title, 'Newer');
});

test('big lists go in batches', async () => {
  const { h, sync, upserts } = setup();
  for (let i = 0; i < SYNC_BATCH + 5; i++) h.runner.create({ text: `t${i}`, cwd: h.cfg.defaults.cwd, accountId: 'claude-3' });
  sync.start();
  await sync.flushNow();
  assert.equal(upserts().length, 2);
  assert.equal((upserts()[0]!.args.threads as unknown[]).length, SYNC_BATCH);
  assert.equal((upserts()[1]!.args.threads as unknown[]).length, 5);
});

test('heartbeats once a minute; stop with bye says goodbye, stop without does not', async () => {
  const { h, sync, calls } = setup();
  sync.start();
  await tick();
  const beats = () => calls.filter((c) => c.fn === 'sync:heartbeat').length;
  assert.equal(beats(), 1);
  h.clock.advance(HEARTBEAT_MS);
  await tick();
  assert.equal(beats(), 2);
  await sync.stop();
  h.clock.advance(HEARTBEAT_MS * 3);
  await tick();
  assert.equal(beats(), 2, 'stopped');
  assert.equal(calls.filter((c) => c.fn === 'sync:bye').length, 0);
  // A fresh one stopping for good.
  const again = setup();
  again.sync.start();
  await again.sync.stop({ bye: true });
  assert.equal(again.calls.filter((c) => c.fn === 'sync:bye').length, 1);
  // Nothing after stop: a thread made later isn't written.
  again.h.runner.create({ text: 'late', cwd: again.h.cfg.defaults.cwd, accountId: 'claude-3' }).thread;
  again.h.clock.advance(SYNC_COALESCE_MS * 2);
  await tick();
  assert.equal(again.calls.filter((c) => c.fn === 'sync:upsertThreads').length, 0);
});

test('off without a url, a key or when disabled, and says why', async () => {
  for (const [opts, reason] of [
    [{ config: { url: undefined } }, 'no sync.url in runner.json'],
    [{ key: undefined }, 'no secrets/convex-key'],
    [{ config: { enabled: false } }, 'sync.enabled is false'],
  ] as const) {
    const { h, sync, calls } = setup(opts as never);
    h.runner.create({ text: 'x', cwd: h.cfg.defaults.cwd, accountId: 'claude-3' }).thread;
    sync.start();
    await sync.flushNow();
    h.clock.advance(HEARTBEAT_MS);
    await tick();
    assert.deepEqual(sync.status(), { state: 'off', reason });
    assert.equal(calls.length, 0);
  }
});

test('the runner id is made once and kept in runner.json', () => {
  const home = tmpDir();
  fs.writeFileSync(path.join(home, 'runner.json'), JSON.stringify({ port: 1234, sync: { url: 'https://x.convex.cloud' } }));
  const id = ensureRunnerId(home);
  assert.match(id, /^[0-9a-f]{12}$/);
  assert.equal(ensureRunnerId(home), id);
  const json = readRunnerJson(home);
  assert.equal(json.port, 1234, 'the rest of runner.json is kept');
  assert.equal(json.sync?.url, 'https://x.convex.cloud');
  assert.equal(json.sync?.runnerId, id);
});

test('the poster speaks the deployment HTTP API and reports its errors', async () => {
  const seen: { url: string; body: unknown }[] = [];
  let reply: { ok: boolean; status: number; json: unknown } = { ok: true, status: 200, json: { status: 'success', value: 7 } };
  const fetchFn = (async (url: string, init: RequestInit) => {
    seen.push({ url, body: JSON.parse(init.body as string) });
    return { ok: reply.ok, status: reply.status, json: async () => reply.json } as Response;
  }) as unknown as typeof fetch;
  const post = convexPoster('https://x.convex.cloud/', fetchFn);
  assert.equal(await post('mutation', 'sync:heartbeat', { key: 'k' }), 7);
  assert.equal(seen[0]!.url, 'https://x.convex.cloud/api/mutation');
  assert.deepEqual(seen[0]!.body, { path: 'sync:heartbeat', args: { key: 'k' }, format: 'json' });
  reply = { ok: true, status: 200, json: { status: 'error', errorMessage: 'bad runner key' } };
  await assert.rejects(post('query', 'sync:threadsOf', {}), /bad runner key/);
  reply = { ok: false, status: 502, json: undefined };
  await assert.rejects(post('query', 'sync:threadsOf', {}), /HTTP 502/);
});
