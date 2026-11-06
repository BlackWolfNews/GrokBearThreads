// Files an agent's Edit or Write turns into code that runs by itself
// (docs/protocol.md, "Agent writes that run as code").
//
// A patch file is imported into the runner, and its hooks and setup run
// unasked; a folder's Claude Code settings start hooks and MCP servers. So
// in a thread that isn't on Full access, writing one is running code, and
// the permission to edit a file mustn't stand in for permission to run it
// (Gautam's scan, 6 Nov: F1, F4). In Ask and Auto, an edit of one of these
// always asks, with no "Always allow", whatever the thread's rules or the
// auto classifier would say, and what it writes isn't trusted: Mike trusts
// it in Patches. On Full access nothing changes, as the agent could run
// anything there already.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

// Said on the approval card, after the edit's own title.
export const RUNS_AS_CODE = 'Threadbear runs this file as code';

// What a PreToolUse hook tells the CLI when it makes such an edit ask.
export const RUNS_AS_CODE_REASON = `${RUNS_AS_CODE}, so it always asks outside Full access.`;

// By name alone, wherever it is: a patch file (a project's or
// ~/.threadbear/patches, which is trusted whatever it holds), anything else
// under ~/.threadbear (what home patches import), Claude Code settings
// (`.claude/settings.json`, `settings.local.json` and the like, home's
// included) and an `.mcp.json`. The runner adds the files a patch it has
// hashed covers, and the scripts the thread folder's Claude settings name.
export function runsAsCodeByName(file: string, home: string = os.homedir()): boolean {
  // As the disk has it, and without case: on macOS `.Threadbear/Patches/x.ts`
  // is the same file as `.threadbear/patches/x.ts`, and a symlink to one
  // writes the file it points at.
  const abs = canonicalPath(file).toLowerCase();
  const dir = path.dirname(abs);
  if (path.basename(dir) === 'patches' && path.basename(path.dirname(dir)) === '.threadbear' && ['.ts', '.js', '.mjs'].includes(path.extname(abs))) return true;
  if (isInside(abs, canonicalPath(path.join(path.resolve(home), '.threadbear')).toLowerCase())) return true;
  const name = path.basename(abs);
  if (name === '.mcp.json') return true;
  return path.basename(dir) === '.claude' && /^settings(\..*)?\.json$/.test(name);
}

// `file` with the symlinks on its way resolved and each name as the disk
// spells it, as far as it exists; the rest as given.
export function canonicalPath(file: string): string {
  let head = path.resolve(file);
  const rest: string[] = [];
  for (;;) {
    try {
      return path.join(fs.realpathSync.native(head), ...rest);
    } catch {
      const up = path.dirname(head);
      if (up === head) return path.resolve(file);
      rest.unshift(path.basename(head));
      head = up;
    }
  }
}

function isInside(file: string, dir: string): boolean {
  const rel = path.relative(dir, file);
  return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel));
}
