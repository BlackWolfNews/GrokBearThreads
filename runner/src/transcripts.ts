// Moving a Claude session to another folder. The CLI keeps each session's
// transcript under <configDir>/projects/<folder as a name>/<sessionId>.jsonl
// and only looks in the current folder's directory when resuming, so a
// thread that moves folder can keep its whole conversation by copying the
// transcript across before the CLI starts there. This leans on how the CLI
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
// from <fromCwd>'s project directory to <toCwd>'s. Returns false if the
// transcript can't be found or copied. Never deletes or overwrites the
// original, so the session can still be resumed where it was.
export function copySessionTranscript(configDir: string, fromCwd: string, toCwd: string, sessionId: string): boolean {
  if (!/^[0-9a-zA-Z-]+$/.test(sessionId)) return false;
  const projects = path.join(configDir, 'projects');
  const fromDir = names(fromCwd)
    .map((n) => path.join(projects, n))
    .find((d) => fs.existsSync(path.join(d, `${sessionId}.jsonl`)));
  if (!fromDir) return false;
  const toDir = path.join(projects, names(toCwd)[0]);
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
