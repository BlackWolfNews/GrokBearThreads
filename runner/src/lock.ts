import fs from 'node:fs';
import path from 'node:path';
import { processInfo } from './proc.ts';

// One runner per data dir. A second one (`npm start` while the LaunchAgent
// runs, say) would sweep the first one's CLIs as orphans and append to the
// same event logs, so it has to stop before it touches anything.
// run/runner.pid holds the owner's pid and start time; a lock whose owner
// is gone, or whose pid now belongs to another process, is taken over.
export type Lock = { release(): void };

export function acquireLock(runDir: string): Lock | { heldBy: number } {
  const file = path.join(runDir, 'runner.pid');
  const me = { pid: process.pid, lstart: processInfo(process.pid)?.lstart ?? '' };
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      fs.mkdirSync(runDir, { recursive: true });
      const fd = fs.openSync(file, 'wx', 0o644);
      try {
        fs.writeSync(fd, JSON.stringify(me) + '\n');
      } finally {
        fs.closeSync(fd);
      }
      return {
        release() {
          try {
            if (readHolder(file)?.pid === process.pid) fs.unlinkSync(file);
          } catch {
            // already gone
          }
        },
      };
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code !== 'EEXIST') throw e;
      const holder = readHolder(file);
      if (holder && holder.pid !== process.pid && holderAlive(holder)) return { heldBy: holder.pid };
      fs.rmSync(file, { force: true });
    }
  }
  throw new Error(`Couldn't take the runner lock at ${file}`);
}

function readHolder(file: string): { pid: number; lstart?: string } | null {
  try {
    const raw = fs.readFileSync(file, 'utf8').trim();
    // Older runners wrote just the pid.
    if (/^\d+$/.test(raw)) return { pid: Number(raw) };
    const j = JSON.parse(raw) as { pid?: unknown; lstart?: unknown };
    return typeof j.pid === 'number' ? { pid: j.pid, lstart: typeof j.lstart === 'string' ? j.lstart : undefined } : null;
  } catch {
    return null;
  }
}

function holderAlive(h: { pid: number; lstart?: string }): boolean {
  const info = processInfo(h.pid);
  if (!info) return false;
  if (h.lstart) return info.lstart === h.lstart;
  return /main\.ts/.test(info.command);
}
