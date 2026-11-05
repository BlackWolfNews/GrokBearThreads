// Which patch files the runner may load (docs/protocol.md, "Trusting a
// folder's patches").
//
// A patch file is code: the runner imports it, and its hooks, live
// functions and worktree setup run by themselves. Without a gate, opening a
// thread in a repo someone else wrote would run that repo's code before
// you'd sent a word. So a project's patch file only loads once you've
// trusted it, the way VS Code and Claude Code ask before running a
// folder's code.
//
// Trust is kept per folder (the one holding `.threadbear/`) as the hashes
// of the patch files you said yes to. A file whose content you haven't
// trusted waits: "new" when nothing in that folder has been trusted yet,
// "changed" when something has (a git pull brought a new version). A
// patch file a thread's agent writes with Edit or Write is trusted as it
// stands, as that agent could already run anything in the folder, and
// asking about every button you ask for would be noise.
//
// A git worktree counts as its main checkout, so a thread's worktree of a
// trusted repo isn't asked about again. Only a worktree git itself made
// counts: the worktree's .git file and the repo's record of it must point
// at each other, so a folder can't claim to be a worktree of a trusted repo.
//
// Always trusted: ~/.threadbear/patches (yours, like ~/.zshrc) and
// Threadbear's own checkout (the code that's already running you).
//
// What's hashed is the patch file and every local file it imports, and
// theirs in turn (relative or absolute specifiers: `./lib/ask.ts`), so a
// pull that changes only a helper is asked about too. Files it names in a
// `./` or `../` path (the script its worktree setup or an action runs) are
// hashed as well, as they run by themselves too. A patch with no local
// files hashes as its own text alone, as it did before helpers counted.
// Packages (`node:fs`, `zod`) aren't followed: they're the folder's
// dependencies, as `npm install` put them there, and hashing node_modules
// every 15 seconds would be slow and re-ask after every install.
//
// The hash is only worth anything if it covers what will run. A patch that
// loads code by a name worked out when it runs (`import(name)`,
// `createRequire`), or reaches more files than are followed, can't be
// checked, so it isn't loaded at all, trusted or not: its `error` says why.
// Saying yes to it would trust whatever that name points at later.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { atomicWriteFileSync } from './fsutil.ts';

export type TrustVerdict =
  | { trusted: true }
  | { trusted: false; reason: 'new' | 'changed'; hash: string; helpers?: string[] }
  // Nothing can trust it as it stands (see the top): `problem` says why.
  | { trusted: false; reason: 'unchecked'; problem: string };

// Hashes kept per folder: enough for a repo's patches across a few
// branches and versions, without the file growing for ever.
export const HASHES_KEPT = 200;

// Version 1 hashed patch files alone. Its hashes are read as they are: one
// for a patch with no helpers is the same in both, and one for a patch
// with helpers matches nothing now, so it's asked about again. (A first
// look used to take such a patch's helpers as trusted, but version 1 never
// saw them, so that trusted whatever a pull had put there: Daybreak, 5 Nov.)
// A `legacy` list a runner from then wrote is ignored, and goes on the next save.
type TrustFile = { version: 1 | 2; folders: Record<string, string[]> };

// At most this many local files are followed from one patch file; one that
// reaches more can't be checked.
export const MAX_HELPERS = 100;

export interface PatchGate {
  // Whether a project's patch file may load. `mtimeMs` keys the hash cache.
  check(file: string, mtimeMs: number): Promise<TrustVerdict>;
}

// What the runner keeps: the gate, and the ways in.
export interface PatchTrustStore extends PatchGate {
  readonly existed: boolean;
  trust(file: string, hash: string): boolean;
  trustCurrent(files: string[]): string[];
  // Trusts, as they are now, the patch files that import `file` (an agent
  // edited a helper). Only patches already looked at are known.
  trustDependents(file: string): string[];
  save(): void;
}

// Lets every file through: tests that aren't about trust, and `tb land`
// reading the worktree check it was asked to run.
export const TRUST_ALL: PatchTrustStore = {
  existed: true,
  check: async () => ({ trusted: true }),
  trust: () => true,
  trustCurrent: (files) => files,
  trustDependents: () => [],
  save: () => {},
};

