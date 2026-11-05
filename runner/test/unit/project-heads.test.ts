// The list of projects from small rows, and two reads that no longer take in
// what the caller doesn't need (convex/projectHeads.ts, phone.ts, sync.ts), run
// against the in-memory backend. Nothing here can measure bytes: what these
// tests pin is which rows each function touches and writes.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { call, load, memoryBackend } from '../helpers/convex-memory.ts';
import { SHARED_USAGE_OTHERS_API_VERSION, sharedUsageArgs } from '../../src/sync.ts';

const OWNER = 'owner-key';
const BRUCE_KEY = 'tbr_bruce';
const M5 = 'm5runner0001';
const BRUCE = 'cb921b2447ea';
const TOKEN = 'tb_phone';

const { sha256 } = load('lib') as { sha256: (s: string) => Promise<string> };
const sync = load('sync');
const phone = load('phone');

async function setup() {
  process.env.RUNNER_KEY = OWNER;
  delete process.env.RUNNER_KEY_NEXT;
  const b = memoryBackend();
  await b.ctx.db.insert('runnerKeys', { runnerId: BRUCE, keyHash: await sha256(BRUCE_KEY), name: 'bruce', createdAt: 1 });
  await b.ctx.db.insert('tokens', { hash: await sha256(TOKEN), name: 'phone', expiresAt: Date.now() + 100_000, createdAt: 1 });
  return b;
}

const project = (id: string, extra: Record<string, unknown> = {}) => ({
  id,
  title: `Project ${id}`,
  folders: ['/a'],
  goals: 'GOALS',
  state: 'STATE',
  notes: 'NOTES',
  createdBy: 'mike',
  archived: false,
  createdAt: 'c',
  updatedAt: 'u1',
  threadCount: 2,
  ...extra,
});
const heartbeat = (key: string, runnerId: string) => ({ key, runner: { runnerId, name: runnerId, version: 'v', startedAt: 'x', draining: false, threadCount: 0 } });

test('the list comes from small rows: no notes, goals, state or folders, and apps get the shape they always did', async () => {
  const s = await setup();
  await call(s.ctx, sync.setProjects, { key: OWNER, runnerId: M5, projects: [project('p1'), project('p2', { archived: true })] });
  assert.equal(s.rows('projectHeads').length, 2);
  for (const head of s.rows('projectHeads')) {
    for (const big of ['notes', 'goals', 'state', 'folders']) assert.equal(head[big], undefined);
  }
  const list = (await call(s.ctx, phone.projects, { token: TOKEN })) as Record<string, any>[];
  assert.deepEqual(list.map((p) => p.id), ['p1']);
  assert.deepEqual([list[0]!.goals, list[0]!.state, list[0]!.notes, list[0]!.folders], ['', '', '', []]);
  assert.equal(list[0]!.title, 'Project p1');
  assert.equal(list[0]!.threadCount, 2);
  assert.deepEqual(((await call(s.ctx, phone.projects, { token: TOKEN, archived: true })) as any[]).map((p) => p.id).sort(), ['p1', 'p2']);
});

test('one project whole, for its page; a gone one is null', async () => {
  const s = await setup();
  await call(s.ctx, sync.setProjects, { key: OWNER, runnerId: M5, projects: [project('p1')] });
  const p = (await call(s.ctx, phone.project, { token: TOKEN, runnerId: M5, id: 'p1' })) as Record<string, any>;
  assert.deepEqual([p.goals, p.state, p.notes, p.folders], ['GOALS', 'STATE', 'NOTES', ['/a']]);
  assert.equal(await call(s.ctx, phone.project, { token: TOKEN, runnerId: M5, id: 'nope' }), null);
  await assert.rejects(call(s.ctx, phone.project, { token: 'tb_wrong', runnerId: M5, id: 'p1' }));
});

test('editing notes, goals or state leaves the list row alone, so nobody watching the list re-runs', async () => {
  const s = await setup();
  await call(s.ctx, sync.setProjects, { key: OWNER, runnerId: M5, projects: [project('p1')] });
  const before = s.rows('projectHeads')[0]!;
  await call(s.ctx, sync.upsertProjects, { key: OWNER, runnerId: M5, projects: [project('p1', { notes: 'NEW', goals: 'NEW', state: 'NEW', updatedAt: 'u2' })], removed: [] });
  assert.equal(s.rows('projectHeads')[0], before);
  // Nor does a whole list saying the same thing.
  await call(s.ctx, sync.setProjects, { key: OWNER, runnerId: M5, projects: [project('p1', { notes: 'NEWER', updatedAt: 'u3' })] });
  assert.equal(s.rows('projectHeads')[0]!._id, before._id);
  assert.equal(s.rows('projectHeads')[0], before);
  // A title, count or activity is what a list shows.
  await call(s.ctx, sync.upsertProjects, { key: OWNER, runnerId: M5, projects: [project('p1', { title: 'Renamed' })], removed: [] });
  assert.equal(s.rows('projectHeads')[0]!.title, 'Renamed');
  await call(s.ctx, sync.upsertProjects, { key: OWNER, runnerId: M5, projects: [project('p1', { title: 'Renamed', lastActivityAt: 'later', icon: { symbol: 'star', by: 'mike' } })], removed: [] });
  assert.equal(s.rows('projectHeads')[0]!.lastActivityAt, 'later');
  assert.equal(s.rows('projectHeads')[0]!.icon.symbol, 'star');
});

