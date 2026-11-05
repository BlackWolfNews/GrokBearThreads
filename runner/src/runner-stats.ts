// A machine's CPU, memory and disk, for the website's Runners view (API 45,
// docs/convex-backend.md). Nothing is written unless someone has that view open:
// the website keeps a row saying so (`sync:runnerWatch`), and while it's fresh
// this reports every WATCHED_MS into a small row of its own (`runnerStats`). The
// heartbeat row isn't used for the figures, as every phone's list re-runs when
// that changes. It only carries `pressure`, which rarely does, for the rail's dot.
import { execFile } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';

export const WATCHED_MS = 10_000;
// How often to look, with nobody watching, for the rail's low memory or disk
// dot. Looking reads memory by spawning vm_stat on a Mac, and a spawn can block
// the main thread for a moment under heavy disk load, so not every heartbeat.
export const PRESSURE_MS = 5 * 60_000;

export type MachineStats = {
  cpuPercent: number;
  cores: number;
  memUsed: number;
  memTotal: number;
  diskFree: number;
  diskTotal: number;
  load1?: number;
  uptimeSec: number;
  machine?: string;
  os?: string;
};

export type Pressure = 'memory' | 'disk';

// Over this much memory used, or under this much disk free, the runner says so.
// Memory is what's in real use (below), not what macOS has cached, so a Mac
// doesn't read as full just because it's been up a while.
const MEMORY_HIGH = 0.9;
const DISK_LOW_BYTES = 10 * 1024 ** 3;

export function pressureOf(s: MachineStats): Pressure | undefined {
  if (s.memTotal > 0 && s.memUsed / s.memTotal >= MEMORY_HIGH) return 'memory';
  if (s.diskTotal > 0 && s.diskFree < DISK_LOW_BYTES) return 'disk';
  return undefined;
}

type CpuTimes = { idle: number; total: number };

export function cpuTimes(cpus: Pick<os.CpuInfo, 'times'>[]): CpuTimes {
  let idle = 0;
  let total = 0;
  for (const { times } of cpus) {
    idle += times.idle;
    total += times.user + times.nice + times.sys + times.idle + times.irq;
  }
  return { idle, total };
}

export function cpuPercentBetween(a: CpuTimes, b: CpuTimes): number {
  const total = b.total - a.total;
  if (total <= 0) return 0;
  return Math.round(Math.min(100, Math.max(0, (1 - (b.idle - a.idle) / total) * 100)));
}

// What Activity Monitor calls Memory Used: app memory (anonymous pages less the
// purgeable ones), wired and compressed. os.freemem() on a Mac counts only pages
// nothing has touched, which reads as nearly full all the time.
export function parseVmStat(text: string): number | undefined {
  const page = Number(text.match(/page size of (\d+) bytes/)?.[1]);
  const pages = (label: string) => Number(text.match(new RegExp(`${label}:\\s+(\\d+)`))?.[1]);
  const anonymous = pages('Anonymous pages');
  const purgeable = pages('Pages purgeable');
  const wired = pages('Pages wired down');
  const compressed = pages('Pages occupied by compressor');
  if (![page, anonymous, purgeable, wired, compressed].every(Number.isFinite)) return undefined;
  return (Math.max(0, anonymous - purgeable) + wired + compressed) * page;
}

export function parseMemInfo(text: string): { used: number; total: number } | undefined {
  const kb = (label: string) => Number(text.match(new RegExp(`^${label}:\\s+(\\d+) kB`, 'm'))?.[1]);
  const total = kb('MemTotal');
  const available = kb('MemAvailable');
  if (!Number.isFinite(total) || !Number.isFinite(available)) return undefined;
  return { used: (total - available) * 1024, total: total * 1024 };
}

function run(file: string, args: string[]): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile(file, args, { timeout: 3000 }, (err, stdout) => (err ? reject(err) : resolve(stdout)));
  });
}

async function memory(): Promise<{ used: number; total: number }> {
  const total = os.totalmem();
  const plain = { used: total - os.freemem(), total };
  try {
    if (os.platform() === 'darwin') return { used: parseVmStat(await run('/usr/bin/vm_stat', [])) ?? plain.used, total };
    if (os.platform() === 'linux') return parseMemInfo(await fs.promises.readFile('/proc/meminfo', 'utf8')) ?? plain;
  } catch {
    // The rough figure rather than none.
  }
  return plain;
}

