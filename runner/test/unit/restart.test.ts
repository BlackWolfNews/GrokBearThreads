import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { makeHarness, tick, type Harness } from '../helpers/fakes.ts';
import { Restarter, restartPath, resumesPath, restartMethods, parseRestartParams, takeResume, pendingMessage, type RestartFile } from '../../src/restart.ts';
import { RpcServer } from '../../src/rpc.ts';
import { RunnerClient } from '../../src/client.ts';
import { ClaudeAdapter } from '../../src/adapters/claude/adapter.ts';
import { ProcessRegistry } from '../../src/proc.ts';
import { nullLogger } from '../../src/log.ts';
import { RpcError } from '../../src/protocol.ts';
import { checkSequence } from '../helpers/protocol-check.ts';
import { tmpDir } from '../helpers/fakes.ts';

const MIN = 60_000;

// A Restarter on a harness, standing in for main.ts: restart() only counts.
function withRestarter(h: Harness, version = '0.1.0+old') {
  const state = { restarts: 0 };
  const r = new Restarter({ runner: h.runner, home: h.home, clock: h.clock, log: nullLogger, version, release: 'old', restart: () => state.restarts++ });
  return { r, state };
}

function create(h: Harness, extra: Record<string, unknown> = {}) {
  return h.runner.create({ text: 'Deploy the runner', accountId: 'claude-3', ...extra });
}

function notices(h: Harness): string[] {
  return h.notes.filter((n) => n.method === 'runner.notice').map((n) => (n.params as { message: string }).message);
}

function saved(h: Harness): RestartFile {
  return JSON.parse(fs.readFileSync(restartPath(h.home), 'utf8'));
}

test('with nothing running a restart starts at once, after the reply, and is saved first', async () => {
  const h = makeHarness();
  const { r, state } = withRestarter(h);
  const res = r.request({ reason: 'new release' });
  assert.deepEqual(res, { scheduled: true, waitingFor: [] });
  assert.equal(state.restarts, 0, 'not inside the request, so the reply goes out first');
  await tick();
  assert.equal(state.restarts, 1);
  const file = saved(h);
  assert.equal(file.when, 'idle');
  assert.equal(file.reason, 'new release');
  assert.equal(file.fromVersion, '0.1.0+old');
  assert.ok(file.shutdownAt, 'the shutdown time is saved for the resume age');
  assert.deepEqual(notices(h), ['The runner is restarting now.']);
  // A second request while restarting merges and doesn't restart twice.
  assert.deepEqual(r.request({}), { scheduled: true, waitingFor: [] });
  await tick();
  assert.equal(state.restarts, 1);
});

test('idle waits for running threads and for approvals and questions', async () => {
  const h = makeHarness();
  const { r, state } = withRestarter(h);
  const { thread } = create(h, { permissionMode: 'ask' });
  const s = h.adapter.last;
  s.init();
  const res = r.request({ when: 'idle' });
  assert.deepEqual(res, { scheduled: true, waitingFor: [thread.id] });
  assert.deepEqual(notices(h), ['The runner will restart when 1 thread finishes.']);
  assert.deepEqual(r.helloNotices(), [{ level: 'info', message: 'The runner will restart when 1 thread finishes.' }]);
  assert.deepEqual(r.status().pendingRestart?.waitingFor, [thread.id]);

  // Blocked on an approval, then a question: still busy.
  const approval = s.sink.requestApproval({ toolUseId: 't1', name: 'Bash', title: 'ls', input: { command: 'ls' }, canAlwaysAllow: true, signal: new AbortController().signal });
  assert.equal(h.runner.get(thread.id).status, 'waiting');
  await tick();
  assert.equal(state.restarts, 0);
  const approvalId = h.events(thread.id).find((e) => e.type === 'approval.requested').approvalId;
  h.runner.respondApproval({ threadId: thread.id, approvalId, decision: 'allow' });
  assert.equal((await approval).decision, 'allow');
  const question = s.sink.requestQuestion({ toolUseId: 't2', questions: [{ question: 'Tea?', multiSelect: false, options: [{ label: 'Yes' }] }], signal: new AbortController().signal });
  await tick();
  assert.equal(state.restarts, 0);
  const questionId = h.events(thread.id).find((e) => e.type === 'question.requested').approvalId;
  h.runner.respondApproval({ threadId: thread.id, approvalId: questionId, decision: 'answered', answers: { '0': 'Yes' } });
  await question;
  await tick();
  assert.equal(state.restarts, 0, 'the turn is still running');

  s.result();
  assert.equal(state.restarts, 0, 'checked after the tick, not inside the turn ending');
  await tick();
  assert.equal(state.restarts, 1);
});

