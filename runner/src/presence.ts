// Whether Mike is at this Mac: the Mac app is connected and he's used the
// keyboard or mouse in the last AT_MAC_IDLE_MS. The phone only buzzes while
// he isn't (docs/convex-backend.md, "Notifications and presence"), so a
// thread needing him while he's at his desk shows on the Mac alone, and
// reaches his phone if he walks away without seeing to it.
import { spawnSync } from 'node:child_process';

export const AT_MAC_IDLE_MS = 2 * 60_000;

// Time since the last keyboard or mouse event, from IOKit's HIDIdleTime
// (nanoseconds). Undefined if it can't be read.
export function hidIdleMs(): number | undefined {
  const r = spawnSync('/usr/sbin/ioreg', ['-c', 'IOHIDSystem', '-d', '4', '-r', '-k', 'HIDIdleTime'], { encoding: 'utf8', timeout: 2000 });
  const ns = r.stdout?.match(/"HIDIdleTime" = (\d+)/)?.[1];
  return ns === undefined ? undefined : Number(ns) / 1_000_000;
}

export function isAtMac(appConnected: boolean, idleMs: number | undefined): boolean {
  return appConnected && idleMs !== undefined && idleMs < AT_MAC_IDLE_MS;
}
