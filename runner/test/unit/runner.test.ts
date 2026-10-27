import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { makeHarness, tick, tmpDir } from '../helpers/fakes.ts';
import { checkSequence, checkSummary } from '../helpers/protocol-check.ts';
import { makePng } from '../helpers/png.ts';
import { RpcError } from '../../src/protocol.ts';

const MIN = 60_000;

function create(h: ReturnType<typeof makeHarness>, extra: Record<string, unknown> = {}) {
  return h.runner.create({ text: 'Fix the tests\nmore detail here', accountId: 'claude-3', ...extra });
}

test('create starts a turn: user.message, turn.started, a CLI with a pre-assigned session', () => {
  const h = makeHarness();
  const { thread, turnId } = create(h, { model: 'claude-haiku-5-5' });
  assert.deepEqual(checkSummary(thread), []);
  assert.equal(thread.title, 'Fix the tests');
  assert.equal(thread.status, 'starting');
  assert.equal(thread.live, true);
  const s = h.adapter.last;
  assert.equal(s.opts.resume, false);
  assert.match(s.opts.sessionId, /^[0-9a-f-]{36}$/);
  assert.equal(s.opts.model, 'claude-haiku-5-5');
  assert.equal(s.opts.account.id, 'claude-3');
  assert.equal(s.opts.permissionMode, 'full');
  // The turnId goes with the message, so the CLI's turns can be matched to it.
  assert.deepEqual(s.sent, [{ id: turnId, text: 'Fix the tests\nmore detail here', images: [] }]);
  const evs = h.events(thread.id);
  assert.deepEqual(evs.map((e) => e.type), ['user.message', 'turn.started']);
  assert.ok(evs.every((e) => e.turnId === turnId));
  s.init();
  assert.equal(h.runner.get(thread.id).status, 'running');
  assert.equal(h.runner.get(thread.id).nativeSessionId, s.opts.sessionId);
});

test('deltas are coalesced, carry the last seq, and inProgress shows the partial text', () => {
  const h = makeHarness();
  const { thread } = create(h);
  const s = h.adapter.last;
  s.init();
  s.delta('m1:0', 'Hel');
  s.delta('m1:0', 'lo ');
  s.delta('m1:0', 'there');
  assert.equal(h.events(thread.id).filter((e) => e.type === 'assistant.text.delta').length, 0, 'nothing sent before the flush interval');
  const page = h.runner.events(thread.id);
  assert.deepEqual(page.inProgress, [{ itemId: 'm1:0', type: 'assistant.text', text: 'Hello there' }]);
  const deltas = h.events(thread.id).filter((e) => e.type === 'assistant.text.delta');
  assert.equal(deltas.length, 1, 'events() flushed one coalesced delta');
  assert.equal(deltas[0].text, 'Hello there');
  assert.equal(deltas[0].seq, 2);
  s.delta('m1:0', '!');
  h.clock.advance(40);
  assert.equal(h.events(thread.id).filter((e) => e.type === 'assistant.text.delta').length, 2);
  s.text('m1:0', 'Hello there!');
  assert.deepEqual(h.runner.events(thread.id).inProgress, []);
  s.result('completed', 0.01);
  const evs = h.events(thread.id);
  assert.deepEqual(checkSequence(evs), []);
  assert.deepEqual(
    evs.filter((e) => !e.type.endsWith('.delta')).map((e) => e.type),
    ['user.message', 'turn.started', 'assistant.text', 'turn.completed'],
  );
  const done = evs.at(-1);
  assert.equal(done.outcome, 'completed');
  assert.equal(done.costUsd, 0.01);
  const t = h.runner.get(thread.id);
  assert.equal(t.status, 'idle');
  assert.equal(t.preview, 'Hello there!');
  assert.equal(t.needsYou, true);
  assert.equal(t.costUsd, 0.01);
  assert.equal(h.runner.markSeen(thread.id, t.lastSeq).thread.needsYou, false);
});

test('seq replay: events pages and subscribe backlog have no gaps', () => {
  const h = makeHarness();
  const { thread } = create(h);
  const s = h.adapter.last;
  s.init();
  for (let i = 0; i < 20; i++) s.text(`m${i}:0`, `reply ${i}`);
  s.result();
  const all = h.runner.events(thread.id, { limit: 1000 }).events;
  assert.equal(all.length, 23);
  assert.deepEqual(all.map((e) => e.seq), Array.from({ length: 23 }, (_, i) => i + 1));
  const newest = h.runner.events(thread.id, { limit: 5 });
  assert.deepEqual([newest.firstSeq, newest.lastSeq], [19, 23]);
  const older = h.runner.events(thread.id, { beforeSeq: 19, limit: 5 });
  assert.deepEqual(older.events.map((e) => e.seq), [14, 15, 16, 17, 18]);
  const after = h.runner.events(thread.id, { afterSeq: 20 });
  assert.deepEqual(after.events.map((e) => e.seq), [21, 22, 23]);
  const between = h.runner.events(thread.id, { afterSeq: 5, beforeSeq: 9 });
  assert.deepEqual(between.events.map((e) => e.seq), [6, 7, 8]);
  assert.deepEqual(h.runner.backlog(thread.id, 21).events.map((e) => e.seq), [22, 23]);
  // A restarted runner reads the same log.
  const h2 = h.restart();
  assert.equal(h2.runner.events(thread.id, { limit: 1000 }).events.length, 23);
  assert.equal(h2.runner.get(thread.id).lastSeq, 23);
});

test('idle release after 30 minutes, then the next send resumes the session', async () => {
  const h = makeHarness();
  const { thread } = create(h);
  const s = h.adapter.last;
  s.init();
  s.text('m1:0', 'done');
  s.result('completed', 0.002);
  assert.ok(h.runner.hasIdleTimer(thread.id));
  h.clock.advance(30 * MIN - 1);
  assert.equal(s.ended, false);
  assert.equal(h.runner.isLive(thread.id), true);
  h.clock.advance(1);
  assert.equal(s.ended, true);
  await tick();
  assert.equal(h.runner.get(thread.id).live, false);
  const again = h.runner.send(thread.id, 'and again');
  await tick();
  assert.equal(h.adapter.sessions.length, 2);
  const s2 = h.adapter.last;
  assert.equal(s2.opts.resume, true);
  assert.equal(s2.opts.sessionId, s.opts.sessionId);
  assert.deepEqual(s2.sent, [{ id: again.turnId, text: 'and again', images: [] }]);
  const notes = h.events(thread.id).filter((e) => e.type === 'system.note');
  assert.deepEqual(notes.map((e) => e.text), ['Resumed session']);
  s2.init();
  // The CLI's cost total carries on across a resume.
  s2.result('completed', 0.005);
  const last = h.events(thread.id).at(-1);
  assert.equal(last.costUsd, 0.003);
  assert.equal(h.runner.get(thread.id).costUsd, 0.005);
});

