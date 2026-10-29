import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { FakeClock } from '../../src/clock.ts';
import { nullLogger } from '../../src/log.ts';
import { CHECK_MS, ErrorWatch, IGNORE_FOR_MS, MAX_PER_DAY, REOPEN_AFTER_MS, normalise, parseAnswer } from '../../src/error-watch.ts';
import type { ErrorWatchHost } from '../../src/error-watch.ts';
import type { GenerateParams, ModelResult } from '../../src/models/index.ts';
import type { ThreadRecord } from '../../src/store.ts';
import { tick, tmpDir } from '../helpers/fakes.ts';

// An error watch with a fake runner that records the threads it's asked to
// open, and a model whose answer the test sets.
function setup(opts: { repo?: string | null; home?: string; clock?: FakeClock } = {}) {
  const home = opts.home ?? tmpDir();
  const clock = opts.clock ?? new FakeClock();
  const threads: (Pick<ThreadRecord, 'id' | 'title' | 'archivedAt'> & { text: string; cwd?: string })[] = [];
  const host: ErrorWatchHost = {
    threadRecords: () => threads as unknown as ThreadRecord[],
    create: (p) => {
      const t = { id: `t${threads.length + 1}`, title: p.title ?? '', text: p.text, cwd: p.cwd };
      threads.push(t);
      return { thread: { id: t.id, title: t.title } as any };
    },
  };
  let answer: unknown = { open: [], ignore: [] };
  const asked: GenerateParams[] = [];
  const models = {
    generate: async (p: GenerateParams): Promise<ModelResult<string>> => {
      asked.push(p);
      return { ok: true, value: JSON.stringify(answer), model: 'fake', costUsd: 0.001 };
    },
  };
  const noted: { threadId: string; text: string }[] = [];
  let paused = false;
  const watch = new ErrorWatch({ home, clock, log: nullLogger });
  const log = watch.tee(nullLogger);
  watch.start({
    host,
    models,
    repo: opts.repo === null ? undefined : (opts.repo ?? '/repo/threadbear'),
    logFile: '/logs/runner.log',
    paused: () => paused,
    noted: (threadId, _title, text) => noted.push({ threadId, text }),
  });
  return {
    home,
    clock,
    watch,
    log,
    threads,
    asked,
    noted,
    answer: (a: unknown) => (answer = a),
    pause: (p: boolean) => (paused = p),
    id: (msg: string) => watch.list().find((g) => g.msg === msg)!.id,
  };
}

test('normalise takes out ids, hashes, temp paths and numbers', () => {
  assert.equal(normalise('Thread not found: 66935d23-c3c5-4721-8c22-8f3fdddbd426'), 'Thread not found: <id>');
  assert.equal(
    normalise('Unit tests failed; the whole output is in /var/folders/rh/6mw/T/threadbear-deploy-94855-unit-tests.log'),
    'Unit tests failed; the whole output is in <tmp>',
  );
  assert.equal(normalise('commit 137e108 broke'), 'commit <hex> broke');
  // A plain word made of hex letters stays.
  assert.equal(normalise('deadbeefcafe failed'), 'deadbeefcafe failed');
  assert.equal(normalise('pending 3, retry in 5000ms'), 'pending N, retry in Nms');
});

test('the same fault logged many ways is one group per message; info lines and its own are not seen', () => {
  const s = setup();
  s.log.error('librarian look failed', { threadId: 'a', error: 'Error: Thread not found: 66935d23-c3c5-4721-8c22-8f3fdddbd426' });
  s.log.error('librarian look failed', { threadId: 'b', error: 'Error: Thread not found: a5548667-5c60-454b-86ff-52b87eb93345' });
  s.log.warn('phone command failed', { kind: 'update', error: 'Thread not found: 66935d23-c3c5-4721-8c22-8f3fdddbd426' });
  s.log.info('runner starting');
  s.log.warn('error watch could not save', { error: 'x' });
  s.log.warn('model call failed', { error: 'rate limited' });
  const groups = s.watch.list();
  assert.deepEqual(groups.map((g) => [g.level, g.msg, g.count]).sort(), [
    ['ERROR', 'librarian look failed', 2],
    ['WARN', 'phone command failed', 1],
  ]);
  const look = groups.find((g) => g.msg === 'librarian look failed')!;
  assert.equal(look.samples.length, 2);
  assert.match(look.samples[1], /a5548667/, 'samples are the lines as logged');
});

