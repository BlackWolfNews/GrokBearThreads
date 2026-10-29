import { test } from 'node:test';
import assert from 'node:assert/strict';
import { makeHarness, tick } from '../helpers/fakes.ts';
import { checkSummary } from '../helpers/protocol-check.ts';
import { RpcError } from '../../src/protocol.ts';
import { NO_WAKE_TIME } from '../../src/runner.ts';
import { hibernateNote, localWhen, readWakeAnswer, wakePrompt } from '../../src/wake-when.ts';
import type { GenerateParams, ModelResult } from '../../src/models/index.ts';

const DAY = 86_400_000;
const NOW = Date.parse('2026-10-29T06:00:00Z');

test('readWakeAnswer: a time, a topic, both, and what it refuses', () => {
  assert.deepEqual(readWakeAnswer('{"until":"2026-10-31T09:00:00+08:00","topic":null,"why":"Saturday morning"}', NOW), { until: '2026-10-31T01:00:00.000Z', why: 'Saturday morning' });
  assert.deepEqual(readWakeAnswer('```json\n{"until":null,"topic":"woodworking.","why":"A topic"}\n```', NOW), { topic: 'woodworking', why: 'A topic' });
  assert.deepEqual(readWakeAnswer('{"until":"2026-11-28T09:00:00+08:00","topic":"the shed","why":"x"}', NOW), { until: '2026-11-28T01:00:00.000Z', topic: 'the shed', why: 'x' });
  assert.match((readWakeAnswer('not json', NOW) as { error: string }).error, /wasn't JSON/);
  assert.match((readWakeAnswer('{"until":"2026-10-01T00:00:00Z","why":""}', NOW) as { error: string }).error, /already passed/);
  assert.match((readWakeAnswer('{"until":"2031-01-01T00:00:00Z"}', NOW) as { error: string }).error, /two years/);
  assert.equal((readWakeAnswer('{"until":null,"topic":"","why":"No idea what that means"}', NOW) as { error: string }).error, 'No idea what that means');
});

test('the prompt gives the local time, the thread and his words; the note says when', () => {
  const p = wakePrompt({ said: ' at the weekend ', now: NOW, timeZone: 'Australia/Perth', title: 'Workbench drawers', brief: '- Cut list done' });
  assert.match(p, /^Now: Thursday,? 29 October 2026,? (at )?2:00 pm \(Australia\/Perth\)/);
  assert.match(p, /The thread: "Workbench drawers"/);
  assert.match(p, /- Cut list done/);
  assert.match(p, /Mike wants it back: at the weekend$/);
  const sat = Date.parse('2026-10-31T01:00:00Z');
  assert.equal(localWhen(sat, 'Australia/Perth'), 'Saturday 31 October, 9 am');
  assert.equal(localWhen(sat + 30 * 60_000, 'Australia/Perth'), 'Saturday 31 October, 9:30 am');
  assert.equal(hibernateNote({ until: new Date(sat).toISOString(), why: '' }, 'at the weekend', 'Australia/Perth'), 'Hibernating until Saturday 31 October, 9 am. You said "at the weekend".');
  assert.equal(
    hibernateNote({ topic: 'woodworking', until: new Date(sat).toISOString(), why: '' }, 'next time I do woodworking, or Saturday', 'Australia/Perth'),
    'Hibernating until you next talk about woodworking, or Saturday 31 October, 9 am at the latest. You said "next time I do woodworking, or Saturday".',
  );
});

function setup(answer: (p: GenerateParams) => ModelResult<string> | Promise<ModelResult<string>>) {
  const asked: GenerateParams[] = [];
  // Titles ask the model too; only wake-when gets an answer.
  const generate = async (p: GenerateParams): Promise<ModelResult<string>> => {
    if (p.feature !== 'wake-when') return { ok: false, reason: 'off', message: 'off' };
    asked.push(p);
    return answer(p);
  };
  const h = makeHarness(undefined, {}, { models: { generate } });
  const { thread } = h.runner.create({ text: 'Plan the workbench drawers', accountId: 'claude-3' });
  const s = h.adapter.last;
  s.init();
  s.result();
  return { h, thread, asked, s };
}

const ok = (v: unknown): ModelResult<string> => ({ ok: true, value: JSON.stringify(v), model: 'opus' });

test('hibernateWhen: away at once, then until the time Opus gives, with a note', async () => {
  let release!: () => void;
  const gate = new Promise<void>((r) => (release = r));
  const { h, thread, asked, s } = setup(async () => {
    await gate;
    return ok({ until: new Date(h.clock.now() + 2 * DAY).toISOString(), topic: null, why: 'Saturday' });
  });
  const call = h.runner.hibernateWhen({ threadId: thread.id, said: 'at the weekend' });
  // Away before the model answers, saying it's being worked out.
  const away = h.runner.get(thread.id);
  assert.deepEqual(checkSummary(away), []);
  assert.equal(away.snoozedUntil, NO_WAKE_TIME);
  assert.deepEqual(away.wakeWhen, { said: 'at the weekend', pending: true });
  assert.deepEqual(h.runner.list().map((t) => t.id), []);
  assert.equal(s.ended, true);
  release();
  const res = await call;
  assert.equal(asked[0].strong, true);
  assert.equal(asked[0].feature, 'wake-when');
  assert.match(asked[0].prompt, /The thread: "Plan the workbench drawers"/);
  assert.match(asked[0].prompt, /How it started \(Mike\): Plan the workbench drawers/);
  assert.equal(res.until, new Date(h.clock.now() + 2 * DAY).toISOString());
  assert.equal(res.thread.snoozedUntil, res.until);
  assert.deepEqual(res.thread.wakeWhen, { said: 'at the weekend' });
  assert.deepEqual(checkSummary(res.thread), []);
  assert.match(h.events(thread.id).at(-1).text, /^Hibernating until .+\. You said "at the weekend"\.$/);
  // Comes back as any snooze does, and forgets the words.
  h.clock.advance(2 * DAY);
  const back = h.runner.get(thread.id);
  assert.equal(back.snoozedUntil, undefined);
  assert.equal(back.wakeWhen, undefined);
  assert.equal(back.needsYou, true);
});

test('hibernateWhen: a model that fails or says nothing usable puts it back, unread as it was', async () => {
  const { h, thread } = setup(() => ok({ until: null, topic: null, why: "That isn't a time" }));
  await assert.rejects(h.runner.hibernateWhen({ threadId: thread.id, said: 'banana' }), (e: RpcError) => /Couldn't work out when to wake it: That isn't a time/.test(e.message));
  const t = h.runner.get(thread.id);
  assert.equal(t.snoozedUntil, undefined);
  assert.equal(t.wakeWhen, undefined);
  assert.deepEqual(h.runner.list().map((x) => x.id), [thread.id]);
  await assert.rejects(h.runner.hibernateWhen({ threadId: thread.id, said: '  ' }), (e: RpcError) => e.code === -32602);
  const off = setup(() => ({ ok: false, reason: 'no-room', message: 'Every login in Claude is out of room.' }));
  await assert.rejects(off.h.runner.hibernateWhen({ threadId: off.thread.id, said: 'tomorrow' }), /out of room/);
  assert.equal(off.h.runner.get(off.thread.id).snoozedUntil, undefined);
});

test('hibernateWhen: a private folder sends his words alone', async () => {
  const { h, thread, asked } = setup((p) => (p.cwd ? { ok: false, reason: 'private', message: 'private' } : ok({ until: null, topic: 'woodworking', why: 'topic' })));
  const res = await h.runner.hibernateWhen({ threadId: thread.id, said: 'next time I talk about woodworking' });
  assert.equal(asked.length, 2);
  assert.doesNotMatch(asked[1].prompt, /workbench/);
  assert.deepEqual(res.thread.wakeWhen, { said: 'next time I talk about woodworking', topic: 'woodworking' });
  assert.equal(res.thread.snoozedUntil, NO_WAKE_TIME);
});

test('a topic waits for the librarian: waitingTopics lists it, wakeForTopic brings it back unread with where', async () => {
  const { h, thread } = setup(() => ok({ until: null, topic: 'woodworking', why: 'topic' }));
  await h.runner.hibernateWhen({ threadId: thread.id, said: 'next time I talk about woodworking' });
  assert.deepEqual(h.runner.waitingTopics(), [{ threadId: thread.id, title: 'Plan the workbench drawers', topic: 'woodworking' }]);
  // A month on it's still waiting.
  h.clock.advance(30 * DAY);
  assert.deepEqual(h.runner.list(['snoozed']).map((t) => t.id), [thread.id]);
  const other = h.runner.create({ text: 'Router table jig', accountId: 'claude-3' }).thread;
  assert.equal(h.runner.wakeForTopic(thread.id, thread.id), false);
  assert.equal(h.runner.wakeForTopic(thread.id, other.id), true);
  assert.equal(h.events(thread.id).at(-1).text, 'Woke up: you talked about woodworking in "Router table jig".');
  const t = h.runner.get(thread.id);
  assert.equal(t.snoozedUntil, undefined);
  assert.equal(t.needsYou, true);
  assert.deepEqual(h.runner.waitingTopics(), []);
  assert.equal(h.runner.wakeForTopic(thread.id, other.id), false);
});

test('a plain snooze clears the words, and a restart mid-answer brings the thread back', async () => {
  const { h, thread } = setup(() => ok({ until: null, topic: 'woodworking', why: 'topic' }));
  await h.runner.hibernateWhen({ threadId: thread.id, said: 'woodworking' });
  h.runner.update({ threadId: thread.id, snoozedUntil: new Date(h.clock.now() + DAY).toISOString() });
  assert.equal(h.runner.get(thread.id).wakeWhen, undefined);
  // Pending when the runner stops: it comes back on the next start.
  let release!: () => void;
  const gate = new Promise<void>((r) => (release = r));
  const p = setup(async () => (await gate, ok({ until: null, topic: 'x', why: '' })));
  const call = p.h.runner.hibernateWhen({ threadId: p.thread.id, said: 'later' });
  await tick();
  p.h.runner.flush();
  const h2 = p.h.restart();
  const t = h2.runner.get(p.thread.id);
  assert.equal(t.snoozedUntil, undefined);
  assert.equal(t.wakeWhen, undefined);
  release();
  await call.catch(() => undefined);
});