test('a background subagent asking for approval after its turn ended keeps the runner up', async () => {
  const h = makeHarness();
  const { r, state } = withRestarter(h);
  const { thread } = create(h, { permissionMode: 'ask' });
  const s = h.adapter.last;
  s.init();
  s.result();
  // The subagent asks with no turn running: the runner opens one for it.
  void s.sink.requestApproval({ name: 'Write', title: 'Write x', input: {}, canAlwaysAllow: false, signal: new AbortController().signal });
  assert.equal(h.runner.get(thread.id).status, 'waiting');
  assert.deepEqual(r.request({}).waitingFor, [thread.id]);
  await tick();
  assert.equal(state.restarts, 0);
});

test('a send while a restart is pending still works, and the restart waits for it', async () => {
  const h = makeHarness();
  const { r, state } = withRestarter(h);
  const a = create(h).thread;
  const sa = h.adapter.last;
  sa.init();
  const b = create(h).thread;
  const sb = h.adapter.last;
  sb.init();
  sb.result();
  assert.deepEqual(r.request({}).waitingFor, [a.id]);

  // Queued behind A's turn: when that ends the next one starts in the same
  // tick, so the runner never looks idle in between.
  h.runner.send(a.id, 'and one more thing');
  sa.result();
  await tick();
  assert.equal(state.restarts, 0);
  assert.equal(h.runner.get(a.id).status, 'running');
  assert.equal(sa.sent.length, 2, 'the queued message reached the CLI');

  // A new turn in an idle thread counts too.
  h.runner.send(b.id, 'also this');
  await tick();
  sa.result();
  await tick();
  assert.equal(state.restarts, 0, 'B is running now');
  assert.deepEqual(r.status().pendingRestart?.waitingFor, [b.id]);
  sb.result();
  await tick();
  assert.equal(state.restarts, 1);
});

test('"now" restarts straight away and wins over a pending idle restart', async () => {
  const h = makeHarness();
  const { r, state } = withRestarter(h);
  const { thread } = create(h);
  h.adapter.last.init();
  assert.deepEqual(r.request({ resume: { threadId: thread.id, text: 'carry on' } }).waitingFor, [thread.id]);
  await tick();
  assert.equal(state.restarts, 0);
  assert.deepEqual(r.request({ when: 'now', reason: 'stuck' }), { scheduled: true, waitingFor: [] });
  await tick();
  assert.equal(state.restarts, 1);
  const file = saved(h);
  assert.equal(file.when, 'now');
  assert.equal(file.reason, 'stuck');
  assert.deepEqual(file.resumes.map((x) => x.threadId), [thread.id], 'the earlier resume is kept');
});