export class PatchTrust implements PatchTrustStore {
  private file?: string;
  private folders = new Map<string, string[]>();
  private always: string[];
  // `trusted`: some version of this patch was trusted while this runner
  // has run, so an agent's edit to one of its helpers may carry it on.
  private hashes = new Map<string, HashEntry>();
  // Whether there was a trust file when this started. A runner from before
  // trust existed has none, and seeds it from what it was already running.
  readonly existed: boolean;

  // `file` undefined keeps it in memory (tests). `always` are folders whose
  // patches are trusted whatever they hold.
  constructor(opts: { file?: string; always?: string[] } = {}) {
    this.file = opts.file;
    this.always = (opts.always ?? []).map((d) => realpath(path.resolve(d)));
    this.existed = this.load() !== 'missing';
  }

  // Reads the file again when another runner (one finishing turns after a
  // handover) has written it since. A missing file is a first start; an
  // unreadable one trusts nothing, and isn't seeded over: a broken file
  // shouldn't quietly trust everything.
  private loadedMtime?: number;
  private load(): 'missing' | 'read' | 'same' | 'broken' {
    if (!this.file) return 'missing';
    let mtimeMs: number;
    try {
      mtimeMs = fs.statSync(this.file).mtimeMs;
    } catch {
      return 'missing';
    }
    if (mtimeMs === this.loadedMtime) return 'same';
    this.loadedMtime = mtimeMs;
    try {
      const raw = JSON.parse(fs.readFileSync(this.file, 'utf8')) as Partial<TrustFile>;
      this.folders.clear();
      for (const [key, list] of Object.entries(raw.folders ?? {})) {
        if (Array.isArray(list)) this.folders.set(key, list.filter((h): h is string => typeof h === 'string'));
      }
      return 'read';
    } catch {
      return 'broken';
    }
  }

  async check(file: string, mtimeMs: number): Promise<TrustVerdict> {
    this.load();
    const key = folderKey(file);
    if (this.always.some((d) => isInside(key, d))) return { trusted: true };
    const entry = this.hashOf(file, mtimeMs);
    const { hash, deps } = entry;
    // Before the hash: a stored yes can't vouch for code the hash didn't see.
    if (entry.incomplete) return { trusted: false, reason: 'unchecked', problem: entry.incomplete };
    const known = this.folders.get(key);
    if (known?.includes(hash)) {
      entry.trusted = true;
      return { trusted: true };
    }
    const helpers = deps.map((d) => d.path);
    return { trusted: false, reason: known?.length ? 'changed' : 'new', hash, ...(helpers.length ? { helpers } : {}) };
  }

  // Trusts one version of a patch file, by the hash the app showed. False
  // when the file isn't a patch file.
  trust(file: string, hash: string): boolean {
    if (!isPatchFile(file) || !/^[0-9a-f]{64}$/.test(hash)) return false;
    this.add(folderKey(file), [hash]);
    return true;
  }

  // Trusts patch files as they are on disk now: an agent's own edits and
  // the first start's seeding. Files that can't be read are skipped.
  trustCurrent(files: string[]): string[] {
    const done: string[] = [];
    const byKey = new Map<string, string[]>();
    for (const file of files) {
      if (!isPatchFile(file)) continue;
      let hash: string;
      try {
        const entry = this.hashOf(file, fs.statSync(file).mtimeMs);
        // check() refuses it whatever's stored, so storing it would only
        // say it was trusted when it isn't.
        if (entry.incomplete) continue;
        entry.trusted = true;
        hash = entry.hash;
      } catch {
        continue;
      }
      const key = folderKey(file);
      byKey.set(key, [...(byKey.get(key) ?? []), hash]);
      done.push(file);
    }
    for (const [key, hashes] of byKey) this.add(key, hashes, false);
    if (byKey.size) this.save();
    return done;
  }