test('a check asks the model about new errors and opens a thread in the repo for each one worth it', async () => {
  const s = setup();
  s.log.error('librarian look failed', { error: 'Thread not found: 66935d23-c3c5-4721-8c22-8f3fdddbd426' });
  s.log.warn('phone command failed', { error: 'Thread not found: 66935d23-c3c5-4721-8c22-8f3fdddbd426' });
  s.log.warn('convex sync failed; will retry', { error: 'fetch failed' });
  const look = s.id('librarian look failed');
  const phone = s.id('phone command failed');
  const sync = s.id('convex sync failed; will retry');
  s.answer({ open: [{ ids: [look, phone], title: 'Deleted threads still get looked up', why: 'Something keeps a deleted thread id.' }], ignore: [{ ids: [sync], why: 'Network blip' }] });
  const r = await s.watch.check();
  assert.equal(s.asked.length, 1);
  assert.equal(s.asked[0].feature, 'errors');
  assert.match(s.asked[0].prompt, new RegExp(`${look} \\[ERROR\\] librarian look failed: 1 time`));
  assert.deepEqual(r, { opened: ['t1'], ignored: [sync] });
  const t = s.threads[0];
  assert.equal(t.title, 'Deleted threads still get looked up');
  assert.equal(t.cwd, '/repo/threadbear');
  assert.match(t.text, /Something keeps a deleted thread id\./);
  assert.match(t.text, /ERROR librarian look failed: 1 time/);
  assert.match(t.text, /WARN phone command failed/);
  assert.match(t.text, /`tb land`/);
  assert.match(t.text, /say why and stop/);
  assert.deepEqual(s.noted, [{ threadId: 't1', text: 'Opened a thread for "librarian look failed" and 1 more' }]);
  // Decided: nothing to ask about until something new comes in.
  s.log.error('librarian look failed', { error: 'Thread not found: a5548667-5c60-454b-86ff-52b87eb93345' });
  s.log.warn('convex sync failed; will retry', { error: 'fetch failed' });
  await s.watch.check();
  assert.equal(s.asked.length, 1);
  // Kept across a restart.
  const again = setup({ home: s.home, clock: s.clock });
  assert.equal(again.watch.list().find((g) => g.id === look)?.decision?.threadId, 't1');
});

test('the timer checks every CHECK_MS, and not while the librarian is paused', async () => {
  const s = setup();
  s.log.error('could not build a release of main', { error: 'Unit tests failed' });
  s.pause(true);
  s.clock.advance(CHECK_MS);
  await tick(6);
  assert.equal(s.asked.length, 0);
  s.pause(false);
  s.clock.advance(CHECK_MS);
  await tick(6);
  assert.equal(s.asked.length, 1);
});

test('no repo (a dev runner) means no checks at all', async () => {
  const s = setup({ repo: null });
  s.log.error('something broke', { error: 'x' });
  s.clock.advance(CHECK_MS * 3);
  await tick(6);
  assert.equal(s.asked.length, 0);
  assert.deepEqual(await s.watch.check(), { opened: [], ignored: [] });
  assert.equal(s.watch.list().length, 1, 'still seen, for when it can');
});

