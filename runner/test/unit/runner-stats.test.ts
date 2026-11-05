import { test } from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import { cpuPercentBetween, cpuTimes, machineSampler, parseMemInfo, parseVmStat, PRESSURE_MS, pressureOf, RunnerStats, WATCHED_MS, type MachineStats } from '../../src/runner-stats.ts';

const GB = 1024 ** 3;
const stats = (o: Partial<MachineStats> = {}): MachineStats => ({ cpuPercent: 10, cores: 8, memUsed: 4 * GB, memTotal: 16 * GB, diskFree: 200 * GB, diskTotal: 500 * GB, uptimeSec: 100, ...o });

test('a machine says when memory or disk runs low', () => {
  assert.equal(pressureOf(stats()), undefined);
  assert.equal(pressureOf(stats({ memUsed: 15 * GB })), 'memory');
  assert.equal(pressureOf(stats({ diskFree: 9 * GB })), 'disk');
  assert.equal(pressureOf(stats({ memTotal: 0, diskTotal: 0, diskFree: 0 })), undefined);
});

test('CPU is the busy share between two looks', () => {
  const times = (idle: number, user: number) => ({ times: { user, nice: 0, sys: 0, idle, irq: 0 } });
  const a = cpuTimes([times(100, 100), times(100, 100)]);
  const b = cpuTimes([times(150, 150), times(150, 150)]);
  assert.equal(cpuPercentBetween(a, b), 50);
  assert.equal(cpuPercentBetween(a, a), 0, 'no time passed');
});

test('memory on a Mac is app memory, wired and compressed, not what is merely cached', () => {
  const text = `Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                               10000.
Pages active:                            500000.
Pages inactive:                          480000.
Pages wired down:                        100000.
Pages purgeable:                          20000.
Anonymous pages:                         300000.
Pages occupied by compressor:             50000.
`;
  assert.equal(parseVmStat(text), (280000 + 100000 + 50000) * 16384);
  assert.equal(parseVmStat('nothing like it'), undefined);
});

test('memory on Linux is what is not available', () => {
  assert.deepEqual(parseMemInfo('MemTotal:       8000 kB\nMemFree:      100 kB\nMemAvailable:   6000 kB\n'), { used: 2000 * 1024, total: 8000 * 1024 });
  assert.equal(parseMemInfo('nothing'), undefined);
});

test('sampling this machine gives sensible figures', async () => {
  const s = await machineSampler(os.tmpdir())();
  assert.ok(s.memTotal > 0 && s.memUsed > 0 && s.memUsed <= s.memTotal, 'memory');
  assert.ok(s.diskTotal > 0 && s.diskFree > 0 && s.diskFree <= s.diskTotal, 'disk');
  assert.ok(s.cores > 0 && s.cpuPercent >= 0 && s.cpuPercent <= 100, 'cpu');
});

function setup() {
  let now = 1000;
  const timers: { at: number; fn: () => void; dead: boolean }[] = [];
  const posts: Record<string, unknown>[] = [];
  let samples = 0;
  let push: ((v: unknown) => void) | undefined;
  let unsubscribed = false;
  let current = stats();
  const r = new RunnerStats({
    sample: async () => {
      samples++;
      return current;
    },
    post: async (fn, args) => {
      posts.push({ fn, ...args });
    },
    subscribe: (fn, _a, update) => {
      assert.equal(fn, 'sync:runnerWatch');
      push = update;
      return () => {
        unsubscribed = true;
      };
    },
    key: 'k',
    runnerId: 'r1',
    clock: {
      now: () => now,
      setTimeout: (fn, ms) => {
        const t = { at: now + ms, fn, dead: false };
        timers.push(t);
        return { cancel: () => (t.dead = true) };
      },
    },
    log: { debug: () => {} },
  });
  const settle = () => new Promise((resolve) => setImmediate(resolve));
  const advance = async (ms: number) => {
    const end = now + ms;
    for (;;) {
      const next = timers.filter((t) => !t.dead && t.at <= end).sort((a, b) => a.at - b.at)[0];
      if (!next) break;
      now = next.at;
      next.dead = true;
      next.fn();
      await settle();
    }
    now = end;
  };
  return { r, posts, settle, advance, watch: (until: number | null) => push!(until === null ? null : { until }), now: () => now, samples: () => samples, unsubscribed: () => unsubscribed, setStats: (s: MachineStats) => (current = s) };
}

test('nothing is written while nobody is watching', async () => {
  const t = setup();
  t.r.start();
  await t.settle();
  t.watch(null);
  await t.advance(60 * 60_000);
  assert.deepEqual(t.posts, []);
});

test('someone watching gets figures at once, then every few seconds, until they stop', async () => {
  const t = setup();
  t.r.start();
  await t.settle();
  t.watch(t.now() + 25_000);
  await t.settle();
  assert.equal(t.posts.length, 1, 'straight away');
  assert.equal(t.posts[0]!.fn, 'sync:setRunnerStats');
  assert.equal(t.posts[0]!.runnerId, 'r1');
  await t.advance(WATCHED_MS);
  assert.equal(t.posts.length, 2);
  await t.advance(WATCHED_MS);
  assert.equal(t.posts.length, 3);
  await t.advance(10 * WATCHED_MS);
  assert.equal(t.posts.length, 3, 'stops when the watch lapses');
});

test('a watch renewed while reporting keeps one loop going, not two', async () => {
  const t = setup();
  t.r.start();
  await t.settle();
  t.watch(t.now() + 15_000);
  await t.settle();
  t.watch(t.now() + 45_000);
  t.watch(t.now() + 45_000);
  await t.settle();
  assert.equal(t.posts.length, 1);
  await t.advance(WATCHED_MS);
  assert.equal(t.posts.length, 2);
});

test('an old watch does nothing, and stop lets go of everything', async () => {
  const t = setup();
  t.r.start();
  await t.settle();
  t.watch(t.now() - 1);
  await t.settle();
  assert.deepEqual(t.posts, []);
  t.watch(t.now() + 60_000);
  await t.settle();
  t.r.stop();
  assert.ok(t.unsubscribed());
  const before = t.posts.length;
  await t.advance(60_000);
  assert.equal(t.posts.length, before);
});

test('pressure is looked for now and then, with nothing posted', async () => {
  const t = setup();
  t.r.start();
  await t.settle();
  assert.equal(t.r.pressure, undefined);
  t.setStats(stats({ memUsed: 15 * GB }));
  await t.advance(PRESSURE_MS);
  assert.equal(t.r.pressure, 'memory');
  assert.deepEqual(t.posts, []);
  assert.equal(t.samples(), 2);
});
