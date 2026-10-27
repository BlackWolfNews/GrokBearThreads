// Handovers (docs/protocol.md): a draining runner lets go of idle threads
// at once, keeps busy ones until nothing would be cut short, and a new
// runner on the same data dir adopts each one it hands over.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { FakeAccounts, FakeAdapter, makeHarness, testConfig, tick, type Harness } from '../helpers/fakes.ts';
import { Runner, type Notification } from '../../src/runner.ts';
import { ThreadStore } from '../../src/store.ts';
import { FakeClock } from '../../src/clock.ts';
import { nullLogger } from '../../src/log.ts';
import { ErrorCode, RpcError } from '../../src/protocol.ts';

const MIN = 60_000;

function create(h: Harness, text = 'Fix the tests') {
  return h.runner.create({ text, accountId: 'claude-3' });
}

// A second runner on the same data dir, as the new release would be.
function primary(h: Harness, skip: string[]) {
  const adapter = new FakeAdapter();
  const notes: Notification[] = [];
  const runner = new Runner({
    config: testConfig(h.home),
    store: new ThreadStore(h.home),
    adapters: { claude: adapter, codex: new FakeAdapter('codex') },
    accounts: new FakeAccounts(),
    clock: new FakeClock(),
    log: nullLogger,
    defer: (fn) => fn(),
    copyTranscript: () => false,
  });
  runner.onNotification((n) => notes.push(n));
  runner.start({ skip: new Set(skip) });
  return { runner, adapter, notes };
}

test('a draining runner lets idle threads go at once and keeps a busy one until its turn ends', async () => {
  const h = makeHarness();
  const idle = create(h, 'idle one').thread;
  const s1 = h.adapter.last;
  s1.init();
  s1.result('completed');
  const busy = create(h, 'busy one').thread;
  const s2 = h.adapter.last;
  s2.init();
  const handed: string[] = [];
  await h.runner.beginDrain([busy.id], { onHandedOver: (id) => handed.push(id), backgroundMs: 30 * MIN });
  // The idle CLI exited and the runner no longer has the thread.
  assert.equal(s1.ended, true);
  assert.equal(h.runner.has(idle.id), false);
  assert.deepEqual(h.runner.keeping(), [busy.id]);
  assert.deepEqual(handed, []);
  // New threads belong on the new runner.
  assert.throws(() => create(h, 'new'), (e: unknown) => e instanceof RpcError && e.code === ErrorCode.busy);

  // The new runner loads the idle thread but not the busy one.
  const b = primary(h, [busy.id]);
  assert.deepEqual(b.runner.threadIds(), [idle.id]);

  s2.text('m1:0', 'done');
  s2.result('completed');
  await tick();
  assert.equal(s2.ended, true);
  assert.deepEqual(handed, [busy.id]);
  assert.deepEqual(h.runner.keeping(), []);
  const adopted = b.runner.adopt(busy.id)!;
  assert.equal(adopted.status, 'idle');
  assert.equal(adopted.lastSeq, h.store.log(busy.id).lastSeq);
  // It carries on there: the next message resumes the same session.
  b.runner.send(busy.id, 'and then');
  assert.equal(b.adapter.last.opts.resume, true);
  assert.equal(b.adapter.last.opts.sessionId, s2.opts.sessionId);
});

test('a message queued during the turn moves across with the thread and starts on the new runner', async () => {
  const h = makeHarness();
  const t = create(h).thread;
  const s = h.adapter.last;
  s.init();
  const handed: string[] = [];
  await h.runner.beginDrain([t.id], { onHandedOver: (id) => handed.push(id), backgroundMs: 30 * MIN });
  const b = primary(h, [t.id]);
  // Queued (as a schedule's message is) rather than steered into the turn.
  const queued = h.runner.send(t.id, 'next thing', [], { queue: true });
  s.result('completed');
  await tick();
  assert.deepEqual(handed, [t.id]);
  // Nothing more started on the old runner.
  assert.equal(h.adapter.sessions.length, 1);
  b.runner.adopt(t.id);
  assert.deepEqual(b.adapter.last.sent, [{ id: queued.turnId, text: 'next thing', images: [] }]);
  assert.equal(b.runner.get(t.id).status, 'starting');
});