test('a send during a turn goes into it: shown at once, handed to the CLI, answered by that turn', () => {
  const h = makeHarness();
  const { thread, turnId } = create(h);
  const s = h.adapter.last;
  s.init();
  const { turnId: got } = h.runner.send(thread.id, 'second');
  assert.equal(got, turnId, 'the reply names the running turn');
  assert.equal(s.sent.length, 2, 'went to the CLI straight away');
  assert.equal(s.sent[1].text, 'second');
  assert.notEqual(s.sent[1].id, turnId, 'with an id of its own, so the CLI can say when it was answered');
  const evs = h.events(thread.id);
  const um = evs.filter((e) => e.type === 'user.message');
  assert.equal(um.length, 2);
  assert.equal(um[1].turnId, turnId, 'shown in the running turn');
  assert.ok(evs.indexOf(um[1]) > evs.findIndex((e) => e.type === 'turn.started'));
  assert.equal(h.runner.get(thread.id).status, 'running');
  // The CLI folded it in: one result answers both.
  s.result('completed', 0.01, undefined, { answered: [turnId, s.sent[1].id!], answers: s.sent[1].id });
  const done = h.events(thread.id).filter((e) => e.type === 'turn.completed');
  assert.equal(done.length, 1);
  assert.equal(done[0].turnId, turnId);
  assert.equal(h.runner.get(thread.id).status, 'idle');
  assert.equal(h.runner.hasIdleTimer(thread.id), true);
  assert.deepEqual(checkSequence(h.events(thread.id)), []);
});

test('a message sent during a turn that the CLI runs next keeps the turn open until it is answered', () => {
  const h = makeHarness();
  const { thread, turnId } = create(h);
  const s = h.adapter.last;
  s.init();
  h.runner.send(thread.id, 'second');
  const second = s.sent[1].id!;
  s.text('m1:0', 'First answer.');
  // The reply was already finishing, so the CLI answers the first message
  // alone and runs the second straight after.
  s.result('completed', 0.01, undefined, { answered: [turnId], answers: turnId, queuedTurns: 1 });
  assert.equal(h.events(thread.id).filter((e) => e.type === 'turn.completed').length, 0, 'the turn goes on');
  assert.equal(h.runner.get(thread.id).status, 'running');
  assert.equal(h.runner.hasIdleTimer(thread.id), false);
  s.init();
  s.text('m2:0', 'Second answer.');
  s.result('completed', 0.03, undefined, { answered: [second], answers: second, queuedTurns: 0 });
  const evs = h.events(thread.id).filter((e) => !e.type.endsWith('.delta'));
  assert.deepEqual(
    evs.map((e) => e.type),
    ['user.message', 'turn.started', 'user.message', 'assistant.text', 'assistant.text', 'turn.completed'],
  );
  assert.ok(evs.every((e) => e.turnId === turnId), 'one thread turn for both CLI turns');
  assert.equal(evs.at(-1).costUsd, 0.03, 'the cost of both');
  assert.equal(h.runner.get(thread.id).status, 'idle');
});

test('a failure part way through a turn with a message still to answer is shown, and the turn goes on', () => {
  const h = makeHarness();
  const { thread, turnId } = create(h);
  const s = h.adapter.last;
  s.init();
  h.runner.send(thread.id, 'second');
  const second = s.sent[1].id!;
  s.result('failed', 0.01, 'API overloaded', { answered: [turnId], answers: turnId, queuedTurns: 1 });
  let evs = h.events(thread.id);
  assert.equal(evs.at(-1).type, 'error');
  assert.equal(evs.at(-1).message, 'API overloaded');
  assert.equal(h.runner.get(thread.id).status, 'running');
  s.init();
  s.result('completed', 0.02, undefined, { answered: [second], answers: second, queuedTurns: 0 });
  evs = h.events(thread.id);
  assert.equal(evs.at(-1).type, 'turn.completed');
  assert.equal(evs.at(-1).outcome, 'completed');
  assert.equal(h.runner.get(thread.id).status, 'idle');
});

test('Stop cancels a message sent during the turn; it stays in the transcript', async () => {
  const h = makeHarness();
  const { thread, turnId } = create(h);
  const s = h.adapter.last;
  s.init();
  h.runner.send(thread.id, 'second');
  h.runner.interrupt(thread.id);
  await tick();
  assert.equal(s.interrupts, 1);
  // The CLI cancelled the queued message along with the turn.
  s.result('interrupted', 0.01, undefined, { answered: [turnId], answers: turnId, queuedTurns: 0 });
  const evs = h.events(thread.id);
  assert.equal(evs.at(-1).type, 'turn.completed');
  assert.equal(evs.at(-1).outcome, 'interrupted');
  assert.equal(evs.filter((e) => e.type === 'user.message').length, 2);
  assert.equal(h.runner.get(thread.id).status, 'idle');
  assert.equal(s.sent.length, 2, 'nothing sent again');
  // Sent after Stop was pressed, before the CLI stopped: waits for the next turn.
  h.runner.interrupt(thread.id);
  assert.equal(h.runner.get(thread.id).status, 'idle');
});

test('a message sent after Stop, before the CLI has stopped, waits for the next turn', async () => {
  const h = makeHarness();
  const { thread } = create(h);
  const s = h.adapter.last;
  s.init();
  h.runner.interrupt(thread.id);
  const { turnId: next } = h.runner.send(thread.id, 'try again');
  assert.equal(s.sent.length, 1, 'not handed to a CLI that is about to cancel its queue');
  s.result('interrupted');
  assert.equal(s.sent.length, 2);
  assert.equal(s.sent[1].id, next);
  assert.equal(h.events(thread.id).filter((e) => e.type === 'user.message' && e.turnId === next).length, 1);
});

test('the CLI dropping a message sent during the turn ends the turn with a note', () => {
  const h = makeHarness();
  const { thread, turnId } = create(h);
  const s = h.adapter.last;
  s.init();
  h.runner.send(thread.id, 'second');
  s.result('failed', 0.01, 'boom', { answered: [turnId], answers: turnId, queuedTurns: 0 });
  const evs = h.events(thread.id);
  assert.deepEqual(evs.slice(-3).map((e) => e.type), ['system.note', 'error', 'turn.completed']);
  assert.match(evs.at(-3).text, /dropped/);
  assert.equal(h.runner.get(thread.id).status, 'error');
});

