// Moving a Claude session to another folder or login. The CLI keeps each
// session's transcript under
// <configDir>/projects/<folder as a name>/<sessionId>.jsonl and only looks
// in the current folder's directory of its own config dir when resuming, so
// a thread that moves folder, or moves to another Claude login (a pool
// move), can keep its whole conversation by copying the transcript across
// before the CLI starts there. The CLI resumes another login's transcript,
// thinking signatures and all (test/e2e/pools.e2e.test.ts checks it). This leans on how the CLI
// lays out its files, which isn't documented, so callers fall back to a
// short handoff note when it doesn't work.
import fs from 'node:fs';
import path from 'node:path';

// The CLI names a folder's directory after its real path with every
// character that isn't a letter or digit turned into "-"
// ("/private/tmp/a.b" -> "-private-tmp-a-b"). Very long paths get a hash
// suffix instead, which isn't reproduced here; those fall back.
export function projectDirName(cwd: string): string {
  return cwd.replace(/[^a-zA-Z0-9]/g, '-');
}

function names(cwd: string): string[] {
  const out = [projectDirName(cwd)];
  try {
    const real = projectDirName(fs.realpathSync(cwd));
    if (!out.includes(real)) out.unshift(real);
  } catch {
    // folder gone; the plain name is all there is
  }
  return out;
}

// Copies session <sessionId> (its .jsonl and any subagent folder beside it)
// from <fromCwd>'s project directory under <fromConfigDir> to <toCwd>'s
// under <toConfigDir> (the same config dir for a folder move). Returns false
// if the transcript can't be found or copied. Never deletes or overwrites
// the original, so the session can still be resumed where it was.
export function copySessionTranscript(fromConfigDir: string, toConfigDir: string, fromCwd: string, toCwd: string, sessionId: string): boolean {
  if (!/^[0-9a-zA-Z-]+$/.test(sessionId)) return false;
  const fromDir = names(fromCwd)
    .map((n) => path.join(fromConfigDir, 'projects', n))
    .find((d) => fs.existsSync(path.join(d, `${sessionId}.jsonl`)));
  if (!fromDir) return false;
  const toDir = path.join(toConfigDir, 'projects', names(toCwd)[0]);
  if (toDir === fromDir) return true;
  try {
    fs.mkdirSync(toDir, { recursive: true });
    fs.copyFileSync(path.join(fromDir, `${sessionId}.jsonl`), path.join(toDir, `${sessionId}.jsonl`));
    const extras = path.join(fromDir, sessionId);
    if (fs.existsSync(extras)) fs.cpSync(extras, path.join(toDir, sessionId), { recursive: true });
    return true;
  } catch {
    return false;
  }
}

// Where the CLI keeps a sub-agent's own transcript: beside the session's,
// in <sessionId>/subagents/agent-<id>.jsonl. Null when it isn't there.
export function subagentTranscriptPath(configDir: string, cwd: string, sessionId: string, agentId: string): string | null {
  if (!/^[0-9a-zA-Z-]+$/.test(sessionId) || !/^[0-9a-zA-Z_-]+$/.test(agentId)) return null;
  for (const n of names(cwd)) {
    const file = path.join(configDir, 'projects', n, sessionId, 'subagents', `agent-${agentId}.jsonl`);
    if (fs.existsSync(file)) return file;
  }
  return null;
}
