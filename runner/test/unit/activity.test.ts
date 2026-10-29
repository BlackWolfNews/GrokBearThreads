import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { makeHarness, tmpDir } from '../helpers/fakes.ts';
import { RpcServer } from '../../src/rpc.ts';
import { readToken } from '../../src/config.ts';
import { nullLogger } from '../../src/log.ts';
import { aboutThread, activityDir, describe, formatSummary, parseSince, readActivity, type ActivityEvent } from '../../src/activity.ts';

const TB = path.resolve(import.meta.dirname, '..', '..', 'bin', 'tb');
const NOW = Date.parse('2026-10-29T06:00:00.000Z');

test('--since takes minutes, hours, days or a time', () => {
  assert.equal(parseSince('30m', NOW), NOW - 30 * 60_000);
  assert.equal(parseSince('2h', NOW), NOW - 2 * 3_600_000);
  assert.equal(parseSince('7d', NOW), NOW - 7 * 86_400_000);
  assert.equal(parseSince('2026-10-29T05:00:00Z', NOW), NOW - 3_600_000);
  assert.throws(() => parseSince('a while', NOW), /--since takes/);
});

test('reads the day files in order, from the time given, past a broken line', () => {
  const dir = tmpDir('tb-activity-');
  fs.writeFileSync(path.join(dir, '2026-10-28.jsonl'), [
    JSON.stringify({ at: '2026-10-28T09:00:00.000+08:00', kind: 'click', target: 'too early' }),
    JSON.stringify({ at: '2026-10-29T10:30:00.000+08:00', kind: 'click', target: 'second' }),
  ].join('\n') + '\n');
  fs.writeFileSync(path.join(dir, '2026-10-29.jsonl'), [
    JSON.stringify({ at: '2026-10-29T10:00:00.000+08:00', kind: 'view', thread: 'abcdef12-0000' }),
    '{"at":"2026-10-29T11:00:00.000+08:00","kind":"cli',
    JSON.stringify({ at: '2026-10-29T12:00:00.000+08:00', kind: 'menu', target: 'Thread › Archive', key: '⌘E' }),
  ].join('\n') + '\n');
  fs.writeFileSync(path.join(dir, '2026-09-01.jsonl'), JSON.stringify({ at: '2026-09-01T10:00:00.000+08:00', kind: 'click' }) + '\n');
  fs.writeFileSync(path.join(dir, 'notes.txt'), 'not a day\n');
  const events = readActivity(dir, Date.parse('2026-10-29T01:00:00.000Z'));
  assert.deepEqual(events.map((e) => e.kind + (e.target ? ` ${e.target}` : '')), ['view', 'click second', 'menu Thread › Archive']);
  assert.deepEqual(readActivity(path.join(dir, 'missing'), 0), []);
});

test('each kind reads as a line, with the thread it was in', () => {
  const titles = new Map([['abcdef12-0000-4000-8000-000000000000', 'Fix the tests']]);
  const id = 'abcdef12-0000-4000-8000-000000000000';
  const at = '2026-10-29T10:00:00.000+08:00';
  const line = (e: Omit<ActivityEvent, 'at'>) => describe({ at, ...e }, titles);
  assert.equal(line({ kind: 'click', target: 'Archive (⌘E)', button: 'right', panel: 'threads', thread: id }), 'click   "Archive (⌘E)" (right) in threads · abcdef12 Fix the tests');
  assert.equal(line({ kind: 'click', view: 'ComposerTextView', clicks: 2, modifiers: '⌘' }), 'click   ComposerTextView (x2 with ⌘)');
  assert.equal(line({ kind: 'menu', target: 'Thread › Archive', key: '⌘E' }), 'menu    "Thread › Archive" (⌘E)');
  assert.equal(line({ kind: 'view', thread: id }), 'view    abcdef12 Fix the tests');
  assert.equal(line({ kind: 'view', mode: 'projects', page: 'projects' }), 'view    projects page (projects)');
  assert.equal(line({ kind: 'send', new: true, images: 2 }), 'send    new thread with 2 pictures');
  assert.equal(line({ kind: 'approval', decision: 'allow', thread: id }), 'answer  allow · abcdef12 Fix the tests');
});

