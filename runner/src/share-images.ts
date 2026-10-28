// The pictures in a shared thread's events (docs/website.md, "Sharing"),
// which the mirror uploads to file storage so the shared page can show
// them. Only for shared threads: the rest keep their pictures on the Mac.
import fs from 'node:fs';
import os from 'node:os';
import type { PersistedEvent } from './protocol.ts';

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