  // Only patches trusted before: editing a helper isn't a way to trust a
  // patch that's still waiting.
  trustDependents(file: string): string[] {
    const target = realpath(path.resolve(file));
    const dependents = [...this.hashes].filter(([, h]) => h.trusted && h.deps.some((d) => d.path === target)).map(([f]) => f);
    return dependents.length ? this.trustCurrent(dependents) : [];
  }

  private add(key: string, hashes: string[], save = true): void {
    this.load();
    const list = (this.folders.get(key) ?? []).filter((h) => !hashes.includes(h));
    list.push(...hashes);
    this.folders.set(key, list.slice(-HASHES_KEPT));
    if (save) this.save();
  }

  // Writes the file; seeding writes it even when it found nothing, so the
  // next start doesn't seed again.
  save(): void {
    if (!this.file) return;
    const out: TrustFile = { version: 2, folders: Object.fromEntries(this.folders) };
    atomicWriteFileSync(this.file, JSON.stringify(out, null, 2) + '\n');
    this.loadedMtime = fs.statSync(this.file).mtimeMs;
  }

  // The patch's hash with its helpers'. Cached until the patch or one of
  // its helpers changes (a stat each; patches are read every 15 seconds).
  private hashOf(file: string, mtimeMs: number): HashEntry {
    const hit = this.hashes.get(file);
    if (hit && hit.mtimeMs === mtimeMs && hit.deps.every((d) => mtimeOf(d.path) === d.mtimeMs) && hit.unnamed.every((p) => mtimeOf(p) === undefined)) return hit;
    const entry = { mtimeMs, ...patchHash(file), trusted: hit?.trusted };
    this.hashes.set(file, entry);
    return entry;
  }
}

type Dep = { path: string; mtimeMs?: number };
type HashEntry = PatchHash & { mtimeMs: number; trusted?: boolean };

// `deps` are the local files hashed with it; `unnamed`, paths it names that
// aren't there (so one turning up changes the hash); `incomplete`, why the
// hash can't cover everything it loads, when it can't.
export type PatchHash = { hash: string; deps: Dep[]; unnamed: string[]; incomplete?: string };

// A patch file's hash: its own text's alone when it has no local files,
// else one over its text and each file's, by path relative to the patch
// (so a worktree and its main checkout agree). A helper it imports that's
// missing counts as missing, so adding it later changes the hash.
export function patchHash(file: string): PatchHash {
  const text = fs.readFileSync(file);
  const own = sha256(text);
  const root = realpath(path.resolve(file));
  // The folder holding `.threadbear/`: where its commands run (a thread's
  // folder, or the worktree's root for setup), so `./setup.sh` is there.
  const folder = path.dirname(path.dirname(path.dirname(root)));
  const seen = new Set([root]);
  const deps: Dep[] = [];
  const unnamed = new Set<string>();
  let incomplete: string | undefined;
  const add = (dep: Dep): boolean => {
    if (deps.length >= MAX_HELPERS) {
      incomplete ??= `patch trust follows at most ${MAX_HELPERS} local files, and this patch reaches more.`;
      return false;
    }
    deps.push(dep);
    return true;
  };
  const queue: { from: string; text: string }[] = [{ from: root, text: text.toString('utf8') }];
  scan: while (queue.length) {
    const { from, text: src } = queue.shift()!;
    const load = computedLoad(src);
    if (load && !incomplete) {
      const name = from === root ? path.basename(root) : path.relative(path.dirname(root), from);
      incomplete = `patch trust can't check what ${name} line ${load.line} loads (\`${load.code}\`). Import local files by a plain path, like './lib/x.ts', and it can.`;
    }
    for (const spec of localSpecifiers(src)) {
      const target = resolveHelper(path.dirname(from), spec);
      if (seen.has(target)) continue;
      seen.add(target);
      const mtimeMs = mtimeOf(target);
      if (!add({ path: target, mtimeMs })) break scan;
      if (mtimeMs !== undefined && SCANNED.includes(path.extname(target))) {
        try {
          queue.push({ from: target, text: fs.readFileSync(target, 'utf8') });
        } catch {
          // unreadable: hashed as missing below
        }
      }
    }
    // Named files are hashed as they are, not followed: a script is its own
    // program, run by a shell, and what it runs in turn is past what this
    // follows. Only from the two places a path is read from; a command that
    // `cd`s first isn't worked out.
    for (const spec of namedPaths(src)) {
      const tries = [path.resolve(path.dirname(from), spec), path.resolve(folder, spec)];
      const found = tries.find(isFile);
      if (!found) {
        for (const t of tries) unnamed.add(t);
        continue;
      }
      const target = realpath(found);
      if (seen.has(target)) continue;
      seen.add(target);
      if (!add({ path: target, mtimeMs: mtimeOf(target) })) break scan;
    }
  }
  const missing = [...unnamed];
  if (!deps.length) return { hash: own, deps, unnamed: missing, ...(incomplete ? { incomplete } : {}) };
  const dir = path.dirname(root);
  const lines = deps
    .map((d) => {
      let h = 'missing';
      try {
        h = sha256(fs.readFileSync(d.path));
      } catch {
        // stays missing
      }
      return `${path.relative(dir, d.path)} ${h}`;
    })
    .sort();
  return { hash: sha256(Buffer.from(['threadbear-patch-2', own, ...lines].join('\n'))), deps, unnamed: missing, ...(incomplete ? { incomplete } : {}) };
}

