import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { makeHarness, tick, tmpDir } from '../helpers/fakes.ts';
import { makePng } from '../helpers/png.ts';
import { formatThread, formatStatus, lastTurns, exportThread, lastLines, findRepoRoot, duration } from '../../src/tb-dev.ts';
import { Restarter, restartMethods, restartPath } from '../../src/restart.ts';
import { RpcServer } from '../../src/rpc.ts';
import { RunnerClient } from '../../src/client.ts';
import { readToken } from '../../src/config.ts';
import { nullLogger } from '../../src/log.ts';
import type { PersistedEvent, ThreadSummary } from '../../src/protocol.ts';

const TB = path.join(import.meta.dirname, '..', '..', 'bin', 'tb');
const MOCK = path.join(import.meta.dirname, '..', '..', '..', 'app', 'Tools', 'mock-runner');

const T: ThreadSummary = {
  id: 'abcdef12-0000-4000-8000-000000000000',
  title: 'Fix the tests',
  cwd: '/w',
  accountId: 'claude-3',
  provider: 'claude',
  permissionMode: 'full',
  status: 'idle',
  live: true,
  needsYou: false,
  createdAt: '2026-10-26T10:00:00.000Z',
  updatedAt: '2026-10-26T10:00:00.000Z',
  lastActivityAt: '2026-10-26T10:00:00.000Z',
  preview: '',
  lastSeq: 21,
  lastSeenSeq: 21,
};

function events(img = '/m/a.png'): PersistedEvent[] {
  const bodies: Record<string, unknown>[] = [
    { turnId: 't1', type: 'user.message', text: 'Fix the flaky test\nIt fails on CI', images: [{ path: img, mediaType: 'image/png', width: 10, height: 20 }] },
    { turnId: 't1', type: 'turn.started' },
    { turnId: 't1', type: 'reasoning', itemId: 'r1', text: 'Looking at the test first.\nMore' },
    { turnId: 't1', type: 'assistant.text', itemId: 'm1', text: 'I will run the tests.' },
    { turnId: 't1', type: 'tool.call', itemId: 'c1', name: 'Bash', kind: 'command', title: 'npm test', input: {} },
    { turnId: 't1', type: 'tool.result', itemId: 'c1', ok: false, text: 'FAIL a.test.ts\n1 failing', truncated: false, images: [] },
    { turnId: 't1', type: 'tool.call', itemId: 'c2', name: 'Edit', kind: 'edit', title: 'Edit src/a.ts', input: {} },
    { turnId: 't1', type: 'edit.diff', itemId: 'c2', path: '/w/src/a.ts', hunks: [{ oldStart: 1, oldLines: 2, newStart: 1, newLines: 2, lines: [' a', '-b', '+c'] }] },
    { turnId: 't1', type: 'approval.requested', approvalId: 'ap1', itemId: 'c2', name: 'Edit', title: 'Edit src/a.ts', input: {}, options: ['allow', 'deny'] },
    { turnId: 't1', type: 'approval.resolved', approvalId: 'ap1', decision: 'allow' },
    { turnId: 't1', type: 'tool.result', itemId: 'c2', ok: true, text: '', truncated: false, images: [] },
    { turnId: 't1', type: 'plan.updated', entries: [{ text: 'Run tests', status: 'completed' }, { text: 'Fix', status: 'in_progress' }, { text: 'Commit', status: 'pending' }] },
    { turnId: 't1', type: 'assistant.text', itemId: 'm2', text: 'Fixed it.\n\nAll green.' },
    { turnId: 't1', type: 'turn.completed', outcome: 'completed', durationMs: 12_345, costUsd: 0.0123 },
    { type: 'system.note', text: 'Runner restarted: a to b' },
    { turnId: 't2', type: 'user.message', text: 'Carry on', images: [], origin: 'runner' },
    { turnId: 't2', type: 'turn.started' },
    { turnId: 't2', type: 'question.requested', approvalId: 'ap2', questions: [{ question: 'Commit now?', multiSelect: false, options: [{ label: 'Yes' }, { label: 'No' }] }] },
    { turnId: 't2', type: 'approval.resolved', approvalId: 'ap2', decision: 'answered' },
    { turnId: 't2', type: 'error', message: 'Something broke' },
    { turnId: 't2', type: 'turn.completed', outcome: 'failed', durationMs: 2000, error: 'Something broke' },
  ];
  return bodies.map((b, i) => ({ seq: i + 1, ts: '2026-10-26T10:00:00.000Z', threadId: T.id, ...b }) as unknown as PersistedEvent);
}

