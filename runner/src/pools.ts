// Pools (docs/protocol.md, "Pools"): a named, ordered list of logins of any
// provider. A thread in a pool runs each turn on whichever of its logins
// has room, and moves when the one it's on runs dry. Everything here is
// pure, so the rules can be tested without a runner; runner.ts calls it.
import os from 'node:os';
import path from 'node:path';
import type { Account, Pool, Provider, UsageWindow } from './protocol.ts';
import { PROVIDERS } from './protocol.ts';
import { accountRoom, MIN_ROOM_PERCENT, resetTime } from './usage.ts';

// How long a wait lasts when no login in the pool says when it's back, and
// how long a login that hit its limit counts as blocked with no reset time.
export const UNKNOWN_WAIT_MS = 30 * 60_000;
// A wait ends a minute after the reset, so the provider has caught up.
export const WAIT_SLACK_MS = 60_000;

const PROVIDER_TITLES: Record<Provider, string> = { claude: 'Claude', codex: 'Codex' };

// The built-in list, worked out from the logins found: one pool per
// provider holding its logins that have no note, then one per noted login
// (claude-2's "Convex work only" is `convex`), titled from the note's first
// word. Providers in PROVIDERS order, each one's noted pools after it, so
// Mike's list is Claude, Convex, Codex.
export function defaultPools(accounts: Account[], notes: Record<string, string>, folders: Record<string, string[]>): Pool[] {
  const out: Pool[] = [];
  const noteOf = (a: Account): string | undefined => (notes[a.id] ?? a.note)?.trim() || undefined;
  for (const provider of PROVIDERS) {
    const mine = accounts.filter((a) => a.provider === provider);
    const plain = mine.filter((a) => !noteOf(a));
    if (plain.length) out.push(withFolders({ id: provider, title: PROVIDER_TITLES[provider], accountIds: plain.map((a) => a.id), builtIn: true }, plain, folders));
    for (const a of mine.filter((x) => noteOf(x))) {
      const word = noteOf(a)!.split(/\s+/)[0].replace(/[^\p{L}\p{N}_-]/gu, '');
      let id = word.toLowerCase();
      if (!id || out.some((p) => p.id === id) || (PROVIDERS as readonly string[]).includes(id)) id = a.id;
      out.push(withFolders({ id, title: word || a.title, accountIds: [a.id], builtIn: true }, [a], folders));
    }
  }
  return out;
}

function withFolders(pool: Pool, members: Account[], folders: Record<string, string[]>): Pool {
  const f = [...new Set(members.flatMap((a) => folders[a.id] ?? []))];
  return f.length ? { ...pool, folders: f } : pool;
}

// The pools in force: runner.json's `pools` when it has any, else the
// built-in ones. A runner.json entry of the wrong shape is skipped.
export function readPools(cfg: { pools?: unknown; accountNotes?: Record<string, string> }, accounts: Account[], folders: Record<string, string[]> = {}): Pool[] {
  const saved = Array.isArray(cfg.pools) ? cfg.pools.map(shapeOf).filter((p): p is Pool => !!p) : [];
  if (saved.length) return saved;
  return defaultPools(accounts, cfg.accountNotes ?? {}, folders);
}

// A pool as given, with only its known fields, or undefined when it isn't
// one at all.
function shapeOf(raw: unknown): Pool | undefined {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return undefined;
  const r = raw as Record<string, unknown>;
  if (typeof r.id !== 'string' || typeof r.title !== 'string' || !Array.isArray(r.accountIds)) return undefined;
  if (r.accountIds.some((x) => typeof x !== 'string')) return undefined;
  const pool: Pool = { id: r.id.trim(), title: r.title.trim(), accountIds: [...new Set(r.accountIds as string[])] };
  if (r.folders !== undefined) {
    if (!Array.isArray(r.folders) || r.folders.some((x) => typeof x !== 'string')) return undefined;
    const f = (r.folders as string[]).map((x) => x.trim()).filter(Boolean);
    if (f.length) pool.folders = f;
  }
  return pool;
}