async function osName(): Promise<string | undefined> {
  try {
    if (os.platform() === 'darwin') return `macOS ${(await run('/usr/bin/sw_vers', ['-productVersion'])).trim()}`;
    if (os.platform() === 'linux') return (await fs.promises.readFile('/etc/os-release', 'utf8')).match(/^PRETTY_NAME="?([^"\n]+)"?/m)?.[1];
  } catch {
    // Only a label.
  }
  return undefined;
}

// Samples this machine. `home` picks the disk, the one the runner's data is on.
export function machineSampler(home: string): () => Promise<MachineStats> {
  let last = cpuTimes(os.cpus());
  let name: Promise<string | undefined> | undefined;
  return async () => {
    const now = cpuTimes(os.cpus());
    const cpuPercent = cpuPercentBetween(last, now);
    last = now;
    const [mem, disk, osLabel] = await Promise.all([memory(), fs.promises.statfs(home), (name ??= osName())]);
    // Node says "unknown" on some Arm Linux, the Pixel's among them.
    const model = os.cpus()[0]?.model.trim();
    const load1 = os.platform() === 'win32' ? undefined : os.loadavg()[0];
    return {
      cpuPercent,
      cores: os.cpus().length,
      memUsed: mem.used,
      memTotal: mem.total,
      diskFree: disk.bavail * disk.bsize,
      diskTotal: disk.blocks * disk.bsize,
      ...(load1 !== undefined ? { load1: Math.round(load1 * 100) / 100 } : {}),
      uptimeSec: Math.round(os.uptime()),
      ...(model && model.toLowerCase() !== 'unknown' ? { machine: model } : {}),
      ...(osLabel ? { os: osLabel } : {}),
    };
  };
}

type Timer = { cancel(): void };
export type RunnerStatsDeps = {
  sample: () => Promise<MachineStats>;
  post: (fn: string, args: Record<string, unknown>) => Promise<unknown>;
  subscribe: (fn: string, args: Record<string, unknown>, onUpdate: (v: unknown) => void, onError: (e: unknown) => void) => () => void;
  key: string | undefined;
  runnerId: string;
  clock: { now(): number; setTimeout(fn: () => void, ms: number): Timer };
  log: { debug(msg: string, data?: Record<string, unknown>): void };
};

export class RunnerStats {
  private until = 0;
  private watchTimer?: Timer;
  private pressureTimer?: Timer;
  private unsubscribe?: () => void;
  private started = false;
  /** What the heartbeat carries. */
  pressure: Pressure | undefined;

  private deps: RunnerStatsDeps;

  constructor(deps: RunnerStatsDeps) {
    this.deps = deps;
  }

  start(): void {
    if (this.started) return;
    this.started = true;
    const { key } = this.deps;
    this.unsubscribe = this.deps.subscribe(
      'sync:runnerWatch',
      { key },
      (v) => this.watched(v),
      (e) => this.deps.log.debug('runner watch failed', { error: String(e) }),
    );
    void this.lookForPressure();
  }

  stop(): void {
    this.started = false;
    this.unsubscribe?.();
    this.unsubscribe = undefined;
    this.watchTimer?.cancel();
    this.pressureTimer?.cancel();
    this.watchTimer = undefined;
    this.pressureTimer = undefined;
  }

  private watched(v: unknown): void {
    const until = typeof (v as { until?: unknown } | null)?.until === 'number' ? (v as { until: number }).until : 0;
    this.until = until;
    // Already reporting: the running tick sees the new time. Otherwise now,
    // so whoever just opened the view has figures straight away.
    if (!this.watchTimer && until > this.deps.clock.now()) void this.report();
  }

  private async report(): Promise<void> {
    if (!this.started) return;
    // A slow post must not start a second loop alongside this one.
    this.watchTimer = this.deps.clock.setTimeout(() => {
      this.watchTimer = undefined;
      if (this.until > this.deps.clock.now()) void this.report();
    }, WATCHED_MS);
    try {
      const stats = await this.deps.sample();
      this.pressure = pressureOf(stats);
      if (!this.started) return;
      await this.deps.post('sync:setRunnerStats', { key: this.deps.key, runnerId: this.deps.runnerId, stats });
    } catch (e) {
      this.deps.log.debug('runner stats failed', { error: String(e) });
    }
  }

  private async lookForPressure(): Promise<void> {
    if (!this.started) return;
    try {
      this.pressure = pressureOf(await this.deps.sample());
    } catch (e) {
      this.deps.log.debug('runner pressure failed', { error: String(e) });
    }
    if (this.started) this.pressureTimer = this.deps.clock.setTimeout(() => void this.lookForPressure(), PRESSURE_MS);
  }
}