test('a message to a kept thread with no turn waits for the new runner', async () => {
  const h = makeHarness();
  const t = create(h).thread;
  const s = h.adapter.last;
  s.init();
  // Background work keeps it after the turn.
  s.out({ kind: 'tasks', tasks: [{ id: 'b1', type: 'local_bash', kind: 'shell', description: 'npm test' }] });
  s.result('completed');
  const handed: string[] = [];
  await h.runner.beginDrain([t.id], { onHandedOver: (id) => handed.push(id), backgroundMs: 30 * MIN });
  assert.deepEqual(handed, []);
  h.runner.send(t.id, 'how did it go?');
  // Queued, not started on the old release.
  assert.equal(s.sent.length, 1);
  assert.equal(h.runner.get(t.id).status, 'idle');
  s.out({ kind: 'tasks', tasks: [] });
  await tick();
  h.clock.advance(20_000); // past the wake grace
  await tick();
  assert.deepEqual(handed, [t.id]);
  const b = primary(h, [t.id]);
  b.runner.adopt(t.id);
  assert.equal(b.adapter.last.sent[0].text, 'how did it go?');
});

test('background work holds a kept thread for backgroundMs after its turn, then is stopped with a note', async () => {
  const h = makeHarness();
  const t = create(h).thread;
  const s = h.adapter.last;
  s.init();
  s.out({ kind: 'tasks', tasks: [{ id: 'b1', type: 'local_bash', kind: 'shell', description: 'npm run dev' }] });
  s.result('completed');
  const handed: string[] = [];
  await h.runner.beginDrain([t.id], { onHandedOver: (id) => handed.push(id), backgroundMs: 30 * MIN, checkMs: MIN });
  h.clock.advance(29 * MIN);
  await tick();
  assert.deepEqual(handed, []);
  assert.equal(s.ended, false);
  h.clock.advance(MIN);
  await tick();
  assert.deepEqual(handed, [t.id]);
  assert.equal(s.endedHard, true);
  const notes = h.events(t.id).filter((e) => e.type === 'system.note').map((e) => e.text);
  assert.ok(notes.some((n) => /Stopped background work.*npm run dev/.test(n)), notes.join('\n'));
});

test('an approval holds a kept thread until it is answered', async () => {
  const h = makeHarness();
  const t = h.runner.create({ text: 'edit it', accountId: 'claude-3', permissionMode: 'ask' }).thread;
  const s = h.adapter.last;
  s.init();
  const decision = s.sink.requestApproval({ toolUseId: 'tu1', name: 'Bash', title: 'rm -rf build', input: { command: 'rm -rf build' }, canAlwaysAllow: true, signal: new AbortController().signal });
  const approvalId = (h.events(t.id).find((e) => e.type === 'approval.requested') as any).approvalId;
  const handed: string[] = [];
  await h.runner.beginDrain([t.id], { onHandedOver: (id) => handed.push(id), backgroundMs: 30 * MIN });
  h.runner.respondApproval({ threadId: t.id, approvalId, decision: 'allow' });
  assert.equal((await decision).decision, 'allow');
  assert.deepEqual(handed, []);
  s.result('completed');
  await tick();
  assert.deepEqual(handed, [t.id]);
});

test('a thread left by a draining runner that died is adopted as after a crash', async () => {
  const h = makeHarness();
  const t = create(h).thread;
  h.adapter.last.init();
  h.runner.flush();
  // The old runner is gone mid-turn; thread.json still says running.
  const b = primary(h, [t.id]);
  const adopted = b.runner.adopt(t.id, { crashed: true })!;
  assert.equal(adopted.status, 'stopped');
  const last = b.notes.filter((n) => n.method === 'thread.event').map((n: any) => n.params.event).at(-1);
  assert.equal(last.type, 'turn.completed');
  assert.equal(last.outcome, 'interrupted');
});

test('a kept thread hibernated until the runner restarts wakes when it comes across', async () => {
  const h = makeHarness();
  const t = create(h).thread;
  const s = h.adapter.last;
  s.init();
  const handed: string[] = [];
  await h.runner.beginDrain([t.id], { onHandedOver: (id) => handed.push(id), backgroundMs: 30 * MIN });
  h.runner.update({ threadId: t.id, snoozedUntil: 'restart' });
  s.result('interrupted');
  await tick();
  assert.deepEqual(handed, [t.id]);
  const b = primary(h, [t.id]);
  const adopted = b.runner.adopt(t.id)!;
  assert.equal(adopted.snoozedUntil, undefined);
  assert.equal(adopted.snoozedUntilRestart, undefined);
});

