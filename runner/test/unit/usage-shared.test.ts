// Readings other runners took of the same login (docs/protocol.md,
// "Accounts", "Shared readings"): a subscription is one limit wherever it's
// signed in, so the newest reading from any machine counts, window by
// window, as with Token Stats and the runner's own turns.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import type { AccountUsage } from '../../src/protocol.ts';
import { UsageStore } from '../../src/usage.ts';
import { FakeClock } from '../../src/clock.ts';
import { nullLogger } from '../../src/log.ts';
import { tmpDir } from '../helpers/fakes.ts';

const T0 = Date.parse('2026-11-05T05:00:00.000Z');
const iso = (mins: number) => new Date(T0 + mins * 60_000).toISOString();

function store() {
  const dir = tmpDir();
  const clock = new FakeClock(T0);
  const usage = new UsageStore({ limitsFile: path.join(dir, 'none', 'limits.json'), dataDir: dir, clock, log: nullLogger });
  return { usage, clock };
}
const GMAIL = { id: 'claude-main', provider: 'claude' as const, configDir: '/tmp/x', email: 'mike.cann@gmail.com' };
const weekly = (u: AccountUsage | undefined) => u?.windows.find((w) => w.kind === 'weekly')?.remainingPercent;
const reading = (mins: number, week: number, extra: Partial<AccountUsage> = {}): AccountUsage => ({
  windows: [{ kind: 'weekly', title: 'Weekly', remainingPercent: week, resetsAt: iso(3 * 24 * 60) }], readAt: iso(mins), source: 'tokenStats', ...extra,
});

test("the Mac's newer reading of the same login wins over the server's old one", () => {
  const { usage, clock } = store();
  // The server's own turn, an hour ago: 97% of the week left.
  usage.record('claude-main', { windows: [{ kind: 'weekly', title: 'Weekly', remainingPercent: 97, resetsAt: iso(3 * 24 * 60) }] });
  clock.advance(60 * 60_000);
  let heard: string[] = [];
  usage.onChange((ids) => (heard = ids));
  usage.usageFor(GMAIL);
  usage.setShared([{ runnerId: 'm5', provider: 'claude', email: 'Mike.Cann@gmail.com', usage: reading(55, 32) }]);
  const u = usage.usageFor(GMAIL);
  assert.equal(weekly(u), 32);
  assert.equal(u?.source, 'shared');
  assert.deepEqual(heard, ['claude-main'], 'clients hear');
  // The server's own next turn is newer again.
  clock.advance(60_000);
  usage.record('claude-main', { windows: [{ kind: 'weekly', title: 'Weekly', remainingPercent: 30, resetsAt: iso(3 * 24 * 60) }] });
  assert.equal(weekly(usage.usageFor(GMAIL)), 30);
});

test('an older reading from elsewhere, another login, or a stale one changes nothing', () => {
  const { usage, clock } = store();
  clock.advance(60 * 60_000);
  usage.record('claude-main', { windows: [{ kind: 'weekly', title: 'Weekly', remainingPercent: 50, resetsAt: iso(3 * 24 * 60) }] });
  usage.setShared([
    { runnerId: 'm5', provider: 'claude', email: 'mike.cann@gmail.com', usage: reading(10, 5) },
    { runnerId: 'm5', provider: 'claude', email: 'mike@gangbusters.io', usage: reading(70, 1) },
    { runnerId: 'm5', provider: 'codex', email: 'mike.cann@gmail.com', usage: reading(70, 1) },
    { runnerId: 'bruce', provider: 'claude', email: 'mike.cann@gmail.com', usage: reading(70, 2, { stale: true }) },
  ]);
  const u = usage.usageFor(GMAIL);
  assert.equal(weekly(u), 50);
  assert.equal(u?.source, 'live');
});

test('a login another machine found at its limit counts as blocked here until it resets', () => {
  const { usage, clock } = store();
  usage.usageFor(GMAIL);
  const atLimit: AccountUsage = { windows: [{ kind: 'weekly', title: 'Weekly', remainingPercent: 0, resetsAt: iso(120) }], readAt: iso(5), source: 'live', blocked: true };
  clock.advance(10 * 60_000);
  usage.setShared([{ runnerId: 'm5', provider: 'claude', email: 'mike.cann@gmail.com', usage: atLimit }]);
  assert.equal(usage.usageFor(GMAIL)?.blocked, true);
  clock.advance(121 * 60_000);
  assert.notEqual(usage.usageFor(GMAIL)?.blocked, true, 'its reset has passed');
});

test('a login with no email known takes nothing from elsewhere', () => {
  const { usage } = store();
  const noEmail = { ...GMAIL, email: undefined };
  usage.setShared([{ runnerId: 'm5', provider: 'claude', email: 'mike.cann@gmail.com', usage: reading(0, 10) }]);
  assert.equal(usage.usageFor(noEmail), undefined);
});
