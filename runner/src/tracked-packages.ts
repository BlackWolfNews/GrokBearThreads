// Files under node_modules that a repo commits, which patch trust hashes
// like the rest of the repo (docs/protocol.md, "Trusting a folder's
// patches").
//
// A package `npm install` put in node_modules is the folder's dependency,
// and isn't hashed: that would re-ask after every install. But a repo can
// commit its own `node_modules/zod` (git add -f gets past .gitignore), and
// a bare `import 'zod'` from a trusted patch then loaded whatever a later
// pull put there, unasked (Mike's call, 7 Nov, after Gautam's scan). So
// files git tracks under any node_modules folder of the repo, submodules
// included, are the repo's own: once a patch, or a script one of its
// commands runs, imports a package from inside the repo, every one of them
// is hashed and followed for its own imports, as a helper is. Installed
// (untracked) packages stay as they are. When git can't say what it tracks
// (it fails, or the folder isn't a git checkout at all), patch trust can't
// tell an installed package from a shipped one, so it fails closed.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import { isBuiltin } from 'node:module';
import path from 'node:path';
import type { Reads } from './script-trust.ts';

// What git tracks under node_modules in one repo: `files`, real paths
// (regular files and links alike), and `links`, the tracked symlinks, by
// path; or `problem` when git couldn't say.
export type TrackedNodeModules = { files: Set<string>; links: Set<string> } | { problem: string };

// At most this many tracked files under node_modules are followed; a repo
// that commits more can't be checked.
export const MAX_TRACKED_PACKAGE_FILES = 100;

const cache = new Map<string, { key: string; out: TrackedNodeModules }>();

// git, without anything a repo's own config could make it run: a folder
// from a zip can carry a .git/config with core.fsmonitor set, which `git
// ls-files` would start. `-c` reaches submodules' git too.
function git(dir: string, args: string[]): string {
  const env = { ...process.env };
  for (const k of Object.keys(env)) if (k.startsWith('GIT_')) delete env[k];
  return execFileSync('git', ['-c', 'core.fsmonitor=false', '-c', 'core.untrackedCache=false', '-C', dir, ...args], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'ignore'],
    timeout: 10_000,
    maxBuffer: 64 * 1024 * 1024,
    env,
  });
}

// The index files that say what `top` (and each submodule) tracks, so a
// cached hash knows to look again when one changes: a pull that starts
// tracking node_modules/zod over an installed copy writes the files and
// the index, but not the files the hash read.
const indexOf = new Map<string, string>();
function indexFiles(top: string): string[] {
  let f = indexOf.get(top);
  if (f === undefined) {
    try {
      f = path.resolve(top, git(top, ['rev-parse', '--git-path', 'index']).trim());
      indexOf.set(top, f);
    } catch {
      return []; // the listing below fails too
    }
  }
  return [f];
}

// What git tracks under node_modules in the repo at `top` (a real path).
// Read once per index state.
export function trackedNodeModules(top: string, reads?: Reads): TrackedNodeModules {
  if (!fs.existsSync(path.join(top, '.git'))) {
    return { problem: `${top} isn't a git checkout, so patch trust can't tell a package npm installed from one the folder ships in node_modules.` };
  }
  const indexes = indexFiles(top);
  for (const f of indexes) reads?.watch(f);
  let key = '';
  try {
    key = indexes.map((f) => {
      const st = fs.statSync(f);
      return `${f}:${st.ino}:${st.size}:${st.mtimeMs}:${st.ctimeMs}`;
    }).join('\n');
  } catch {
    key = '';
  }
  const hit = cache.get(top);
  if (key && hit && hit.key === key) return hit.out;
  let listed: string;
  try {
    listed = git(top, ['ls-files', '-z', '-s', '--recurse-submodules']);
  } catch {
    return { problem: `git couldn't list what ${top} tracks, so patch trust can't tell a package npm installed from one the repo ships in node_modules.` };
  }
  const files = new Set<string>();
  const links = new Set<string>();
  for (const line of listed.split('\0')) {
    const m = /^(\d{6}) [0-9a-f]+ \d+\t([\s\S]+)$/.exec(line);
    if (!m) continue;
    const rel = m[2]!;
    if (!rel.split('/').includes('node_modules')) continue;
    const p = path.join(top, rel);
    if (m[1] === '120000') links.add(p);
    files.add(p);
  }
  const out = { files, links };
  if (key) cache.set(top, { key, out });
  return out;
}

// A bare specifier's package: `zod` of `zod/v4`, `@ws/lib` of `@ws/lib/x`.
export function packageName(specifier: string): string {
  const parts = specifier.split('/');
  return (specifier.startsWith('@') ? parts.slice(0, 2) : parts.slice(0, 1)).join('/');
}

function inside(p: string, dir: string): boolean {
  const rel = path.relative(dir, p);
  return rel === '' || (!!rel && !rel.startsWith('..' + path.sep) && rel !== '..' && !path.isAbsolute(rel));
}

// Where Node would look for a bare import from `fromDir`: the first
// `node_modules/<name>` up from it. Undefined when there's none (Node
// fails, or resolves it some other way the load hook refuses).
function packageDir(fromDir: string, name: string): string | undefined {
  for (let d = fromDir; ; d = path.dirname(d)) {
    const p = path.join(d, 'node_modules', name);
    try {
      fs.lstatSync(p);
      return p;
    } catch {
      // not here: one up
    }
    if (path.dirname(d) === d) return undefined;
  }
}

// What importing `spec` from a file in `fromDir` means for the repo at
// `top` (a real path): `undefined` when it's a builtin or lands outside the
// repo (installed elsewhere); otherwise `inRepo`, with `files`, every file
// git tracks under node_modules in the repo, which the caller hashes and
// follows (empty when it tracks none: then the package was installed), or
// `problem` when that can't be told.
export function bareImport(fromDir: string, spec: string, top: string, reads?: Reads): { files: string[] } | { problem: string } | undefined {
  if (isBuiltin(spec) || spec.startsWith('node:')) return undefined;
  const name = packageName(spec);
  if (!name || name.split('/').some((s) => !s || s === '.' || s === '..')) return undefined;
  const dir = packageDir(fromDir, name);
  if (!dir) return undefined;
  let real: string;
  try {
    real = fs.realpathSync(dir);
  } catch {
    return undefined;
  }
  const lexical = inside(dir, top);
  if (!lexical && !inside(real, top)) return undefined;
  const tracked = trackedNodeModules(top, reads);
  if ('problem' in tracked) return tracked;
  // A link git tracks on the way (node_modules/zod -> elsewhere) is the
  // repo's say of where the package is: the repo's own, so not followed.
  if (lexical) {
    for (let d = dir; inside(d, top) && d !== top; d = path.dirname(d)) {
      if (tracked.links.has(d)) return { problem: `${path.relative(top, d)} is a link the repo commits, so where ${spec} loads from is the repo's to change, and patch trust doesn't follow links in node_modules.` };
    }
  }
  if (tracked.files.size > MAX_TRACKED_PACKAGE_FILES) return { problem: `the repo commits ${tracked.files.size} files under node_modules, more than the ${MAX_TRACKED_PACKAGE_FILES} patch trust follows.` };
  for (const f of tracked.files) {
    if (tracked.links.has(f)) return { problem: `${path.relative(top, f)} is a link the repo commits under node_modules, which patch trust doesn't follow.` };
    if (f.endsWith('.node')) return { problem: `${path.relative(top, f)} is a native addon the repo commits, which patch trust can't read.` };
  }
  return { files: [...tracked.files].sort() };
}