test('runner.status reports the version, live CLIs, busy threads and the pending restart', () => {
  const h = makeHarness();
  const { r } = withRestarter(h);
  const a = create(h).thread;
  h.adapter.last.init();
  const b = create(h).thread;
  h.adapter.last.init();
  h.adapter.last.result();
  let s = r.status();
  assert.equal(s.version, '0.1.0+old');
  assert.equal(s.release, 'old');
  assert.equal(s.pid, process.pid);
  assert.equal(s.home, h.home);
  assert.equal(s.liveClis, 2);
  assert.deepEqual(s.running, [a.id]);
  assert.equal(s.pendingRestart, undefined);
  assert.deepEqual(r.helloNotices(), []);
  r.request({ reason: 'deploy', resume: { threadId: b.id, text: 'check it' } });
  s = r.status();
  assert.deepEqual(s.pendingRestart, { when: 'idle', requestedAt: new Date(h.clock.now()).toISOString(), waitingFor: [a.id], reason: 'deploy', resumeThreadId: b.id });
});

test('a resume for a thread that does not exist is refused up front', () => {
  const h = makeHarness();
  const { r } = withRestarter(h);
  assert.throws(() => r.request({ resume: { threadId: 'nope', text: 'x' } }), (e: RpcError) => e.code === -32004);
  assert.equal(fs.existsSync(restartPath(h.home)), false);
});

test('after a restart the thread gets a note and its resume as a turn from the runner', async () => {
  const h = makeHarness();
  const { r } = withRestarter(h, '0.1.0+old');
  const { thread } = create(h);
  const s = h.adapter.last;
  s.init();
  s.result();
  r.request({ resume: { threadId: thread.id, text: 'The runner restarted. Check it works, then carry on.' } });
  await tick();

  const h2 = h.restart();
  const r2 = withRestarter(h2, '0.1.0+new').r;
  r2.resumeAfterRestart();
  assert.equal(fs.existsSync(restartPath(h.home)), false, 'restart.json is gone once handled');
  const evs = h2.events(thread.id);
  // The new CLI resumes the native session, as any message after a restart does.
  assert.deepEqual(evs.map((e) => e.type), ['system.note', 'user.message', 'turn.started', 'system.note']);
  assert.equal(evs[0].text, 'Runner restarted: 0.1.0+old to 0.1.0+new');
  assert.equal(evs[1].origin, 'runner');
  assert.equal(evs[1].text, 'The runner restarted. Check it works, then carry on.');
  assert.equal(evs[3].text, 'Resumed session');
  assert.deepEqual(checkSequence(h2.runner.events(thread.id).events), []);
  await tick();
  assert.equal(h2.adapter.last.sent[0].text, 'The runner restarted. Check it works, then carry on.');
  // Messages people send carry no origin.
  h2.adapter.last.init();
  h2.adapter.last.result();
  h2.runner.send(thread.id, 'thanks');
  assert.equal(h2.events(thread.id).filter((e) => e.type === 'user.message').at(-1).origin, undefined);
  // Nothing left to resume on the start after that.
  const h3 = h2.restart();
  withRestarter(h3).r.resumeAfterRestart();
  assert.deepEqual(h3.events(thread.id).filter((e) => e.type !== 'turn.completed'), [], 'only recovery of the turn left running');
});

test('after a crash rollback the resumed thread hears which release it is really on', async () => {
  const h = makeHarness();
  const { r } = withRestarter(h, '0.1.0+old');
  const { thread } = create(h);
  h.adapter.last.init();
  h.adapter.last.result();
  r.request({ resume: { threadId: thread.id, text: 'carry on' } });
  await tick();
  // The new release crashed at startup and launch.mjs went back to "old".
  const h2 = h.restart();
  const rolledBack = 'Release new kept crashing at startup, so the runner went back to old.';
  new Restarter({ runner: h2.runner, home: h2.home, clock: h2.clock, log: nullLogger, version: '0.1.0+old', rolledBack, restart: () => {} }).resumeAfterRestart();
  const note = h2.events(thread.id).find((e) => e.type === 'system.note');
  assert.equal(note.text, `Runner restarted: 0.1.0+old to 0.1.0+old\n\n${rolledBack}`);
});

