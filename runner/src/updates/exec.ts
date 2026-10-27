// How CLI updates run commands and fetch versions. Injected, so tests use
// stub npm, codex and claude binaries and canned version lookups, and never
// touch the network or a real install.
import { execFile } from 'node:child_process';

export type ExecResult = { code: number; stdout: string; stderr: string; error?: string };
export type ExecOptions = { cwd?: string; env?: NodeJS.ProcessEnv; timeoutMs?: number };
export type Exec = (command: string, args: string[], opts?: ExecOptions) => Promise<ExecResult>;
// The body of a GET, or a thrown error (timeout, status other than 200).
export type FetchText = (url: string, timeoutMs: number) => Promise<string>;

// Never throws: a missing binary, a timeout or a non-zero exit all come back
// as a result with a code other than 0.
export const defaultExec: Exec = (command, args, opts = {}) =>
  new Promise((resolve) => {
    execFile(
      command,
      args,
      { cwd: opts.cwd, env: opts.env, timeout: opts.timeoutMs ?? 60_000, maxBuffer: 32 * 1024 * 1024, encoding: 'utf8', killSignal: 'SIGKILL' },
      (err, stdout, stderr) => {
        if (!err) return resolve({ code: 0, stdout, stderr });
        const e = err as NodeJS.ErrnoException & { code?: number | string; killed?: boolean };
        const code = typeof e.code === 'number' ? e.code : -1;
        resolve({ code, stdout: stdout ?? '', stderr: stderr ?? '', error: e.killed ? 'timed out' : e.message });
      },
    );
  });

export const defaultFetchText: FetchText = async (url, timeoutMs) => {
  const res = await fetch(url, { signal: AbortSignal.timeout(timeoutMs), headers: { 'user-agent': 'threadbare-runner' } });
  if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
  return await res.text();
};

// "2.1.311", "0.165.0", "0.166.0-alpha.2". Anything else isn't a version.
export const VERSION_RE = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/;

export function compareVersions(a: string, b: string): number {
  const [ma, pa = ''] = a.split('-', 2);
  const [mb, pb = ''] = b.split('-', 2);
  const na = ma.split('.').map(Number);
  const nb = mb.split('.').map(Number);
  for (let i = 0; i < 3; i++) if ((na[i] ?? 0) !== (nb[i] ?? 0)) return (na[i] ?? 0) - (nb[i] ?? 0);
  if (pa === pb) return 0;
  if (!pa) return 1; // a release is newer than its pre-releases
  if (!pb) return -1;
  // Pre-release identifiers compare numerically when both are numbers.
  const xa = pa.split('.');
  const xb = pb.split('.');
  for (let i = 0; i < Math.max(xa.length, xb.length); i++) {
    if (xa[i] === undefined) return -1;
    if (xb[i] === undefined) return 1;
    if (xa[i] === xb[i]) continue;
    const na2 = /^\d+$/.test(xa[i]) ? Number(xa[i]) : NaN;
    const nb2 = /^\d+$/.test(xb[i]) ? Number(xb[i]) : NaN;
    if (!Number.isNaN(na2) && !Number.isNaN(nb2)) return na2 - nb2;
    return xa[i] < xb[i] ? -1 : 1;
  }
  return 0;
}
