// The pictures in a shared thread's events (docs/website.md, "Sharing"),
// which the mirror uploads to file storage so the shared page can show
// them. Only for shared threads: the rest keep their pictures on the Mac.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import type { PersistedEvent } from './protocol.ts';
import { absolute } from './highlights.ts';
import { sniffImage, sniffVideo } from './media.ts';

// A picture bigger than this stays on the Mac.
export const SHARE_IMAGE_BYTES = 10 * 1024 * 1024;

export type ShareImage = {
  seq: number;
  path: string; // the file on this Mac
  src?: string; // as the agent wrote it in Markdown, for the page to swap
  mediaType: string;
  width?: number;
  height?: number;
};

const TYPES: Record<string, string> = {
  png: 'image/png',
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  gif: 'image/gif',
  webp: 'image/webp',
};

// The media type a browser can show for a file name, or undefined.
export function imageType(file: string): string | undefined {
  const ext = file.toLowerCase().match(/\.([a-z0-9]+)$/)?.[1];
  return ext ? TYPES[ext] : undefined;
}

// What the phone can play as well as show (reply pictures only: a shared
// page draws its pictures with <img>).
function replyMediaType(file: string): string | undefined {
  return imageType(file) ?? (/\.(mp4|m4v|mov)$/i.test(file) ? 'video/mp4' : undefined);
}

// A Markdown image's address as a file on this Mac: an absolute path, a
// file:// URL or a ~ path. Undefined for a web address or anything else.
export function localImagePath(src: string, home = os.homedir(), typeOf = imageType): string | undefined {
  let p = src.trim();
  if (p.startsWith('file://')) {
    try {
      p = decodeURIComponent(new URL(p).pathname);
    } catch {
      return undefined;
    }
  } else if (p.startsWith('~/')) p = home + p.slice(1);
  if (!p.startsWith('/') || p.includes('\0')) return undefined;
  return typeOf(p) ? p : undefined;
}

// ![alt](src) and ![alt](<src> "title"), as CommonMark writes them.
const MARKDOWN_IMAGE = /!\[[^\]]*\]\(\s*(?:<([^>\n]+)>|([^)\s]+))(?:\s+"[^"]*")?\s*\)/g;

export function markdownImages(text: string, home = os.homedir(), typeOf = imageType): { src: string; path: string }[] {
  const out: { src: string; path: string }[] = [];
  for (const m of text.matchAll(MARKDOWN_IMAGE)) {
    const src = (m[1] ?? m[2])!;
    const p = localImagePath(src, home, typeOf);
    if (p && !out.some((x) => x.src === src)) out.push({ src, path: p });
  }
  return out;
}

// What one event shows: a message's attachments, what a tool handed back
// (a screenshot, an image it read or made), and pictures the agent put in
// its text by path.
export function imagesInEvent(e: PersistedEvent, home = os.homedir()): ShareImage[] {
  if (e.type === 'user.message' || e.type === 'tool.result') {
    return (e.images ?? []).map((i) => ({
      seq: e.seq,
      path: i.path,
      mediaType: i.mediaType,
      ...(i.width ? { width: i.width } : {}),
      ...(i.height ? { height: i.height } : {}),
    }));
  }
  if (e.type === 'assistant.text') {
    return markdownImages(e.text, home).map(({ src, path }) => ({ seq: e.seq, path, src, mediaType: imageType(path)! }));
  }
  return [];
}

// A file's bytes, at most SHARE_IMAGE_BYTES, or why not.
function readCapped(file: string): { bytes: Uint8Array } | { skip: string } {
  let size: number;
  try {
    size = fs.statSync(file).size;
  } catch {
    return { skip: 'the file is gone' };
  }
  if (size > SHARE_IMAGE_BYTES) return { skip: `it's ${Math.round(size / 1024 / 1024)} MB` };
  return { bytes: new Uint8Array(fs.readFileSync(file)) };
}

// Where a shared thread's pictures may come from: its media folder in the
// data dir (where attachments and tool pictures are copied), and its own
// folder for pictures made there since the thread started (`since`, its
// creation time from the runner's records), which is what the agent drew,
// shot or exported. A picture that was in the folder before is the folder's
// own, and Markdown naming one would publish it (Daybreak verify-fix,
// 5 Nov), so it shows its caption. Not the temp folders, though agents save
// screenshots there: they hold every app's, so any picture there was one
// Markdown line from a public page.
export type ShareRoot = { dir: string; since?: number };

export function shareRoots(cwd: string | undefined, mediaDir: string | undefined, startedAt: string | undefined): ShareRoot[] {
  const roots: ShareRoot[] = [];
  if (mediaDir) roots.push({ dir: mediaDir });
  // No start time to go by: nothing from the folder.
  const since = startedAt ? Date.parse(startedAt) : NaN;
  if (cwd && Number.isFinite(since)) roots.push({ dir: cwd, since });
  return roots;
}

function under(file: string, dir: string): boolean {
  const rel = path.relative(dir, file);
  return rel === '' || (rel !== '..' && !rel.startsWith('..' + path.sep) && !path.isAbsolute(rel));
}