test('Peers: a draining runner\'s threads are marked onOldRunner, its usage readings come here, and changes are told', async () => {
  const h = makeHarness();
  const home = h.home;
  const { writeDrainInfo, Peers } = await import('../../src/handover.ts');
  writeDrainInfo(home, { pid: 424242, port: 1, version: 'old', since: new Date().toISOString(), threads: ['t-old'] });
  let notify: (m: string, p: any) => void = () => {};
  const client = {
    call: async (method: string) => {
      if (method === 'drain.hello') return { threads: ['t-old'], version: 'old' };
      if (method === 'threads.list') return { threads: [{ id: 't-old', title: 'Old', status: 'running', lastActivityAt: '2026-01-01T00:00:00Z' }] };
      return {};
    },
    onNotification: (fn: (m: string, p: any) => void) => ((notify = fn), () => {}),
    waitClosed: () => new Promise<never>(() => {}),
    close: () => {},
  };
  const published: any[] = [];
  const readings: string[] = [];
  let changes = 0;
  const peers = new Peers({
    home,
    token: 't',
    log: nullLogger,
    runner: { adopt: () => undefined, publish: (n) => published.push(n) },
    sweep: async () => {},
    connect: async () => client as any,
    alive: () => true,
    usage: (accountId) => readings.push(accountId),
    onChange: () => changes++,
  });
  assert.deepEqual([...(await peers.connectAll())], ['t-old']);
  assert.equal(changes, 1);
  assert.equal(peers.find('t-old')!.onOldRunner, true);
  notify('thread.updated', { thread: { id: 't-old', title: 'Old', status: 'idle', lastActivityAt: '2026-01-01T00:01:00Z' } });
  assert.equal(published.at(-1).params.thread.onOldRunner, true);
  notify('drain.usage', { accountId: 'claude-3', reading: { windows: [] } });
  assert.deepEqual(readings, ['claude-3']);
  notify('drain.handedOver', { threadId: 't-old' });
  assert.equal(changes, 2);
  assert.deepEqual(peers.status()[0].threads, []);
});

test('subagents hold a kept thread until they finish (up to agentMs); shells only for backgroundMs', async () => {
  const h = makeHarness();
  const t = create(h).thread;
  const s = h.adapter.last;
  s.init();
  s.out({ kind: 'tasks', tasks: [{ id: 'a1', type: 'local_agent', kind: 'agent', description: 'Build the worktree feature' }] });
  s.result('completed');
  const handed: string[] = [];
  await h.runner.beginDrain([t.id], { onHandedOver: (id) => handed.push(id), backgroundMs: 30 * MIN, agentMs: 240 * MIN, checkMs: MIN });
  // Past the shells' limit, the subagent still holds it.
  h.clock.advance(60 * MIN);
  await tick();
  assert.deepEqual(handed, []);
  assert.equal(s.ended, false);
  // It finishes; the thread goes across without anything being stopped.
  s.out({ kind: 'tasks', tasks: [] });
  h.clock.advance(20_000);
  await tick();
  h.clock.advance(MIN);
  await tick();
  assert.deepEqual(handed, [t.id]);
  assert.equal(s.endedHard, false);
});

test('Peers: once closed (this runner is draining), a thread coming across is not taken in here', async () => {
  const h = makeHarness();
  const { writeDrainInfo, Peers } = await import('../../src/handover.ts');
  writeDrainInfo(h.home, { pid: 434343, port: 1, version: 'old', since: new Date().toISOString(), threads: ['t-old'] });
  let notify: (m: string, p: any) => void = () => {};
  const client = {
    call: async (method: string) => (method === 'drain.hello' ? { threads: ['t-old'] } : method === 'threads.list' ? { threads: [{ id: 't-old', title: 'Old', lastActivityAt: '' }] } : {}),
    onNotification: (fn: (m: string, p: any) => void) => ((notify = fn), () => {}),
    waitClosed: () => new Promise<never>(() => {}),
    close: () => {},
  };
  const adopted: string[] = [];
  const peers = new Peers({ home: h.home, token: 't', log: nullLogger, runner: { adopt: (id) => (adopted.push(id), undefined), publish: () => {} }, sweep: async () => {}, connect: async () => client as any, alive: () => true });
  await peers.connectAll();
  peers.close();
  notify('drain.handedOver', { threadId: 't-old' });
  assert.deepEqual(adopted, []);
});
