// Claude Code's native install: `~/.local/bin/claude` links to
// `~/.local/share/claude/versions/<v>`, one file per version. `claude
// update` downloads the new one and swaps the link; a running Claude keeps
// the file it started from, so updating while turns run is safe (checked
// 26 Oct: a session on 2.1.310 carried on after T3 updated to 2.1.311).
import fs from 'node:fs';
import path from 'node:path';
import { readJsonSync } from '../fsutil.ts';
import { VERSION_RE, type Exec, type FetchText } from './exec.ts';

export const CLAUDE_RELEASES = 'https://downloads.claude.ai/claude-code-releases';
// What `claude update` prints, exiting 0, when another Claude holds the
// installer's lock. Nothing changed; try again later.
export const CLAUDE_LOCKED = /Another Claude process \(PID \d+\) is currently running/i;

// The version new sessions start: the link's target, or `claude --version`
// for an install that isn't a link. Undefined when there's no claude.
export async function claudeInstalledVersion(claudePath: string, exec: Exec): Promise<string | undefined> {
  try {
    const target = fs.readlinkSync(claudePath);
    const v = path.basename(target);
    if (VERSION_RE.test(v)) return v;
  } catch {
    // Not a link (or not there): ask the binary.
  }
  if (!fs.existsSync(claudePath)) return undefined;
  const r = await exec(claudePath, ['--version'], { timeoutMs: 10_000 });
  return r.code === 0 ? /(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)/.exec(r.stdout)?.[1] : undefined;
}

// settings.json's autoUpdatesChannel ("latest" or "stable"), as the CLI's
// own updater reads it. Mike's is unset, which means latest.
export function claudeChannel(claudeMainDir: string): string {
  const s = readJsonSync<Record<string, unknown>>(path.join(claudeMainDir, 'settings.json'));
  const c = s?.autoUpdatesChannel;
  return typeof c === 'string' && /^[a-z]+$/.test(c) ? c : 'latest';
}

export async function claudeLatestVersion(fetchText: FetchText, channel: string, timeoutMs: number): Promise<string | undefined> {
  const text = (await fetchText(`${CLAUDE_RELEASES}/${channel}`, timeoutMs)).trim();
  return VERSION_RE.test(text) ? text : undefined;
}

export type ClaudeUpdateResult =
  | { kind: 'updated'; from?: string; to: string; output: string }
  | { kind: 'unchanged'; version?: string; output: string }
  | { kind: 'locked'; output: string }
  | { kind: 'failed'; message: string; output: string };

// Runs `claude update` and reads the link afterwards, since the command
// exits 0 both when it updated and when another Claude held the lock.
export async function runClaudeUpdate(o: { claudePath: string; cwd: string; exec: Exec; env?: NodeJS.ProcessEnv; timeoutMs: number }): Promise<ClaudeUpdateResult> {
  const before = await claudeInstalledVersion(o.claudePath, o.exec);
  // The binary is shared by every login, so no account's config dir.
  const env = { ...(o.env ?? process.env) };
  delete env.CLAUDE_CONFIG_DIR;
  fs.mkdirSync(o.cwd, { recursive: true });
  const r = await o.exec(o.claudePath, ['update'], { cwd: o.cwd, env, timeoutMs: o.timeoutMs });
  const output = `${r.stdout}${r.stderr}`;
  const after = await claudeInstalledVersion(o.claudePath, o.exec);
  if (after && after !== before) return { kind: 'updated', from: before, to: after, output };
  if (CLAUDE_LOCKED.test(output)) return { kind: 'locked', output };
  if (r.code !== 0) return { kind: 'failed', message: r.error ?? `claude update exited ${r.code}`, output };
  return { kind: 'unchanged', version: after, output };
}
