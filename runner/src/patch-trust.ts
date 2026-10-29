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
// Only the patch file's own text is hashed. A patch that imports a helper
// from elsewhere in the repo isn't asked about again when the helper
// changes; worth knowing, not worth the complexity yet.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { atomicWriteFileSync } from './fsutil.ts';

export type TrustVerdict = { trusted: true } | { trusted: false; reason: 'new' | 'changed'; hash: string };

// Hashes kept per folder: enough for a repo's patches across a few
// branches and versions, without the file growing for ever.
export const HASHES_KEPT = 200;

type TrustFile = { version: 1; folders: Record<string, string[]> };

export interface PatchGate {
  // Whether a project's patch file may load. `mtimeMs` keys the hash cache.
  check(file: string, mtimeMs: number): Promise<TrustVerdict>;
}

// What the runner keeps: the gate, and the ways in.
export interface PatchTrustStore extends PatchGate {
  readonly existed: boolean;
  trust(file: string, hash: string): boolean;
  trustCurrent(files: string[]): string[];
  save(): void;
}

// Lets every file through: tests that aren't about trust, and `tb land`
// reading the worktree check it was asked to run.
export const TRUST_ALL: PatchTrustStore = {
  existed: true,
  check: async () => ({ trusted: true }),
  trust: () => true,
  trustCurrent: (files) => files,
  save: () => {},
};

export class PatchTrust implements PatchTrustStore {
  private file?: string;
  private folders = new Map<string, string[]>();
  private always: string[];
  private hashes = new Map<string, { mtimeMs: number; hash: string }>();
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
    const hash = await this.hashOf(file, mtimeMs);
    const known = this.folders.get(key);
    if (known?.includes(hash)) return { trusted: true };
    return { trusted: false, reason: known?.length ? 'changed' : 'new', hash };
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
      let text: Buffer;
      try {
        text = fs.readFileSync(file);
      } catch {
        continue;
      }
      const key = folderKey(file);
      byKey.set(key, [...(byKey.get(key) ?? []), sha256(text)]);
      done.push(file);
    }
    for (const [key, hashes] of byKey) this.add(key, hashes, false);
    if (byKey.size) this.save();
    return done;
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
    const out: TrustFile = { version: 1, folders: Object.fromEntries(this.folders) };
    atomicWriteFileSync(this.file, JSON.stringify(out, null, 2) + '\n');
    this.loadedMtime = fs.statSync(this.file).mtimeMs;
  }

  private async hashOf(file: string, mtimeMs: number): Promise<string> {
    const hit = this.hashes.get(file);
    if (hit && hit.mtimeMs === mtimeMs) return hit.hash;
    const hash = sha256(await fs.promises.readFile(file));
    this.hashes.set(file, { mtimeMs, hash });
    return hash;
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
