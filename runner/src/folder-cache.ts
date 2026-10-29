// What patch discovery (patches.ts) reads from disk: folder listings,
// patch files' modified times and .env files, kept for a few seconds and
// shared by every thread.
//
// Every thread's patches are read again every 15 seconds, walking up from
// its folder to home and listing each folder on the way. Mike has a couple
// of hundred threads in a few dozen folders, so the same folders were
// listed over and over, synchronously: on a Mac busy rendering or backing
// up, that froze the runner for seconds at a time and every click in the
// app waited. Now a folder is listed once per few seconds whoever asks, and
// loadPatchSet fills the cache asynchronously (warm) before its synchronous
// walk, so the walk reads memory rather than the disk.
//
// The synchronous methods read the disk themselves on a miss, so anything
// that skips warm still works, just as before.
import fs from 'node:fs';
import path from 'node:path';

export type EntryKind = 'dir' | 'file' | 'other';
// name -> kind; null when the folder couldn't be listed.
type Listing = Map<string, EntryKind> | null;
type Entry<T> = { at: number; value: T };

export class FolderCache {
  private listings = new Map<string, Entry<Listing>>();
  private kinds = new Map<string, Entry<EntryKind | undefined>>();
  private mtimes = new Map<string, Entry<number | undefined>>();
  private texts = new Map<string, Entry<string | undefined>>();
  private loading = new Map<string, Promise<unknown>>();
  private ttlMs: number;
  private now: () => number;

  // ttlMs: how long anything read is trusted. The default, forever, suits
  // a cache made for one call (the patches.ts functions' default); the
  // runner keeps one with a few seconds.
  constructor(ttlMs = Infinity, now: () => number = Date.now) {
    this.ttlMs = ttlMs;
    this.now = now;
  }

  // Forgets everything: the next reads go to the disk.
  clear(): void {
    this.listings.clear();
    this.kinds.clear();
    this.mtimes.clear();
    this.texts.clear();
  }

  // The names in a folder; empty when it can't be listed.
  names(dir: string): string[] {
    return [...(this.listing(dir)?.keys() ?? [])];
  }

  // What's at a path: a folder, a file, something else, or nothing.
  // Answered from the parent's listing where there is one, so checking
  // for convex/, package.json and .threadbear/ in a folder is one listing.
  kind(p: string): EntryKind | undefined {
    // A folder with no .threadbear has no .threadbear/patches either: no
    // need to try listing a folder already known not to be there.
    if (this.knownNotAFolder(path.dirname(p))) return undefined;
    const parent = this.listing(path.dirname(p));
    if (parent) return parent.get(path.basename(p));
    return this.cached(this.kinds, p, () => statKind(p));
  }

  isDir(p: string): boolean {
    return this.kind(p) === 'dir';
  }

  exists(p: string): boolean {
    return this.kind(p) !== undefined;
  }

  mtimeMs(file: string): number | undefined {
    return this.cached(this.mtimes, file, () => {
      try {
        return fs.statSync(file).mtimeMs;
      } catch {
        return undefined;
      }
    });
  }

  // A small text file (a .env); undefined when it can't be read.
  text(file: string): string | undefined {
    return this.cached(this.texts, file, () => {
      try {
        return fs.readFileSync(file, 'utf8');
      } catch {
        return undefined;
      }
    });
  }

  // Lists these folders off the event loop, at most once each however many
  // ask at the same time.
  async warmFolders(dirs: Iterable<string>): Promise<void> {
    await Promise.all([...new Set(dirs)].map((d) => this.load(this.listings, 'l:', d, () => readListing(d))));
  }

  async warmMtimes(files: Iterable<string>): Promise<void> {
    await Promise.all(
      [...new Set(files)].map((f) =>
        this.load(this.mtimes, 'm:', f, () =>
          fs.promises.stat(f).then(
            (s) => s.mtimeMs,
            () => undefined,
          ),
        ),
      ),
    );
  }

  async warmTexts(files: Iterable<string>): Promise<void> {
    await Promise.all(
      [...new Set(files)].map((f) =>
        this.load(this.texts, 't:', f, () =>
          fs.promises.readFile(f, 'utf8').then(
            (t) => t,
            () => undefined,
          ),
        ),
      ),
    );
  }

  // From a cached listing of its parent alone, never the disk.
  private knownNotAFolder(dir: string): boolean {
    const up = path.dirname(dir);
    if (up === dir) return false;
    const parent = this.listings.get(up);
    return this.fresh(parent) && parent.value !== null && parent.value.get(path.basename(dir)) !== 'dir';
  }

  private listing(dir: string): Listing {
    return this.cached(this.listings, dir, () => readListingSync(dir));
  }

  private fresh<T>(entry: Entry<T> | undefined): entry is Entry<T> {
    return entry !== undefined && this.now() - entry.at < this.ttlMs;
  }

  private cached<T>(map: Map<string, Entry<T>>, key: string, read: () => T): T {
    const hit = map.get(key);
    if (this.fresh(hit)) return hit.value;
    const value = read();
    map.set(key, { at: this.now(), value });
    return value;
  }

  private async load<T>(map: Map<string, Entry<T>>, prefix: string, key: string, read: () => Promise<T>): Promise<void> {
    if (this.fresh(map.get(key))) return;
    const id = prefix + key;
    let pending = this.loading.get(id) as Promise<T> | undefined;
    if (!pending) {
      pending = read();
      this.loading.set(id, pending);
    }
    try {
      const value = await pending;
      map.set(key, { at: this.now(), value });
    } finally {
      this.loading.delete(id);
    }
  }
}

function statKind(p: string): EntryKind | undefined {
  try {
    const s = fs.statSync(p);
    return s.isDirectory() ? 'dir' : s.isFile() ? 'file' : 'other';
  } catch {
    return undefined;
  }
}

// A symlink is listed as what it points to (a linked folder is a folder),
// and a broken one not at all, as stat would say.
function readListingSync(dir: string): Listing {
  let entries: fs.Dirent[];
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return null;
  }
  const out = new Map<string, EntryKind>();
  for (const e of entries) {
    const kind = e.isSymbolicLink() ? statKind(path.join(dir, e.name)) : direntKind(e);
    if (kind) out.set(e.name, kind);
  }
  return out;
}

async function readListing(dir: string): Promise<Listing> {
  let entries: fs.Dirent[];
  try {
    entries = await fs.promises.readdir(dir, { withFileTypes: true });
  } catch {
    return null;
  }
  const out = new Map<string, EntryKind>();
  await Promise.all(
    entries.map(async (e) => {
      let kind: EntryKind | undefined = direntKind(e);
      if (e.isSymbolicLink()) {
        kind = await fs.promises.stat(path.join(dir, e.name)).then(
          (s) => (s.isDirectory() ? 'dir' : s.isFile() ? 'file' : 'other'),
          () => undefined,
        );
      }
      if (kind) out.set(e.name, kind);
    }),
  );
  // Same order as readdir gave, whatever order the stats came back in.
  return new Map(entries.filter((e) => out.has(e.name)).map((e) => [e.name, out.get(e.name)!]));
}

function direntKind(e: fs.Dirent): EntryKind {
  return e.isDirectory() ? 'dir' : e.isFile() ? 'file' : 'other';
}