test('a project gone goes from the list, by upsert and by the whole list', async () => {
  const s = await setup();
  await call(s.ctx, sync.setProjects, { key: OWNER, runnerId: M5, projects: [project('p1'), project('p2'), project('p3')] });
  await call(s.ctx, sync.upsertProjects, { key: OWNER, runnerId: M5, projects: [], removed: ['p1'] });
  assert.deepEqual(s.rows('projectHeads').map((h) => h.id).sort(), ['p2', 'p3']);
  await call(s.ctx, sync.setProjects, { key: OWNER, runnerId: M5, projects: [project('p3')] });
  assert.deepEqual(s.rows('projectHeads').map((h) => h.id), ['p3']);
});

test("a runner's projects from before the table are copied on its next heartbeat, once", async () => {
  const s = await setup();
  await s.ctx.db.insert('projects', { ...project('old'), runnerId: M5 });
  assert.deepEqual(await call(s.ctx, phone.projects, { token: TOKEN }), []);
  await call(s.ctx, sync.heartbeat, heartbeat(OWNER, M5));
  assert.deepEqual(((await call(s.ctx, phone.projects, { token: TOKEN })) as any[]).map((p) => p.id), ['old']);
  // Not read again: a row put in by hand isn't picked up by the next one.
  await s.ctx.db.insert('projects', { ...project('later'), runnerId: M5 });
  await call(s.ctx, sync.heartbeat, heartbeat(OWNER, M5));
  assert.deepEqual(s.rows('projectHeads').map((h) => h.id), ['old']);
  // Another runner's are its own to seed.
  await s.ctx.db.insert('projects', { ...project('b1'), runnerId: BRUCE });
  await call(s.ctx, sync.heartbeat, heartbeat(BRUCE_KEY, BRUCE));
  assert.deepEqual(s.rows('projectHeads').map((h) => h.id).sort(), ['b1', 'old']);
});

test("one runner's list doesn't touch another's", async () => {
  const s = await setup();
  await call(s.ctx, sync.setProjects, { key: OWNER, runnerId: M5, projects: [project('p1')] });
  await call(s.ctx, sync.setProjects, { key: BRUCE_KEY, runnerId: BRUCE, projects: [project('p1')] });
  await call(s.ctx, sync.setProjects, { key: BRUCE_KEY, runnerId: BRUCE, projects: [] });
  assert.deepEqual(s.rows('projectHeads').map((h) => h.runnerId), [M5]);
});

const account = (id: string, email: string) => ({ id, provider: 'claude', title: id, email, usage: { windows: [], readAt: 'now', source: 'live' } });

test("sync:sharedUsage with the caller's runner id leaves its own rows out, and without one tells everyone's", async () => {
  const s = await setup();
  await call(s.ctx, sync.setAccounts, { key: OWNER, runnerId: M5, accounts: [account('a', 'one@x.com')] });
  await call(s.ctx, sync.setAccounts, { key: BRUCE_KEY, runnerId: BRUCE, accounts: [account('b', 'one@x.com'), account('c', 'other@x.com')] });
  const of = (rows: unknown) => (rows as { runnerId: string; email: string }[]).map((r) => `${r.runnerId}:${r.email}`).sort();
  assert.deepEqual(of(await call(s.ctx, sync.sharedUsage, { key: OWNER, runnerId: M5 })), [`${BRUCE}:one@x.com`, `${BRUCE}:other@x.com`]);
  // A runner from before sends none.
  assert.equal(of(await call(s.ctx, sync.sharedUsage, { key: OWNER })).length, 3);
  // A runner key: never its own, whatever it sends, and only its own logins' readings.
  assert.deepEqual(of(await call(s.ctx, sync.sharedUsage, { key: BRUCE_KEY, runnerId: M5 })), [`${M5}:one@x.com`]);
  assert.deepEqual(of(await call(s.ctx, sync.sharedUsage, { key: BRUCE_KEY })), [`${M5}:one@x.com`]);
});

test('a runner sends its id only to a backend that takes it', () => {
  assert.deepEqual(sharedUsageArgs('k', 'r1', SHARED_USAGE_OTHERS_API_VERSION), { key: 'k', runnerId: 'r1' });
  assert.deepEqual(sharedUsageArgs('k', 'r1', SHARED_USAGE_OTHERS_API_VERSION - 1), { key: 'k' });
});

test("sync:schedules gives a runner key its own schedules and the owner everyone's", async () => {
  const s = await setup();
  const sched = (id: string, runnerId: string) => ({ runnerId, id, title: id, text: 't', whenText: 'w', paused: false, createdAt: 'c', updatedAt: 'u', runs: 0, owned: true });
  await s.ctx.db.insert('schedules', sched('m', M5));
  await s.ctx.db.insert('schedules', sched('b', BRUCE));
  await s.ctx.db.insert('schedules', { ...sched('mirrored', BRUCE), owned: undefined });
  const ids = (rows: unknown) => (rows as { id: string }[]).map((r) => r.id).sort();
  assert.deepEqual(ids(await call(s.ctx, sync.schedules, { key: BRUCE_KEY })), ['b']);
  assert.deepEqual(ids(await call(s.ctx, sync.schedules, { key: OWNER })), ['b', 'm']);
});