test('a message sent while the last CLI is still leaving waits for the next turn', async () => {
  const h = makeHarness();
  h.adapter.slowExit = true;
  const { thread } = create(h);
  const s = h.adapter.last;
  s.init();
  s.result();
  h.clock.advance(30 * MIN);
  assert.equal(s.ended, true, 'released when idle');
  const { turnId: first } = h.runner.send(thread.id, 'first');
  const { turnId: second } = h.runner.send(thread.id, 'second');
  assert.notEqual(second, first, 'no CLI to join, so it gets a turn of its own');
  assert.equal(h.events(thread.id).filter((e) => e.type === 'user.message').length, 2, 'the first is shown; the second waits');
  s.exit();
  await tick();
  const s2 = h.adapter.last;
  assert.notEqual(s2, s);
  assert.deepEqual(s2.sent.map((m) => m.id), [first]);
  s2.init();
  s2.result('completed', undefined, undefined, { answered: [first], answers: first });
  assert.deepEqual(s2.sent.map((m) => m.id), [first, second]);
  const um = h.events(thread.id).filter((e) => e.type === 'user.message');
  assert.deepEqual(um.slice(1).map((e) => e.turnId), [first, second]);
});

test('a message sent during a turn with a folder change due waits for the next turn', async () => {
  const h = makeHarness();
  const { thread, turnId } = create(h);
  const s = h.adapter.last;
  s.init();
  const dir = tmpDir();
  h.runner.update({ threadId: thread.id, cwd: dir });
  const { turnId: next } = h.runner.send(thread.id, 'in the new folder');
  assert.notEqual(next, turnId);
  assert.equal(s.sent.length, 1, 'meant for the new folder, not this CLI');
  s.result('completed', undefined, undefined, { answered: [turnId], answers: turnId });
  await tick();
  const s2 = h.adapter.last;
  assert.notEqual(s2, s);
  assert.equal(s2.opts.cwd, dir);
  assert.deepEqual(s2.sent.map((m) => m.id), [next]);
});

test('interrupt asks the CLI to stop and the turn ends as interrupted', async () => {
  const h = makeHarness();
  const { thread } = create(h);
  const s = h.adapter.last;
  s.init();
  s.delta('m1:0', 'one two');
  h.runner.interrupt(thread.id);
  await tick();
  assert.equal(s.interrupts, 1);
  s.text('m1:0', 'one two');
  s.result('failed', 0.001, 'aborted');
  const done = h.events(thread.id).at(-1);
  assert.equal(done.type, 'turn.completed');
  assert.equal(done.outcome, 'interrupted');
  assert.equal(done.error, undefined);
  assert.equal(h.runner.get(thread.id).status, 'idle');
});

test('interrupt before the CLI is ready kills it and still ends the turn', async () => {
  const h = makeHarness();
  const { thread } = create(h);
  const s = h.adapter.last;
  s.interruptError = new Error('not ready');
  h.runner.interrupt(thread.id);
  await tick();
  assert.equal(s.killed, true);
  const done = h.events(thread.id).at(-1);
  assert.equal(done.outcome, 'interrupted');
  assert.equal(h.runner.get(thread.id).live, false);
});

test('ask mode: approval card, waiting status, allow resolves the CLI callback', async () => {
  const h = makeHarness();
  const { thread } = create(h, { permissionMode: 'ask' });
  const s = h.adapter.last;
  assert.equal(s.opts.permissionMode, 'ask');
  s.init();
  const ac = new AbortController();
  const answer = s.sink.requestApproval({ toolUseId: 'tu1', name: 'Bash', title: 'rm -rf build', input: { command: 'rm -rf build' }, canAlwaysAllow: true, signal: ac.signal });
  const req = h.events(thread.id).find((e) => e.type === 'approval.requested');
  assert.deepEqual(req.options, ['allow', 'allowAlways', 'deny']);
  assert.equal(req.itemId, 'tu1');
  const t = h.runner.get(thread.id);
  assert.equal(t.status, 'waiting');
  assert.equal(t.needsYou, true);
  assert.throws(() => h.runner.respondApproval({ threadId: thread.id, approvalId: req.approvalId, decision: 'answered' }), RpcError);
  h.runner.respondApproval({ threadId: thread.id, approvalId: req.approvalId, decision: 'allowAlways' });
  assert.deepEqual(await answer, { decision: 'allowAlways', message: undefined });
  const resolved = h.events(thread.id).find((e) => e.type === 'approval.resolved');
  assert.equal(resolved.decision, 'allowAlways');
  assert.equal(h.runner.get(thread.id).status, 'running');
  assert.throws(() => h.runner.respondApproval({ threadId: thread.id, approvalId: req.approvalId, decision: 'allow' }), /no longer pending/);
});

test('questions are answered by question text, header or index', async () => {
  const h = makeHarness();
  const { thread } = create(h);
  const s = h.adapter.last;
  s.init();
  const questions = [
    { question: 'Tea or coffee?', header: 'Drink', multiSelect: false, options: [{ label: 'Tea' }, { label: 'Coffee' }] },
    { question: 'Milk?', multiSelect: false, options: [{ label: 'Yes' }, { label: 'No' }] },
  ];
  const answer = s.sink.requestQuestion({ toolUseId: 'q1', questions, signal: new AbortController().signal });
  const req = h.events(thread.id).find((e) => e.type === 'question.requested');
  assert.deepEqual(req.questions, questions);
  h.runner.respondApproval({ threadId: thread.id, approvalId: req.approvalId, decision: 'answered', answers: { Drink: 'Tea', '1': 'No' } });
  assert.deepEqual((await answer).answers, { 'Tea or coffee?': 'Tea', 'Milk?': 'No' });
  assert.equal(h.events(thread.id).at(-1).decision, 'answered');
});

test('pending approvals expire when the CLI cancels or the turn is interrupted', async () => {
  const h = makeHarness();
  const { thread } = create(h, { permissionMode: 'ask' });
  const s = h.adapter.last;
  s.init();
  const ac = new AbortController();
  const a1 = s.sink.requestApproval({ name: 'Edit', title: 'Edit a.ts', input: {}, canAlwaysAllow: false, signal: ac.signal });
  ac.abort();
  assert.equal((await a1).decision, 'expired');
  const a2 = s.sink.requestApproval({ name: 'Edit', title: 'Edit a.ts', input: {}, canAlwaysAllow: false, signal: new AbortController().signal });
  h.runner.interrupt(thread.id);
  assert.equal((await a2).decision, 'expired');
  const resolved = h.events(thread.id).filter((e) => e.type === 'approval.resolved').map((e) => e.decision);
  assert.deepEqual(resolved, ['expired', 'expired']);
});

