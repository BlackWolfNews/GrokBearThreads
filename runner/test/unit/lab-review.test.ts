// Review by another lab (experiment labReview, runner/lab-review.ts): a
// turn that changed code and finished starts a review thread on the other
// provider, waits for it, and wakes with its findings.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { FakeAccounts, makeHarness, tmpDir, withCodex, ACCOUNTS } from '../helpers/fakes.ts';
import { LAB_REVIEW_ROUNDS } from '../../src/runner/lab-review.ts';
import { EXPERIMENTS, experimentOn } from '../../src/experiments.ts';

const END_TURN = 'mcp__threadbear__end_turn';

function setup(o: { on?: boolean; accounts?: typeof ACCOUNTS; cfg?: Record<string, unknown> } = {}) {
  const home = tmpDir();
  if (o.on !== false) fs.writeFileSync(path.join(home, 'runner.json'), JSON.stringify({ experiments: { labReview: true } }));
  const h = makeHarness(home, o.cfg ?? {}, { accounts: new FakeAccounts(o.accounts ?? withCodex()) });
  return h;
}

// Ten lines of code changed in one file, as the CLI reports an edit.
function codeDiff(file = 'src/app.ts', lines = 10) {
  return { type: 'edit.diff', itemId: `d-${file}`, path: file, hunks: [{ oldStart: 1, oldLines: lines / 2, newStart: 1, newLines: lines / 2, lines: [...Array(lines / 2)].flatMap((_, i) => [`-old ${i}`, `+new ${i}`]) }] };
}

// A turn in a thread: Mike's message (or none), the edits, end_turn and a reply.
function turn(h: ReturnType<typeof setup>, id: string, o: { text?: string; diffs?: object[]; reply?: string; input?: Record<string, unknown>; session?: any } = {}) {
  if (o.text !== undefined) h.runner.send(id, o.text);
  const s = o.session ?? [...h.adapter.sessions, ...h.codex.sessions].filter((x) => x.opts.threadId === id).at(-1)!;
  for (const d of o.diffs ?? []) s.out({ kind: 'event', event: d });
  s.out({ kind: 'event', event: { type: 'tool.call', itemId: `e${Math.random()}`, name: END_TURN, kind: 'mcp', title: 'end_turn', input: o.input ?? { needs: 'nothing' } } });
  s.text(`m${Math.random()}`, o.reply ?? 'Fixed it.');
  s.result();
}

function start(h: ReturnType<typeof setup>, text = 'Fix the login bug') {
  const { thread } = h.runner.create({ text, accountId: 'claude-main' });
  return thread.id;
}

test('labReview: off by default, so a code change finishes as before', () => {
  assert.equal(EXPERIMENTS.find((x) => x.id === 'labReview')?.on, false);
  const h = setup({ on: false });
  assert.equal(experimentOn(h.home, 'labReview'), false);
  const id = start(h);
  turn(h, id, { diffs: [codeDiff()] });
  assert.equal(h.runner.get(id).snoozedUntil, undefined);
  assert.equal(h.codex.sessions.length, 0);
});