function realOr(p: string): string {
  try {
    return fs.realpathSync(p);
  } catch {
    return p;
  }
}

const OUTSIDE = "it isn't in the thread's folder or its media";
const BEFORE = "it was in the thread's folder before the thread started, so it isn't the agent's";

// The bytes of a shared thread's picture and what they really are, or why
// not. It goes to a public page, so: a file under one of `roots` (by its
// real path too, so a folder link can't lead out), new enough for that
// root, not itself a link, and really a picture whatever its name says.
// The type comes from the bytes. Read through one descriptor opened
// without following a link, and checked to be the file at the real path,
// so nothing can be swapped in between the checks and the read.
export function readShareImage(file: string, roots: ShareRoot[]): { bytes: Uint8Array; mediaType: string; width?: number; height?: number } | { skip: string } {
  const abs = path.resolve(file);
  const holding = roots.filter((r) => under(abs, r.dir) || under(abs, realOr(r.dir)));
  if (!holding.length) return { skip: OUTSIDE };
  let st: fs.Stats;
  try {
    st = fs.lstatSync(abs);
  } catch {
    return { skip: 'the file is gone' };
  }
  if (st.isSymbolicLink()) return { skip: "it's a link" };
  if (!st.isFile()) return { skip: "it can't be read" };
  const real = realOr(abs);
  const inside = holding.filter((r) => under(real, realOr(r.dir)));
  if (!inside.length) return { skip: OUTSIDE };
  let fd: number;
  try {
    fd = fs.openSync(abs, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  } catch (e) {
    return { skip: (e as NodeJS.ErrnoException).code === 'ELOOP' ? "it's a link" : "it can't be read" };
  }
  try {
    const open = fs.fstatSync(fd);
    let atReal: fs.Stats;
    try {
      atReal = fs.statSync(real);
    } catch {
      return { skip: 'the file is gone' };
    }
    if (!open.isFile() || open.ino !== atReal.ino || open.dev !== atReal.dev) return { skip: "it can't be read" };
    // The media folder's are always the thread's; the thread folder's only
    // when written since the thread started.
    if (!inside.some((r) => r.since === undefined || open.mtimeMs >= r.since)) return { skip: BEFORE };
    if (open.size > SHARE_IMAGE_BYTES) return { skip: `it's ${Math.round(open.size / 1024 / 1024)} MB` };
    const bytes = Buffer.alloc(open.size);
    let got = 0;
    while (got < bytes.length) {
      const n = fs.readSync(fd, bytes, got, bytes.length - got, got);
      if (n === 0) break;
      got += n;
    }
    // Pictures only: the page draws them with <img>.
    const info = sniffImage(bytes.subarray(0, got));
    if (!info) return { skip: "it isn't a picture" };
    return { bytes: new Uint8Array(bytes.subarray(0, got)), mediaType: info.mediaType, ...(info.width ? { width: info.width } : {}), ...(info.height ? { height: info.height } : {}) };
  } catch {
    return { skip: "it can't be read" };
  } finally {
    fs.closeSync(fd);
  }
}

// What the phone shows of any thread, shared or not (backend API 24,
// docs/convex-backend.md): what the agent put in front of Mike on purpose,
// a picture or video in its reply, or one it pinned. Attachments and what
// tools hand back stay on the Mac, as they're many and big. The file goes as
// it is, so a GIF keeps its frames; the phone shrinks only what it draws.
export type ReplyImage = {
  seq: number;
  path: string; // the file on this Mac
  src?: string; // as the agent wrote it in Markdown, for the phone to swap
  pinned?: true; // the `pin` tool's, which goes under the turn's reply
};

export const PIN_TOOL = 'mcp__threadbear__pin';

export function replyImagesInEvent(e: PersistedEvent, cwd: string | undefined, home = os.homedir()): ReplyImage[] {
  if (e.type === 'assistant.text') return markdownImages(e.text, home, replyMediaType).map(({ src, path }) => ({ seq: e.seq, path, src }));
  if (e.type !== 'tool.call' || e.name !== PIN_TOOL || typeof e.input.path !== 'string') return [];
  // The pin tool takes a path relative to the thread's folder.
  const raw = e.input.path.trim();
  if (!raw || (!raw.startsWith('/') && !raw.startsWith('~') && !cwd)) return [];
  const file = absolute(raw, cwd ?? '/', home);
  return replyMediaType(file) ? [{ seq: e.seq, path: file, pinned: true }] : [];
}

// The bytes to upload and what they really are, or why not. An agent can
// write any path with a .png on the end, so the file has to be a picture or
// a video.
export function readReplyImage(file: string): { bytes: Uint8Array; mediaType: string; width?: number; height?: number } | { skip: string } {
  let read: ReturnType<typeof readCapped>;
  try {
    read = readCapped(file);
  } catch {
    return { skip: "it can't be read" };
  }
  if ('skip' in read) return read;
  const buf = Buffer.from(read.bytes);
  const info = sniffImage(buf) ?? sniffVideo(buf);
  if (!info) return { skip: "it isn't a picture" };
  return { bytes: read.bytes, mediaType: info.mediaType, ...(info.width ? { width: info.width } : {}), ...(info.height ? { height: info.height } : {}) };
}