const HEADER = ['Fix the tests', 'abcdef12-0000-4000-8000-000000000000, idle, claude-3, full access, in /w'];

const TURN_2 = ['  Note: Runner restarted: a to b', '', 'Runner: Carry on', '  Question: Commit now? (Yes / No)', '  Answer: answered', '  Error: Something broke', '  (failed, 2.0s: Something broke)'];

test('tb show: messages, one line per tool call, approvals, notes and turn footers', () => {
  assert.equal(
    formatThread(T, events()),
    [
      ...HEADER,
      '',
      'User: Fix the flaky test',
      '  It fails on CI',
      '  [image: /m/a.png, 10x20]',
      '',
      'Assistant: I will run the tests.',
      '  - npm test (failed)',
      '  - Edit src/a.ts',
      '  Approval asked: Edit src/a.ts',
      '  Answer: allowed',
      '  Plan:',
      '    [x] Run tests',
      '    [>] Fix',
      '    [ ] Commit',
      '',
      'Assistant: Fixed it.',
      '',
      '  All green.',
      '  (completed, 12.3s, $0.0123)',
      ...TURN_2,
      '',
    ].join('\n'),
  );
});

test('tb show --tools adds results, diffs and thinking; --last keeps the last turns and the note before them', () => {
  const text = formatThread(T, events(), { tools: true });
  assert.ok(
    text.includes(
      [
        '  (thinking) Looking at the test first.',
        '',
        'Assistant: I will run the tests.',
        '  - npm test (failed)',
        '      FAIL a.test.ts',
        '      1 failing',
        '  - Edit src/a.ts',
        '       a',
        '      -b',
        '      +c',
        '  Approval asked: Edit src/a.ts',
        '  Answer: allowed',
        '      (no output)',
      ].join('\n'),
    ),
    text,
  );
  assert.equal(formatThread(T, events(), { last: 1 }), [...HEADER, '(1 earlier turn not shown)', ...TURN_2, ''].join('\n'));
  assert.equal(lastTurns(events(), 5).hidden, 0);
  // Long results are cut.
  const long = events();
  (long[5] as { text: string }).text = Array.from({ length: 30 }, (_, i) => `line ${i}`).join('\n');
  assert.match(formatThread(T, long, { tools: true }), /      line 19\n      \.\.\. 10 more lines\n/);
});

test('tb status text', () => {
  const now = Date.parse('2026-10-26T12:00:00.000Z');
  const text = formatStatus(
    {
      version: '0.1.0+r1',
      release: 'r1',
      pid: 42,
      startedAt: '2026-10-26T09:55:00.000Z',
      home: '/h',
      logFile: '/h/runner.log',
      liveClis: 2,
      running: [T.id],
      pendingRestart: { when: 'idle', requestedAt: '2026-10-26T11:57:00.000Z', waitingFor: [T.id], reason: 'deploy', resumeThreadId: T.id },
    },
    [{ ...T, status: 'running' }],
    now,
  );
  assert.equal(
    text,
    [
      'Runner 0.1.0+r1, pid 42, up 2h 5m',
      'Data dir: /h',
      'Log: /h/runner.log',
      'Live CLIs: 2',
      'Busy threads: 1',
      '  abcdef12  Fix the tests  [running]',
      'Restart pending: when idle, asked 3m ago, waiting for 1 thread',
      '  Reason: deploy',
      '  Then carries on: abcdef12  Fix the tests  [running]',
      '',
    ].join('\n'),
  );
  assert.equal(duration(3 * 86_400_000 + 3_600_000), '3d 1h');
});

