import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import type { ImageRef } from './protocol.ts';

export type ImageInfo = { mediaType: string; width?: number; height?: number };

const EXT: Record<string, string> = {
  'image/png': 'png',
  'image/jpeg': 'jpg',
  'image/gif': 'gif',
  'image/webp': 'webp',
};

export function extForMediaType(mediaType: string): string {
  return EXT[mediaType] ?? 'bin';
}

// Reads the image type and pixel size from the file header, so the app can
// lay out thumbnails without decoding anything.
export function sniffImage(buf: Buffer): ImageInfo | null {
  if (buf.length >= 24 && buf.readUInt32BE(0) === 0x89504e47 && buf.readUInt32BE(4) === 0x0d0a1a0a) {
    return { mediaType: 'image/png', width: buf.readUInt32BE(16), height: buf.readUInt32BE(20) };
  }
  if (buf.length >= 10 && buf.toString('ascii', 0, 3) === 'GIF') {
    return { mediaType: 'image/gif', width: buf.readUInt16LE(6), height: buf.readUInt16LE(8) };
  }
  if (buf.length >= 30 && buf.toString('ascii', 0, 4) === 'RIFF' && buf.toString('ascii', 8, 12) === 'WEBP') {
    const chunk = buf.toString('ascii', 12, 16);
    if (chunk === 'VP8 ' && buf.length >= 30) {
      return { mediaType: 'image/webp', width: buf.readUInt16LE(26) & 0x3fff, height: buf.readUInt16LE(28) & 0x3fff };
    }
    if (chunk === 'VP8L' && buf.length >= 25) {
      const b = buf.readUInt32LE(21);
      return { mediaType: 'image/webp', width: (b & 0x3fff) + 1, height: ((b >> 14) & 0x3fff) + 1 };
    }
    if (chunk === 'VP8X' && buf.length >= 30) {
      return {
        mediaType: 'image/webp',
        width: (buf.readUIntLE(24, 3) & 0xffffff) + 1,
        height: (buf.readUIntLE(27, 3) & 0xffffff) + 1,
      };
    }
    return { mediaType: 'image/webp' };
  }
  if (buf.length >= 4 && buf[0] === 0xff && buf[1] === 0xd8) {
    let i = 2;
    while (i + 9 < buf.length) {
      if (buf[i] !== 0xff) {
        i++;
        continue;
      }
      const marker = buf[i + 1];
      if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
        i += 2;
        continue;
      }
      const len = buf.readUInt16BE(i + 2);
      // SOF0..SOF15 except DHT (C4), JPG (C8) and DAC (CC) carry the size.
      if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
        return { mediaType: 'image/jpeg', height: buf.readUInt16BE(i + 5), width: buf.readUInt16BE(i + 7) };
      }
      i += 2 + len;
    }
    return { mediaType: 'image/jpeg' };
  }
  return null;
}

// Biggest image file accepted from the app.
const MAX_IMAGE_BYTES = 100 * 1024 * 1024;

export function readImageInfo(file: string): ImageInfo | null {
  let fd: number | null = null;
  try {
    // Only regular files: opening a named pipe (or a device) would block
    // the runner until something writes to it.
    const st = fs.statSync(file);
    if (!st.isFile() || st.size > MAX_IMAGE_BYTES) return null;
    fd = fs.openSync(file, 'r');
    // JPEG size markers can sit after big EXIF blocks, so read generously.
    const size = Math.min(fs.fstatSync(fd).size, 512 * 1024);
    const buf = Buffer.alloc(size);
    fs.readSync(fd, buf, 0, size, 0);
    return sniffImage(buf);
  } catch {
    return null;
  } finally {
    if (fd !== null) fs.closeSync(fd);
  }
}

export function imageRefFor(file: string, fallbackType?: string): ImageRef {
  const info = readImageInfo(file);
  const ref: ImageRef = { path: file, mediaType: info?.mediaType ?? fallbackType ?? 'application/octet-stream' };
  if (info?.width) ref.width = info.width;
  if (info?.height) ref.height = info.height;
  return ref;
}

// Saves base64 image data (from a tool result) into a media folder.
export function saveBase64Image(dir: string, data: string, mediaType: string, hint: string): ImageRef {
  fs.mkdirSync(dir, { recursive: true });
  const buf = Buffer.from(data, 'base64');
  const info = sniffImage(buf);
  const type = info?.mediaType ?? mediaType;
  const name = `${safeName(hint)}-${crypto.createHash('sha1').update(buf).digest('hex').slice(0, 10)}.${extForMediaType(type)}`;
  const file = path.join(dir, name);
  if (!fs.existsSync(file)) fs.writeFileSync(file, buf);
  const ref: ImageRef = { path: file, mediaType: type };
  if (info?.width) ref.width = info.width;
  if (info?.height) ref.height = info.height;
  return ref;
}

// Copies an image into a folder under a fresh name and returns its ref.
// Used by media.import (into inbox/) and when a message is sent (into the
// thread's media/ so the transcript keeps working if inbox/ is cleaned).
export function copyImageInto(dir: string, src: string): ImageRef {
  const info = readImageInfo(src);
  if (!info) throw new Error(`Not a supported image: ${path.basename(src)}`);
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, `${crypto.randomUUID()}.${extForMediaType(info.mediaType)}`);
  fs.copyFileSync(src, file);
  const ref: ImageRef = { path: file, mediaType: info.mediaType };
  if (info.width) ref.width = info.width;
  if (info.height) ref.height = info.height;
  return ref;
}

// The API rejects images over about 5 MB (base64) or 8000 px. Shrink big
// ones with sips (built into macOS) before sending. Returns the bytes and
// media type to send; the original file stays as it was for the transcript.
export function prepareImageForModel(ref: ImageRef, tmpDir: string): { data: Buffer; mediaType: string } {
  const data = fs.readFileSync(ref.path);
  const tooBig = data.length > 3_700_000 || (ref.width ?? 0) > 7900 || (ref.height ?? 0) > 7900;
  if (!tooBig) return { data, mediaType: ref.mediaType };
  try {
    fs.mkdirSync(tmpDir, { recursive: true });
    const out = path.join(tmpDir, `${crypto.randomUUID()}.jpg`);
    execFileSync('/usr/bin/sips', ['-s', 'format', 'jpeg', '-s', 'formatOptions', '80', '-Z', '2048', ref.path, '--out', out], {
      stdio: 'ignore',
    });
    const small = fs.readFileSync(out);
    fs.rmSync(out, { force: true });
    return { data: small, mediaType: 'image/jpeg' };
  } catch {
    return { data, mediaType: ref.mediaType };
  }
}

function safeName(s: string): string {
  return s.replace(/[^a-zA-Z0-9_-]+/g, '_').slice(0, 40) || 'image';
}
