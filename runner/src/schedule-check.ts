// A schedule's check (experiment scheduleChecks, experiments.ts): a shell
// command its runner runs before each run, in the schedule's folder. If it
// prints nothing, the run is skipped and no agent starts, so a watcher that
// polls every few minutes costs nothing until there's something to do.
// Whatever it prints goes into the message. A check that fails (exits
// non-zero or times out) doesn't skip the run: the run goes ahead with the
// error, so the agent can see the check is broken rather than it going
// quiet. Cloudroom, Intentic and Paradev gate their automations this way
// (6 Nov 2026, thread d698c77d).
//
// THREADBEAR_CHECK_STATE names a file of the schedule's own that the check
// may keep state in between runs (the last id it saw), and
// THREADBEAR_SCHEDULE_ID is the schedule's id.
//
// A check like that reports each thing once, so what it printed is kept in
// a file of the schedule's own (keptCheckFile) until a run carrying it has
// really been sent, and the run uses that rather than running the check
// again. A restart landing between the check and the send would otherwise
// lose it: the next runner's check finds nothing new (6 Nov 2026, schedule
// 54f11e8a in a handover).
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { atomicWriteFileSync } from './fsutil.ts';

export const CHECK_TIMEOUT_MS = 60_000;
export const CHECK_OUTPUT_CHARS = 8000;
export const MAX_CHECK_CHARS = 2000;

export type CheckResult = { ok: true; output: string } | { ok: false; output: string; why: string };

export function checkStateFile(home: string, scheduleId: string): string {
  return path.join(home, 'schedule-checks', `${scheduleId}.state`);
}

export function keptCheckFile(home: string, scheduleId: string): string {
  return path.join(home, 'schedule-checks', `${scheduleId}.kept.json`);
}

// What a check printed that hasn't reached a thread yet. `check` is the
// command that printed it: a changed check doesn't send the old one's news.
export type KeptCheck = { check: string; at: string; extra: string };

export function readKeptCheck(home: string, scheduleId: string, check: string): KeptCheck | undefined {
  let kept: KeptCheck;
  try {
    kept = JSON.parse(fs.readFileSync(keptCheckFile(home, scheduleId), 'utf8'));
  } catch {
    return undefined;
  }
  if (!kept || typeof kept.extra !== 'string' || kept.check !== check) return undefined;
  return kept;
}

export function keepCheck(home: string, scheduleId: string, kept: KeptCheck): void {
  const file = keptCheckFile(home, scheduleId);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  // It can hold whatever the check printed, so it's the user's only.
  atomicWriteFileSync(file, JSON.stringify(kept), 0o600);
}

export function dropKeptCheck(home: string, scheduleId: string): void {
  fs.rmSync(keptCheckFile(home, scheduleId), { force: true });
}

export function runCheck(p: { command: string; cwd: string; home: string; scheduleId: string; timeoutMs?: number }): Promise<CheckResult> {
  const state = checkStateFile(p.home, p.scheduleId);
  try {
    fs.mkdirSync(path.dirname(state), { recursive: true });
  } catch {
    // The check can still run; it just has nowhere to keep state.
  }
  return new Promise((resolve) => {
    let out = '';
    let done = false;
    const finish = (r: CheckResult) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      resolve(r);
    };
    const child = spawn('/bin/sh', ['-c', p.command], {
      cwd: fs.existsSync(p.cwd) ? p.cwd : undefined,
      env: { ...process.env, THREADBEAR_SCHEDULE_ID: p.scheduleId, THREADBEAR_CHECK_STATE: state },
      stdio: ['ignore', 'pipe', 'pipe'],
      // Its own process group, so a timeout stops whatever it started too.
      detached: true,
    });
    const take = (b: Buffer) => {
      // Keep the end: the last lines of a long output say the most.
      out = (out + b.toString('utf8')).slice(-CHECK_OUTPUT_CHARS * 2);
    };
    child.stdout?.on('data', take);
    child.stderr?.on('data', take);
    const timer = setTimeout(() => {
      try {
        if (child.pid) process.kill(-child.pid, 'SIGKILL');
      } catch {
        child.kill('SIGKILL');
      }
      finish({ ok: false, output: clip(out), why: `it took longer than ${Math.round((p.timeoutMs ?? CHECK_TIMEOUT_MS) / 1000)} seconds` });
    }, p.timeoutMs ?? CHECK_TIMEOUT_MS);
    child.on('error', (e) => finish({ ok: false, output: clip(out), why: e.message }));
    child.on('close', (code, signal) => {
      if (code === 0) finish({ ok: true, output: clip(out) });
      else finish({ ok: false, output: clip(out), why: signal ? `it was stopped by ${signal}` : `it exited with ${code}` });
    });
  });
}

function clip(s: string): string {
  const t = s.trim();
  return t.length > CHECK_OUTPUT_CHARS ? '…' + t.slice(-CHECK_OUTPUT_CHARS) : t;
}

// What goes under the scheduled message, or that the run is skipped.
export function checkOutcome(r: CheckResult): { skip: string } | { extra: string } {
  if (r.ok && !r.output) return { skip: 'Its check found nothing new.' };
  const block = r.output ? `\n\n\`\`\`\n${r.output.replaceAll('```', "'''")}\n\`\`\`` : '';
  if (r.ok) return { extra: `\n\nIts check found this:${block}` };
  return { extra: `\n\nIts check failed (${r.why}), so this run went ahead anyway. If it keeps failing, fix the check with update_schedule.${block}` };
}