test('snooze releases the CLI, hides the thread, and brings it back unread', async () => {
  const h = makeHarness();
  const { thread } = create(h);
  const s = h.adapter.last;
  s.init();
  s.result();
  h.runner.markSeen(thread.id, 99);
  const until = new Date(h.clock.now() + 60 * MIN).toISOString();
  const res = h.runner.update({ threadId: thread.id, snoozedUntil: until });
  assert.equal(res.thread.snoozedUntil, until);
  assert.equal(s.ended, true);
  await tick();
  assert.equal(h.runner.get(thread.id).live, false);
  assert.deepEqual(h.runner.list().map((t) => t.id), []);
  assert.deepEqual(h.runner.list(['snoozed']).map((t) => t.id), [thread.id]);
  h.clock.advance(60 * MIN);
  assert.deepEqual(h.runner.list().map((t) => t.id), [thread.id]);
  const t = h.runner.get(thread.id);
  assert.equal(t.snoozedUntil, undefined);
  assert.equal(t.needsYou, true);
  assert.equal(h.runner.markSeen(thread.id, t.lastSeq).thread.needsYou, false);
});

test('archive mid-turn interrupts, then releases the CLI; unarchive brings it back', async () => {
  const h = makeHarness();
  const { thread } = create(h);
  const s = h.adapter.last;
  s.init();
  h.runner.update({ threadId: thread.id, archived: true });
  await tick();
  assert.equal(s.interrupts, 1);
  s.result('failed');
  assert.equal(s.ended, true, 'released straight after the turn');
  assert.equal(h.events(thread.id).at(-1).outcome, 'interrupted');
  assert.deepEqual(h.runner.list(['archived']).map((t) => t.id), [thread.id]);
  assert.ok(h.runner.get(thread.id).archivedAt);
  h.runner.update({ threadId: thread.id, archived: false });
  assert.deepEqual(h.runner.list().map((t) => t.id), [thread.id]);
});

test('changing account or folder starts a new native session with a handoff note', async () => {
  const h = makeHarness();
  const { thread } = create(h);
  const s = h.adapter.last;
  s.init();
  s.text('m1:0', 'The tests pass now.');
  s.result('completed', 0.01);
  const other = tmpDir();
  h.runner.update({ threadId: thread.id, accountId: 'claude-main', cwd: other });
  assert.equal(s.ended, true);
  await tick();
  h.runner.send(thread.id, 'Now commit it');
  await tick();
  const s2 = h.adapter.last;
  assert.equal(s2.opts.resume, false);
  assert.notEqual(s2.opts.sessionId, s.opts.sessionId);
  assert.equal(s2.opts.account.id, 'claude-main');
  assert.equal(s2.opts.cwd, other);
  const sent = s2.sent[0].text;
  assert.match(sent, /^\[Threadbare handoff\]/);
  assert.match(sent, /User: Fix the tests/);
  assert.match(sent, /Assistant: The tests pass now\./);
  assert.ok(sent.endsWith('Now commit it'));
  assert.ok(!sent.includes('User: Now commit it'), 'the new message is not repeated in the note');
  const um = h.events(thread.id).filter((e) => e.type === 'user.message').at(-1);
  assert.equal(um.text, 'Now commit it', 'the transcript keeps what the user typed');
  assert.ok(h.events(thread.id).some((e) => e.type === 'system.note' && /Started a new session/.test(e.text)));
  // Cost keeps adding up across native sessions.
  s2.init();
  s2.result('completed', 0.004);
  assert.equal(h.runner.get(thread.id).costUsd, 0.014);
});

test('a send while the CLI is shutting down waits for it, then starts the next one', async () => {
  for (const how of ['idle', 'folder'] as const) {
    const h = makeHarness();
    h.adapter.slowExit = true;
    const { thread } = create(h);
    const s = h.adapter.last;
    s.init();
    s.result();
    if (how === 'idle') h.clock.advance(30 * MIN);
    else h.runner.update({ threadId: thread.id, cwd: tmpDir() });
    assert.equal(s.ended, true, `${how}: release started`);
    const { turnId } = h.runner.send(thread.id, 'next');
    await tick();
    assert.equal(h.adapter.sessions.length, 1, `${how}: never two CLIs on one thread`);
    s.exit();
    await tick();
    const evs = h.events(thread.id).filter((e) => e.turnId === turnId);
    assert.ok(!evs.some((e) => e.type === 'error' || e.type === 'turn.completed'), `${how}: the old CLI exiting doesn't end the new turn`);
    assert.equal(h.adapter.sessions.length, 2, `${how}: the next CLI started`);
    const s2 = h.adapter.last;
    assert.equal(s2.opts.resume, how === 'idle');
    assert.ok(s2.sent[0].text.endsWith('next'));
    s2.init();
    s2.result();
    assert.equal(h.events(thread.id).at(-1).outcome, 'completed');
    assert.equal(h.runner.get(thread.id).live, true);
  }
});

test('model and permission mode changes go to the live CLI', () => {
  const h = makeHarness();
  const { thread } = create(h);
  const s = h.adapter.last;
  s.init();
  h.runner.update({ threadId: thread.id, model: 'claude-haiku-5-5', permissionMode: 'ask' });
  assert.deepEqual(s.models, ['claude-haiku-5-5']);
  assert.deepEqual(s.modes, ['ask']);
  const t = h.runner.update({ threadId: thread.id, model: null }).thread;
  assert.equal(t.model, undefined);
  assert.deepEqual(s.models, ['claude-haiku-5-5', undefined]);
});

test('effort goes to the CLI at start and on change; null is the model\'s own level', () => {
  const h = makeHarness();
  const { thread } = create(h, { effort: 'low' });
  assert.deepEqual(checkSummary(thread), []);
  assert.equal(thread.effort, 'low');
  const s = h.adapter.last;
  assert.equal(s.opts.effort, 'low');
  s.init();
  h.runner.update({ threadId: thread.id, effort: 'max' });
  assert.deepEqual(s.efforts, ['max']);
  const t = h.runner.update({ threadId: thread.id, effort: null }).thread;
  assert.equal(t.effort, undefined);
  assert.deepEqual(s.efforts, ['max', undefined]);
  // What the CLI reports it ran at shows on the summary.
  s.effort('high');
  assert.equal(h.runner.get(thread.id).effortInUse, 'high');
  assert.deepEqual(checkSummary(h.runner.get(thread.id)), []);
});

test("a turn on a thread with no model shows the account's real default", () => {
  const h = makeHarness();
  const { thread } = create(h);
  const s = h.adapter.last;
  s.init(undefined, 'claude-fable-5-1');
  const t = h.runner.get(thread.id);
  assert.equal(t.model, undefined);
  assert.equal(t.modelInUse, 'claude-fable-5-1');
  const note = h.notes.find((n) => n.method === 'accounts.updated');
  assert.ok(note && note.method === 'accounts.updated');
  assert.equal(note.params.accounts.find((a) => a.id === 'claude-3')?.defaultModel, 'claude-fable-5-1');
  assert.equal(h.runner.hello().accounts.find((a) => a.id === 'claude-3')?.defaultModel, 'claude-fable-5-1');
  // The same again isn't news.
  const before = h.notes.length;
  s.init(undefined, 'claude-fable-5-1');
  assert.equal(h.notes.filter((n) => n.method === 'accounts.updated').length, 1);
  assert.ok(h.notes.length >= before);
  // A thread with a model of its own says nothing about the default.
  const b = create(h, { model: 'haiku' }).thread;
  h.adapter.last.init(undefined, 'claude-haiku-5-5');
  assert.equal(h.runner.get(b.id).modelInUse, 'claude-haiku-5-5');
  assert.equal(h.runner.hello().accounts.find((a) => a.id === 'claude-3')?.defaultModel, 'claude-fable-5-1');
});

