// The pictures in a shared thread's events (docs/website.md, "Sharing"),
// which the mirror uploads to file storage so the shared page can show
// them. Only for shared threads: the rest keep their pictures on the Mac.
import fs from 'node:fs';
import os from 'node:os';
import type { PersistedEvent } from './protocol.ts';
import { absolute } from './highlights.ts';
import { sniffImage } from './media.ts';

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

// A Markdown image's address as a file on this Mac: an absolute path, a
// file:// URL or a ~ path. Undefined for a web address or anything else.
export function localImagePath(src: string, home = os.homedir()): string | undefined {
  let p = src.trim();
  if (p.startsWith('file://')) {
    try {
      p = decodeURIComponent(new URL(p).pathname);
    } catch {
      return undefined;
    }
  } else if (p.startsWith('~/')) p = home + p.slice(1);
  if (!p.startsWith('/') || p.includes('\0')) return undefined;
  return imageType(p) ? p : undefined;
}

// ![alt](src) and ![alt](<src> "title"), as CommonMark writes them.
const MARKDOWN_IMAGE = /!\[[^\]]*\]\(\s*(?:<([^>\n]+)>|([^)\s]+))(?:\s+"[^"]*")?\s*\)/g;

export function markdownImages(text: string, home = os.homedir()): { src: string; path: string }[] {
  const out: { src: string; path: string }[] = [];
  for (const m of text.matchAll(MARKDOWN_IMAGE)) {
    const src = (m[1] ?? m[2])!;
    const p = localImagePath(src, home);
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

// The bytes to upload, or why not.
export function readShareImage(file: string): { bytes: Uint8Array } | { skip: string } {
  let size: number;
  try {
    size = fs.statSync(file).size;
  } catch {
    return { skip: 'the file is gone' };
  }
  if (size > SHARE_IMAGE_BYTES) return { skip: `it's ${Math.round(size / 1024 / 1024)} MB` };
  return { bytes: new Uint8Array(fs.readFileSync(file)) };
}

// What the phone shows of any thread, shared or not (backend API 24,
// docs/convex-backend.md): what the agent put in front of Mike on purpose,
// a picture in its reply or a picture it pinned. Attachments and what tools
// hand back stay on the Mac, as they're many and big.
export type ReplyImage = {
  seq: number;
  path: string; // the file on this Mac
  src?: string; // as the agent wrote it in Markdown, for the phone to swap
  pinned?: true; // the `pin` tool's, which goes under the turn's reply
};

export const PIN_TOOL = 'mcp__threadbear__pin';

export function replyImagesInEvent(e: PersistedEvent, cwd: string | undefined, home = os.homedir()): ReplyImage[] {
  if (e.type === 'assistant.text') return markdownImages(e.text, home).map(({ src, path }) => ({ seq: e.seq, path, src }));
  if (e.type !== 'tool.call' || e.name !== PIN_TOOL || typeof e.input.path !== 'string') return [];
  // The pin tool takes a path relative to the thread's folder.
  const raw = e.input.path.trim();
  if (!raw || (!raw.startsWith('/') && !raw.startsWith('~') && !cwd)) return [];
  const file = absolute(raw, cwd ?? '/', home);
  return imageType(file) ? [{ seq: e.seq, path: file, pinned: true }] : [];
}

// The bytes to upload and what they really are, or why not. An agent can
// write any path with a .png on the end, so the file has to be a picture.
export function readReplyImage(file: string): { bytes: Uint8Array; mediaType: string; width?: number; height?: number } | { skip: string } {
  let read: ReturnType<typeof readShareImage>;
  try {
    read = readShareImage(file);
  } catch {
    return { skip: "it can't be read" };
  }
  if ('skip' in read) return read;
  const info = sniffImage(Buffer.from(read.bytes));
  if (!info) return { skip: "it isn't a picture" };
  return { bytes: read.bytes, mediaType: info.mediaType, ...(info.width ? { width: info.width } : {}), ...(info.height ? { height: info.height } : {}) };
}
