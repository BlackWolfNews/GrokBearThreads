// The media helpers Codex images go through: copying an image file a CLI
// saved or viewed into a thread's media folder, and saving a data: URL.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { copyImageFileInto, saveDataUrl } from '../../src/media.ts';
import { fileContext } from '../../src/adapters/context.ts';
import { tmpDir } from '../helpers/fakes.ts';
import { makePng } from '../helpers/png.ts';

// A 24-bit BMP, which sips turns into a PNG.
function makeBmp(w: number, h: number): Buffer {
  const row = Math.ceil((w * 3) / 4) * 4;
  const size = 54 + row * h;
  const b = Buffer.alloc(size);
  b.write('BM', 0, 'ascii');
  b.writeUInt32LE(size, 2);
  b.writeUInt32LE(54, 10);
  b.writeUInt32LE(40, 14);
  b.writeInt32LE(w, 18);
  b.writeInt32LE(h, 22);
  b.writeUInt16LE(1, 26);
  b.writeUInt16LE(24, 28);
  b.writeUInt32LE(row * h, 34);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) b.set([255, 0, 0], 54 + y * row + x * 3);
  return b;
}

test('copyImageFileInto copies a PNG under <hint>-<sha1>.png, once', () => {
  const dir = tmpDir('tb-media-');
  const src = path.join(dir, 'gen.png');
  fs.writeFileSync(src, makePng(12, 7));
  const media = path.join(dir, 'media');
  const a = copyImageFileInto(media, src, 'generated')!;
  assert.match(path.basename(a.path), /^generated-[0-9a-f]{10}\.png$/);
  assert.deepEqual({ ...a, path: path.dirname(a.path) }, { path: media, mediaType: 'image/png', width: 12, height: 7 });
  assert.deepEqual(fs.readFileSync(a.path), fs.readFileSync(src));
  // A replay of the same image lands on the same file; nothing new is written.
  const mtime = fs.statSync(a.path).mtimeMs;
  const b = copyImageFileInto(media, src, 'generated')!;
  assert.equal(b.path, a.path);
  assert.equal(fs.statSync(b.path).mtimeMs, mtime);
  assert.equal(fs.readdirSync(media).length, 1);
});

test('copyImageFileInto takes a file:// URL, and refuses what is not a readable image file', () => {
  const dir = tmpDir('tb-media-');
  const src = path.join(dir, 'with space.png');
  fs.writeFileSync(src, makePng(3, 3));
  const media = path.join(dir, 'media');
  assert.equal(copyImageFileInto(media, pathToFileURL(src).href, 'view')?.width, 3);
  fs.writeFileSync(path.join(dir, 'notes.txt'), 'hello');
  assert.equal(copyImageFileInto(media, path.join(dir, 'notes.txt'), 'view'), null);
  assert.equal(copyImageFileInto(media, path.join(dir, 'missing.png'), 'view'), null);
  assert.equal(copyImageFileInto(media, dir, 'view'), null, 'a folder');
  assert.equal(copyImageFileInto(media, 'relative.png', 'view'), null);
  // Over 100 MB (a sparse file, so nothing is really written).
  const huge = path.join(dir, 'huge.png');
  fs.writeFileSync(huge, makePng(2, 2));
  fs.truncateSync(huge, 101 * 1024 * 1024);
  assert.equal(copyImageFileInto(media, huge, 'view'), null);
});

test('copyImageFileInto turns a BMP into a PNG with sips', { skip: !fs.existsSync('/usr/bin/sips') && 'no sips' }, () => {
  const dir = tmpDir('tb-media-');
  const src = path.join(dir, 'pic.bmp');
  fs.writeFileSync(src, makeBmp(5, 4));
  const media = path.join(dir, 'media');
  const ref = copyImageFileInto(media, src, 'view')!;
  assert.ok(ref, 'converted');
  assert.match(path.basename(ref.path), /^view-[0-9a-f]{10}\.png$/);
  assert.deepEqual([ref.mediaType, ref.width, ref.height], ['image/png', 5, 4]);
  assert.deepEqual(fs.readdirSync(media), [path.basename(ref.path)], 'no temp file left');
  assert.equal(copyImageFileInto(media, src, 'view')!.path, ref.path);
});

test('saveDataUrl saves a base64 image and refuses anything else', () => {
  const media = path.join(tmpDir('tb-media-'), 'media');
  const png = makePng(9, 2);
  const ref = saveDataUrl(media, `data:image/png;base64,${png.toString('base64')}`, 'threadbear.read_thread')!;
  assert.match(path.basename(ref.path), /^threadbear_read_thread-[0-9a-f]{10}\.png$/);
  assert.deepEqual([ref.width, ref.height], [9, 2]);
  assert.equal(saveDataUrl(media, 'data:text/plain;base64,aGVsbG8=', 'x'), null);
  assert.equal(saveDataUrl(media, 'data:image/svg+xml,<svg/>', 'x'), null);
  assert.equal(saveDataUrl(media, 'https://example.com/a.png', 'x'), null);
});

test('fileContext gives normalisers copyImage and saveDataUrl into the media folder', () => {
  const dir = tmpDir('tb-media-');
  const media = path.join(dir, 'media');
  const ctx = fileContext(dir, media, path.join(dir, 'blobs'));
  const src = path.join(dir, 'a.png');
  fs.writeFileSync(src, makePng(4, 4));
  assert.equal(path.dirname(ctx.copyImage!(src, 'view')!.path), media);
  assert.equal(path.dirname(ctx.saveDataUrl!(`data:image/png;base64,${makePng(1, 1).toString('base64')}`, 'x')!.path), media);
});