test('the model list comes from the adapter at startup and reaches clients', async () => {
  const h = makeHarness();
  const choices = [{ id: 'opus', model: 'claude-opus-5-5', title: 'Opus 5.5', effortLevels: ['low', 'high'] as const }];
  const asked: string[] = [];
  h.adapter.models = async (account) => {
    asked.push(account.id);
    return choices.map((c) => ({ ...c, effortLevels: [...c.effortLevels] }));
  };
  await h.runner.probeModels();
  assert.deepEqual(asked, ['claude-main', 'claude-3']);
  const note = h.notes.find((n) => n.method === 'accounts.updated');
  assert.ok(note && note.method === 'accounts.updated');
  assert.deepEqual(h.runner.hello().accounts.map((a) => a.models?.[0]?.title), ['Opus 5.5', 'Opus 5.5']);
  // A CLI that can't answer leaves the list unknown and the runner going.
  h.adapter.models = async () => {
    throw new Error('no cli');
  };
  await h.runner.probeModels();
  assert.equal(h.runner.hello().accounts[0].models?.length, 1);
});

test('a CLI that dies mid-turn fails the turn with an error event', () => {
  const h = makeHarness();
  const { thread } = create(h);
  const s = h.adapter.last;
  s.init();
  s.sink.exited(new Error('Claude Code process exited with code 1'));
  const evs = h.events(thread.id);
  assert.deepEqual(evs.slice(-2).map((e) => e.type), ['error', 'turn.completed']);
  assert.equal(evs.at(-1).outcome, 'failed');
  const t = h.runner.get(thread.id);
  assert.equal(t.status, 'error');
  assert.equal(t.live, false);
});

test('startup recovery: mid-turn threads stop, approvals expire, queued text is kept', () => {
  const h = makeHarness();
  const { thread, turnId } = create(h, { permissionMode: 'ask' });
  const s = h.adapter.last;
  s.init();
  void s.sink.requestApproval({ name: 'Bash', title: 'ls', input: {}, canAlwaysAllow: true, signal: new AbortController().signal });
  h.runner.send(thread.id, 'queued while waiting');
  const approvalId = h.events(thread.id).find((e) => e.type === 'approval.requested').approvalId;
  // Simulate the runner dying: a new runner loads the same data dir.
  const h2 = h.restart();
  const t = h2.runner.get(thread.id);
  assert.equal(t.status, 'stopped');
  assert.equal(t.live, false);
  assert.equal(t.needsYou, true);
  const evs = h2.runner.events(thread.id).events;
  // The message went into the turn, so it's in the transcript already and
  // there's nothing queued to report.
  const tail = evs.slice(-3);
  assert.deepEqual(tail.map((e) => e.type), ['user.message', 'approval.resolved', 'turn.completed']);
  assert.equal((tail[0] as any).text, 'queued while waiting');
  assert.equal((tail[0] as any).turnId, turnId);
  assert.equal((tail[1] as any).approvalId, approvalId);
  assert.equal((tail[1] as any).decision, 'expired');
  assert.equal((tail[2] as any).turnId, turnId);
  assert.equal((tail[2] as any).outcome, 'interrupted');
  assert.deepEqual(checkSequence(evs), []);
  // Sending again resumes the session it had.
  h2.runner.send(thread.id, 'carry on');
  assert.equal(h2.adapter.last.opts.resume, true);
});

test('startup recovery: a message still waiting for its turn is kept as a note', () => {
  const h = makeHarness();
  const { thread, turnId } = create(h);
  const s = h.adapter.last;
  s.init();
  // A folder change is due on the next turn, so the message waits for it
  // rather than joining this one.
  h.runner.update({ threadId: thread.id, cwd: tmpDir() });
  h.runner.send(thread.id, 'queued while waiting');
  assert.equal(s.sent.length, 1);
  const h2 = h.restart();
  const evs = h2.runner.events(thread.id).events;
  const tail = evs.slice(-2);
  assert.deepEqual(tail.map((e) => e.type), ['turn.completed', 'system.note']);
  assert.equal((tail[0] as any).turnId, turnId);
  assert.match((tail[1] as any).text, /queued while waiting/);
  assert.deepEqual(checkSequence(evs), []);
});

test('stopping the runner mid-turn ends the turn as stopped, not failed', async () => {
  const h = makeHarness();
  const { thread, turnId } = create(h, { permissionMode: 'ask' });
  const s = h.adapter.last;
  s.init();
  s.delta('m1:0', 'partial answer');
  const approval = s.sink.requestApproval({ name: 'Bash', title: 'ls', input: {}, canAlwaysAllow: true, signal: new AbortController().signal });
  await h.runner.shutdown();
  assert.equal((await approval).decision, 'expired');
  // The CLI dies as the runner kills its process group; that's not an error.
  s.sink.exited(new Error('Claude Code process exited with code 143'));
  const evs = h.events(thread.id).filter((e) => !e.type.endsWith('.delta'));
  assert.deepEqual(evs.slice(-3).map((e) => e.type), ['assistant.text', 'approval.resolved', 'turn.completed']);
  assert.equal(evs.at(-3).text, 'partial answer');
  const done = evs.at(-1);
  assert.equal(done.turnId, turnId);
  assert.equal(done.outcome, 'interrupted');
  assert.ok(!evs.some((e) => e.type === 'error'));
  assert.equal(h.runner.get(thread.id).status, 'stopped');
  // The next runner has nothing left to recover and resumes the session.
  const h2 = h.restart();
  assert.equal(h2.runner.get(thread.id).status, 'stopped');
  assert.equal(h2.runner.events(thread.id).events.at(-1)!.type, 'turn.completed');
  h2.runner.send(thread.id, 'carry on');
  assert.equal(h2.adapter.last.opts.resume, true);
});