test('labReview: a Claude code change is reviewed on Codex, then the thread wakes with the findings', () => {
  const h = setup();
  const id = start(h);
  turn(h, id, { diffs: [codeDiff()], reply: 'Fixed the login bug.' });
  const t = h.runner.get(id);
  assert.ok(t.snoozedUntil, 'it waits on the review');
  assert.equal(t.waitingOn?.length, 1);
  const reviewId = t.waitingOn![0].threadId;
  const review = h.runner.get(reviewId);
  assert.equal(review.provider, 'codex');
  assert.equal(review.accountId, 'codex-main');
  assert.equal(review.cwd, t.cwd);
  assert.equal(h.runner.threads.get(reviewId)!.rec.reviewOf, id);
  const brief = h.events(reviewId).find((e) => e.type === 'user.message').text as string;
  assert.match(brief, /Fix the login bug/);
  assert.match(brief, /Fixed the login bug\./);
  assert.match(brief, /\+new 0/);
  assert.match(brief, /Don't edit/);
  assert.ok(h.events(id).some((e) => e.type === 'system.note' && /^Another lab is reviewing this change/.test(e.text)));

  // The review finishes: the thread wakes with its findings, and the
  // review thread is put away.
  const rs = h.codex.sessions.find((s) => s.opts.threadId === reviewId)!;
  rs.init();
  turn(h, reviewId, { session: rs, reply: 'src/app.ts:3 drops the session on refresh.' });
  const woke = h.runner.get(id);
  assert.equal(woke.snoozedUntil, undefined);
  const msg = h.events(id).filter((e) => e.type === 'user.message').at(-1);
  assert.equal(msg.origin, 'runner');
  assert.match(msg.text, /Codex reviewed the change/);
  assert.match(msg.text, /drops the session on refresh/);
  assert.match(msg.text, /fix what holds up/);
  const after = h.runner.get(reviewId);
  assert.ok(after.archivedAt);
  assert.equal(after.archivedBy, 'threadbear');
});

test('labReview: docs-only or tiny changes, and turns that need Mike, are not reviewed', () => {
  const h = setup();
  const id = start(h);
  turn(h, id, { diffs: [codeDiff('README.md', 40)] });
  assert.equal(h.runner.get(id).snoozedUntil, undefined);
  turn(h, id, { text: 'and the tiny one', diffs: [codeDiff('src/a.ts', 2)] });
  assert.equal(h.runner.get(id).snoozedUntil, undefined);
  turn(h, id, { text: 'one more', diffs: [codeDiff()], input: { needs: 'you', asks: [{ question: 'Deploy it?' }] } });
  assert.equal(h.runner.get(id).snoozedUntil, undefined);
  assert.equal(h.codex.sessions.length, 0);
});

test('labReview: at most LAB_REVIEW_ROUNDS reviews until Mike writes again', () => {
  const h = setup();
  const id = start(h);
  const review = () => {
    const w = h.runner.get(id).waitingOn?.[0];
    if (!w) return false;
    const rs = h.codex.sessions.find((s) => s.opts.threadId === w.threadId)!;
    rs.init();
    turn(h, w.threadId, { session: rs, reply: 'One more issue.' });
    return true;
  };
  turn(h, id, { diffs: [codeDiff()] });
  let rounds = 0;
  while (review()) {
    rounds++;
    // The fix turn the findings started.
    turn(h, id, { diffs: [codeDiff()] });
    assert.ok(rounds <= LAB_REVIEW_ROUNDS);
  }
  assert.equal(rounds, LAB_REVIEW_ROUNDS);
  // A new ask from Mike can be reviewed again.
  turn(h, id, { text: 'Now the logout bug', diffs: [codeDiff()] });
  assert.ok(h.runner.get(id).waitingOn?.length);
});

test('labReview: with no other lab, a fresh session of the same provider reviews, and says it is not independent', () => {
  const h = setup({ accounts: ACCOUNTS });
  const id = start(h);
  turn(h, id, { diffs: [codeDiff()] });
  const reviewId = h.runner.get(id).waitingOn![0].threadId;
  assert.equal(h.runner.get(reviewId).provider, 'claude');
  assert.ok(h.events(id).some((e) => e.type === 'system.note' && /isn't another lab/.test(e.text)));
});

test("labReview: a folder kept for a pool is reviewed only on that pool's logins", () => {
  const kept = tmpDir('tb-kept-');
  const h = setup({ cfg: { pools: [
    { id: 'claude', title: 'Claude', accountIds: ['claude-main'] },
    { id: 'convex', title: 'Convex', accountIds: ['claude-3'], folders: [kept] },
    { id: 'codex', title: 'Codex', accountIds: ['codex-main'] },
  ] } });
  const { thread } = h.runner.create({ text: 'Fix it', cwd: kept, accountId: 'claude-3' });
  turn(h, thread.id, { diffs: [codeDiff()] });
  const reviewId = h.runner.get(thread.id).waitingOn![0].threadId;
  assert.equal(h.runner.get(reviewId).accountId, 'claude-3');
  // And the kept login never reviews a thread outside its folder.
  const other = start(h);
  turn(h, other, { diffs: [codeDiff()] });
  assert.equal(h.runner.get(h.runner.get(other).waitingOn![0].threadId).accountId, 'codex-main');
});

test('labReview: a review thread never gets a review of its own', () => {
  const h = setup();
  const id = start(h);
  turn(h, id, { diffs: [codeDiff()] });
  const reviewId = h.runner.get(id).waitingOn![0].threadId;
  const rs = h.codex.sessions.find((s) => s.opts.threadId === reviewId)!;
  rs.init();
  turn(h, reviewId, { session: rs, diffs: [codeDiff('src/oops.ts')], reply: 'Found one, and fixed it myself.' });
  assert.equal(h.runner.get(reviewId).waitingOn, undefined);
  assert.match(h.events(id).filter((e) => e.type === 'user.message').at(-1).text, /asked not to edit files but changed oops\.ts/);
});