test('tb export writes the mock runner fixture format, with images copied next to it', () => {
  const src = tmpDir();
  fs.mkdirSync(path.join(src, 'a'));
  fs.mkdirSync(path.join(src, 'b'));
  const png = makePng(4, 3);
  fs.writeFileSync(path.join(src, 'a', 'shot.png'), png);
  fs.writeFileSync(path.join(src, 'b', 'shot.png'), png);
  const evs = events(path.join(src, 'a', 'shot.png'));
  // Same name from another folder, the same file twice, and one that's gone.
  (evs[5] as { images: unknown[] }).images = [
    { path: path.join(src, 'b', 'shot.png'), mediaType: 'image/png' },
    { path: path.join(src, 'a', 'shot.png'), mediaType: 'image/png' },
    { path: path.join(src, 'gone.png'), mediaType: 'image/png' },
  ];
  const out = path.join(tmpDir(), T.id);
  assert.deepEqual(exportThread(T, evs, out), { events: 21, media: 2 });
  assert.deepEqual(fs.readdirSync(path.join(out, 'media')).sort(), ['2-shot.png', 'shot.png']);
  const thread = JSON.parse(fs.readFileSync(path.join(out, 'thread.json'), 'utf8'));
  assert.equal(thread.id, T.id);
  assert.equal(thread.live, false);
  const lines = fs.readFileSync(path.join(out, 'events.ndjson'), 'utf8').split('\n');
  assert.equal(lines.pop(), '', 'ends with a newline');
  const back = lines.map((l) => JSON.parse(l));
  assert.deepEqual(back.map((e) => e.seq), evs.map((e) => e.seq));
  assert.deepEqual(back[0].images[0], { path: 'media/shot.png', mediaType: 'image/png', width: 10, height: 20 });
  assert.deepEqual(back[5].images.map((i: { path: string }) => i.path), ['media/2-shot.png', 'media/shot.png', path.join(src, 'gone.png')]);
  assert.equal(back[15].origin, 'runner');
});

test('the mock runner loads an export', { skip: !fs.existsSync(path.join(MOCK, 'node_modules', 'ws')) && 'mock runner has no node_modules' }, async () => {
  const src = tmpDir();
  fs.writeFileSync(path.join(src, 'shot.png'), makePng(4, 3));
  const parent = tmpDir();
  exportThread(T, events(path.join(src, 'shot.png')), path.join(parent, T.id));
  const data = tmpDir();
  const ready = path.join(data, 'ready');
  const mock = spawn(process.execPath, [path.join(MOCK, 'server.mjs'), '--data-dir', data, '--fixtures', parent, '--ready-file', ready, '--quiet'], { stdio: 'ignore' });
  try {
    for (let i = 0; i < 100 && !fs.existsSync(ready); i++) await new Promise((r) => setTimeout(r, 50));
    const port = Number(fs.readFileSync(ready, 'utf8'));
    const c = await RunnerClient.connect(`ws://127.0.0.1:${port}/rpc`, fs.readFileSync(path.join(data, 'secrets', 'runner-token'), 'utf8').trim());
    const list = await c.call('threads.list', { include: ['inbox'] });
    assert.deepEqual(list.threads.map((t: ThreadSummary) => t.id), [T.id]);
    const page = await c.call('threads.events', { threadId: T.id, limit: 100 });
    assert.equal(page.events.length, 21);
    assert.equal(page.events[0].images[0].path, path.join(parent, T.id, 'media', 'shot.png'));
    assert.ok(fs.existsSync(page.events[0].images[0].path));
    c.close();
  } finally {
    mock.kill();
  }
});

test('tb export finds the checkout to put fixtures in', () => {
  const root = tmpDir();
  fs.mkdirSync(path.join(root, 'app', 'Tools', 'mock-runner'), { recursive: true });
  fs.writeFileSync(path.join(root, 'app', 'Tools', 'mock-runner', 'server.mjs'), '');
  fs.mkdirSync(path.join(root, 'runner', 'src'), { recursive: true });
  assert.equal(findRepoRoot([path.join(root, 'runner', 'src')]), root);
  assert.equal(findRepoRoot([tmpDir()]), undefined);
});

test('tb logs reads the last lines from the end, filtered to a thread', () => {
  const file = path.join(tmpDir(), 'runner.log');
  const lines: string[] = [];
  // Over a 64 KB block, with a multi-byte character on every line so some
  // straddle a block edge.
  for (let i = 0; i < 3000; i++) lines.push(`2026-10-26T10:00:00.000Z INFO line ${i} é ${i % 3 === 0 ? '{"threadId":"abc"}' : ''}`);
  fs.writeFileSync(file, lines.join('\n') + '\n');
  assert.deepEqual(lastLines(file, 2), lines.slice(-2));
  const all = lastLines(file, 5000);
  assert.equal(all.length, 3000);
  assert.deepEqual(all, lines);
  const mine = lastLines(file, 1000, 'abc');
  assert.equal(mine.length, 1000);
  assert.ok(mine.every((l) => l.includes('"threadId":"abc"') && l.includes('é')));
  assert.deepEqual(lastLines(file, 0), []);
});

