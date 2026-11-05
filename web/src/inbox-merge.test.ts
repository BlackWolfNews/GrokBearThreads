import { test } from 'node:test';
import assert from 'node:assert/strict';
import { CHANGES_MARGIN_MS, firstSince, mergeChanges } from './inbox-merge.ts';

const row = (threadId: string, lastActivityMs: number, view = 'inbox', title = threadId) => ({ threadId, lastActivityMs, view, title });
const stamped = (r: ReturnType<typeof row>, updatedMs: number) => ({ ...r, updatedMs });

test('a changed row replaces the old one, newest first, without its stamp', () => {
  const { rows } = mergeChanges([row('a', 2), row('b', 1)], 0, { rows: [stamped(row('b', 3, 'inbox', 'new'), 100)], gone: [] });
  assert.deepEqual(rows.map((r) => r.threadId), ['b', 'a']);
  assert.equal(rows[0]!.title, 'new');
  assert.equal('updatedMs' in rows[0]!, false);
});

test('a row moved out of the inbox, or gone, leaves it', () => {
  const { rows } = mergeChanges([row('a', 2), row('b', 1), row('c', 0)], 0, { rows: [stamped(row('a', 2, 'den'), 100)], gone: ['b'] });
  assert.deepEqual(rows.map((r) => r.threadId), ['c']);
});

test('a row coming back to the inbox joins it', () => {
  const { rows } = mergeChanges([], 0, { rows: [stamped(row('a', 2), 100)], gone: [] });
  assert.deepEqual(rows.map((r) => r.threadId), ['a']);
});

test('it asks from a little before the newest heard, and stays put with nothing newer', () => {
  const since = firstSince(10_000);
  const a = mergeChanges([], since, { rows: [stamped(row('a', 2), 20_000)], gone: [] });
  assert.equal(a.since, 20_000 - CHANGES_MARGIN_MS);
  const b = mergeChanges(a.rows, a.since, { rows: [stamped(row('a', 2), 20_000)], gone: [] });
  assert.equal(b.since, a.since);
  const c = mergeChanges(b.rows, b.since, { rows: [], gone: [] });
  assert.equal(c.since, a.since);
});