test('--thread picks out one thread, its own panel included', () => {
  const at = '2026-10-29T10:00:00.000+08:00';
  assert.equal(aboutThread({ at, kind: 'click', thread: 'abcdef12-0000' }, 'abcd'), true);
  assert.equal(aboutThread({ at, kind: 'panels', showing: ['threads', 'thread:abcdef12-0000'] }, 'abcdef'), true);
  assert.equal(aboutThread({ at, kind: 'click', thread: 'ffff' }, 'abcd'), false);
});

test('the summary counts what is used most', () => {
  const at = '2026-10-29T10:00:00.000+08:00';
  const events: ActivityEvent[] = [
    { at, kind: 'click', target: 'Send', panel: 'thread' },
    { at, kind: 'click', target: 'Send', panel: 'thread' },
    { at, kind: 'click', target: 'Archive (⌘E)', panel: 'threads' },
    { at, kind: 'menu', target: 'Thread › Archive', key: '⌘E' },
    { at, kind: 'hover', target: 'Hibernate' },
  ];
  const text = formatSummary(events);
  assert.match(text, /^5 events from /);
  assert.match(text, /Clicks \(3\)\n {5}2 {2}"Send"\n {5}1 {2}"Archive \(⌘E\)"/);
  assert.match(text, /Clicks by panel \(3\)\n {5}2 {2}thread\n {5}1 {2}threads/);
  assert.match(text, /Menu items \(1\)\n {5}1 {2}"Thread › Archive" \(⌘E\)/);
  assert.match(text, /Tooltips read \(1\)/);
});

function run(args: string[], env: Record<string, string>): Promise<{ code: number | null; out: string; err: string }> {
  return new Promise((resolve) => {
    let out = '';
    let err = '';
    const p = spawn(process.execPath, [TB, ...args], { env: { ...process.env, ...env }, stdio: ['ignore', 'pipe', 'pipe'] });
    p.stdout.on('data', (d) => (out += d));
    p.stderr.on('data', (d) => (err += d));
    p.once('exit', (code) => resolve({ code, out, err }));
  });
}

test('tb activity prints the timeline with thread titles from the runner', async () => {
  const h = makeHarness();
  const server = new RpcServer({ host: '127.0.0.1', port: 0, token: readToken(h.home), runner: h.runner, log: nullLogger });
  const { port } = await server.listen();
  try {
    const { thread } = h.runner.create({ text: 'Tidy the sidebar', accountId: 'claude-3' });
    const dir = activityDir(h.home);
    fs.mkdirSync(dir);
    const at = new Date(Date.now() - 60_000);
    const day = `${at.getFullYear()}-${String(at.getMonth() + 1).padStart(2, '0')}-${String(at.getDate()).padStart(2, '0')}`;
    fs.writeFileSync(path.join(dir, `${day}.jsonl`), JSON.stringify({ at: at.toISOString(), kind: 'view', thread: thread.id }) + '\n');
    const env = { THREADBEAR_HOME: h.home, THREADBEAR_URL: `ws://127.0.0.1:${port}/rpc` };
    const r = await run(['activity'], env);
    assert.equal(r.code, 0, r.err);
    assert.match(r.out, new RegExp(`view {4}${thread.id.slice(0, 8)} ${thread.title}`));
    const json = await run(['activity', '--json', '--since', '1d'], env);
    assert.equal(JSON.parse(json.out.trim()).thread, thread.id);
    // Typing it wrong says so, rather than ignoring the flag.
    const wrong = await run(['activity', '--follow'], env);
    assert.equal(wrong.code, 2);
    assert.match(wrong.err, /tb activity doesn't take --follow/);
  } finally {
    await server.close();
  }
});

test('tb activity says how to turn it on when there is no log', async () => {
  const home = tmpDir('tb-activity-');
  const r = await run(['activity'], { THREADBEAR_HOME: home, THREADBEAR_PORT: '1' });
  assert.equal(r.code, 1);
  assert.match(r.err, /Settings > General/);
});