test('a resume queued behind a running turn keeps its origin', () => {
  const h = makeHarness();
  const { thread } = create(h);
  h.adapter.last.init();
  h.runner.send(thread.id, 'from the runner', [], { origin: 'runner' });
  h.adapter.last.result();
  const msgs = h.events(thread.id).filter((e) => e.type === 'user.message');
  assert.deepEqual(msgs.map((m) => m.origin), [undefined, 'runner']);
});

test('a crash while a restart is pending still delivers the resume on the next start', async () => {
  const h = makeHarness();
  const { r, state } = withRestarter(h);
  const { thread } = create(h);
  h.adapter.last.init();
  r.request({ resume: { threadId: thread.id, text: 'carry on' } });
  await tick();
  assert.equal(state.restarts, 0, 'still waiting for the turn');
  assert.equal(saved(h).shutdownAt, undefined);

  // The runner dies mid-turn; launchd starts it again.
  h.clock.advance(5 * MIN);
  const h2 = h.restart();
  h2.clock.advance(5 * MIN);
  withRestarter(h2, '0.1.0+new').r.resumeAfterRestart();
  const evs: any[] = h2.runner.events(thread.id).events;
  const i = evs.findIndex((e) => e.type === 'system.note' && e.text.startsWith('Runner restarted'));
  assert.equal(evs[i - 1].type, 'turn.completed', 'recovery ended the turn the crash cut short');
  assert.equal(evs[i - 1].outcome, 'interrupted');
  assert.equal(evs[i].text, 'Runner restarted: 0.1.0+old to 0.1.0+new');
  assert.equal(evs[i + 1].type, 'user.message');
  assert.equal(evs[i + 1].origin, 'runner');
  assert.equal(evs[i + 2].type, 'turn.started');
  assert.equal(fs.existsSync(restartPath(h.home)), false);
});

test('a resume more than 15 minutes old only leaves the note', () => {
  const h = makeHarness();
  const { thread } = create(h);
  h.adapter.last.init();
  h.adapter.last.result();
  const sessions = h.adapter.sessions.length;
  const at = new Date(h.clock.now() - 16 * MIN).toISOString();
  const file: RestartFile = { when: 'idle', requestedAt: at, shutdownAt: at, fromVersion: '0.1.0+old', resumes: [{ threadId: thread.id, text: 'carry on', requestedAt: at }] };
  fs.writeFileSync(restartPath(h.home), JSON.stringify(file));
  withRestarter(h, '0.1.0+new').r.resumeAfterRestart();
  const last = h.events(thread.id).at(-1);
  assert.equal(last.type, 'system.note');
  assert.match(last.text, /^Runner restarted: 0\.1\.0\+old to 0\.1\.0\+new\n\nNot carrying on by itself: the request is more than 15 minutes old\.$/);
  assert.equal(h.adapter.sessions.length, sessions);
  assert.equal(fs.existsSync(restartPath(h.home)), false);
});

test('the age counts from the shutdown, so a restart that waited a long time still resumes', () => {
  const h = makeHarness();
  const { thread } = create(h);
  h.adapter.last.init();
  h.adapter.last.result();
  const file: RestartFile = {
    when: 'idle',
    requestedAt: new Date(h.clock.now() - 90 * MIN).toISOString(),
    shutdownAt: new Date(h.clock.now() - 1 * MIN).toISOString(),
    fromVersion: 'a',
    resumes: [{ threadId: thread.id, text: 'carry on', requestedAt: new Date(h.clock.now() - 90 * MIN).toISOString() }],
  };
  fs.writeFileSync(restartPath(h.home), JSON.stringify(file));
  withRestarter(h, 'b').r.resumeAfterRestart();
  assert.equal(h.events(thread.id).at(-1).type, 'turn.started');
});

