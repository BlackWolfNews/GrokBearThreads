// What a librarian look can do to the Pocket (pocketChanges in librarian.ts):
// the rules that keep a small model from filling or emptying the deck.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { POCKET_ADDS_PER_DAY, pocketChanges } from '../../src/librarian.ts';

const ctx = { threadId: 't1', cards: [], seen: '', addsToday: 0, addedBefore: false };
const mine = { title: 'Post to Corby', text: 'Long Croft Road', threadId: 't1', updatedAt: 'x' };
const theirs = { title: 'Europe trip', text: 'EXBEEI', threadId: 't2', updatedAt: 'x' };
const noThread = { title: 'Wifi', text: 'hunter2', updatedAt: 'x' };
const card = { title: 'Post office', text: 'Take the parcel' };

test('adds a card when the thread has none', () => {
  assert.deepEqual(pocketChanges({ save: [{ ...card, place: 'post office' }] }, ctx).save, [{ ...card, place: 'post office' }]);
});

test('a null or odd answer changes nothing', () => {
  for (const raw of [null, undefined, 'x', 3, { save: 'x', remove: 4 }, { save: [null, {}, { title: 'x' }] }]) {
    assert.deepEqual(pocketChanges(raw, ctx), { save: [], remove: [] });
  }
});

test('adds only one, only if the thread has no card and never had one from the librarian, and within the daily cap', () => {
  const two = { save: [card, { title: 'Second', text: 'More' }] };
  assert.equal(pocketChanges(two, ctx).save.length, 1);
  assert.equal(pocketChanges({ save: [card] }, { ...ctx, cards: [mine] }).save.length, 0);
  assert.equal(pocketChanges({ save: [card] }, { ...ctx, addedBefore: true }).save.length, 0);
  assert.equal(pocketChanges({ save: [card] }, { ...ctx, addsToday: POCKET_ADDS_PER_DAY }).save.length, 0);
});

test("never touches another thread's card or one with no thread", () => {
  const cards = [theirs, noThread];
  const a = pocketChanges({ save: [{ title: 'europe TRIP', text: 'changed' }, { title: 'Wifi', text: 'changed' }], remove: ['Europe trip', 'Wifi'] }, { ...ctx, cards });
  assert.deepEqual(a, { save: [], remove: [] });
});

test("updates and removes this thread's own card, by any casing, and keeps its place", () => {
  const cards = [{ ...mine, place: 'post office' }];
  assert.deepEqual(pocketChanges({ save: [{ title: 'post to corby', text: 'New' }] }, { ...ctx, cards }).save, [{ title: 'post to corby', text: 'New', place: 'post office' }]);
  assert.deepEqual(pocketChanges({ remove: ['POST TO CORBY'] }, { ...ctx, cards }).remove, ['Post to Corby']);
});

test('saving a card unchanged is nothing, and saving beats removing the same card', () => {
  assert.deepEqual(pocketChanges({ save: [{ title: mine.title, text: mine.text }] }, { ...ctx, cards: [mine] }).save, []);
  const both = pocketChanges({ save: [{ title: mine.title, text: 'New' }], remove: [mine.title] }, { ...ctx, cards: [mine] });
  assert.equal(both.remove.length, 0);
});

test('an address or code the look was not shown is refused', () => {
  const madeUp = { title: 'Post', text: 'HM Passport Office\nPEX 546 040 0327\nNN18 8UA' };
  assert.equal(pocketChanges({ save: [madeUp] }, { ...ctx, seen: 'going to the post office' }).save.length, 0);
  assert.equal(pocketChanges({ save: [madeUp] }, { ...ctx, seen: 'Address: PEX 546 040 0327, NN18 8UA.' }).save.length, 1);
  assert.equal(pocketChanges({ save: [{ title: 'Code', text: 'Booking EXBEEI.' }] }, { ...ctx, seen: 'nothing' }).save.length, 0);
});

test('a title or text too long for the tool is refused', () => {
  assert.equal(pocketChanges({ save: [{ title: 'x'.repeat(61), text: 'y' }] }, ctx).save.length, 0);
  assert.equal(pocketChanges({ save: [{ title: 'x', text: 'y'.repeat(2001) }] }, ctx).save.length, 0);
});
