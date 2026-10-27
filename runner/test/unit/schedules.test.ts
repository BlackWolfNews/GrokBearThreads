import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { makeHarness, tick } from '../helpers/fakes.ts';
import { describeAt, describeCron, nextRuns, parseCron } from '../../src/cron.ts';
import { Scheduler, scheduleMethods } from '../../src/schedules.ts';
import { buildThreadbearTools } from '../../src/threadbear-mcp.ts';
import { ErrorCode, RpcError } from '../../src/protocol.ts';
import { nullLogger } from '../../src/log.ts';

const MIN = 60_000;
const iso = (ms: number) => new Date(ms).toISOString();
const runs = (cron: string, from: string, zone: string, n = 3) => nextRuns(parseCron(cron), Date.parse(from), zone, n).map(iso);

// ------------------------------------------------------------------- cron

test('cron: the common shapes in words', () => {
  const words = (c: string) => describeCron(parseCron(c));
  assert.equal(words('0 9 * * 1-5'), 'Weekdays at 9:00');
  assert.equal(words('30 7 * * 0,6'), 'Weekends at 7:30');
  assert.equal(words('*/15 * * * *'), 'Every 15 minutes');
  assert.equal(words('* * * * *'), 'Every minute');
  assert.equal(words('@hourly'), 'Every hour');
  assert.equal(words('5 * * * *'), 'Every hour at :05');
  assert.equal(words('0 */2 * * *'), 'Every 2 hours');
  assert.equal(words('@daily'), 'Every day at 0:00');
  assert.equal(words('0 9,17 * * mon,wed'), 'Every Monday and Wednesday at 9:00 and 17:00');
  assert.equal(words('0 9 1 * *'), 'On the 1st of every month at 9:00');
  assert.equal(words('0 9 1 jan *'), 'On the 1st of January at 9:00');
  assert.equal(words('7-9 3 * * *'), 'Cron 7-9 3 * * *');
  assert.equal(describeCron(parseCron('0 9 * * 1-5'), 'Australia/Perth'), 'Weekdays at 9:00 (Australia/Perth)');
  assert.equal(describeAt(Date.parse('2026-10-28T07:30:00Z'), 'Australia/Perth', Date.parse('2026-10-26T00:00:00Z')), 'Once, Wed 28 Oct at 15:30');
  assert.equal(describeAt(Date.parse('2027-01-02T07:30:00Z'), 'UTC', Date.parse('2026-10-26T00:00:00Z')), 'Once, Sat 2 Jan 2027 at 7:30');
});

test('cron: next runs in a zone', () => {
  // 12:00 UTC on Monday 26 Oct is 20:00 in Perth, so the next weekday 9:00 is Tuesday's.
  assert.deepEqual(runs('0 9 * * 1-5', '2026-10-26T12:00:00Z', 'Australia/Perth'), [
    '2026-10-27T01:00:00.000Z',
    '2026-10-28T01:00:00.000Z',
    '2026-10-29T01:00:00.000Z',
  ]);
  assert.deepEqual(runs('*/20 * * * *', '2026-10-26T12:05:00Z', 'UTC'), ['2026-10-26T12:20:00.000Z', '2026-10-26T12:40:00.000Z', '2026-10-26T13:00:00.000Z']);
  // Strictly after: a run due right now is the next one's.
  assert.deepEqual(runs('0 12 * * *', '2026-10-26T12:00:00Z', 'UTC', 1), ['2026-10-27T12:00:00.000Z']);
  // Both day fields restricted: either matches (the 13th, or a Friday).
  assert.deepEqual(runs('0 0 13 * 5', '2026-11-01T00:00:00Z', 'UTC', 3), ['2026-11-06T00:00:00.000Z', '2026-11-13T00:00:00.000Z', '2026-11-20T00:00:00.000Z']);
  // 7 is Sunday too.
  assert.deepEqual(runs('0 0 * * 7', '2026-10-26T00:00:00Z', 'UTC', 1), ['2026-11-01T00:00:00.000Z']);
  assert.deepEqual(runs('0 0 30 2 *', '2026-10-26T00:00:00Z', 'UTC'), [], '30 February never comes');
});