// Checks a list for pools.save. The error says what's wrong, for -32602.
// An empty list is fine: it goes back to the built-in ones.
export function validatePools(raw: unknown, accounts: Account[]): { pools: Pool[] } | { error: string } {
  if (!Array.isArray(raw)) return { error: 'pools must be an array' };
  const pools: Pool[] = [];
  for (const [i, item] of raw.entries()) {
    const p = shapeOf(item);
    if (!p) return { error: `pools[${i}] needs id and title strings and accountIds, an array of strings (folders, if given, strings too)` };
    if (!p.id) return { error: `pools[${i}] has a blank id` };
    if (!p.title) return { error: `Pool ${p.id} has a blank title` };
    if (pools.some((x) => x.id === p.id)) return { error: `Two pools are called ${p.id}` };
    if (!p.accountIds.length) return { error: `Pool ${p.id} has no logins` };
    const unknown = p.accountIds.filter((id) => !accounts.some((a) => a.id === id));
    if (unknown.length) return { error: `Pool ${p.id} names ${unknown.join(', ')}, which ${unknown.length === 1 ? "isn't a login" : "aren't logins"} this runner knows` };
    pools.push(p);
  }
  return { pools };
}

// The pool a new thread in `cwd` starts on: the one whose folders hold it,
// the deepest folder winning (then the first pool). `~` is `home`.
export function poolForFolder(pools: Pool[], cwd: string, home: string = os.homedir()): Pool | undefined {
  if (!cwd.trim()) return undefined;
  const at = path.resolve(expand(cwd, home));
  let best: { pool: Pool; len: number } | undefined;
  for (const pool of pools) {
    for (const f of pool.folders ?? []) {
      const dir = path.resolve(expand(f, home));
      if (at !== dir && !at.startsWith(dir.endsWith(path.sep) ? dir : dir + path.sep)) continue;
      if (!best || dir.length > best.len) best = { pool, len: dir.length };
    }
  }
  return best?.pool;
}

function expand(p: string, home: string): string {
  if (p === '~') return home;
  if (p.startsWith('~/')) return path.join(home, p.slice(2));
  return p;
}

// A login a turn can start on: not blocked, and at or above the minimum
// room, or its usage isn't known.
export function loginOk(account: Account): boolean {
  if (account.usage?.blocked) return false;
  const room = accountRoom(account);
  return room === undefined || room >= MIN_ROOM_PERCENT;
}

// The providers a pool has logins of, in the order its accountIds first
// name them.
export function poolProviders(pool: Pool, accounts: Account[]): Provider[] {
  const out: Provider[] = [];
  for (const id of pool.accountIds) {
    const a = accounts.find((x) => x.id === id);
    if (a && !out.includes(a.provider)) out.push(a.provider);
  }
  return out;
}

export function poolAccounts(pool: Pool, accounts: Account[]): Account[] {
  return pool.accountIds.map((id) => accounts.find((a) => a.id === id)).filter((a): a is Account => !!a);
}

// Which of the pool's logins of `provider` to run on. `current` stays if
// it's OK, since every move costs a cold prompt cache. Otherwise the one
// with the most room at or above the minimum, then the first whose usage
// isn't known. `prefer` (a new thread's last-used login) wins a tie, and
// is taken when its usage isn't known, as pickAccount does: nothing says
// another has more room. undefined when none has room. `exclude` leaves
// logins out (the one that just ran dry).
export function pickInPool(pool: Pool, accounts: Account[], o: { provider: Provider; exclude?: string[]; current?: string; prefer?: string }): string | undefined {
  const members = poolAccounts(pool, accounts).filter((a) => a.provider === o.provider && !o.exclude?.includes(a.id));
  const current = members.find((a) => a.id === o.current);
  if (current && loginOk(current)) return current.id;
  const preferred = members.find((a) => a.id === o.prefer && !a.usage?.blocked);
  if (preferred && accountRoom(preferred) === undefined) return preferred.id;
  let best: { id: string; room: number } | undefined;
  for (const a of members) {
    const room = accountRoom(a);
    if (a.usage?.blocked || room === undefined || room < MIN_ROOM_PERCENT) continue;
    if (!best || room > best.room || (room === best.room && a.id === o.prefer)) best = { id: a.id, room };
  }
  if (best) return best.id;
  return members.find((a) => !a.usage?.blocked && accountRoom(a) === undefined)?.id;
}

export type NextLogin = { accountId: string; provider: Provider } | { waitUntil: string; accountId?: string };

// Where a thread goes when its login can't run the next turn: the pool
// login of its own provider with the most room, else the first other
// provider in pool order with a login with room (a cross-provider move),
// else a wait until the first of the pool's logins is back.
export function nextLogin(pool: Pool, accounts: Account[], thread: { accountId: string; provider: Provider }, now: number): NextLogin {
  const order = [thread.provider, ...poolProviders(pool, accounts).filter((p) => p !== thread.provider)];
  for (const provider of order) {
    const id = pickInPool(pool, accounts, { provider, exclude: [thread.accountId] });
    if (id) return { accountId: id, provider };
  }
  return roomWait(pool, accounts, now);
}