test('list, search and protocol errors', () => {
  const h = makeHarness();
  const a = create(h).thread;
  h.clock.advance(1000);
  const b = h.runner.create({ text: 'Plan the garden shed', accountId: 'claude-main' }).thread;
  assert.deepEqual(h.runner.list().map((t) => t.id), [b.id, a.id]);
  assert.deepEqual(h.runner.search('garden').map((t) => t.id), [b.id]);
  assert.deepEqual(h.runner.search('FIX tests').map((t) => t.id), [a.id]);
  h.runner.update({ threadId: a.id, archived: true });
  assert.deepEqual(h.runner.search('fix').map((t) => t.id), [a.id], 'search includes archived threads');
  assert.throws(() => h.runner.get('nope'), (e: RpcError) => e.code === -32004);
  assert.throws(() => h.runner.create({ text: 'x', accountId: 'claude-99' }), (e: RpcError) => e.code === -32010);
  assert.throws(() => h.runner.create({ text: 'x', cwd: '/definitely/not/here' }), (e: RpcError) => e.code === -32602);
  assert.throws(() => h.runner.send(a.id, ''), (e: RpcError) => e.code === -32602);
});

test('images are copied into the thread media folder and sent with the message', () => {
  const h = makeHarness();
  const src = path.join(h.home, 'shot.png');
  fs.writeFileSync(src, makePng(20, 10));
  const { image } = h.runner.importMedia(src);
  assert.ok(image.path.startsWith(path.join(h.home, 'inbox')));
  assert.deepEqual([image.mediaType, image.width, image.height], ['image/png', 20, 10]);
  const { thread } = h.runner.create({ text: 'What is this?', images: [image] });
  const um = h.events(thread.id)[0];
  assert.equal(um.images.length, 1);
  assert.ok(um.images[0].path.startsWith(path.join(h.home, 'threads', thread.id, 'media')));
  assert.equal(um.images[0].width, 20);
  assert.deepEqual(h.adapter.last.sent[0].images, um.images);
  fs.rmSync(image.path);
  assert.ok(fs.existsSync(um.images[0].path), 'the thread keeps its copy when inbox is cleaned');
});

test('default account is the last one used', () => {
  const h = makeHarness();
  assert.equal(h.runner.hello().defaults.accountId, 'claude-main');
  create(h);
  assert.equal(h.runner.hello().defaults.accountId, 'claude-3');
  assert.equal(h.runner.create({ text: 'x' }).thread.accountId, 'claude-3');
});

test("runner.json's default model is used when a new thread names none", () => {
  // dev-runner.sh sets it, so a thread started from a debug app's composer
  // runs on the cheapest model rather than the account's default.
  const h = makeHarness(tmpDir(), { defaults: { cwd: tmpDir(), model: 'claude-haiku-5-5' } });
  assert.equal(h.runner.hello().defaults.model, 'claude-haiku-5-5');
  const a = h.runner.create({ text: 'x', accountId: 'claude-3' }).thread;
  assert.equal(a.model, 'claude-haiku-5-5');
  assert.equal(h.adapter.last.opts.model, 'claude-haiku-5-5');
  const b = h.runner.create({ text: 'y', accountId: 'claude-3', model: 'sonnet' }).thread;
  assert.equal(b.model, 'sonnet', 'a model given wins');
  assert.equal(makeHarness().runner.hello().defaults.model, undefined);
});

// ---------------------------------------------------------------- review fixes

test('a turn the CLI starts by itself gets turn events, a running status and needsYou', async () => {
  const h = makeHarness();
  const { thread } = create(h);
  const s = h.adapter.last;
  s.init();
  s.result();
  h.runner.markSeen(thread.id, h.runner.get(thread.id).lastSeq);
  assert.equal(h.runner.get(thread.id).needsYou, false);
  // A background shell finished; the CLI starts a turn on its own.
  s.out({ kind: 'cliTurn', note: 'Background command "sleep 5" completed (exit code 0)' });
  const t = h.runner.get(thread.id);
  assert.equal(t.status, 'running');
  assert.equal(h.runner.hasIdleTimer(thread.id), false, 'no idle release while it runs');
  s.text('m9:0', 'The background job finished.');
  // A message sent now goes into that turn, like any running turn.
  const { turnId: got } = h.runner.send(thread.id, 'thanks');
  assert.equal(s.sent.length, 2);
  const msgId = s.sent[1].id!;
  const started = h.events(thread.id).filter((e) => e.type === 'turn.started');
  const auto = started[1];
  assert.equal(got, auto.turnId);
  // The CLI's own turn ended before it took the message; it answers it next.
  s.result('completed', 0, undefined, { own: true, queuedTurns: 1 });
  assert.equal(h.runner.get(thread.id).status, 'running', 'the turn waits for the answer');
  s.init();
  s.text('m10:0', 'You are welcome.');
  s.result('completed', 0, undefined, { answered: [msgId], answers: msgId, queuedTurns: 0 });
  const evs = h.events(thread.id).filter((e) => !e.type.endsWith('.delta'));
  const autoEvents = evs.filter((e) => e.turnId === auto.turnId).map((e) => e.type);
  assert.deepEqual(autoEvents, ['turn.started', 'system.note', 'assistant.text', 'user.message', 'assistant.text', 'turn.completed']);
  assert.deepEqual(checkSequence(h.events(thread.id)), []);
  assert.equal(h.runner.get(thread.id).needsYou, true);
  assert.equal(h.runner.hasIdleTimer(thread.id), true);
});

test("a message sent while a turn is only a background subagent's approval waits for that turn", async () => {
  const h = makeHarness();
  const { thread } = create(h, { permissionMode: 'ask' });
  const s = h.adapter.last;
  s.init();
  s.result();
  h.runner.markSeen(thread.id, h.runner.get(thread.id).lastSeq);
  // A background subagent asks for approval with no turn running: the
  // runner opens a turn for the card, but the CLI isn't running one.
  const ac = new AbortController();
  const answer = s.sink.requestApproval({ name: 'Bash', title: 'npm test', input: {}, canAlwaysAllow: true, signal: ac.signal });
  assert.equal(h.runner.get(thread.id).status, 'waiting');
  const { turnId: next } = h.runner.send(thread.id, 'while you wait');
  assert.equal(s.sent.length, 1, 'nothing to join; waits');
  const approvalId = h.events(thread.id).find((e) => e.type === 'approval.requested').approvalId;
  h.runner.respondApproval({ threadId: thread.id, approvalId, decision: 'allow' });
  await answer;
  assert.equal(s.sent.length, 1, 'the turn goes on until the CLI runs one and ends it');
  s.out({ kind: 'cliTurn' });
  s.result('completed', 0, undefined, { own: true });
  // That turn ended; the waiting message starts its own.
  assert.equal(s.sent.length, 2);
  assert.equal(s.sent[1].id, next);
  assert.deepEqual(checkSequence(h.events(thread.id)), []);
});