// ------------------------------------------------------------- the CLI

async function serve() {
  const h = makeHarness();
  const state = { restarts: 0 };
  const r = new Restarter({ runner: h.runner, home: h.home, clock: h.clock, log: nullLogger, version: '0.1.0+test', logFile: path.join(h.home, 'runner.log'), restart: () => state.restarts++ });
  const server = new RpcServer({ host: '127.0.0.1', port: 0, token: readToken(h.home), runner: h.runner, log: nullLogger, methods: restartMethods(r) });
  const { port } = await server.listen();
  return { h, r, state, server, url: `ws://127.0.0.1:${port}/rpc` };
}

// Runs bin/tb against the test runner. Variables from a thread this test
// might itself run in are dropped unless the test sets them.
function tb(home: string, url: string, args: string[], env: Record<string, string> = {}) {
  const base: NodeJS.ProcessEnv = {};
  for (const [k, v] of Object.entries(process.env)) if (!k.startsWith('THREADBARE_')) base[k] = v;
  let out = '';
  const p = spawn(process.execPath, [TB, ...args], { env: { ...base, THREADBARE_HOME: home, THREADBARE_URL: url, ...env }, stdio: ['ignore', 'pipe', 'pipe'] });
  p.stdout.on('data', (d) => (out += d));
  p.stderr.on('data', (d) => (out += d));
  const exited = new Promise<number | null>((r) => p.once('exit', (code) => r(code)));
  return { out: () => out, exited, kill: () => p.kill() };
}

async function run(home: string, url: string, args: string[], env: Record<string, string> = {}) {
  const t = tb(home, url, args, env);
  const code = await t.exited;
  return { code, out: t.out() };
}

