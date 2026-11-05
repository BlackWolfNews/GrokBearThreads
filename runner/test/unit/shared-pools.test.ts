// Pools shared between runners (docs/protocol.md, "Pools", "Shared between
// runners"): the backend's list names logins by provider and email, and
// each runner turns it into its own pools, and back again on pools.save.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { Account, Pool } from '../../src/protocol.ts';
import { fromShared, memberOf, toShared, type SharedPool } from '../../src/pools.ts';

const login = (id: string, email: string | undefined, provider: 'claude' | 'codex' = 'claude'): Account => ({
  id, provider, title: email ?? id, configDir: `/tmp/${id}`, ...(email ? { email } : {}),
});

// Mike's Mac (runner m5) and the Hetzner box (runner hz), whose
// claude-main is a different login from the Mac's.
const M5 = [login('claude-main', 'mike@cannstudios.com'), login('claude-1', 'Mike.Cann@gmail.com'), login('claude-2', 'mike.cann@convex.dev'), login('claude-3', 'mike@gangbusters.io'), login('codex-main', 'mike.cann@gmail.com', 'codex')];
const HZ = [login('claude-main', 'mike.cann@gmail.com'), login('codex-main', 'mike.cann@gmail.com', 'codex')];

const MAC_POOLS: Pool[] = [
  { id: 'claude', title: 'Claude', accountIds: ['claude-main', 'claude-1', 'claude-3'] },
  { id: 'convex', title: 'ConvexClaude', accountIds: ['claude-2'], folders: ['~/dev/convex'] },
  { id: 'codex', title: 'Codex', accountIds: ['codex-main'] },
];

test('memberOf: a login by provider and lower-case email, or by runner and id with none', () => {
  assert.deepEqual(memberOf(M5[1]!, 'm5'), { provider: 'claude', email: 'mike.cann@gmail.com' });
  assert.deepEqual(memberOf(login('claude-9', undefined), 'm5'), { provider: 'claude', runnerId: 'm5', accountId: 'claude-9' });
});

test("the Mac's pools go up by email and come back as they were", () => {
  const shared = toShared(MAC_POOLS, [], M5, 'm5');
  assert.deepEqual(shared[0]!.members, [
    { provider: 'claude', email: 'mike@cannstudios.com' },
    { provider: 'claude', email: 'mike.cann@gmail.com' },
    { provider: 'claude', email: 'mike@gangbusters.io' },
  ]);
  assert.deepEqual(shared[1]!.folders, ['~/dev/convex']);
  assert.deepEqual(fromShared(shared, M5, 'm5'), MAC_POOLS);
});

test('on another runner each pool is the logins it has, and a pool with none is left out', () => {
  const shared = toShared(MAC_POOLS, [], M5, 'm5');
  assert.deepEqual(fromShared(shared, HZ, 'hz'), [
    { id: 'claude', title: 'Claude', accountIds: ['claude-main'] },
    { id: 'codex', title: 'Codex', accountIds: ['codex-main'] },
  ]);
});

test('a save on a runner that sees less keeps what it cannot see', () => {
  const before = toShared(MAC_POOLS, [], M5, 'm5');
  // The box renames Claude and changes nothing else it can see.
  const seen = fromShared(before, HZ, 'hz');
  seen[0]!.title = 'Claude subs';
  const after = toShared(seen, before, HZ, 'hz');
  assert.equal(after[0]!.title, 'Claude subs');
  assert.deepEqual(after[0]!.members, before[0]!.members, "the Mac's cannstudios and gangbusters stay, in their places");
  assert.deepEqual(after.map((p) => p.id), ['claude', 'codex', 'convex'], 'the convex pool it never saw is kept, after its own');
  assert.deepEqual(after[2], before[1]);
});

test('a login taken out on one runner goes; one added joins after the kept ones', () => {
  const before = toShared(MAC_POOLS, [], M5, 'm5');
  const seen = fromShared(before, M5, 'm5');
  seen[0]!.accountIds = ['claude-1', 'claude-3'];
  assert.deepEqual(toShared(seen, before, M5, 'm5')[0]!.members.map((m) => m.email), ['mike.cann@gmail.com', 'mike@gangbusters.io']);
  // The box adds a Codex login to Claude: it joins the end.
  const box = fromShared(before, HZ, 'hz');
  box[0]!.accountIds = ['claude-main', 'codex-main'];
  const after = toShared(box, before, HZ, 'hz');
  assert.deepEqual(after[0]!.members.map((m) => `${m.provider}:${m.email}`), ['claude:mike@cannstudios.com', 'claude:mike.cann@gmail.com', 'claude:mike@gangbusters.io', 'codex:mike.cann@gmail.com']);
});

test('a pool deleted where it was seen goes; a login with no email only counts on its own runner', () => {
  const before = toShared(MAC_POOLS, [], M5, 'm5');
  const seen = fromShared(before, HZ, 'hz').filter((p) => p.id !== 'codex');
  assert.deepEqual(toShared(seen, before, HZ, 'hz').map((p) => p.id), ['claude', 'convex']);

  const odd = login('claude-9', undefined);
  const shared: SharedPool[] = toShared([{ id: 'x', title: 'X', accountIds: ['claude-9'] }], [], [odd], 'm5');
  assert.deepEqual(fromShared(shared, [odd], 'm5')[0]!.accountIds, ['claude-9']);
  assert.deepEqual(fromShared(shared, [odd], 'hz'), [], 'claude-9 on another runner is some other login');
});
