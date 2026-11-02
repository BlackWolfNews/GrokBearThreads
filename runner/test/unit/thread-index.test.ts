// The sidebar table (src/thread-index.ts, step 6 part 2) against a fake
// backend: what it writes, when it doesn't, and what the app hears.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { makeHarness, tick } from '../helpers/fakes.ts';
import { ThreadIndex, runnerTokenFile, type RemoteThreads } from '../../src/thread-index.ts';
import { nullLogger } from '../../src/log.ts';
import type { Notification } from '../../src/runner.ts';

function setup(takesStartedBy?: () => boolean, appConnected?: () => boolean) {
  const h = makeHarness();
  const writes: { rows: { threadId: string; title: string; preview: string; status: string }[]; removed: string[]; keep?: string[] }[] = [];
  let onRemote: ((v: unknown) => void) | undefined;
  let subscriptions = 0;
  const heard: RemoteThreads[] = [];
  const index = new ThreadIndex({
    post: async (_kind, fn, args) => {
      if (fn === 'sync:setThreadIndex') writes.push(args as never);
      return null;
    },
    subscribe: (fn, args, onUpdate) => {
      assert.equal(fn, 'sync:otherRunnersThreads');
      assert.deepEqual(args, { key: 'k', runnerId: 'r-m5' });
      onRemote = onUpdate;
      subscriptions++;
      return () => {
        onRemote = undefined;
      };
    },
    key: 'k',
    runnerId: 'r-m5',
    home: h.home,
    host: h.runner,
    publish: (n: Notification) => n.method === 'remoteThreads.updated' && heard.push(n.params),
    clock: h.clock,
    log: nullLogger,
    ...(takesStartedBy ? { takesStartedBy } : {}),
    ...(appConnected ? { appConnected } : {}),
  });
  const flush = async () => {
    h.clock.advance(1500);
    await tick();
  };
  return { h, index, writes, heard, flush, remote: (v: unknown) => onRemote?.(v), watching: () => Boolean(onRemote), subscriptions: () => subscriptions };
}

test('the first write has every thread and prunes the rest; later ones only what a sidebar shows', async () => {
  const { h, index, writes, flush } = setup();
  const { thread } = h.runner.create({ text: 'Fix the deploy', accountId: 'claude-3' });
  index.start();
  await flush();
  assert.equal(writes.length, 1);
  assert.deepEqual(writes[0]!.keep, [thread.id]);
  assert.equal(writes[0]!.rows[0]!.threadId, thread.id);

  // A turn going: once it's running and has said something (it's unread
  // now), more replies move only the preview and last activity. No write.
  const s = h.adapter.last;
  s.init();
  s.text('a1', 'Looking at the logs now');
  await flush();
  const settled = writes.length;
  assert.ok(settled >= 2, 'starting the turn changed its status');
  s.delta('a2', 'And the config');
  s.text('a2', 'And the config too');
  await flush();
  s.text('a3', 'Found it');
  await flush();
  assert.equal(writes.length, settled, 'new replies alone write nothing');

  // A rename does.
  h.runner.update({ threadId: thread.id, title: 'Deploy fix' });
  await flush();
  assert.equal(writes.at(-1)!.rows[0]!.title, 'Deploy fix');
  assert.equal(writes.at(-1)!.keep, undefined);

  // So does deleting it.
  h.runner.delete(thread.id);
  await flush();
  assert.deepEqual(writes.at(-1)!.removed, [thread.id]);
  index.stop();
});

test('other runners’ threads reach the app, with a token file only when one was copied in', async () => {
  const { h, index, heard, remote } = setup();
  index.start();
  const lastSeenAt = h.clock.now() - 30_000;
  const value = {
    runners: [{ runnerId: 'r-bruce', name: 'bruce', icon: 'macmini', lastSeenAt, rpcUrl: 'wss://bruce.example.ts.net:8797/rpc' }],
    threads: [{ runnerId: 'r-bruce', threadId: 't1', title: 'Birthday check', cwd: '/Users/bruce', accountId: 'codex-main', provider: 'codex', status: 'idle', needsYou: false, unread: true, preview: 'No birthdays', createdAt: 'c', lastActivityAt: 'l' }],
  };
  remote(value);
  assert.equal(heard.length, 1);
  assert.deepEqual(heard[0]!.runners, [{ id: 'r-bruce', name: 'bruce', icon: 'macmini', online: true, lastSeenAt: new Date(lastSeenAt).toISOString(), rpcUrl: 'wss://bruce.example.ts.net:8797/rpc' }]);
  assert.equal(heard[0]!.threads[0]!.title, 'Birthday check');

  const file = runnerTokenFile(h.home, 'r-bruce');
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, 'secret\n', { mode: 0o600 });
  assert.equal(index.list().runners[0]!.tokenFile, file);
  index.stop();
});

test('a row carries who started the thread, once the backend takes it, and goes again when it does', async () => {
  let takes = false;
  const { h, index, writes, flush } = setup(() => takes);
  const from = h.runner.create({ text: 'The parent', accountId: 'claude-3' }).thread;
  const { thread } = h.runner.create({ text: 'Fix it', accountId: 'claude-3', startedBy: { kind: 'thread', label: 'Agent', threadId: from.id, why: 'fixing a hook' } });
  index.start();
  await flush();
  const row = () => writes.flatMap((w) => w.rows).filter((r) => r.threadId === thread.id).at(-1) as unknown as { startedBy?: unknown };
  assert.equal(row().startedBy, undefined, 'an older backend would turn the batch down');
  takes = true;
  const before = writes.length;
  index.refresh();
  await flush();
  assert.ok(writes.length > before);
  assert.deepEqual(row().startedBy, { kind: 'thread', label: 'Agent', threadTitle: 'The parent', why: 'fixing a hook' });
  index.stop();
});

test('other runners’ threads are watched only while a Mac app is connected', async () => {
  let app = false;
  const { h, index, heard, remote, watching, subscriptions } = setup(undefined, () => app);
  index.start();
  assert.equal(watching(), false, 'no app (Bruce): nothing watched');
  h.clock.advance(60_000);
  await tick();
  assert.equal(watching(), false);

  // An app connecting asks for the list, which starts the watch at once.
  app = true;
  assert.deepEqual(index.list().threads, []);
  assert.equal(watching(), true);
  remote({ runners: [{ runnerId: 'r-bruce', name: 'bruce', lastSeenAt: h.clock.now() }], threads: [] });
  assert.equal(heard.length, 1);

  // A relaunch, gone for under two minutes, keeps the watch.
  app = false;
  h.clock.advance(60_000);
  await tick();
  assert.equal(watching(), true);
  app = true;
  h.clock.advance(15_000);
  await tick();
  app = false;
  h.clock.advance(3 * 60_000);
  await tick();
  assert.equal(watching(), false, 'gone for good: the watch stops');
  assert.equal(index.list().runners[0]!.name, 'bruce', 'what was heard stays for the next app');
  assert.equal(watching(), true);
  assert.equal(subscriptions(), 2);

  // Connected without asking (the periodic check finds it).
  app = false;
  h.clock.advance(3 * 60_000);
  await tick();
  assert.equal(watching(), false);
  app = true;
  h.clock.advance(15_000);
  await tick();
  assert.equal(watching(), true);
  index.stop();
  assert.equal(watching(), false);
});