test("a CLI turn that starts while the thread's message waits in the CLI doesn't end that message's turn", () => {
  const h = makeHarness();
  const { thread, turnId } = create(h);
  const s = h.adapter.last;
  s.init();
  // The CLI was already busy with its own turn when the message arrived.
  s.out({ kind: 'cliTurn' });
  s.text('m1:0', 'Otters have thick fur.');
  s.out({ kind: 'result', result: { outcome: 'completed', durationMs: 5, own: true } });
  assert.equal(h.runner.get(thread.id).status, 'running', 'still waiting for its own answer');
  assert.ok(!h.events(thread.id).some((e) => e.type === 'turn.completed'));
  // A stale answer for some other message doesn't end it either.
  s.out({ kind: 'result', result: { outcome: 'completed', durationMs: 5, answers: 'some-other-id' } });
  assert.ok(!h.events(thread.id).some((e) => e.type === 'turn.completed'));
  s.text('m2:0', 'PINEAPPLE');
  s.out({ kind: 'result', result: { outcome: 'completed', durationMs: 5, answers: turnId } });
  const done = h.events(thread.id).filter((e) => e.type === 'turn.completed');
  assert.equal(done.length, 1);
  assert.equal(done[0].turnId, turnId);
  assert.equal(h.events(thread.id).filter((e) => e.type === 'turn.started').length, 1);
  assert.equal(h.runner.get(thread.id).status, 'idle');
});

test('a background subagent asking for approval with no turn running gets a turn and a card', async () => {
  const h = makeHarness();
  const { thread } = create(h, { permissionMode: 'ask' });
  const s = h.adapter.last;
  s.init();
  s.result();
  const answer = s.sink.requestApproval({ name: 'Bash', title: 'mkdir late-made', input: { command: 'mkdir late-made' }, canAlwaysAllow: true, signal: new AbortController().signal });
  const req = h.events(thread.id).find((e) => e.type === 'approval.requested');
  assert.ok(req, 'the card is shown');
  assert.equal(req.itemId, undefined);
  const started = h.events(thread.id).filter((e) => e.type === 'turn.started').at(-1);
  assert.equal(req.turnId, started.turnId);
  const t = h.runner.get(thread.id);
  assert.equal(t.status, 'waiting');
  assert.equal(t.needsYou, true);
  h.runner.respondApproval({ threadId: thread.id, approvalId: req.approvalId, decision: 'allow' });
  assert.equal((await answer).decision, 'allow');
  assert.equal(h.runner.get(thread.id).status, 'running');
  // The subagent finishes; the CLI's own turn reports it, then ends.
  s.out({ kind: 'cliTurn', note: 'Agent "make a folder" completed' });
  s.text('m5:0', 'Made the folder.');
  s.out({ kind: 'result', result: { outcome: 'completed', durationMs: 5, own: true } });
  assert.equal(h.events(thread.id).filter((e) => e.type === 'turn.started').length, 2, 'one turn for the request and the report');
  assert.equal(h.events(thread.id).at(-1).type, 'turn.completed');
  assert.equal(h.runner.get(thread.id).status, 'idle');
  assert.deepEqual(checkSequence(h.events(thread.id)), []);
});

test('interrupting a turn opened only for an approval ends it at once', async () => {
  const h = makeHarness();
  const { thread } = create(h, { permissionMode: 'ask' });
  const s = h.adapter.last;
  s.init();
  s.result();
  const answer = s.sink.requestQuestion({ questions: [{ question: 'Which?', multiSelect: false, options: [{ label: 'A' }] }], signal: new AbortController().signal });
  h.runner.interrupt(thread.id);
  assert.equal((await answer).answers, null);
  const done = h.events(thread.id).at(-1);
  assert.equal(done.type, 'turn.completed');
  assert.equal(done.outcome, 'interrupted');
  assert.equal(h.runner.get(thread.id).status, 'idle');
});

test('an interrupted turn the CLI never ends is ended after a grace period', async () => {
  const h = makeHarness();
  const { thread, turnId } = create(h);
  const s = h.adapter.last;
  s.init();
  h.runner.interrupt(thread.id);
  await tick();
  assert.equal(s.interrupts, 1);
  h.clock.advance(9_999);
  assert.equal(h.runner.get(thread.id).status, 'running');
  h.clock.advance(1);
  const done = h.events(thread.id).at(-1);
  assert.equal(done.type, 'turn.completed');
  assert.equal(done.turnId, turnId);
  assert.equal(done.outcome, 'interrupted');
  assert.equal(h.runner.get(thread.id).status, 'idle');
  // A late result from the CLI changes nothing.
  s.result('interrupted');
  assert.equal(h.events(thread.id).filter((e) => e.type === 'turn.completed').length, 1);
});

test('background work keeps the CLI past the idle time; release afterwards', async () => {
  const h = makeHarness();
  const { thread } = create(h);
  const s = h.adapter.last;
  s.init();
  s.out({ kind: 'tasks', tasks: [{ id: 'b1', type: 'local_bash', description: 'npm run dev' }] });
  s.result();
  assert.equal(h.runner.hasIdleTimer(thread.id), false);
  h.clock.advance(3 * 30 * MIN);
  assert.equal(s.ended, false, 'not released while the job runs');
  s.out({ kind: 'tasks', tasks: [] });
  assert.equal(h.runner.hasIdleTimer(thread.id), true);
  h.clock.advance(30 * MIN);
  assert.equal(s.ended, true);
  assert.equal(s.endedHard, false);
});

test('snoozing a thread with background work stops it straight away and says so', async () => {
  const h = makeHarness();
  const { thread } = create(h);
  const s = h.adapter.last;
  s.init();
  s.out({ kind: 'tasks', tasks: [{ id: 'b1', type: 'local_bash', description: 'npm run dev' }] });
  s.result();
  h.runner.update({ threadId: thread.id, snoozedUntil: new Date(h.clock.now() + 60 * MIN).toISOString() });
  assert.equal(s.ended, true);
  assert.equal(s.endedHard, true, 'killed rather than waiting for the job');
  const note = h.events(thread.id).at(-1);
  assert.equal(note.type, 'system.note');
  assert.match(note.text, /Stopped background work.*npm run dev/);
  await tick();
  assert.equal(h.runner.get(thread.id).live, false);
});

test('a CLI turn left open when its CLI is released ends as interrupted', async () => {
  const h = makeHarness();
  h.adapter.slowExit = true;
  const { thread } = create(h);
  const s = h.adapter.last;
  s.init();
  s.result();
  h.runner.update({ threadId: thread.id, archived: true });
  assert.equal(s.ended, true);
  // While it shuts down, a background job's notification starts a turn.
  s.out({ kind: 'cliTurn' });
  assert.equal(h.runner.get(thread.id).status, 'running');
  s.exit();
  await tick();
  const done = h.events(thread.id).at(-1);
  assert.equal(done.type, 'turn.completed');
  assert.equal(done.outcome, 'interrupted');
  assert.equal(h.runner.get(thread.id).status, 'idle');
  assert.equal(h.runner.get(thread.id).live, false);
});