// When to look again with nothing in the pool to run on: the earliest time
// one of its logins that isn't OK is back, plus a minute; 30 minutes from
// now when none says.
export function roomWait(pool: Pool, accounts: Account[], now: number): { waitUntil: string; accountId?: string } {
  let first: { at: number; id: string } | undefined;
  for (const a of poolAccounts(pool, accounts)) {
    if (loginOk(a)) continue;
    const at = backAt(a, now);
    if (at !== undefined && (!first || at < first.at)) first = { at, id: a.id };
  }
  if (!first) return { waitUntil: new Date(now + UNKNOWN_WAIT_MS).toISOString() };
  return { waitUntil: new Date(first.at + WAIT_SLACK_MS).toISOString(), accountId: first.id };
}

function mainWindows(a: Account): UsageWindow[] {
  return (a.usage?.windows ?? []).filter((w) => w.kind === 'five_hour' || w.kind === 'weekly');
}

// The window that stops a login: one at its limit, else the tightest.
function limitWindow(a: Account): UsageWindow | undefined {
  const main = mainWindows(a);
  const out = main.filter((w) => w.remainingPercent < 1);
  if (out.length) return out.sort((x, y) => Date.parse(y.resetsAt ?? '') - Date.parse(x.resetsAt ?? ''))[0];
  return [...main].sort((x, y) => x.remainingPercent - y.remainingPercent)[0];
}

// When a login that isn't OK has room again: when the windows holding it
// back have all reset. Blocked with no window at its limit: the tightest
// window's reset. undefined when no reset time is known.
export function backAt(a: Account, now: number): number | undefined {
  const main = mainWindows(a);
  let holding = main.filter((w) => w.remainingPercent < (a.usage?.blocked ? 1 : MIN_ROOM_PERCENT));
  if (!holding.length && a.usage?.blocked) holding = [limitWindow(a)].filter((w): w is UsageWindow => !!w);
  const times = holding.map((w) => Date.parse(w.resetsAt ?? '')).filter((t) => Number.isFinite(t) && t > now);
  return times.length && times.length === holding.length ? Math.max(...times) : undefined;
}

// When a login that just hit its limit counts as blocked until: the window
// at its limit (or the tightest) resetting, else UNKNOWN_WAIT_MS from now.
export function blockedUntil(a: Account, now: number): number {
  const w = limitWindow(a);
  const t = w?.resetsAt ? Date.parse(w.resetsAt) : NaN;
  return Number.isFinite(t) && t > now ? t : now + UNKNOWN_WAIT_MS;
}

// Why a login can't run the next turn, for the move note: "hit its 5-hour
// limit, back at 6:10 pm", or "is down to 6% of its weekly limit, which
// resets Thu 1 pm".
export function limitWhy(a: Account, now: number, hit = false): string {
  const w = limitWindow(a);
  const name = w ? (w.kind === 'five_hour' ? '5-hour' : 'weekly') : 'usage';
  const at = w?.resetsAt && Date.parse(w.resetsAt) > now ? resetTime(w.resetsAt, now) : undefined;
  if (hit || a.usage?.blocked || !w || w.remainingPercent < 1) return `hit its ${name} limit${at ? `, back at ${at}` : ''}`;
  return `is down to ${Math.round(w.remainingPercent)}% of its ${name} limit${at ? `, which resets ${at}` : ''}`;
}

// One login's room in a word, for list_accounts and tb pools: "61%",
// "out until 5 am", "room unknown".
export function roomWord(a: Account, now: number): string {
  if (!loginOk(a)) {
    const at = backAt(a, now);
    const room = accountRoom(a);
    const head = a.usage?.blocked || room === undefined ? 'out' : `${Math.round(room)}%, resting`;
    return at ? `${head} until ${resetTime(new Date(at).toISOString(), now)}` : head;
  }
  const room = accountRoom(a);
  return room === undefined ? 'room unknown' : `${Math.round(room)}%`;
}

// "claude-main 61%, claude-1 16%, claude-3 out until 5 am".
export function poolLine(pool: Pool, accounts: Account[], now: number): string {
  return pool.accountIds.map((id) => {
    const a = accounts.find((x) => x.id === id);
    return a ? `${id} ${roomWord(a, now)}` : `${id} (not found)`;
  }).join(', ');
}

// A pool by id, or by title ignoring case, for tools that take a name.
export function findPool(pools: Pool[], q: string): Pool | undefined {
  const t = q.trim().toLowerCase();
  return pools.find((p) => p.id === q.trim()) ?? pools.find((p) => p.id.toLowerCase() === t || p.title.toLowerCase() === t);
}