test('at most 3 automatic resumes per thread an hour; past that, only the note', () => {
  const h = makeHarness();
  const { thread } = create(h);
  const s = h.adapter.last;
  s.init();
  s.result();
  const restartOnce = () => {
    const now = new Date(h.clock.now()).toISOString();
    const file: RestartFile = { when: 'idle', requestedAt: now, shutdownAt: now, fromVersion: 'a', resumes: [{ threadId: thread.id, text: 'go on', requestedAt: now }] };
    fs.writeFileSync(restartPath(h.home), JSON.stringify(file));
    const before = h.events(thread.id).length;
    withRestarter(h, 'b').r.resumeAfterRestart();
    const added = h.events(thread.id).slice(before);
    const live = h.adapter.last;
    // Finish the resumed turn so the next one starts cleanly.
    if (added.some((e) => e.type === 'user.message')) {
      live.init();
      live.result();
    }
    return added;
  };
  for (let i = 0; i < 3; i++) {
    const added = restartOnce();
    assert.equal(added.filter((e) => e.type === 'user.message' && e.origin === 'runner').length, 1, `resume ${i + 1} is sent`);
    h.clock.advance(10 * MIN);
  }
  const fourth = restartOnce();
  assert.deepEqual(fourth.map((e) => e.type), ['system.note']);
  assert.match(fourth[0].text, /already been resumed 3 times in the last hour/);
  // An hour after the first one, there's room again.
  h.clock.advance(31 * MIN);
  assert.equal(restartOnce().filter((e) => e.type === 'user.message').length, 1);
  // The guard is per thread and lives in run/resumes.json.
  assert.ok(fs.existsSync(resumesPath(h.home)));
  assert.equal(takeResume(h.home, 'another-thread', h.clock.now()), true);
});

test('snoozed or archived threads get the note but are not woken by a resume', () => {
  const h = makeHarness();
  const { thread } = create(h);
  h.adapter.last.init();
  h.adapter.last.result();
  h.runner.update({ threadId: thread.id, archived: true });
  const now = new Date(h.clock.now()).toISOString();
  fs.writeFileSync(restartPath(h.home), JSON.stringify({ when: 'idle', requestedAt: now, fromVersion: 'a', resumes: [{ threadId: thread.id, text: 'go', requestedAt: now }] }));
  withRestarter(h, 'b').r.resumeAfterRestart();
  assert.equal(h.events(thread.id).at(-1).type, 'system.note');
  assert.ok(h.runner.get(thread.id).archivedAt, 'still archived');
});

test('an unreadable restart.json, or one for a deleted thread, is dropped without harm', () => {
  const h = makeHarness();
  fs.writeFileSync(restartPath(h.home), '{ not json');
  withRestarter(h).r.resumeAfterRestart();
  assert.equal(fs.existsSync(restartPath(h.home)), false);
  const now = new Date(h.clock.now()).toISOString();
  fs.writeFileSync(restartPath(h.home), JSON.stringify({ when: 'idle', requestedAt: now, fromVersion: 'a', resumes: [{ threadId: 'gone', text: 'x', requestedAt: now }] }));
  withRestarter(h).r.resumeAfterRestart();
  assert.equal(fs.existsSync(restartPath(h.home)), false);
});

test('restart params are checked', () => {
  assert.deepEqual(parseRestartParams({}), {});
  assert.deepEqual(parseRestartParams({ when: 'now', reason: ' x ', resume: { threadId: 't', text: 'go' } }), { when: 'now', reason: 'x', resume: { threadId: 't', text: 'go' } });
  for (const bad of [{ when: 'later' }, { reason: 3 }, { resume: 'x' }, { resume: { threadId: 't' } }, { resume: { threadId: 't', text: '  ' } }, { resume: [] }]) {
    assert.throws(() => parseRestartParams(bad), (e: RpcError) => e.code === -32602, JSON.stringify(bad));
  }
  assert.equal(pendingMessage(2), 'The runner will restart when 2 threads finish.');
});

