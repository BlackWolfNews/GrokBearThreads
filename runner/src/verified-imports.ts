// Imports a trusted project patch from the bytes its trust hash was made
// from, never from the folder as it is by then (docs/protocol.md,
// "Trusting a folder's patches"). Checking a patch's hash and then
// importing its path left a gap: a command that rewrote the patch, or a
// helper it imports, between the two ran unhashed code under the earlier
// yes (Codex review, 5 Nov).
//
// So the loader gets the patch's import graph as the bytes patchHash read
// (patch-trust.ts, `code`) and where each local import led (`edges`), and
// Node's module hooks serve exactly that. What an import from one of those
// files may load is decided by how it's written, not where it resolves to
// now:
//   - a local one (`./x`, `../x`, `/x`, `file:`) loads the very file the
//     hash followed it to, from the hashed bytes, without resolving it
//     again: a symlink retargeted since, even into node_modules, changes
//     nothing (Codex's second review, 5 Nov). One the hash didn't follow
//     refuses the patch.
//   - a bare one (a package, `node:fs`) resolves as Node resolves it,
//     wherever that is (a workspace package under packages/ too):
//     packages aren't hashed, by design.
// The files keep their own paths, so `import.meta.url` means what it did.
import fs from 'node:fs';
import { registerHooks } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';

// Module URL (the patch file's with its ?v= query, a helper's plain) to
// the bytes to serve for it.
const sources = new Map<string, Buffer>();
// A served module's plain URL to its local specifiers' targets (URLs).
const edges = new Map<string, Map<string, string>>();
let installed = false;

const plain = (url: string) => url.replace(/[?#].*$/, '');

// The URL to import a trusted patch at, after noting its code. `root` is
// the patch file's real path, `hash` its trust hash (so a new version is
// a new module), `code` its import graph by real path, `links` each of
// those files' local specifiers to the real path the hash followed.
export function verifiedUrl(root: string, hash: string, code: Map<string, Buffer>, links: Map<string, Map<string, string>>): string {
  install();
  const url = `${pathToFileURL(root).href}?v=${hash}`;
  for (const [file, bytes] of code) {
    // A helper is a module once per process (as before): the first
    // verified version noted is the one Node loads.
    sources.set(file === root ? url : pathToFileURL(file).href, bytes);
  }
  // The patch file's plain URL too, so a helper importing it back is
  // served the hashed bytes.
  if (!sources.has(pathToFileURL(root).href)) sources.set(pathToFileURL(root).href, code.get(root)!);
  for (const [from, specs] of links) {
    const to = new Map([...specs].map(([spec, target]) => [spec, pathToFileURL(target).href]));
    edges.set(pathToFileURL(from).href, to);
  }
  return url;
}

function served(url: string): Buffer | undefined {
  return sources.get(url) ?? sources.get(plain(url));
}

// How a specifier is written: local (a path or file: URL) or bare.
export function isLocalSpecifier(specifier: string): boolean {
  return /^\.{1,2}(\/|$)|^\//.test(specifier) || specifier.startsWith('file:');
}

function install(): void {
  if (installed) return;
  installed = true;
  registerHooks({
    resolve(specifier, context, nextResolve) {
      const parent = context.parentURL;
      if (!parent || !served(parent) || !isLocalSpecifier(specifier)) return nextResolve(specifier, context);
      const key = specifier.startsWith('file:') ? fileURLToPath(specifier) : specifier;
      const target = edges.get(plain(parent))?.get(key);
      const from = fileURLToPath(plain(parent));
      if (!target || !served(target)) throw new Error(`${from} imports ${specifier}, which patch trust didn't hash: not loaded.`);
      return { url: target, format: undefined, shortCircuit: true };
    },
    load(url, context, nextLoad) {
      const bytes = url.startsWith('file:') ? served(url) : undefined;
      if (!bytes) return nextLoad(url, context);
      // The format as Node would take it (from the extension and the
      // package.json); the source is the hashed bytes, whatever the
      // file holds now. Only a plain file is read for that (a fifo put
      // there would hang).
      if (!fs.statSync(fileURLToPath(plain(url))).isFile()) throw new Error(`${fileURLToPath(plain(url))} isn't a file now: not loaded.`);
      const out = nextLoad(url, context);
      return { ...out, source: bytes, shortCircuit: true };
    },
  });
}
