import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mergeOlder, mergeTail } from './transcript-merge.ts';

const rows = (...seqs: number[]) => seqs.map((seq) => ({ seq }));
const seqs = (h: { rows: Map<number, unknown> }) => [...h.rows.keys()].sort((a, b) => a - b);

test('rows that scroll out of the tail stay, and older pages join on', () => {
  let { held } = mergeTail(undefined, { messages: rows(5, 6, 7), hasMore: true });
  assert.equal(held.hasMore, true);
  ({ held } = mergeTail(held, { messages: rows(6, 7, 8), hasMore: true }));
  assert.deepEqual(seqs(held), [5, 6, 7, 8]);
  held = mergeOlder(held, { messages: rows(3, 4), hasMore: false });
  assert.deepEqual(seqs(held), [3, 4, 5, 6, 7, 8]);
  // Having reached the start, a tail that's still got more above doesn't undo that.
  ({ held } = mergeTail(held, { messages: rows(7, 8, 9), hasMore: true }));
  assert.equal(held.hasMore, false);
});

test('a tail past everything held starts again, rather than leaving a hole', () => {
  const first = mergeTail(undefined, { messages: rows(5, 6), hasMore: true }).held;
  const { held, gap } = mergeTail(first, { messages: rows(20, 21), hasMore: true });
  assert.equal(gap, true);
  assert.deepEqual(seqs(held), [20, 21]);
  assert.equal(held.hasMore, true);
});

test('a tail with nothing above it is never a gap', () => {
  const first = mergeTail(undefined, { messages: rows(1), hasMore: false }).held;
  assert.equal(mergeTail(first, { messages: rows(9), hasMore: false }).gap, false);
});

test('an empty first answer does not hide what arrives after it', () => {
  const first = mergeTail(undefined, { messages: [], hasMore: false }).held;
  const { held, gap } = mergeTail(first, { messages: rows(71, 72), hasMore: true });
  assert.equal(gap, false);
  assert.equal(held.hasMore, true, 'the older ones can still be loaded');
});
