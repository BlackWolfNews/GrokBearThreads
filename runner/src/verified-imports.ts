// Imports a trusted project patch from the bytes its trust hash was made
// from, never from the folder as it is by then (docs/protocol.md,
// "Trusting a folder's patches"). Checking a patch's hash and then
// importing its path left a gap: a command that rewrote the patch, or a
// helper it imports, between the two ran unhashed code under the earlier
// yes (Codex review, 5 Nov).
//
// So the loader gets the patch's import graph as the bytes patchHash read
// (patch-trust.ts, `code`), and Node's module hooks serve those bytes for
// those files. A module served that way may import only another such file,
// a package (node_modules) or a builtin: a local import that resolves to
// anything else (a helper retargeted, a file the hash never saw) throws,
// and the patch doesn't load. The files keep their own paths, so
// `import.meta.url` and relative imports mean what they did.
import fs from 'node:fs';
import { registerHooks } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';

// Module URL (with the patch file's ?v= query, or a helper's plain URL)
// to the bytes to serve for it.
const sources = new Map<string, Buffer>();
let installed = false;

const plain = (url: string) => url.replace(/[?#].*$/, '');

// The URL to import a trusted patch at, after noting its code. `root` is
// the patch file's real path, `hash` its trust hash (so a new version is
// a new module), `code` its import graph by real path.
export function verifiedUrl(root: string, hash: string, code: Map<string, Buffer>): string {
  install();
  const url = `${pathToFileURL(root).href}?v=${hash}`;
  for (const [file, bytes] of code) {
    const href = pathToFileURL(file).href;
    // A helper is a module once per process (as before): the first
    // verified version noted is the one Node loads.
    if (file === root) sources.set(url, bytes);
    else sources.set(href, bytes);
  }
  // The patch file's plain URL too, so a helper importing it back is
  // served (and allowed).
  if (!sources.has(pathToFileURL(root).href)) sources.set(pathToFileURL(root).href, code.get(root)!);
  return url;
}

function served(url: string): Buffer | undefined {
  return sources.get(url) ?? sources.get(plain(url));
}

function isPackage(url: string): boolean {
  return /\/node_modules\//.test(fileURLToPath(plain(url)));
}

function install(): void {
  if (installed) return;
  installed = true;
  registerHooks({
    resolve(specifier, context, nextResolve) {
      const out = nextResolve(specifier, context);
      const parent = context.parentURL;
      if (parent && served(parent) && out.url.startsWith('file:') && !served(out.url) && !isPackage(out.url)) {
        throw new Error(`${fileURLToPath(plain(parent))} imports ${fileURLToPath(plain(out.url))}, which patch trust didn't hash (it changed or moved since): not loaded.`);
      }
      return out;
    },
    load(url, context, nextLoad) {
      const bytes = url.startsWith('file:') ? served(url) : undefined;
      if (!bytes) return nextLoad(url, context);
      // The format as Node would take it (from the extension and the
      // package.json); the source is the hashed bytes, whatever the
      // file holds now.
      // Only a plain file is read for that (a fifo put there would hang).
      if (!fs.statSync(fileURLToPath(plain(url))).isFile()) throw new Error(`${fileURLToPath(plain(url))} isn't a file now: not loaded.`);
      const out = nextLoad(url, context);
      return { ...out, source: bytes, shortCircuit: true };
    },
  });
}