const SCANNED = ['.ts', '.mts', '.cts', '.js', '.mjs', '.cjs', '.tsx', '.jsx'];

// The local specifiers in a module's source: static and dynamic imports,
// re-exports and require calls whose specifier starts with ./, ../ or /.
// A regex rather than a parser: a match inside a comment or string only
// adds a file to the hash, which can't let anything through.
export function localSpecifiers(src: string): string[] {
  const out = new Set<string>();
  const re = /(?:\bfrom\s*|\bimport\s*\(?\s*|\brequire\s*\(\s*)(['"`])((?:\.{1,2}\/|\/)[^'"`\n]*)\1/g;
  for (let m; (m = re.exec(src)); ) out.add(m[2]);
  return [...out];
}

// The first place a module loads code by a name the scan can't read:
// `import(...)` or `require(...)` of anything but one plain string (a
// variable, a `${}` template, 'a' + b), and any `createRequire`, whose
// require can be called by any name. Also a regex: one in a comment or a
// string counts too, which only keeps a patch out, never lets one in.
// `x.import(...)` is a method, not a load; `module.require` is one.
export function computedLoad(src: string): { line: number; code: string } | undefined {
  const re = /(?<![\w$.])(?:import|require)\s*\(|\bmodule\s*\.\s*require\s*\(|\bcreateRequire\b/g;
  const plain = /^\s*(?:'[^'\\\n]*'|"[^"\\\n]*"|`[^`\\$]*`)\s*[,)]/;
  for (let m; (m = re.exec(src)); ) {
    const isCall = m[0].endsWith('(');
    if (isCall && plain.test(src.slice(m.index + m[0].length))) continue;
    const rest = src.slice(m.index).split('\n')[0];
    const close = rest.indexOf(')');
    const code = isCall ? (close >= 0 ? rest.slice(0, close + 1) : rest).slice(0, 80) : m[0];
    return { line: src.slice(0, m.index).split('\n').length, code };
  }
  return undefined;
}

// Paths a module names that start ./ or ../, anywhere: in a command
// (`setup: "./scripts/setup.sh --fast"`), an argument, a comment. Extra
// matches only add files to the hash. Pictures are left out: an icon is
// only ever shown, and redrawing one shouldn't ask about the patch again.
export function namedPaths(src: string): string[] {
  const out = new Set<string>();
  const re = /(?<![\w./\\-])\.\.?\/[^\s'"`;&|()<>{}[\],*?!$=\\]+/g;
  for (let m; (m = re.exec(src)); ) {
    const p = m[0].replace(/[.:]+$/, '');
    if (p.length > 2 && !PICTURES.includes(path.extname(p).toLowerCase())) out.add(p);
  }
  return [...out];
}

const PICTURES = ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg', '.icns', '.pdf', '.heic'];

function isFile(p: string): boolean {
  try {
    return fs.statSync(p).isFile();
  } catch {
    return false;
  }
}

// Where Node (or a bundler-ish habit) would find `spec`: as written, then
// with a script extension, then as a folder's index. As written when none
// is there, so it's hashed as missing.
function resolveHelper(dir: string, spec: string): string {
  const base = path.resolve(dir, spec.replace(/[?#].*$/, ''));
  const tries = [base, ...[...SCANNED, '.json'].map((e) => base + e), ...SCANNED.map((e) => path.join(base, 'index' + e))];
  for (const t of tries) {
    try {
      if (fs.statSync(t).isFile()) return realpath(t);
    } catch {
      // try the next
    }
  }
  return base;
}

function mtimeOf(file: string): number | undefined {
  try {
    return fs.statSync(file).mtimeMs;
  } catch {
    return undefined;
  }
}

function sha256(data: Buffer): string {
  return crypto.createHash('sha256').update(data).digest('hex');
}

// A file in some `.threadbear/patches/` folder with a patch's extension.
export function isPatchFile(file: string): boolean {
  const dir = path.dirname(path.resolve(file));
  return path.basename(dir) === 'patches' && path.basename(path.dirname(dir)) === '.threadbear' && ['.ts', '.js', '.mjs'].includes(path.extname(file));
}

function isInside(dir: string, parent: string): boolean {
  const rel = path.relative(parent, dir);
  return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel));
}

// The folder a patch file's trust is kept under: the one holding its
// `.threadbear/`, or, in a git worktree, the same place in the main checkout.
export function folderKey(file: string): string {
  // Real paths: git writes them into a worktree's .git file, and /tmp or
  // a symlinked ~/dev would otherwise be two folders.
  const folder = realpath(path.dirname(path.dirname(path.dirname(path.resolve(file)))));
  const top = worktreeTop(folder);
  if (!top) return folder;
  const main = mainCheckoutOf(top);
  return main ? path.join(realpath(main), path.relative(top, folder)) : folder;
}

function realpath(p: string): string {
  try {
    return fs.realpathSync(p);
  } catch {
    return p;
  }
}

// The nearest folder from `dir` up with a `.git`, when that `.git` is a
// file (a worktree's) rather than a folder.
function worktreeTop(dir: string): string | undefined {
  for (let d = dir; ; d = path.dirname(d)) {
    let st: fs.Stats | undefined;
    try {
      st = fs.statSync(path.join(d, '.git'));
    } catch {
      // none here
    }
    if (st) return st.isFile() ? d : undefined;
    if (path.dirname(d) === d) return undefined;
  }
}

// The worktree `dir` is in (its top folder) and that worktree's main
// checkout, both as real paths; undefined outside a worktree git made.
export function worktreeOf(dir: string): { top: string; main: string } | undefined {
  const top = worktreeTop(realpath(path.resolve(dir)));
  const main = top ? mainCheckoutOf(top) : undefined;
  return top && main ? { top, main: realpath(main) } : undefined;
}

// The main checkout a worktree belongs to, if git really made it: its .git
// file names `<repo>/.git/worktrees/<name>`, and that folder's `gitdir`
// names this worktree's .git back.
export function mainCheckoutOf(top: string): string | undefined {
  try {
    const dotGit = path.join(top, '.git');
    const m = /^gitdir:\s*(.+?)\s*$/m.exec(fs.readFileSync(dotGit, 'utf8'));
    if (!m) return undefined;
    const gitdir = path.resolve(top, m[1]);
    const back = path.resolve(gitdir, fs.readFileSync(path.join(gitdir, 'gitdir'), 'utf8').trim());
    if (fs.realpathSync(back) !== fs.realpathSync(dotGit)) return undefined;
    const common = path.resolve(gitdir, fs.readFileSync(path.join(gitdir, 'commondir'), 'utf8').trim());
    const name = path.relative(path.join(common, 'worktrees'), gitdir);
    if (path.basename(common) !== '.git' || !name || name.startsWith('..') || name.includes(path.sep)) return undefined;
    return path.dirname(common);
  } catch {
    return undefined;
  }
}