test('cron: daylight saving, skipped and repeated times', () => {
  // Sydney jumps from 2:00 to 3:00 on 4 Oct 2026: that day's 2:30 runs at 3:00.
  const syd = runs('30 2 * * *', '2026-10-02T00:00:00Z', 'Australia/Sydney').map((t) =>
    new Date(t).toLocaleString('en-AU', { timeZone: 'Australia/Sydney', hour: 'numeric', minute: '2-digit', day: 'numeric', hour12: false }),
  );
  assert.deepEqual(syd, ['3, 02:30', '4, 03:00', '5, 02:30']);
  // New York's 1:00 to 2:00 happens twice on 1 Nov 2026: 1:30 runs once, the first time.
  assert.deepEqual(runs('30 1 * * *', '2026-10-31T00:00:00Z', 'America/New_York', 3), [
    '2026-10-31T05:30:00.000Z',
    '2026-11-01T05:30:00.000Z',
    '2026-11-02T06:30:00.000Z',
  ]);
});

test('cron: mistakes say what is wrong', () => {
  assert.throws(() => parseCron('0 9 * *'), /5 fields/);
  assert.throws(() => parseCron('61 * * * *'), /Minute 61 is out of range/);
  assert.throws(() => parseCron('0 9 * * funday'), /Can't read "funday"/);
  assert.throws(() => parseCron('*/0 * * * *'), /step/);
  assert.throws(() => parseCron('0 17-9 * * *'), /backwards/);
});

// -------------------------------------------------------------- scheduler

function setup(h = makeHarness()) {
  const updates: unknown[] = [];
  h.runner.onNotification((n) => n.method === 'schedules.updated' && updates.push(n.params));
  const sched = new Scheduler({ runner: h.runner, home: h.home, clock: h.clock, log: nullLogger, zone: () => 'UTC' });
  sched.start();
  return { h, sched, updates };
}

function idleThread(h: ReturnType<typeof makeHarness>) {
  const { thread } = h.runner.create({ text: 'Watch the deploy', accountId: 'claude-3' });
  const s = h.adapter.last;
  s.init();
  s.result('completed');
  return { thread, s };
}

test('a one-off sends to its thread when due, says it was scheduled, then is done', async () => {
  const { h, sched, updates } = setup();
  const { thread, s } = idleThread(h);
  const sc = sched.create({ text: 'Check the deploy again', at: iso(h.clock.now() + 10 * MIN), threadId: thread.id });
  assert.equal(sc.title, 'Check the deploy again');
  assert.equal(sc.whenText, 'Once, Mon 26 Oct at 12:10');
  assert.equal(sc.nextRunAt, '2026-10-26T12:10:00.000Z');
  assert.equal(updates.length, 1);

  h.clock.advance(9 * MIN);
  assert.equal(s.sent.length, 1, 'not yet');
  h.clock.advance(MIN);
  await tick();
  const msg = h.events(thread.id).filter((e) => e.type === 'user.message').at(-1);
  assert.equal(msg.origin, 'schedule');
  assert.equal(msg.scheduleId, sc.id);
  assert.equal(msg.text, '[Scheduled: "Check the deploy again", Once, Mon 26 Oct at 12:10]\n\nCheck the deploy again');
  assert.equal(s.sent.at(-1)?.text, msg.text);

  const done = sched.find(sc.id);
  assert.equal(done.runs, 1);
  assert.equal(done.nextRunAt, undefined);
  assert.equal(done.finishedAt, '2026-10-26T12:10:00.000Z');
  assert.deepEqual(done.lastRun, { at: '2026-10-26T12:10:00.000Z', outcome: 'sent', threadId: thread.id });

  // Kept on disk, and gone a week later.
  const saved = JSON.parse(fs.readFileSync(path.join(h.home, 'schedules.json'), 'utf8'));
  assert.equal(saved.schedules[0].id, sc.id);
  assert.equal(saved.schedules[0].whenText, undefined, 'whenText is worked out, not stored');
  h.clock.advance(8 * 86_400_000);
  assert.deepEqual(sched.list(), []);
  sched.stop();
});

test('a schedule for a busy thread waits for its turn to end rather than joining it', async () => {
  const { h, sched } = setup();
  const { thread } = h.runner.create({ text: 'Long job', accountId: 'claude-3' });
  const s = h.adapter.last;
  s.init();
  // An `at` already passed runs straight away.
  sched.create({ text: 'Status?', at: iso(h.clock.now() - MIN), threadId: thread.id });
  await tick();
  assert.equal(s.sent.length, 1, 'not steered into the running turn');
  assert.equal(h.events(thread.id).filter((e) => e.type === 'user.message').length, 1);
  s.result('completed');
  await tick();
  assert.equal(s.sent.length, 2);
  assert.match(s.sent[1].text, /^\[Scheduled: "Status\?"/);
  sched.stop();
});

test('a cron starts a new thread each time, and skips a run while the last thread is still going', async () => {
  const { h, sched } = setup();
  const sc = sched.create({ text: 'Summarise my inbox', title: 'Inbox summary', cron: '*/30 * * * *', accountId: 'claude-3', model: 'claude-haiku-5-5' });
  assert.equal(sc.cwd, h.cfg.defaults.cwd);
  assert.equal(sc.whenText, 'Every 30 minutes');
  assert.equal(sc.nextRunAt, '2026-10-26T12:30:00.000Z');

  h.clock.advance(30 * MIN);
  await tick();
  const first = h.runner.list().find((t) => t.title === 'Inbox summary');
  assert.ok(first, 'a new thread with the schedule title');
  assert.equal(first.accountId, 'claude-3');
  assert.equal(first.model, 'claude-haiku-5-5');
  assert.equal(h.events(first.id)[0].origin, 'schedule');
  // The thread remembers the schedule that started it, even once renamed.
  assert.deepEqual(first.schedule, { id: sc.id, title: 'Inbox summary' });
  h.runner.update({ threadId: first.id, title: 'Renamed' });
  assert.deepEqual(h.runner.get(first.id).schedule, { id: sc.id, title: 'Inbox summary' });
  assert.equal(sched.find(sc.id).nextRunAt, '2026-10-26T13:00:00.000Z');

  // Still running at 13:00: skipped.
  h.clock.advance(30 * MIN);
  await tick();
  assert.equal(h.runner.list().filter((t) => t.schedule?.id === sc.id).length, 1);
  assert.equal(sched.find(sc.id).lastRun?.outcome, 'skipped');

  h.adapter.last.init();
  h.adapter.last.result('completed');
  h.clock.advance(30 * MIN);
  await tick();
  assert.equal(h.runner.list().filter((t) => t.schedule?.id === sc.id).length, 2);
  assert.equal(sched.find(sc.id).runs, 2);
  sched.stop();
});

test('runs missed while the runner was stopped happen once, then the cron carries on from now', async () => {
  const { h, sched } = setup();
  const { thread } = idleThread(h);
  const sc = sched.create({ text: 'ping', cron: '*/5 * * * *', threadId: thread.id });
  sched.stop();
  h.clock.advance(2 * 60 * MIN);
  const again = new Scheduler({ runner: h.runner, home: h.home, clock: h.clock, log: nullLogger, zone: () => 'UTC' });
  again.start();
  await tick();
  // The CLI was let go while idle, so count the thread's messages, not one session's.
  assert.equal(h.events(thread.id).filter((e) => e.type === 'user.message').length, 2, 'one catch-up run, not 24');
  assert.equal(again.find(sc.id).nextRunAt, '2026-10-26T14:05:00.000Z');
  again.stop();
});

test('while the runner is restarting a due run waits', () => {
  const { h, sched } = setup();
  const { thread, s } = idleThread(h);
  h.runner.refuseNewTurns('The runner is restarting; send again in a moment.');
  const sc = sched.create({ text: 'later', at: iso(h.clock.now() + MIN), threadId: thread.id });
  h.clock.advance(2 * MIN);
  assert.equal(s.sent.length, 1);
  const still = sched.find(sc.id);
  assert.equal(still.nextRunAt, sc.nextRunAt, 'still due');
  assert.equal(still.lastRun, undefined);
  sched.stop();
});

test('a failed run says why, and deleting the thread deletes its schedules', () => {
  const { h, sched } = setup();
  const { thread } = idleThread(h);
  const dir = path.join(h.home, 'gone-soon');
  fs.mkdirSync(dir);
  const job = sched.create({ text: 'build', cron: '@hourly', cwd: dir, accountId: 'claude-3' });
  fs.rmSync(dir, { recursive: true });
  h.clock.advance(60 * MIN);
  const failed = sched.find(job.id);
  assert.equal(failed.lastRun?.outcome, 'failed');
  assert.match(failed.lastRun?.note ?? '', /Folder not found/);
  assert.equal(failed.nextRunAt, '2026-10-26T14:00:00.000Z', 'carries on next time');

  sched.create({ text: 'a', cron: '@daily', threadId: thread.id });
  assert.equal(sched.list(thread.id).length, 1);
  h.runner.delete(thread.id);
  assert.equal(sched.list(thread.id).length, 0);
  assert.equal(sched.list().length, 1);
  sched.stop();
});

test('pause, resume, edit and run now', async () => {
  const { h, sched } = setup();
  const { thread, s } = idleThread(h);
  const sc = sched.create({ text: 'standup notes', cron: '0 9 * * 1-5', threadId: thread.id });
  assert.equal(sched.update({ scheduleId: sc.id.slice(0, 6), paused: true }).nextRunAt, undefined);
  const ran = sched.runNow(sc.id);
  await tick();
  assert.equal(ran.threadId, thread.id);
  assert.equal(s.sent.length, 2, 'run now works while paused');
  const resumed = sched.update({ scheduleId: sc.id, paused: false });
  assert.equal(resumed.nextRunAt, '2026-10-27T09:00:00.000Z');
  const once = sched.update({ scheduleId: sc.id, at: '2026-10-26T15:00:00Z' });
  assert.equal(once.cron, undefined);
  assert.equal(once.nextRunAt, '2026-10-26T15:00:00.000Z');
  assert.throws(() => sched.update({ scheduleId: sc.id, cwd: '/tmp' }), /sends to a thread/);
  sched.delete(sc.id);
  assert.throws(() => sched.find(sc.id), (e: unknown) => e instanceof RpcError && e.code === ErrorCode.scheduleNotFound);
  sched.stop();
});

test('the methods check what they are given', () => {
  const { h, sched } = setup();
  const m = scheduleMethods(sched);
  const code = (fn: () => unknown) => {
    try {
      fn();
    } catch (e) {
      return (e as RpcError).code;
    }
    return 0;
  };
  assert.equal(code(() => m['schedules.create']({ text: 'x', cron: '0 9 * *' })), ErrorCode.badParams);
  assert.equal(code(() => m['schedules.create']({ text: 'x', cron: '0 0 30 2 *' })), ErrorCode.badParams);
  assert.equal(code(() => m['schedules.create']({ text: 'x' })), ErrorCode.badParams);
  assert.equal(code(() => m['schedules.create']({ text: 'x', at: 'soon' })), ErrorCode.badParams);
  assert.equal(code(() => m['schedules.create']({ text: 'x', cron: '@daily', timezone: 'Mars/Olympus' })), ErrorCode.badParams);
  assert.equal(code(() => m['schedules.create']({ text: 'x', cron: '@daily', threadId: 'nope' })), ErrorCode.threadNotFound);
  assert.equal(code(() => m['schedules.create']({ text: 'x', cron: '@daily', accountId: 'claude-99' })), ErrorCode.accountNotFound);
  assert.equal(code(() => m['schedules.delete']({ scheduleId: 'nope' })), ErrorCode.scheduleNotFound);
  const p = m['schedules.preview']({ cron: '0 9 * * 1-5', count: 2 }) as { whenText: string; runs: string[] };
  assert.deepEqual(p, { whenText: 'Weekdays at 9:00', runs: ['2026-10-27T09:00:00.000Z', '2026-10-28T09:00:00.000Z'] });
  assert.equal(h.runner.list().length, 0);
  sched.stop();
});

test('agents schedule messages to their own thread by default', async () => {
  const { h, sched } = setup();
  const { thread, s } = idleThread(h);
  const list = buildThreadbearTools(h.runner, thread.id, () => h.clock.now(), sched);
  const call = async (name: string, args: Record<string, unknown>) => {
    const t = list.find((x) => x.name === name)!;
    const r = (await t.handler(args as never, {})) as { content: { text: string }[]; isError?: boolean };
    return { text: r.content[0].text, error: Boolean(r.isError) };
  };
  const made = await call('schedule_message', { text: 'Look at CI again', when: '20m' });
  assert.equal(made.error, false, made.text);
  assert.match(made.text, /Look at CI again {2}\[Once, Mon 26 Oct at 12:20; next in 20m .*\] {2}to this thread/);
  assert.equal(sched.list()[0].createdBy, thread.id);
  assert.equal((await call('schedule_message', { text: 'x' })).error, true, 'needs a when or a cron');
  assert.equal((await call('schedule_message', { text: 'x', cron: '@daily', model: 'opus' })).error, true, 'model is for new threads');

  const daily = await call('schedule_message', { text: 'Morning summary', cron: '0 8 * * *', new_thread: true });
  assert.match(daily.text, /Every day at 8:00; next in 20h .*to a new thread in /);
  assert.match((await call('list_schedules', {})).text, /Look at CI again[\s\S]*Morning summary/);

  const id = sched.list()[0].id.slice(0, 8);
  assert.match((await call('update_schedule', { scheduleId: id, paused: true })).text, /paused/);
  assert.match((await call('delete_schedule', { scheduleId: id })).text, /Deleted the schedule "Look at CI again"/);
  h.clock.advance(30 * MIN);
  await tick();
  assert.equal(s.sent.length, 1, 'the deleted one never sent');
  sched.stop();
});