test('"Always allow" rules are kept on the thread and given to the next CLI', async () => {
  const h = makeHarness();
  const { thread } = create(h, { permissionMode: 'ask' });
  const s = h.adapter.last;
  assert.deepEqual(s.opts.allowRules, []);
  s.init();
  s.out({ kind: 'allowRules', rules: ['Bash(touch second.txt)'] });
  s.out({ kind: 'allowRules', rules: ['Bash(touch second.txt)', 'Write'] });
  s.result();
  h.clock.advance(30 * MIN);
  await tick();
  h.runner.send(thread.id, 'next');
  await tick();
  assert.deepEqual(h.adapter.last.opts.allowRules, ['Bash(touch second.txt)', 'Write']);
  // And after a runner restart.
  const h2 = h.restart();
  h2.runner.send(thread.id, 'again');
  await tick();
  assert.deepEqual(h2.adapter.last.opts.allowRules, ['Bash(touch second.txt)', 'Write']);
});

test('live CLIs are capped: starting one more releases the longest-idle one', async () => {
  const h = makeHarness(undefined, { maxLive: 2 });
  const a = create(h).thread;
  const sa = h.adapter.last;
  sa.init();
  sa.result();
  h.clock.advance(1000);
  const b = create(h).thread;
  const sb = h.adapter.last;
  sb.init();
  // b is mid-turn, so it can't be picked.
  h.clock.advance(1000);
  const c = create(h).thread;
  await tick();
  assert.equal(sa.ended, true, 'the idle one went');
  assert.equal(sb.ended, false, 'the busy one stayed');
  assert.equal(h.runner.isLive(c.id), true);
  // Nothing idle left to release: the cap is passed rather than stopping work.
  h.adapter.last.init();
  await tick();
  create(h);
  await tick();
  assert.equal(sb.ended, false);
  assert.equal(h.runner.isLive(a.id), false);
  assert.equal(h.runner.isLive(b.id), true);
});

test('a send the disk refuses leaves no stuck turn behind', async () => {
  const h = makeHarness();
  const { thread } = create(h);
  const s = h.adapter.last;
  s.init();
  s.result();
  const file = path.join(h.home, 'threads', thread.id, 'events.ndjson');
  fs.chmodSync(file, 0o444);
  try {
    assert.throws(() => h.runner.send(thread.id, 'this one fails'), /EACCES|permission/i);
  } finally {
    fs.chmodSync(file, 0o644);
  }
  const t = h.runner.get(thread.id);
  assert.equal(t.status, 'idle');
  assert.equal(s.sent.length, 1, 'nothing went to the CLI');
  const { turnId } = h.runner.send(thread.id, 'this one works');
  assert.equal(s.sent.length, 2);
  assert.equal(s.sent[1].id, turnId);
  assert.equal(h.runner.get(thread.id).status, 'running');
  assert.deepEqual(checkSequence(h.runner.events(thread.id).events), []);
});

test('recovery: approvals keep their turnId, and a turn already ended on disk is not ended twice', () => {
  const h = makeHarness();
  const { thread, turnId } = create(h, { permissionMode: 'ask' });
  const s = h.adapter.last;
  s.init();
  void s.sink.requestApproval({ name: 'Bash', title: 'ls', input: {}, canAlwaysAllow: true, signal: new AbortController().signal });
  const h2 = h.restart();
  const resolved = h2.runner.events(thread.id).events.find((e) => e.type === 'approval.resolved')!;
  assert.equal(resolved.turnId, turnId);

  // A crash between appending turn.completed and saving thread.json.
  const h3 = makeHarness();
  const t = h3.runner.create({ text: 'hi', accountId: 'claude-3' });
  const s3 = h3.adapter.last;
  s3.init();
  const recFile = path.join(h3.home, 'threads', t.thread.id, 'thread.json');
  const midTurn = fs.readFileSync(recFile, 'utf8');
  s3.result();
  fs.writeFileSync(recFile, midTurn); // thread.json still says running
  assert.equal(JSON.parse(midTurn).status, 'running');
  const h4 = h3.restart();
  const evs = h4.runner.events(t.thread.id).events;
  assert.equal(evs.filter((e) => e.type === 'turn.completed').length, 1);
  assert.equal(h4.runner.get(t.thread.id).status, 'idle');
  assert.equal(h4.runner.get(t.thread.id).lastSeq, evs.at(-1)!.seq);
});

test('an unreadable thread.json is rebuilt from the event log instead of the thread vanishing', async () => {
  const h = makeHarness();
  const { thread } = create(h);
  const s = h.adapter.last;
  s.init();
  s.text('m1:0', 'All fixed.');
  s.result();
  const dir = path.join(h.home, 'threads', thread.id);
  fs.writeFileSync(path.join(dir, 'thread.json'), '');
  const h2 = h.restart();
  const t = h2.runner.list().find((x) => x.id === thread.id)!;
  assert.ok(t, 'still listed');
  assert.equal(t.title, 'Fix the tests');
  assert.equal(t.preview, 'All fixed.');
  assert.equal(t.permissionMode, 'ask');
  assert.ok(fs.readdirSync(dir).some((f) => f.startsWith('thread.json.unreadable-')), 'the bad file is kept aside');
  assert.match(h2.runner.events(thread.id).events.at(-1)!.type, /system.note/);
  h2.runner.send(thread.id, 'carry on');
  await tick();
  const s2 = h2.adapter.last;
  assert.equal(s2.opts.resume, false);
  assert.match(s2.sent[0].text, /earlier session couldn't be found/);
  assert.match(s2.sent[0].text, /Assistant: All fixed\./);
});

test('blank folders, search limit 0 and startup notices', () => {
  const h = makeHarness();
  const t = h.runner.create({ text: 'x', cwd: '  ', accountId: 'claude-3' }).thread;
  assert.equal(t.cwd, h.cfg.defaults.cwd, 'a blank folder means the default');
  assert.throws(() => h.runner.update({ threadId: t.id, cwd: '' }), (e: RpcError) => e.code === -32602);
  assert.deepEqual(h.runner.search('x', 0), []);
  assert.equal(h.runner.search('x', 1).length, 1);
  // The test config points at a claude binary that doesn't exist.
  const notices = h.runner.noticesForNewClient();
  assert.ok(notices.some((n) => n.level === 'error' && /claude CLI isn't at/.test(n.message)));
  // A restart that found a thread mid-turn says so to the next client.
  const h2 = h.restart();
  assert.ok(h2.runner.noticesForNewClient().some((n) => /mid-turn/.test(n.message)));
  h2.clock.advance(11 * MIN);
  assert.ok(!h2.runner.noticesForNewClient().some((n) => /mid-turn/.test(n.message)));
});