test('tb status, self, show, export and rpc against a runner', async () => {
  const { h, server, url } = await serve();
  try {
    const { thread } = h.runner.create({ text: 'Fix the tests', accountId: 'claude-3' });
    const s = h.adapter.last;
    s.init();
    s.text('m1', 'Done.');
    s.result('completed', 0.01);

    // The runner's times come from its fake clock, so "up" isn't checked.
    let r = await run(h.home, url, ['status']);
    assert.equal(r.code, 0, r.out);
    assert.match(r.out, /^Runner 0\.1\.0\+test, pid \d+, up [^\n]+\n/);
    assert.match(r.out, /Live CLIs: 1\nBusy threads: none\n/);
    r = await run(h.home, url, ['status', '--json']);
    assert.equal(JSON.parse(r.out).version, '0.1.0+test');

    r = await run(h.home, url, ['self'], { THREADBARE_THREAD_ID: thread.id });
    assert.equal(r.code, 0, r.out);
    assert.match(r.out, new RegExp(`^${thread.id}\nFix the tests\nStatus: idle, CLI live\n`));
    r = await run(h.home, url, ['self', '--json'], { THREADBARE_THREAD_ID: thread.id });
    assert.equal(JSON.parse(r.out).id, thread.id);
    r = await run(h.home, url, ['self']);
    assert.equal(r.code, 1);
    assert.match(r.out, /THREADBARE_THREAD_ID isn't set/);

    r = await run(h.home, url, ['show', thread.id.slice(0, 8)]);
    assert.equal(r.code, 0, r.out);
    assert.match(r.out, /\nUser: Fix the tests\n\nAssistant: Done\.\n  \(completed, [\d.]+s, \$0\.0100\)\n$/);

    const out = path.join(tmpDir(), 'fixture');
    r = await run(h.home, url, ['export', thread.id, '--out', out]);
    assert.equal(r.code, 0, r.out);
    assert.match(r.out, /Exported 4 events and 0 images to /);
    assert.equal(fs.readFileSync(path.join(out, 'events.ndjson'), 'utf8').trim().split('\n').length, 4);

    r = await run(h.home, url, ['rpc', 'threads.list', '{"include":["inbox"]}']);
    assert.equal(r.code, 0, r.out);
    assert.equal(JSON.parse(r.out).threads[0].id, thread.id);
    r = await run(h.home, url, ['rpc', 'threads.list', 'not json']);
    assert.equal(r.code, 1);
    assert.match(r.out, /Params aren't JSON/);
    r = await run(h.home, url, ['rpc', 'no.such.method']);
    assert.equal(r.code, 1);
    assert.match(r.out, /Unknown method/);
  } finally {
    await server.close();
  }
});

test('tb restart: waits for busy threads, resumes the calling thread, and guards --now inside a thread', async () => {
  const { h, state, server, url } = await serve();
  try {
    const { thread } = h.runner.create({ text: 'Deploy', accountId: 'claude-3' });
    h.adapter.last.init();
    const inThread = { THREADBARE_THREAD_ID: thread.id };

    let r = await run(h.home, url, ['restart', '--now'], inThread);
    assert.equal(r.code, 1);
    assert.match(r.out, /--now stops every turn, this thread's own included/);

    r = await run(h.home, url, ['restart', '--resume', 'Check it works', '--reason', 'new release'], inThread);
    assert.equal(r.code, 0, r.out);
    assert.equal(r.out, `The runner will restart when 1 thread finishes:\n  ${thread.id.slice(0, 8)}  Deploy  [running]\n`);
    const saved = JSON.parse(fs.readFileSync(restartPath(h.home), 'utf8'));
    assert.deepEqual(saved.resumes.map((x: { threadId: string; text: string }) => [x.threadId, x.text]), [[thread.id, 'Check it works']]);
    assert.equal(saved.reason, 'new release');

    r = await run(h.home, url, ['status']);
    assert.match(r.out, /Restart pending: when idle, asked [^\n]+ ago, waiting for 1 thread\n  Reason: new release\n  Then carries on: /);

    // Outside a thread, --resume needs one named.
    r = await run(h.home, url, ['restart', '--resume', 'x']);
    assert.equal(r.code, 1);
    assert.match(r.out, /--resume needs a thread/);

    assert.equal(state.restarts, 0);
    h.adapter.last.result();
    await tick();
    assert.equal(state.restarts, 1);

    r = await run(h.home, url, ['restart', '--now', '--force'], inThread);
    assert.equal(r.code, 0, r.out);
    assert.equal(r.out, 'Restarting now.\n');
  } finally {
    await server.close();
  }
});

test('tb restart and status on a runner that is older than runner.restart', async () => {
  const h = makeHarness();
  const server = new RpcServer({ host: '127.0.0.1', port: 0, token: readToken(h.home), runner: h.runner, log: nullLogger });
  const { port } = await server.listen();
  try {
    const url = `ws://127.0.0.1:${port}/rpc`;
    for (const cmd of ['restart', 'status']) {
      const r = await run(h.home, url, [cmd]);
      assert.equal(r.code, 3, r.out);
      assert.match(r.out, /This runner is too old for runner\.status and runner\.restart/);
    }
  } finally {
    await server.close();
  }
});

test('tb logs prints the tail, filters by thread, and follows', async () => {
  const dir = tmpDir();
  const log = path.join(dir, 'runner.log');
  fs.writeFileSync(log, ['one', 'two {"threadId":"t-1"}', 'three', 'four {"threadId":"t-1"}'].join('\n') + '\n');
  // No runner at this URL: logs still work.
  const env = { THREADBARE_LOG: log };
  let r = await run(dir, 'ws://127.0.0.1:1/rpc', ['logs', '-n', '2'], env);
  assert.equal(r.code, 0, r.out);
  assert.equal(r.out, 'three\nfour {"threadId":"t-1"}\n');
  r = await run(dir, 'ws://127.0.0.1:1/rpc', ['logs', '--thread', 't-1'], env);
  assert.equal(r.out, 'two {"threadId":"t-1"}\nfour {"threadId":"t-1"}\n');
  r = await run(dir, 'ws://127.0.0.1:1/rpc', ['logs'], { THREADBARE_LOG: path.join(dir, 'none.log') });
  assert.equal(r.code, 1);
  assert.match(r.out, /No log at/);

  const f = tb(dir, 'ws://127.0.0.1:1/rpc', ['logs', '-f', '-n', '1', '--thread', 't-2'], env);
  try {
    await new Promise((res) => setTimeout(res, 400));
    fs.appendFileSync(log, 'five {"threadId":"t-2"}\nsix\nseven {"threadId":"t-2"}\n');
    for (let i = 0; i < 40 && !f.out().includes('seven'); i++) await new Promise((res) => setTimeout(res, 50));
    assert.equal(f.out(), 'five {"threadId":"t-2"}\nseven {"threadId":"t-2"}\n');
  } finally {
    f.kill();
  }
  assert.equal(await f.exited, 0, 'SIGTERM ends a follow cleanly');
});