test('at most MAX_PER_DAY threads a day; the rest wait for tomorrow', async () => {
  const s = setup();
  const msgs = Array.from({ length: MAX_PER_DAY + 1 }, (_, i) => `fault ${String.fromCharCode(97 + i)}`);
  for (const m of msgs) s.log.error(m);
  s.answer({ open: msgs.map((m) => ({ ids: [s.id(m)], title: m, why: 'bug' })), ignore: [] });
  const r = await s.watch.check();
  assert.equal(r.opened.length, MAX_PER_DAY);
  assert.match(s.asked[0].prompt, new RegExp(`Open at most ${MAX_PER_DAY} threads`));
  const left = s.watch.list().filter((g) => !g.decision);
  assert.equal(left.length, 1, 'the one there was no room for is asked again');
  // Out of room: no model call at all.
  await s.watch.check();
  assert.equal(s.asked.length, 1);
  // The next day's timed check opens it.
  s.answer({ open: [{ ids: [left[0].id], title: 'last', why: 'bug' }], ignore: [] });
  s.clock.advance(86_400_000);
  await tick(6);
  s.clock.advance(CHECK_MS);
  await tick(6);
  assert.equal(s.threads.length, MAX_PER_DAY + 1);
  assert.equal(s.threads.at(-1)?.title, 'last');
});

test('an error let be is asked about again after a week, if it happened since', async () => {
  const s = setup();
  s.log.warn('convex sync failed; will retry', { error: 'fetch failed' });
  // Not mentioned at all: let be.
  await s.watch.check();
  const g = () => s.watch.list()[0];
  assert.equal(g().decision?.what, 'ignored');
  assert.equal(g().decision?.why, 'Not worth a thread');
  s.clock.advance(IGNORE_FOR_MS);
  await s.watch.check();
  assert.equal(s.asked.length, 1, 'not happened since');
  s.log.warn('convex sync failed; will retry', { error: 'fetch failed' });
  await s.watch.check();
  assert.equal(s.asked.length, 2);
  assert.match(s.asked[1].prompt, /Let be before: Not worth a thread/);
});

test('an error whose thread is still open is never asked about; once archived, a recurrence a day later is', async () => {
  const s = setup();
  s.log.error('codex session did not start', { error: 'dynamic tool namespace description must be at most 1024 characters' });
  const id = s.id('codex session did not start');
  s.answer({ open: [{ ids: [id], title: 'Codex rejects the tool description', why: 'Too long.' }], ignore: [] });
  await s.watch.check();
  s.log.error('codex session did not start', { error: 'dynamic tool namespace description must be at most 1024 characters' });
  s.clock.advance(REOPEN_AFTER_MS * 3);
  await s.watch.check();
  assert.equal(s.asked.length, 1, 'its thread is still open');
  s.threads[0].archivedAt = new Date(s.clock.now()).toISOString();
  s.clock.advance(1000);
  await s.watch.check();
  assert.equal(s.asked.length, 1, 'nothing since it was archived');
  s.log.error('codex session did not start', { error: 'dynamic tool namespace description must be at most 1024 characters' });
  await s.watch.check();
  assert.equal(s.asked.length, 2);
  assert.match(s.asked[1].prompt, /A thread already worked on it \("Codex rejects the tool description"\)/);
});

test('a model that fails or answers in prose decides nothing', async () => {
  const s = setup();
  s.log.error('fault');
  s.answer('not json');
  // The fake stringifies the answer: a JSON string isn't an object.
  await s.watch.check();
  assert.equal(s.watch.list()[0].decision, undefined);
  assert.equal(parseAnswer('Sure! {"open": [{"ids": ["ab"], "title": "T", "why": "w"}], "ignore": "x"}')?.open[0].title, 'T');
  assert.equal(parseAnswer('nothing here'), undefined);
});

test('a new group is saved straight away', () => {
  const s = setup();
  s.log.error('crash coming', { error: 'boom' });
  const file = JSON.parse(fs.readFileSync(path.join(s.home, 'error-watch.json'), 'utf8'));
  assert.equal(file.groups[0].msg, 'crash coming');
});
