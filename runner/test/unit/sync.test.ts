// The Convex mirror (src/sync.ts) against a fake deployment: what it
// writes, when it coalesces, and how it carries on when Convex is away.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { makeHarness, tick, tmpDir } from '../helpers/fakes.ts';
import { ConvexSync, BACKEND_API_VERSION, ICONS_API_VERSION, RUNNER_ICON_API_VERSION, SCHEDULES_API_VERSION, SHARE_API_VERSION, WOKE_API_VERSION, PRESENCE_MS, SYNC_COALESCE_MS, HEARTBEAT_MS, SYNC_BATCH, ensureRunnerId, toThreadDoc, convexPoster, convexUploader, pictureName, type ThreadDoc } from '../../src/sync.ts';
import type { Project } from '../../src/protocol.ts';
import type { ScheduleBackend } from '../../src/schedules.ts';
import { nullLogger, type Logger } from '../../src/log.ts';
import { AT_MAC_IDLE_MS, isAtMac } from '../../src/presence.ts';
import { readRunnerJson } from '../../src/config.ts';

type Call = { kind: string; fn: string; args: Record<string, unknown> };

function setup(
  opts: {
    fail?: () => Error | undefined;
    config?: Partial<ConstructorParameters<typeof ConvexSync>[0]['config']>;
    key?: string;
    answer?: (fn: string) => unknown;
    schedules?: ConstructorParameters<typeof ConvexSync>[0]['schedules'];
  } = {},
) {
  const h = makeHarness();
  const calls: Call[] = [];
  const post = async (kind: 'mutation' | 'query', fn: string, args: Record<string, unknown>) => {
    const err = opts.fail?.();
    if (err) throw err;
    calls.push({ kind, fn, args });
    return opts.answer ? opts.answer(fn) : null;
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
    schedules: opts.schedules,
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
  const woke = { at: '2026-10-27T10:00:00.000Z', since: '2026-10-26T10:00:00.000Z' };
  assert.deepEqual(toThreadDoc({ ...base, woke }, 'r', now).woke, woke);
  assert.ok(!('woke' in inbox));
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

// ------------------------------------------------------------ step 2 and 3

import { MESSAGE_CHARS, toMessageDoc, toolLine, inputSummary, type Command, type MessageDoc } from '../../src/sync.ts';

type Fake = { h: ReturnType<typeof makeHarness>; sync: ConvexSync; calls: Call[]; push: (value: unknown) => void; applied: string[] };

// A harness whose sync has lists, commands and a fake subscription; the
// fake post answers messageHeads and takeCommand the way the deployment
// would.
function setupFull(opts: { heads?: { threadId: string; lastSeq: number }[]; taken?: Set<string>; failApply?: boolean | 'async'; log?: Logger } = {}): Fake {
  const h = makeHarness();
  const calls: Call[] = [];
  const taken = opts.taken ?? new Set<string>();
  const post = async (kind: 'mutation' | 'query', fn: string, args: Record<string, unknown>) => {
    calls.push({ kind, fn, args });
    if (fn === 'sync:messageHeads') return opts.heads ?? [];
    if (fn === 'sync:takeCommand') {
      const id = String(args.commandId);
      if (taken.has(id)) return false;
      taken.add(id);
      return true;
    }
    return null;
  };
  let onUpdate: ((v: unknown) => void) | undefined;
  const subscriber = {
    subscribe: (_fn: string, _args: Record<string, unknown>, update: (v: unknown) => void) => {
      onUpdate = update;
      return () => (onUpdate = undefined);
    },
    close: () => {},
  };
  const applied: string[] = [];
  const sync = new ConvexSync({
    config: { enabled: true, url: 'https://x.convex.cloud', name: 'TestMac', runnerId: 'r1' },
    key: 'k',
    runner: {
      onNotification: (fn) => h.runner.onNotification(fn),
      list: (i) => h.runner.list(i),
      get: (id) => h.runner.get(id),
      events: (id, o) => h.runner.events(id, o),
      listProjects: () => [{ id: 'p1', title: 'Threadbear', folders: ['/w'], goals: 'g', state: 's', notes: 'n', links: [], createdBy: 'mike', createdAt: '2026-10-27T00:00:00.000Z', updatedAt: '2026-10-27T00:00:00.000Z', threadCount: 1 }],
      listSchedules: () => [{ id: 's1', title: 'Nightly', text: 'go', cron: '0 3 * * *', whenText: 'every day at 3 am', paused: false, createdAt: '2026-10-27T00:00:00.000Z', updatedAt: '2026-10-27T00:00:00.000Z', runs: 2, lastRun: { at: '2026-10-27T03:00:00.000Z', outcome: 'sent', threadId: 't9' } }],
      listAccounts: () => [{ id: 'claude-3', provider: 'claude', title: 'three@example.com', configDir: '/tmp/three', models: [{ id: 'x', title: 'X' }] as never, usage: { windows: [{ kind: 'five_hour', title: '5-hour', remainingPercent: 80.5 }], readAt: '2026-10-27T00:00:00.000Z', source: 'live' } }],
    },
    commands: {
      send: (id, text, images, o) => {
        applied.push(`send ${id} ${text} ${o.origin}`);
        // A forwarded command fails later, as a rejected promise.
        if (opts.failApply === 'async') return Promise.reject(new Error('thread is busy'));
        if (opts.failApply) throw new Error('thread is busy');
        return h.runner.send(id, text, images, o);
      },
      respondApproval: (p) => {
        applied.push(`respond ${p.threadId} ${p.approvalId} ${p.decision}`);
        return h.runner.respondApproval(p);
      },
      update: (p) => {
        applied.push(`update ${JSON.stringify(p)}`);
        return h.runner.update(p);
      },
      markSeen: (id) => {
        applied.push(`markSeen ${id}`);
        return h.runner.markSeen(id, h.runner.get(id).lastSeq);
      },
      create: (p) => {
        applied.push(`create ${p.text} ${p.origin}`);
        return h.runner.create(p);
      },
      share: (id, p) => {
        applied.push(`share ${id} ${p.access}${p.newLink ? ' new' : ''}`);
        return h.runner.share(id, p);
      },
      quickAsk: (p) => {
        applied.push(`quickAsk ${p.question} ${p.sources?.length ?? 0}`);
        return h.runner.quickAsk(p);
      },
    },
    version: '0.1.0+test',
    startedAt: '2026-10-27T00:00:00.000Z',
    clock: h.clock,
    log: opts.log ?? nullLogger,
    post,
    subscriber,
  });
  return { h, sync, calls, push: (v) => onUpdate?.(v), applied };
}

const messagesSent = (calls: Call[]): MessageDoc[] => calls.filter((c) => c.fn === 'sync:appendMessages').flatMap((c) => c.args.messages as MessageDoc[]);
const session = (h: ReturnType<typeof makeHarness>, threadId: string) => h.adapter.sessions.filter((s) => s.opts.threadId === threadId).at(-1)!;

test('messages: the first message goes up with the thread, a reply when its text completes, cut if huge', async () => {
  const { h, sync, calls } = setupFull();
  sync.start();
  await sync.flushNow();
  h.clock.advance(SYNC_COALESCE_MS);
  const t = h.runner.create({ text: 'hello there', cwd: h.cfg.defaults.cwd, accountId: 'claude-3' }).thread;
  h.clock.advance(SYNC_COALESCE_MS);
  await tick();
  let sent = messagesSent(calls);
  assert.equal(sent.length, 1);
  assert.deepEqual({ ...sent[0], at: undefined }, { threadId: t.id, seq: 1, role: 'user', text: 'hello there', at: undefined });
  const s = session(h, t.id);
  s.init();
  s.delta('i1', 'partial');
  h.clock.advance(SYNC_COALESCE_MS);
  await tick();
  assert.equal(messagesSent(calls).length, 1, 'deltas are never written');
  s.text('i1', 'x'.repeat(MESSAGE_CHARS + 50));
  s.result('completed');
  h.clock.advance(SYNC_COALESCE_MS);
  await tick();
  sent = messagesSent(calls);
  assert.equal(sent.length, 2);
  assert.equal(sent[1]!.role, 'assistant');
  assert.ok(sent[1]!.text.length < MESSAGE_CHARS + 50 && sent[1]!.text.endsWith('[cut: the rest is on the Mac]'));
});

test('messages: the first start against a deployment sends whole histories once, later starts only what the mirror lacks', async () => {
  const h0 = makeHarness();
  const a = h0.runner.create({ text: 'first', cwd: h0.cfg.defaults.cwd, accountId: 'claude-3' }).thread;
  const sa = session(h0, a.id);
  sa.init();
  for (let i = 0; i < 25; i++) sa.text(`i${i}`, `reply ${i}`);
  sa.result('completed');
  await tick();
  const b = h0.runner.create({ text: 'second', cwd: h0.cfg.defaults.cwd, accountId: 'claude-3' }).thread;
  await tick();
  const h = h0.restart();
  const statePath = path.join(tmpDir('tb-sync-state-'), 'sync-state.json');
  // Reading b's log fails on the first start, as for a thread the old
  // runner hasn't handed over yet.
  let blockB = true;
  const start = async (heads: { threadId: string; lastSeq: number }[], after?: (s: ConvexSync) => Promise<void>) => {
    const posts: Call[] = [];
    const s = new ConvexSync({
      config: { enabled: true, url: 'https://x.convex.cloud', runnerId: 'r1' },
      key: 'k',
      statePath,
      runner: {
        onNotification: (fn) => h.runner.onNotification(fn),
        list: (i) => h.runner.list(i),
        get: (id) => h.runner.get(id),
        events: (id, o) => {
          if (id === b.id && blockB) throw new Error('not here yet');
          return h.runner.events(id, o);
        },
      },
      version: 'v',
      startedAt: 'now',
      clock: h.clock,
      log: nullLogger,
      post: async (kind, fn, args) => {
        posts.push({ kind, fn, args });
        return fn === 'sync:messageHeads' ? heads : null;
      },
    });
    s.start();
    await s.flushNow();
    await after?.(s);
    await s.stop();
    return { posts, sent: messagesSent(posts) };
  };
  // First start: a's whole history, whatever the mirror says it has; b's log
  // can't be read yet, so b isn't counted as done...
  const first = await start([{ threadId: b.id, lastSeq: 1 }], async (s) => {
    // ...until a later write, once it can.
    blockB = false;
    h.runner.update({ threadId: b.id, title: 'renamed' });
    await tick();
    await s.flushNow();
  });
  assert.equal(first.posts.some((p) => p.fn === 'sync:messageHeads'), false, 'no thread is done yet, so nothing to ask');
  const forA = first.sent.filter((m) => m.threadId === a.id && m.role !== 'tool');
  assert.equal(forA.length, 26, 'the first message and every reply');
  assert.equal(forA[0]!.text, 'first');
  assert.equal(first.sent.filter((m) => m.threadId === b.id).length, 1, "b's history went up on the later write");
  assert.deepEqual(JSON.parse(fs.readFileSync(statePath, 'utf8')).histories['https://x.convex.cloud'].sort(), [a.id, b.id].sort());
  // Next start: only what's newer than the mirror's newest message.
  const lastA = forA.at(-1)!.seq;
  const second = await start([{ threadId: a.id, lastSeq: lastA }, { threadId: b.id, lastSeq: 1 }]);
  assert.ok(second.posts.some((p) => p.fn === 'sync:messageHeads'));
  assert.equal(second.sent.filter((m) => m.role !== 'tool').length, 0);
});

test('a tool call becomes one line: the description, the file, the search, else the title', () => {
  const call = (kind: string, input: Record<string, unknown>, title = 'title') => toolLine({ name: 'Tool', kind, title, input });
  assert.equal(call('command', { command: 'npm test', description: 'Run the unit tests' }), 'Run the unit tests');
  assert.equal(call('command', { command: 'npm test\nmore' }, 'npm test'), 'Ran npm test');
  assert.equal(call('read', { file_path: '/Users/someone/dev/x.ts' }), 'Read ~/dev/x.ts');
  assert.equal(call('edit', { file_path: '/tmp/y.ts' }), 'Edited /tmp/y.ts');
  assert.equal(call('search', { pattern: 'TODO' }), 'Searched for TODO');
  assert.equal(call('web', { url: 'https://convex.dev' }), 'Fetched https://convex.dev');
  assert.equal(call('mcp', {}, 'agent-archive: search_archive'), 'agent-archive: search_archive');
  const doc = toMessageDoc('t1', { type: 'tool.call', seq: 7, ts: '2026-10-28T00:00:00.000Z', threadId: 't1', itemId: 'i', name: 'Bash', kind: 'command', title: 'ls', input: { command: 'ls' } } as never)!;
  assert.deepEqual(doc, { threadId: 't1', seq: 7, role: 'tool', text: 'Ran ls', toolKind: 'command', at: '2026-10-28T00:00:00.000Z' });
});

test('approvals: the row carries what the thread waits on until it is answered', async () => {
  const { h, sync, docs } = (() => {
    const f = setupFull();
    return { ...f, docs: () => f.calls.filter((c) => c.fn === 'sync:upsertThreads').flatMap((c) => c.args.threads as ThreadDoc[]) };
  })();
  sync.start();
  await sync.flushNow();
  const t = h.runner.create({ text: 'go', cwd: h.cfg.defaults.cwd, accountId: 'claude-3' }).thread;
  const s = session(h, t.id);
  s.init();
  s.out({ kind: 'event', event: { type: 'approval.requested', approvalId: 'ap1', itemId: 'c1', name: 'Bash', title: 'Run a command', input: { command: 'rm -rf build\necho done', description: 'clean' }, options: ['allow', 'allowAlways', 'deny'] } as never });
  h.clock.advance(SYNC_COALESCE_MS);
  await tick();
  let last = docs().filter((d) => d.threadId === t.id).at(-1)!;
  assert.deepEqual(last.pendingApproval, { approvalId: 'ap1', kind: 'approval', name: 'Bash', title: 'Run a command', options: ['allow', 'allowAlways', 'deny'], inputSummary: 'rm -rf build' });
  // Answered (the fake session plays the CLI's part: the resolved event).
  s.out({ kind: 'event', event: { type: 'approval.resolved', approvalId: 'ap1', decision: 'allow' } as never });
  h.clock.advance(SYNC_COALESCE_MS);
  await tick();
  last = docs().filter((d) => d.threadId === t.id).at(-1)!;
  assert.equal(last.pendingApproval, undefined);
  // A question, with no input to summarise.
  s.out({ kind: 'event', event: { type: 'question.requested', approvalId: 'q1', questions: [{ question: 'Which?', multiSelect: false, options: [{ label: 'A' }, { label: 'B', description: 'the other' }] }] } as never });
  h.clock.advance(SYNC_COALESCE_MS);
  await tick();
  last = docs().filter((d) => d.threadId === t.id).at(-1)!;
  assert.deepEqual(last.pendingApproval, { approvalId: 'q1', kind: 'question', questions: [{ question: 'Which?', multiSelect: false, options: [{ label: 'A' }, { label: 'B', description: 'the other' }] }] });
});

test('inputSummary picks the command or path, one line, never the whole input', () => {
  assert.equal(inputSummary({ description: 'x', command: '  npm test\nnpm run build ' }), 'npm test');
  assert.equal(inputSummary({ file_path: '/a/b.ts', content: 'lots' }), '/a/b.ts');
  assert.equal(inputSummary({ notes: 'y'.repeat(300) })!.length, 200);
  assert.equal(inputSummary({ n: 3 }), undefined);
});

test('lists: projects, schedules and accounts go up at start and when they change', async () => {
  const { h, sync, calls } = setupFull();
  sync.start();
  await sync.flushNow();
  const set = (name: string) => calls.filter((c) => c.fn === `sync:set${name}`);
  assert.equal(set('Projects').length, 1);
  assert.deepEqual(set('Projects')[0]!.args.projects, [{ id: 'p1', title: 'Threadbear', folders: ['/w'], goals: 'g', state: 's', notes: 'n', createdBy: 'mike', archived: false, createdAt: '2026-10-27T00:00:00.000Z', updatedAt: '2026-10-27T00:00:00.000Z', threadCount: 1 }]);
  assert.equal(set('Projects')[0]!.args.runnerId, 'r1');
  assert.deepEqual(set('Schedules')[0]!.args.schedules, [{ id: 's1', title: 'Nightly', text: 'go', whenText: 'every day at 3 am', paused: false, createdAt: '2026-10-27T00:00:00.000Z', updatedAt: '2026-10-27T00:00:00.000Z', runs: 2, cron: '0 3 * * *', lastRun: { at: '2026-10-27T03:00:00.000Z', outcome: 'sent', threadId: 't9' } }]);
  const accounts = set('Accounts')[0]!.args.accounts as Record<string, unknown>[];
  assert.deepEqual(accounts, [{ id: 'claude-3', provider: 'claude', title: 'three@example.com', usage: { windows: [{ kind: 'five_hour', title: '5-hour', remainingPercent: 80.5 }], readAt: '2026-10-27T00:00:00.000Z', source: 'live' } }]);
  assert.ok(!('configDir' in accounts[0]!) && !('models' in accounts[0]!));
  // A change: the whole list again.
  h.runner.publish({ method: 'projects.updated', params: { projects: [] } });
  h.clock.advance(SYNC_COALESCE_MS);
  await tick();
  assert.equal(set('Projects').length, 2);
  assert.deepEqual(set('Projects')[1]!.args.projects, []);
});

test('commands: each pending one is taken once, applied through the runner as from the phone, and finished', async () => {
  const { h, sync, calls, push, applied } = setupFull();
  sync.start();
  await sync.flushNow();
  const t = h.runner.create({ text: 'hello', cwd: h.cfg.defaults.cwd, accountId: 'claude-3' }).thread;
  const s = session(h, t.id);
  s.init();
  s.result('completed');
  await tick();
  const cmds: Command[] = [
    { commandId: 'c1', kind: 'send', threadId: t.id, args: { text: 'from my phone' }, createdAt: 1 },
    { commandId: 'c2', kind: 'update', threadId: t.id, args: { archive: true }, createdAt: 2 },
    { commandId: 'c3', kind: 'create', args: { text: 'a new one', cwd: h.cfg.defaults.cwd, accountId: 'claude-3' }, createdAt: 3 },
    { commandId: 'c4', kind: 'share', threadId: t.id, args: { access: 'link', newLink: true }, createdAt: 4 },
  ];
  push(cmds);
  await tick(10);
  push(cmds); // the same list again, as a live query re-run would send
  await tick(10);
  assert.deepEqual(applied, [`send ${t.id} from my phone phone`, `update {"threadId":"${t.id}","archived":true}`, 'create a new one phone', `share ${t.id} link new`]);
  const finished = calls.filter((c) => c.fn === 'sync:finishCommand').map((c) => c.args);
  assert.equal(finished.length, 4);
  assert.ok(finished.every((f) => f.ok === true && f.key === 'k'));
  assert.ok(typeof finished[2]!.resultThreadId === 'string');
  assert.equal(h.runner.get(finished[2]!.resultThreadId as string).title, 'a new one');
  // The message the phone sent is in the transcript, marked as from the phone.
  const ev = h.events(t.id).find((e: { type: string; text?: string }) => e.type === 'user.message' && e.text === 'from my phone') as { origin?: string };
  assert.equal(ev?.origin, 'phone');
  assert.equal(h.runner.get(t.id).archivedAt !== undefined, true);
  assert.equal(h.runner.get(t.id).share?.access, 'link');
  assert.deepEqual(sync.status().commands, { state: 'on', applied: 4, failed: 0 });
});

test('commands: a quickAsk is kept as a thread and finished with its id', async () => {
  const { h, sync, calls, push, applied } = setupFull();
  sync.start();
  await sync.flushNow();
  push([
    {
      commandId: 'q1',
      kind: 'quickAsk',
      args: { question: 'Which drive?', answer: 'CannMedia.', sources: [{ title: 'Notes', url: 'https://x.example/1' }, { nope: 1 }], askedAt: 5 },
      createdAt: 1,
    },
    { commandId: 'q2', kind: 'quickAsk', args: { question: 'no answer' }, createdAt: 2 },
  ]);
  await tick(10);
  assert.deepEqual(applied, ['quickAsk Which drive? 1']);
  const finished = calls.filter((c) => c.fn === 'sync:finishCommand').map((c) => c.args);
  assert.equal(finished.length, 2);
  assert.equal(finished[0]!.ok, true);
  const id = finished[0]!.resultThreadId as string;
  assert.equal(h.runner.get(id).title, 'Which drive?');
  assert.equal(h.adapter.sessions.length, 0, 'no turn ran');
  assert.equal(finished[1]!.ok, false);
  assert.equal(finished[1]!.note, 'no answer');
});

test('commands: one that fails is finished with a note; one another runner took is left alone', async () => {
  const taken = new Set(['c9']);
  const { h, sync, calls, push, applied } = setupFull({ taken, failApply: true });
  sync.start();
  await sync.flushNow();
  const t = h.runner.create({ text: 'hello', cwd: h.cfg.defaults.cwd, accountId: 'claude-3' }).thread;
  push([
    { commandId: 'c9', kind: 'send', threadId: t.id, args: { text: 'taken elsewhere' }, createdAt: 1 },
    { commandId: 'c10', kind: 'send', threadId: t.id, args: { text: 'fails' }, createdAt: 2 },
    { commandId: 'c11', kind: 'update', threadId: t.id, args: {}, createdAt: 3 },
  ]);
  await tick(10);
  assert.deepEqual(applied, [`send ${t.id} fails phone`]);
  const finished = calls.filter((c) => c.fn === 'sync:finishCommand').map((c) => c.args);
  assert.deepEqual(finished.map((f) => [f.commandId, f.ok, f.note]), [['c10', false, 'thread is busy'], ['c11', false, 'nothing to change']]);
  assert.equal(sync.status().commands?.failed, 2);
  assert.equal(sync.status().commands?.lastError, 'nothing to change');
});

test('commands: one for a thread that has gone is finished quietly; a forwarded one that fails is awaited', async () => {
  // The phone still showed a thread for a moment after it went: its
  // command fails, but that's a race, not a runner problem to warn about.
  const warned: string[] = [];
  const { h, sync, calls, push } = setupFull({ failApply: 'async', log: { ...nullLogger, warn: (m) => void warned.push(m) } });
  sync.start();
  await sync.flushNow();
  const gone = h.runner.create({ text: 'hello', cwd: h.cfg.defaults.cwd, accountId: 'claude-3' }).thread;
  h.runner.delete(gone.id);
  const t = h.runner.create({ text: 'still here', cwd: h.cfg.defaults.cwd, accountId: 'claude-3' }).thread;
  push([
    { commandId: 'g1', kind: 'update', threadId: gone.id, args: { markSeen: true }, createdAt: 1 },
    { commandId: 'g2', kind: 'update', threadId: gone.id, args: { archive: true }, createdAt: 2 },
    { commandId: 'g3', kind: 'send', threadId: t.id, args: { text: 'fails later' }, createdAt: 3 },
  ]);
  await tick(10);
  const finished = calls.filter((c) => c.fn === 'sync:finishCommand').map((c) => c.args);
  assert.deepEqual(finished.map((f) => [f.commandId, f.ok, f.note]), [
    ['g1', false, `Thread not found: ${gone.id}`],
    ['g2', false, `Thread not found: ${gone.id}`],
    ['g3', false, 'thread is busy'],
  ]);
  assert.deepEqual(warned.filter((m) => m.startsWith('phone')), ['phone command failed'], 'only the real failure is a warning');
});

test('commands: stop unsubscribes and nothing is applied after', async () => {
  const { h, sync, push, applied } = setupFull();
  sync.start();
  const t = h.runner.create({ text: 'hello', cwd: h.cfg.defaults.cwd, accountId: 'claude-3' }).thread;
  await sync.stop();
  push([{ commandId: 'c1', kind: 'send', threadId: t.id, args: { text: 'late' }, createdAt: 1 }]);
  await tick(10);
  assert.deepEqual(applied, []);
  assert.equal(sync.status().commands?.state, 'off');
});

test('toMessageDoc keeps text and tool calls, nothing else, and a schedule origin', () => {
  const base = { seq: 4, ts: '2026-10-27T00:00:00.000Z', threadId: 't', turnId: 'u' };
  assert.deepEqual(toMessageDoc('t', { ...base, type: 'user.message', text: 'hi', images: [], origin: 'schedule', scheduleId: 's1' } as never), { threadId: 't', seq: 4, role: 'user', text: 'hi', at: base.ts, origin: 'schedule' });
  assert.equal(toMessageDoc('t', { ...base, type: 'tool.call', itemId: 'i', name: 'Bash', kind: 'command', title: 'ls', input: {} } as never)?.role, 'tool');
  assert.equal(toMessageDoc('t', { ...base, type: 'tool.result', itemId: 'i', ok: true } as never), undefined);
  assert.equal(toMessageDoc('t', { ...base, type: 'reasoning', itemId: 'i', text: 'thinking' } as never), undefined);
});

// ------------------------------------------------------------ push text

import { pushText, PUSH_BODY_CHARS } from '../../../convex/pushText.ts';

test('pushText says why the thread needs Mike: the question, the approval, or the reply', () => {
  const base = { title: 'Fix the dock badge', status: 'idle', preview: 'Done, the badge clears when you open the thread.' };
  assert.deepEqual(pushText(base), { title: 'Fix the dock badge', body: 'Done, the badge clears when you open the thread.' });
  assert.deepEqual(pushText({ ...base, status: 'waiting', pendingApproval: { kind: 'approval', name: 'Bash', title: 'Run a command', inputSummary: 'npm test' } }), { title: 'Fix the dock badge', body: 'Run a command: npm test' });
  assert.deepEqual(pushText({ ...base, status: 'waiting', pendingApproval: { kind: 'question', questions: [{ question: 'Which colour?' }] } }), { title: 'Fix the dock badge', body: 'Which colour?' });
  assert.deepEqual(pushText({ ...base, status: 'error', preview: 'usage limit' }), { title: 'Fix the dock badge', body: 'Failed: usage limit' });
  assert.deepEqual(pushText({ title: '', status: 'idle', preview: '' }), { title: 'Threadbear', body: 'Finished' });
  const long = pushText({ ...base, preview: 'x'.repeat(500) + '\n\nmore' });
  assert.equal(long.body.length, PUSH_BODY_CHARS);
  assert.ok(long.body.endsWith('…'));
});

// ------------------------------------------------------------ paging

import { PAGE_SIZE } from '../../src/sync.ts';

test('paging: the row says where the thread starts, and a page command writes earlier messages as paged rows', async () => {
  const { h, sync, calls, push } = setupFull();
  const t = h.runner.create({ text: 'first', cwd: h.cfg.defaults.cwd, accountId: 'claude-3' }).thread;
  const s = session(h, t.id);
  s.init();
  for (let i = 0; i < PAGE_SIZE + 10; i++) s.text(`i${i}`, `reply ${i}`);
  s.result('completed');
  await tick();
  sync.start();
  await sync.flushNow();
  const rows = calls.filter((c) => c.fn === 'sync:upsertThreads').flatMap((c) => c.args.threads as ThreadDoc[]);
  assert.equal(rows.find((d) => d.threadId === t.id)!.earliestSeq, 1, 'the first user message');
  const before = calls.length;
  // The phone's oldest message is reply 40 (seq 42); it asks for the ones before it.
  const oldest = (await h.runner.events(t.id, { limit: 500 })).events.find((e) => e.type === 'assistant.text' && e.text === `reply ${PAGE_SIZE - 10}`)!;
  push([{ commandId: 'p1', kind: 'page', threadId: t.id, args: { beforeSeq: oldest.seq }, createdAt: 1 }]);
  await tick(10);
  const paged = calls.slice(before).filter((c) => c.fn === 'sync:appendMessages').flatMap((c) => c.args.messages as MessageDoc[]);
  assert.equal(paged.length, PAGE_SIZE - 10 + 1, 'everything before it: the first message and the earlier replies');
  assert.ok(paged.every((m) => m.seq < oldest.seq && typeof m.pagedAt === 'number'));
  assert.equal(paged[0]!.text, 'first');
  assert.equal(paged.at(-1)!.text, `reply ${PAGE_SIZE - 11}`);
  const finished = calls.filter((c) => c.fn === 'sync:finishCommand').map((c) => c.args);
  assert.deepEqual(finished.map((f) => [f.commandId, f.ok]), [['p1', true]]);
  // Nothing before the first message.
  push([{ commandId: 'p2', kind: 'page', threadId: t.id, args: { beforeSeq: 1 }, createdAt: 2 }]);
  await tick(10);
  assert.deepEqual(calls.filter((c) => c.fn === 'sync:finishCommand').at(-1)!.args.note, 'nothing earlier');
});

test('the backend API version from the heartbeat shows in status, and an old backend counts as 0', async () => {
  const fresh = setup({ answer: (fn) => (fn === 'sync:heartbeat' ? { apiVersion: BACKEND_API_VERSION } : null) });
  fresh.sync.start();
  await fresh.sync.flushNow();
  await tick();
  assert.deepEqual(fresh.sync.status().backend, { apiVersion: BACKEND_API_VERSION, expected: BACKEND_API_VERSION });
  await fresh.sync.stop();

  // A backend deployed before convex/version.ts answers the heartbeat with null.
  const old = setup();
  old.sync.start();
  await old.sync.flushNow();
  await tick();
  assert.deepEqual(old.sync.status().backend, { apiVersion: 0, expected: BACKEND_API_VERSION });
  await old.sync.stop();
});

// Project pictures: a runner with a picture for a project sends it to file
// storage once, when the backend takes pictures (API 5), and never again
// for the same copy.
function setupPictures(opts: { backend?: number; has?: { projectId: string; picture: string }[]; project?: Partial<Project> } = {}) {
  const h = makeHarness();
  const dir = tmpDir();
  // A tiny PNG by name only: the bytes don't matter to the sync, which
  // sends what's in the file.
  const iconPath = path.join(dir, 'p1-abc123.png');
  fs.writeFileSync(iconPath, Buffer.from('PNGBYTES'));
  const calls: Call[] = [];
  const uploads: { url: string; bytes: string; mediaType: string }[] = [];
  let project: Project = {
    id: 'p1', title: 'Threadbear', folders: ['/w'], goals: 'g', state: 's', notes: 'n', links: [], createdBy: 'mike',
    createdAt: '2026-10-27T00:00:00.000Z', updatedAt: '2026-10-27T00:00:00.000Z', threadCount: 1,
    icon: { image: { path: iconPath, mediaType: 'image/png', width: 64, height: 64 }, symbol: 'leaf', by: 'librarian', updatedAt: '2026-10-27T00:00:00.000Z' },
    ...opts.project,
  };
  const post = async (kind: 'mutation' | 'query', fn: string, args: Record<string, unknown>) => {
    calls.push({ kind, fn, args });
    if (fn === 'sync:heartbeat') return { apiVersion: opts.backend ?? ICONS_API_VERSION };
    if (fn === 'sync:projectIcons') return opts.has ?? [];
    if (fn === 'sync:iconUploadUrl') return 'https://upload.example/u1';
    return null;
  };
  const sync = new ConvexSync({
    config: { enabled: true, url: 'https://x.convex.cloud', runnerId: 'r1' },
    key: 'k',
    runner: { onNotification: (fn) => h.runner.onNotification(fn), list: (i) => h.runner.list(i), get: (id) => h.runner.get(id), events: (id, o) => h.runner.events(id, o), listProjects: () => [project] },
    version: '0.1.0+test',
    startedAt: '2026-10-27T00:00:00.000Z',
    clock: h.clock,
    log: nullLogger,
    post,
    upload: async (url, bytes, mediaType) => {
      uploads.push({ url, bytes: Buffer.from(bytes).toString(), mediaType });
      return `st_${uploads.length}`;
    },
  });
  const setIcons = () => calls.filter((c) => c.fn === 'sync:setProjectIcon');
  const change = (next: Partial<Project>) => {
    project = { ...project, ...next };
    h.runner.publish({ method: 'projects.updated', params: { projects: [project] } });
  };
  return { h, sync, calls, uploads, setIcons, change, iconPath, dir };
}

test('project pictures: sent to file storage once the backend takes them, once per copy, with the symbol on the project', async () => {
  const { h, sync, calls, uploads, setIcons, change, iconPath, dir } = setupPictures();
  sync.start();
  await sync.flushNow();
  await tick();
  // The project went up with its icon named, and the picture itself followed.
  const set = calls.filter((c) => c.fn === 'sync:setProjects');
  assert.deepEqual((set[0]!.args.projects as { icon?: unknown }[])[0]!.icon, { symbol: 'leaf', picture: 'p1-abc123', by: 'librarian' });
  assert.deepEqual(uploads, [{ url: 'https://upload.example/u1', bytes: 'PNGBYTES', mediaType: 'image/png' }]);
  assert.deepEqual(setIcons()[0]!.args, { key: 'k', runnerId: 'r1', projectId: 'p1', picture: 'p1-abc123', storageId: 'st_1', mediaType: 'image/png' });
  // The list changing again doesn't send the same picture again.
  change({ title: 'Threadbear app' });
  h.clock.advance(SYNC_COALESCE_MS);
  await tick(20);
  assert.equal(uploads.length, 1);
  // A new copy (a new file name) does.
  const next = path.join(dir, 'p1-def456.png');
  fs.writeFileSync(next, Buffer.from('NEWBYTES'));
  change({ icon: { image: { path: next, mediaType: 'image/png' }, by: 'mike', updatedAt: '2026-10-28T00:00:00.000Z' } });
  h.clock.advance(SYNC_COALESCE_MS);
  await tick(20);
  assert.equal(uploads.length, 2);
  assert.equal(uploads[1]!.bytes, 'NEWBYTES');
  assert.equal(setIcons()[1]!.args.picture, 'p1-def456');
  // Back to a symbol only: nothing to upload, and the mirror drops the
  // picture with setProjects.
  change({ icon: { symbol: 'leaf', by: 'librarian', updatedAt: '2026-10-28T00:00:00.000Z' } });
  h.clock.advance(SYNC_COALESCE_MS);
  await tick(20);
  assert.equal(uploads.length, 2);
  assert.deepEqual((calls.filter((c) => c.fn === 'sync:setProjects').at(-1)!.args.projects as { icon?: unknown }[])[0]!.icon, { symbol: 'leaf', by: 'librarian' });
  fs.rmSync(iconPath, { force: true });
  await sync.stop();
});

test('project pictures: one the mirror already has is not sent again, and an older backend gets none', async () => {
  const has = setupPictures({ has: [{ projectId: 'p1', picture: 'p1-abc123' }] });
  has.sync.start();
  await has.sync.flushNow();
  await tick();
  assert.equal(has.uploads.length, 0);
  assert.equal(has.setIcons().length, 0);
  await has.sync.stop();

  const old = setupPictures({ backend: ICONS_API_VERSION - 1 });
  old.sync.start();
  await old.sync.flushNow();
  await tick();
  assert.equal(old.uploads.length, 0);
  assert.ok(!old.calls.some((c) => c.fn === 'sync:projectIcons' || c.fn === 'sync:iconUploadUrl'));
  // The project still names its icon, for a phone that can show the symbol.
  const set = old.calls.filter((c) => c.fn === 'sync:setProjects');
  assert.deepEqual((set[0]!.args.projects as { icon?: unknown }[])[0]!.icon, { symbol: 'leaf', picture: 'p1-abc123', by: 'librarian' });
  await old.sync.stop();
});

test('project pictures: a picture that cannot be read is skipped, not retried until the projects change', async () => {
  const { sync, uploads, iconPath, h, change, dir } = setupPictures();
  fs.rmSync(iconPath, { force: true });
  sync.start();
  await sync.flushNow();
  await tick();
  assert.equal(uploads.length, 0);
  assert.equal(sync.status().state, 'ok');
  // Fixed and changed: sent then.
  const fixed = path.join(dir, 'p1-fixed.png');
  fs.writeFileSync(fixed, Buffer.from('OK'));
  change({ icon: { image: { path: fixed, mediaType: 'image/png' }, by: 'librarian', updatedAt: '2026-10-28T00:00:00.000Z' } });
  h.clock.advance(SYNC_COALESCE_MS);
  await tick(20);
  assert.equal(uploads.length, 1);
  await sync.stop();
});

test('the uploader posts the bytes to the upload URL and reads the storage id back', async () => {
  const seen: { url: string; init: RequestInit }[] = [];
  const fetchFn = (async (url: string | URL | Request, init?: RequestInit) => {
    seen.push({ url: String(url), init: init! });
    return new Response(JSON.stringify({ storageId: 'st_9' }), { status: 200 });
  }) as unknown as typeof fetch;
  const upload = convexUploader(fetchFn);
  assert.equal(await upload('https://upload.example/u', new Uint8Array([1, 2, 3]), 'image/png'), 'st_9');
  assert.equal(seen[0]!.url, 'https://upload.example/u');
  assert.equal((seen[0]!.init.headers as Record<string, string>)['Content-Type'], 'image/png');
  const bad = convexUploader((async () => new Response('nope', { status: 500 })) as unknown as typeof fetch);
  await assert.rejects(bad('https://upload.example/u', new Uint8Array(), 'image/png'), /HTTP 500/);
  assert.equal(pictureName('/x/project-icons/p1-abc.png'), 'p1-abc');
  assert.equal(pictureName('/x/project-icons/p1-abc'), 'p1-abc');
});

test("the runner's expected backend API version is the one convex/version.ts declares", () => {
  const src = fs.readFileSync(path.join(import.meta.dirname, '..', '..', '..', 'convex', 'version.ts'), 'utf8');
  const declared = Number(src.match(/export const API_VERSION = (\d+);/)?.[1]);
  assert.equal(BACKEND_API_VERSION, declared, 'bump BACKEND_API_VERSION in runner/src/sync.ts along with convex/version.ts');
});

test('presence: sent at start, then only when it changes', async () => {
  let atMac = true;
  const h = makeHarness();
  const calls: Call[] = [];
  const sync = new ConvexSync({
    config: { enabled: true, url: 'https://x.convex.cloud', runnerId: 'r1' },
    key: 'k',
    runner: h.runner,
    presence: () => atMac,
    version: 'v',
    startedAt: 'now',
    clock: h.clock,
    log: nullLogger,
    post: async (kind, fn, args) => {
      calls.push({ kind, fn, args });
      return null;
    },
  });
  const sent = () => calls.filter((c) => c.fn === 'sync:setPresence').map((c) => c.args.atMac);
  sync.start();
  await tick();
  assert.deepEqual(sent(), [true]);
  h.clock.advance(PRESENCE_MS);
  await tick();
  assert.deepEqual(sent(), [true], 'unchanged, not sent again');
  atMac = false;
  h.clock.advance(PRESENCE_MS);
  await tick();
  assert.deepEqual(sent(), [true, false]);
  await sync.stop();
});

test('presence: an async check (ioreg off the event loop) is awaited, and a failed one counts as away', async () => {
  let answer: () => Promise<boolean> = async () => true;
  const h = makeHarness();
  const calls: Call[] = [];
  const sync = new ConvexSync({
    config: { enabled: true, url: 'https://x.convex.cloud', runnerId: 'r1' },
    key: 'k',
    runner: h.runner,
    presence: () => answer(),
    version: 'v',
    startedAt: 'now',
    clock: h.clock,
    log: nullLogger,
    post: async (kind, fn, args) => {
      calls.push({ kind, fn, args });
      return null;
    },
  });
  const sent = () => calls.filter((c) => c.fn === 'sync:setPresence').map((c) => c.args.atMac);
  sync.start();
  await tick();
  assert.deepEqual(sent(), [true]);
  answer = async () => {
    throw new Error('ioreg timed out');
  };
  h.clock.advance(PRESENCE_MS);
  await tick();
  assert.deepEqual(sent(), [true, false]);
  await sync.stop();
});

test('at the Mac means the Mac app is connected and the keyboard or mouse was used lately', () => {
  assert.equal(isAtMac(true, 5_000), true);
  assert.equal(isAtMac(true, AT_MAC_IDLE_MS + 1), false, 'stepped away');
  assert.equal(isAtMac(false, 5_000), false, 'the app is closed');
  assert.equal(isAtMac(true, undefined), false, "can't tell, so away");
});

test('a woken thread\'s row carries woke, once the backend takes it', async () => {
  let backend = WOKE_API_VERSION - 1;
  const { h, sync, docs } = setup({ answer: (fn) => (fn === 'sync:heartbeat' ? { apiVersion: backend } : null) });
  const a = h.runner.create({ text: 'one', cwd: h.cfg.defaults.cwd, accountId: 'claude-3' }).thread;
  h.adapter.last.init();
  h.adapter.last.result();
  h.runner.update({ threadId: a.id, snoozedUntil: new Date(h.clock.now() + 60_000).toISOString() });
  h.clock.advance(60_000);
  assert.ok(h.runner.get(a.id).woke);
  sync.start();
  await tick(20);
  await sync.flushNow();
  // An older backend would turn the row down with woke on it.
  const old = docs().filter((d) => d.threadId === a.id);
  assert.ok(old.length);
  assert.ok(old.every((d) => d.woke === undefined));
  backend = WOKE_API_VERSION;
  await sync.stop();
  sync.start();
  await tick(20);
  await sync.flushNow();
  assert.deepEqual(docs().filter((d) => d.threadId === a.id).at(-1)!.woke, h.runner.get(a.id).woke);
  await sync.stop();
});

test('sharing: the row carries share, "off" included, once the backend takes it', async () => {
  let backend = SHARE_API_VERSION - 1;
  const { h, sync, docs } = setup({ answer: (fn) => (fn === 'sync:heartbeat' ? { apiVersion: backend } : null) });
  const a = h.runner.create({ text: 'one', cwd: h.cfg.defaults.cwd, accountId: 'claude-3' }).thread;
  h.runner.share(a.id, { access: 'link' });
  sync.start();
  await tick(20);
  await sync.flushNow();
  // An older backend would turn the row down with share on it.
  const old = docs().filter((d) => d.threadId === a.id);
  assert.ok(old.length);
  assert.ok(old.every((d) => d.share === undefined));

  // Once the backend is new enough the shared thread goes again, with it.
  backend = SHARE_API_VERSION;
  await sync.stop();
  sync.start();
  await tick(20);
  await sync.flushNow();
  const slug = h.runner.get(a.id).share!.slug;
  assert.deepEqual(docs().filter((d) => d.threadId === a.id).at(-1)!.share, { access: 'link', slug });

  // "off" goes up too, so Mike's page for the link keeps its controls.
  h.runner.share(a.id, { access: 'off' });
  h.clock.advance(SYNC_COALESCE_MS);
  await tick(20);
  await sync.flushNow();
  assert.deepEqual(docs().filter((d) => d.threadId === a.id).at(-1)!.share, { access: 'off', slug });
});

test('sharing: pictures of a shared thread go to file storage, once each, and go when it stops', async () => {
  const dir = tmpDir();
  const pic = path.join(dir, 'chart.png');
  fs.writeFileSync(pic, Buffer.from('PNGBYTES'));
  const calls: Call[] = [];
  const uploads: string[] = [];
  let stored: { seq: number; path: string }[] = [];
  const h = makeHarness();
  const sync = new ConvexSync({
    config: { enabled: true, url: 'https://x.convex.cloud', runnerId: 'r1' },
    key: 'k',
    runner: h.runner,
    version: '0.1.0+test',
    startedAt: '2026-10-29T00:00:00.000Z',
    clock: h.clock,
    log: nullLogger,
    post: async (kind, fn, args) => {
      calls.push({ kind, fn, args });
      if (fn === 'sync:heartbeat') return { apiVersion: SHARE_API_VERSION };
      if (fn === 'sync:shareImages') return stored;
      if (fn === 'sync:iconUploadUrl') return 'https://upload.example/u';
      return null;
    },
    upload: async (_url, bytes) => {
      uploads.push(Buffer.from(bytes).toString());
      return `st_${uploads.length}`;
    },
  });
  const t = h.runner.create({ text: 'draw it', cwd: h.cfg.defaults.cwd, accountId: 'claude-3' }).thread;
  const s = session(h, t.id);
  s.init();
  s.text('m1', `Here it is:\n\n![The chart](${pic})\n\nand a [link](https://example.com).`);
  s.result('completed');
  await tick();

  // Not shared: nothing goes up.
  sync.start();
  await tick(20);
  await sync.flushNow();
  assert.equal(uploads.length, 0);

  // Shared: the picture the agent wrote in its text goes up, with its src.
  h.runner.share(t.id, { access: 'link' });
  h.clock.advance(SYNC_COALESCE_MS);
  await tick(20);
  await sync.flushNow();
  const added = calls.filter((c) => c.fn === 'sync:addShareImage').map((c) => c.args);
  assert.equal(added.length, 1);
  assert.equal(added[0]!.path, pic);
  assert.equal(added[0]!.src, pic);
  assert.equal(added[0]!.mediaType, 'image/png');
  assert.equal(added[0]!.storageId, 'st_1');
  assert.deepEqual(uploads, ['PNGBYTES']);

  // A restart doesn't send it again: the mirror says it has it.
  stored = [{ seq: added[0]!.seq as number, path: pic }];
  await sync.stop();
  sync.start();
  await tick(20);
  await sync.flushNow();
  assert.equal(uploads.length, 1);

  // Stopping sharing drops them from the mirror.
  h.runner.share(t.id, { access: 'off' });
  h.clock.advance(SYNC_COALESCE_MS);
  await tick(20);
  await sync.flushNow();
  assert.deepEqual(calls.filter((c) => c.fn === 'sync:dropShareImages').map((c) => c.args), [{ key: 'k', threadId: t.id }]);
});

test('sharing: a shared thread seen before it comes across in a handover has its pictures sent once it arrives', async () => {
  const dir = tmpDir();
  const pic = path.join(dir, 'shot.png');
  fs.writeFileSync(pic, Buffer.from('PNGBYTES'));
  const calls: Call[] = [];
  const h = makeHarness();
  const t = h.runner.create({ text: 'look', cwd: h.cfg.defaults.cwd, accountId: 'claude-3' }).thread;
  const s = session(h, t.id);
  s.init();
  s.text('m1', `![shot](${pic})`);
  s.result('completed');
  await tick();
  h.runner.share(t.id, { access: 'link' });
  // Still on the draining runner: its update comes through, but this
  // runner can't read the thread yet.
  let here = false;
  const sync = new ConvexSync({
    config: { enabled: true, url: 'https://x.convex.cloud', runnerId: 'r1' },
    key: 'k',
    runner: {
      onNotification: (fn) => h.runner.onNotification(fn),
      list: (i) => (here ? h.runner.list(i) : []),
      get: (id) => {
        if (!here) throw new Error('no such thread');
        return h.runner.get(id);
      },
      events: (id, o) => h.runner.events(id, o),
    },
    version: '0.1.0+test',
    startedAt: '2026-10-29T00:00:00.000Z',
    clock: h.clock,
    log: nullLogger,
    post: async (kind, fn, args) => {
      calls.push({ kind, fn, args });
      if (fn === 'sync:heartbeat') return { apiVersion: SHARE_API_VERSION };
      if (fn === 'sync:shareImages') return [];
      if (fn === 'sync:iconUploadUrl') return 'https://upload.example/u';
      return null;
    },
    upload: async () => 'st_1',
  });
  sync.start();
  await tick(20);
  h.runner.publish({ method: 'thread.updated', params: { thread: h.runner.get(t.id) } });
  h.clock.advance(SYNC_COALESCE_MS);
  await tick(20);
  await sync.flushNow();
  assert.equal(calls.filter((c) => c.fn === 'sync:addShareImage').length, 0);
  // It comes across: its update now finds it here.
  here = true;
  h.runner.publish({ method: 'thread.updated', params: { thread: h.runner.get(t.id) } });
  h.clock.advance(SYNC_COALESCE_MS);
  await tick(20);
  await sync.flushNow();
  assert.equal(calls.filter((c) => c.fn === 'sync:addShareImage').length, 1);
});

test('schedules: a backend of API 9 gets the scheduler attached, and schedules stop being mirrored', async () => {
  let inBackend = false;
  const attached: ScheduleBackend[] = [];
  const old = setup({
    answer: (fn) => (fn === 'sync:heartbeat' ? { apiVersion: SCHEDULES_API_VERSION - 1 } : null),
    schedules: { attach: (b) => void attached.push(b), inBackend: () => inBackend },
  });
  old.sync.start();
  await tick();
  assert.equal(attached.length, 0, 'an older backend keeps them in the file');
  await old.sync.stop();

  const answers: Record<string, unknown> = { 'sync:heartbeat': { apiVersion: SCHEDULES_API_VERSION }, 'sync:claimSchedule': true, 'sync:runnersList': [{ runnerId: 'r2', name: 'bruce', lastSeenAt: 5 }] };
  const f = setup({ answer: (fn) => answers[fn] ?? null, schedules: { attach: (b) => void attached.push(b), inBackend: () => inBackend } });
  f.sync.start();
  await tick();
  assert.equal(attached.length, 1);
  const b = attached[0]!;
  assert.equal(await b.claim('s1', 'due', '2026-10-27T03:00:00.000Z'), true);
  const claim = f.calls.find((c) => c.fn === 'sync:claimSchedule')!;
  assert.deepEqual({ ...claim.args, holder: undefined }, { key: 'k', runnerId: 'r1', scheduleId: 's1', holder: undefined, kind: 'due', expect: '2026-10-27T03:00:00.000Z' });
  assert.match(String(claim.args.holder), /^r1:\d+:2026-10-27T00:00:00.000Z$/);
  assert.deepEqual(await b.runners(), [{ id: 'r2', name: 'bruce', lastSeenAt: 5 }]);
  await b.save({ id: 's9', runnerId: 'r2', title: 't', text: 'x', whenText: 'Every day at 0:00', cron: '@daily', paused: false, createdAt: 'c', updatedAt: 'u', runs: 0 });
  assert.deepEqual(f.calls.find((c) => c.fn === 'sync:saveSchedule')!.args.schedule, { id: 's9', runnerId: 'r2', title: 't', text: 'x', whenText: 'Every day at 0:00', paused: false, createdAt: 'c', updatedAt: 'u', runs: 0, cron: '@daily' });

  // Once they live in the backend, a schedules.updated isn't mirrored.
  inBackend = true;
  f.h.runner.publish({ method: 'schedules.updated', params: { schedules: [] } });
  f.h.clock.advance(SYNC_COALESCE_MS);
  await tick();
  assert.equal(f.calls.filter((c) => c.fn === 'sync:setSchedules').length, 0);
  await f.sync.stop();
});

test('the heartbeat carries the runner icon once the backend takes it', async () => {
  let api = RUNNER_ICON_API_VERSION - 1;
  const f = setup({ config: { icon: 'macmini' }, answer: (fn) => (fn === 'sync:heartbeat' ? { apiVersion: api } : null) });
  f.sync.start();
  await tick();
  const beats = () => f.calls.filter((c) => c.fn === 'sync:heartbeat').map((c) => (c.args.runner as { icon?: string }).icon);
  assert.deepEqual(beats(), [undefined], 'not to an older backend, whose validator would refuse it');
  api = RUNNER_ICON_API_VERSION;
  f.h.clock.advance(HEARTBEAT_MS);
  await tick();
  f.h.clock.advance(HEARTBEAT_MS);
  await tick();
  assert.equal(beats().at(-1), 'macmini');
  await f.sync.stop();
});

test('end-of-turn cards: the open asks (web links only) and next steps go on the row, the bullets are marked', () => {
  const now = Date.parse('2026-10-30T10:00:00.000Z');
  const base = {
    id: 't1', title: 'T', cwd: '/w', accountId: 'claude-3', provider: 'claude' as const, permissionMode: 'full' as const, status: 'idle' as const, live: false, needsYou: true,
    createdAt: '2026-10-30T09:00:00.000Z', updatedAt: '2026-10-30T09:30:00.000Z', lastActivityAt: '2026-10-30T09:30:00.000Z', preview: 'p', lastSeq: 9, lastSeenSeq: 9,
  };
  const doc = toThreadDoc({
    ...base,
    needs: 'you',
    asksSeq: 8,
    asks: [
      { action: 'Merge it?', why: 'Tests pass.', where: 'GitHub', options: ['Merge', 'Not yet'], suggested: 0, links: [{ title: 'Open PR', url: 'https://github.com/x/y/pull/1' }, { title: 'See shot', url: '/Users/m/shot.png' }] },
      { action: 'Add the key.', why: 'Settings.', reply: 'done', ticked: true, links: [{ title: 'File', url: '~/notes.md' }] },
    ],
  }, 'r', now);
  assert.equal(doc.asksSeq, 8);
  assert.deepEqual(doc.asks, [
    { action: 'Merge it?', why: 'Tests pass.', options: ['Merge', 'Not yet'], suggested: 0, links: [{ title: 'Open PR', url: 'https://github.com/x/y/pull/1' }] },
    { action: 'Add the key.', why: 'Settings.', reply: 'done', ticked: true },
  ]);
  const done = toThreadDoc({ ...base, needsYou: false, needs: 'nothing' }, 'r', now, undefined, undefined, ['Ship it']);
  assert.deepEqual(done.next, ['Ship it']);
  assert.ok(!('asks' in done) && !('asksSeq' in done));
  const ts = '2026-10-30T09:30:00.000Z';
  assert.equal(toMessageDoc('t', { seq: 5, ts, threadId: 't', type: 'assistant.text', itemId: 'i.summary', text: '- did it', summary: true } as never)?.summary, true);
  assert.ok(!('summary' in toMessageDoc('t', { seq: 4, ts, threadId: 't', type: 'assistant.text', itemId: 'i', text: 'hi' } as never)!));
});

test('commands: a send from the phone keeps the asks it answers', async () => {
  const { h, sync, push } = setupFull();
  sync.start();
  await sync.flushNow();
  const t = h.runner.create({ text: 'hello', cwd: h.cfg.defaults.cwd, accountId: 'claude-3' }).thread;
  const s = session(h, t.id);
  s.init();
  s.result('completed');
  await tick();
  push([{ commandId: 'a1', kind: 'send', threadId: t.id, args: { text: '1. Merge it?\nMerge', answers: [{ action: 'Merge it?', answer: 'Merge' }, { bad: true }] }, createdAt: 1 }]);
  await tick(10);
  const ev = h.events(t.id).find((e: { type: string; text?: string }) => e.type === 'user.message' && e.text?.startsWith('1. Merge')) as { answers?: unknown; origin?: string };
  assert.equal(ev?.origin, 'phone');
  assert.deepEqual(ev?.answers, [{ action: 'Merge it?', answer: 'Merge' }]);
});