test('runner.restart and runner.status over the WebSocket, with the pending notice after hello', async () => {
  const h = makeHarness();
  const { r } = withRestarter(h);
  const server = new RpcServer({ host: '127.0.0.1', port: 0, token: 'tok', runner: h.runner, log: nullLogger, methods: restartMethods(r), helloNotices: () => r.helloNotices() });
  const { port } = await server.listen();
  const url = `ws://127.0.0.1:${port}/rpc`;
  const { thread } = create(h);
  h.adapter.last.init();
  const c = await RunnerClient.connect(url, 'tok');
  try {
    assert.deepEqual((await c.call('runner.status')).running, [thread.id]);
    assert.deepEqual(await c.call('runner.restart', { resume: { threadId: thread.id, text: 'go on' } }), { scheduled: true, waitingFor: [thread.id] });
    await assert.rejects(c.call('runner.restart', { when: 'sometime' }), (e: { code: number }) => e.code === -32602);
    await assert.rejects(c.call('runner.restart', { resume: { threadId: 'missing', text: 'x' } }), (e: { code: number }) => e.code === -32004);
    // Only the methods given are served; nothing from Object's prototype.
    await assert.rejects(c.call('constructor'), (e: { code: number }) => e.code === -32601);
    const c2 = await RunnerClient.connect(url, 'tok');
    const seen: string[] = [];
    c2.onNotification((m, p) => m === 'runner.notice' && seen.push(p.message));
    await c2.call('hello', { client: 'test', version: '1' });
    await new Promise((res) => setTimeout(res, 50));
    assert.ok(seen.includes('The runner will restart when 1 thread finishes.'), seen.join('; '));
    c2.close();
  } finally {
    c.close();
    await server.close();
  }
});

test('every CLI gets THREADBARE_THREAD_ID, THREADBARE_HOME and THREADBARE_RUNNER_VERSION', () => {
  const h = makeHarness();
  const { thread } = create(h);
  const env = h.adapter.last.opts.env!;
  assert.equal(env.THREADBARE_THREAD_ID, thread.id);
  assert.equal(env.THREADBARE_HOME, h.home);
  assert.match(env.THREADBARE_RUNNER_VERSION, /^\d+\.\d+\.\d+\+/);

  // The Claude adapter puts them in the CLI's environment, over anything
  // inherited (a runner started from inside a thread has its own).
  let options: any;
  const queryFn = ((args: { options: unknown }) => {
    options = args.options;
    return { async *[Symbol.asyncIterator]() {}, close() {}, interrupt: async () => {}, setModel: async () => {}, setPermissionMode: async () => {} };
  }) as any;
  const dir = tmpDir();
  const saved = process.env.THREADBARE_THREAD_ID;
  process.env.THREADBARE_THREAD_ID = 'the-parent-thread';
  try {
    new ClaudeAdapter({ claudePath: '/nonexistent', registry: new ProcessRegistry(dir, nullLogger), log: nullLogger, queryFn }).start(
      {
        threadId: 't1',
        cwd: dir,
        account: { id: 'claude-3', provider: 'claude', title: 'x', configDir: dir },
        permissionMode: 'full',
        sessionId: '00000000-0000-0000-0000-000000000002',
        resume: false,
        mediaDir: dir,
        blobsDir: dir,
        tmpDir: dir,
        env: { THREADBARE_THREAD_ID: 't1', THREADBARE_HOME: '/tmp/home', THREADBARE_RUNNER_VERSION: '9.9.9+x' },
      },
      { output() {}, requestApproval: async () => ({ decision: 'deny' }), requestQuestion: async () => ({ answers: null }), exited() {} },
    );
  } finally {
    if (saved === undefined) delete process.env.THREADBARE_THREAD_ID;
    else process.env.THREADBARE_THREAD_ID = saved;
  }
  assert.equal(options.env.THREADBARE_THREAD_ID, 't1');
  assert.equal(options.env.THREADBARE_HOME, '/tmp/home');
  assert.equal(options.env.THREADBARE_RUNNER_VERSION, '9.9.9+x');
  assert.equal(options.env.CLAUDE_CONFIG_DIR, dir, 'the account still applies');
});
