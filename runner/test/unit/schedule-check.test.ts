// Schedule checks (experiment scheduleChecks, src/schedule-check.ts): a
// command run before each run; nothing printed skips it.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { makeHarness, tick, tmpDir } from '../helpers/fakes.ts';
import { Scheduler } from '../../src/schedules.ts';
import { nullLogger } from '../../src/log.ts';
import { checkOutcome, runCheck, type CheckResult } from '../../src/schedule-check.ts';
import { buildThreadbearTools } from '../../src/threadbear-mcp.ts';
import { toOwnedScheduleDoc } from '../../src/sync.ts';

const MIN = 60_000;

function setup(o: { on?: boolean; result?: () => CheckResult } = {}) {
  const h = makeHarness();
  const seen: { command: string; cwd: string }[] = [];
  const sched = new Scheduler({
    runner: h.runner,
    home: h.home,
    clock: h.clock,
    log: nullLogger,
    zone: () => 'UTC',
    checksOn: () => o.on ?? true,
    runCheck: async (p) => {
      seen.push({ command: p.command, cwd: p.cwd });
      return o.result?.() ?? { ok: true, output: '' };
    },
  });
  sched.start();
  return { h, sched, seen };
}

const newThreads = (h: ReturnType<typeof makeHarness>) => h.runner.list(['inbox', 'snoozed', 'archived']).filter((t) => t.title === 'Watch Sentry');

test('scheduleChecks: a check that prints nothing skips the run, and no thread starts', async () => {
  const { h, sched, seen } = setup();
  const sc = await sched.create({ text: 'Triage new Sentry issues', title: 'Watch Sentry', cron: '*/5 * * * *', check: 'sentry-new-issues' });
  h.clock.advance(5 * MIN);
  await tick(6);
  assert.equal(seen.length, 1);
  assert.equal(seen[0].command, 'sentry-new-issues');
  assert.equal(newThreads(h).length, 0);
  const after = sched.find(sc.id);
  assert.equal(after.lastRun?.outcome, 'skipped');
  assert.match(after.lastRun!.note!, /nothing new/);
  assert.equal(after.runs, 0);
  assert.ok(Date.parse(after.nextRunAt!) > h.clock.now(), 'planned for its next time');
  sched.stop();
});

test('scheduleChecks: what the check prints goes into the message', async () => {
  const { h, sched } = setup({ result: () => ({ ok: true, output: 'ISSUE-42 TypeError in sync' }) });
  await sched.create({ text: 'Triage new Sentry issues', title: 'Watch Sentry', cron: '*/5 * * * *', check: 'sentry-new-issues' });
  h.clock.advance(5 * MIN);
  await tick(6);
  const [t] = newThreads(h);
  assert.ok(t, 'a thread started');
  const msg = h.events(t.id).find((e) => e.type === 'user.message').text as string;
  assert.match(msg, /Triage new Sentry issues/);
  assert.match(msg, /Its check found this:[\s\S]*ISSUE-42 TypeError in sync/);
  sched.stop();
});

test('scheduleChecks: a failing check runs anyway, with the error', async () => {
  const { h, sched } = setup({ result: () => ({ ok: false, output: 'sentry: command not found', why: 'it exited with 127' }) });
  await sched.create({ text: 'Triage', title: 'Watch Sentry', cron: '*/5 * * * *', check: 'sentry-new-issues' });
  h.clock.advance(5 * MIN);
  await tick(6);
  const [t] = newThreads(h);
  const msg = h.events(t.id).find((e) => e.type === 'user.message').text as string;
  assert.match(msg, /Its check failed \(it exited with 127\), so this run went ahead anyway/);
  assert.match(msg, /command not found/);
  sched.stop();
});

test('scheduleChecks: with the experiment off the check is ignored and it runs as before', async () => {
  const { h, sched, seen } = setup({ on: false });
  await sched.create({ text: 'Triage', title: 'Watch Sentry', cron: '*/5 * * * *', check: 'sentry-new-issues' });
  h.clock.advance(5 * MIN);
  await tick(6);
  assert.equal(seen.length, 0);
  assert.equal(newThreads(h).length, 1);
  sched.stop();
});

test('scheduleChecks: update sets and takes off the check; Run now skips it', async () => {
  const { h, sched, seen } = setup();
  const sc = await sched.create({ text: 'Triage', title: 'Watch Sentry', cron: '@daily' });
  assert.equal((await sched.update({ scheduleId: sc.id, check: '  ls new/  ' })).check, 'ls new/');
  await sched.runNow(sc.id);
  assert.equal(seen.length, 0, 'Run now is asked for by hand, so it runs');
  assert.equal(newThreads(h).length, 1);
  assert.equal((await sched.update({ scheduleId: sc.id, check: null })).check, undefined);
  await assert.rejects(sched.update({ scheduleId: sc.id, check: 'x'.repeat(2001) }), /at most 2000/);
  sched.stop();
});

test('scheduleChecks: the backend gets the check only from API 51', () => {
  const s = { id: 'a', runnerId: 'r', title: 't', text: 'x', whenText: 'w', paused: false, createdAt: 'c', updatedAt: 'u', runs: 0, check: 'ls' };
  assert.equal(toOwnedScheduleDoc(s as never, 50).check, undefined);
  assert.equal(toOwnedScheduleDoc(s as never, 51).check, 'ls');
});

test('scheduleChecks: the tools offer check only while the experiment is on', () => {
  const { h, sched } = setup();
  const names = (on: boolean) => {
    const tools = buildThreadbearTools(h.runner, 'x', Date.now, sched, undefined, undefined, { scheduleChecks: () => on }) as unknown as { name: string; inputSchema: Record<string, unknown> }[];
    return Object.keys(tools.find((t) => t.name === 'schedule_message')!.inputSchema);
  };
  assert.ok(!names(false).includes('check'));
  assert.ok(names(true).includes('check'));
  sched.stop();
});

test('runCheck: runs in the folder with a state file, keeps what it prints, and times out', async () => {
  const home = tmpDir();
  const cwd = tmpDir('tb-check-cwd-');
  fs.writeFileSync(path.join(cwd, 'new.txt'), 'two new issues');
  const r = await runCheck({ command: 'cat new.txt; echo "$THREADBEAR_SCHEDULE_ID" > "$THREADBEAR_CHECK_STATE"', cwd, home, scheduleId: 'abc' });
  assert.deepEqual(r, { ok: true, output: 'two new issues' });
  assert.equal(fs.readFileSync(path.join(home, 'schedule-checks', 'abc.state'), 'utf8').trim(), 'abc');
  assert.deepEqual(await runCheck({ command: 'true', cwd, home, scheduleId: 'abc' }), { ok: true, output: '' });
  const bad = await runCheck({ command: 'echo nope >&2; exit 3', cwd, home, scheduleId: 'abc' });
  assert.deepEqual(bad, { ok: false, output: 'nope', why: 'it exited with 3' });
  const slow = await runCheck({ command: 'sleep 5', cwd, home, scheduleId: 'abc', timeoutMs: 200 });
  assert.equal(slow.ok, false);
  assert.match((slow as { why: string }).why, /longer than/);
  assert.deepEqual(checkOutcome({ ok: true, output: '' }), { skip: 'Its check found nothing new.' });
});
