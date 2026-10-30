// The tour's sample threads (docs/protocol.md, threads.samples): made up,
// finished exchanges with no CLI, there for someone new to hibernate,
// archive and look round, and all removed when the tour ends.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { RpcError } from '../../src/protocol.ts';
import fs from 'node:fs';
import path from 'node:path';
import { WELCOME_PATCH } from '../../src/samples.ts';
import { makeHarness, tick } from '../helpers/fakes.ts';

test('samples are finished threads with no CLI, the first needing you, in a folder with the example patch', async () => {
  const h = makeHarness();
  const folder = path.join(h.cfg.home, 'Welcome');
  h.runner.samples({ cwd: folder });
  assert.equal(fs.readFileSync(path.join(folder, '.threadbear/patches/welcome.ts'), 'utf8'), WELCOME_PATCH);
  h.runner.samples({ cwd: folder, remove: true });
  const { threads } = h.runner.samples({ cwd: h.cfg.defaults.cwd });
  await tick();
  assert.equal(h.adapter.sessions.length, 0, 'no turn runs');
  assert.deepEqual(threads.map((t) => t.title), ['Fix the flaky login test', 'Plan the weekend', 'Draft the release notes']);
  assert.ok(threads.every((t) => t.sample && t.status === 'idle'));
  const [flaky, weekend, notes] = threads.map((t) => h.runner.get(t.id));
  assert.equal(flaky.needsYou, true);
  assert.equal(flaky.asks?.[0]?.action, 'Should I make the other form tests wait the same way?');
  assert.equal(weekend.needsYou, false);
  assert.ok(weekend.lastSeenSeq < weekend.lastSeq, 'left unread, for the blue dot');
  assert.equal(notes.lastSeenSeq, notes.lastSeq);
  assert.deepEqual(h.events(flaky.id).map((e) => e.type), ['user.message', 'turn.started', 'assistant.text', 'turn.completed']);
  // Newest first in the list, as they're made oldest first.
  assert.ok(Date.parse(flaky.createdAt) >= Date.parse(notes.createdAt));
});

test('asking again gives the same samples; remove deletes them, archived ones too', () => {
  const h = makeHarness();
  const first = h.runner.samples({ cwd: h.cfg.defaults.cwd }).threads.map((t) => t.id);
  assert.deepEqual(h.runner.samples({ cwd: h.cfg.defaults.cwd }).threads.map((t) => t.id), first);
  h.runner.update({ threadId: first[2], archived: true });
  const real = h.runner.create({ text: 'A real one', accountId: 'claude-3' }).thread.id;
  assert.deepEqual(h.runner.samples({ cwd: h.cfg.defaults.cwd, remove: true }).threads, []);
  const left = h.runner.list(['inbox', 'snoozed', 'archived']).map((t) => t.id);
  assert.deepEqual(left, [real]);
});

test('nothing can be sent to a sample', () => {
  const h = makeHarness();
  const [sample] = h.runner.samples({ cwd: h.cfg.defaults.cwd }).threads;
  assert.throws(() => h.runner.send(sample.id, 'Hello'), (e: unknown) => e instanceof RpcError && /sample threads/.test(e.message));
  assert.equal(h.adapter.sessions.length, 0);
});
