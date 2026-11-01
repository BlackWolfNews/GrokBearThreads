import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { imagesInEvent, localImagePath, markdownImages, PIN_TOOL, readReplyImage, replyImagesInEvent } from '../../src/share-images.ts';
import { tmpDir } from '../helpers/fakes.ts';

test('share images: Markdown pictures on this Mac, not on the web', () => {
  const home = '/Users/ann';
  assert.equal(localImagePath('/tmp/a.png', home), '/tmp/a.png');
  assert.equal(localImagePath('~/shots/b.JPG', home), '/Users/ann/shots/b.JPG');
  assert.equal(localImagePath('file:///tmp/c%20d.webp', home), '/tmp/c d.webp');
  assert.equal(localImagePath('https://example.com/a.png', home), undefined);
  assert.equal(localImagePath('/tmp/notes.txt', home), undefined);
  assert.equal(localImagePath('relative/a.png', home), undefined);
  assert.deepEqual(
    markdownImages('![one](/tmp/a.png) and ![two](<~/b c.gif> "title"), ![web](https://x.io/c.png), ![again](/tmp/a.png)', home),
    [{ src: '/tmp/a.png', path: '/tmp/a.png' }, { src: '~/b c.gif', path: '/Users/ann/b c.gif' }],
  );
});

test('share images: attachments, tool pictures and pictures in text', () => {
  const at = '2026-10-29T00:00:00.000Z';
  const img = { path: '/data/media/x.png', mediaType: 'image/png', width: 10, height: 20 };
  assert.deepEqual(imagesInEvent({ seq: 3, ts: at, type: 'user.message', text: 'see', images: [img] } as never), [{ seq: 3, ...img }]);
  assert.deepEqual(imagesInEvent({ seq: 5, ts: at, type: 'tool.result', itemId: 't', ok: true, text: '', truncated: false, images: [img] } as never), [{ seq: 5, ...img }]);
  assert.deepEqual(imagesInEvent({ seq: 7, ts: at, type: 'assistant.text', itemId: 'm', text: '![bear](/tmp/bear.png)' } as never, '/Users/ann'), [
    { seq: 7, path: '/tmp/bear.png', src: '/tmp/bear.png', mediaType: 'image/png' },
  ]);
  assert.deepEqual(imagesInEvent({ seq: 8, ts: at, type: 'reasoning', itemId: 'r', text: '![x](/tmp/x.png)' } as never), []);
});

test('reply images: pictures in a reply and pinned pictures, nothing else', () => {
  const home = '/Users/ann';
  const base = { threadId: 't', turnId: 'u', ts: '2026-11-01T00:00:00.000Z' };
  const ev = (seq: number, rest: object) => ({ ...base, seq, ...rest }) as never;
  const pin = (p: string) => ev(4, { type: 'tool.call', itemId: 'i', name: PIN_TOOL, kind: 'mcp', title: 'pin', input: { path: p } });
  assert.deepEqual(replyImagesInEvent(ev(1, { type: 'assistant.text', text: '![a](/w/a.png) and ![b](https://x.io/b.png)' }), '/w', home), [{ seq: 1, path: '/w/a.png', src: '/w/a.png' }]);
  assert.deepEqual(replyImagesInEvent(pin('/w/a.png'), '/w', home), [{ seq: 4, path: '/w/a.png', pinned: true }]);
  // A relative pin is from the thread's folder, and without one it's unknown.
  assert.deepEqual(replyImagesInEvent(pin('guide/a.jpg'), '/w', home), [{ seq: 4, path: '/w/guide/a.jpg', pinned: true }]);
  assert.deepEqual(replyImagesInEvent(pin('guide/a.jpg'), undefined, home), []);
  assert.deepEqual(replyImagesInEvent(pin('~/a.webp'), undefined, home), [{ seq: 4, path: '/Users/ann/a.webp', pinned: true }]);
  // A pinned doc, a link pin, Mike's attachments and a tool's screenshots stay.
  assert.deepEqual(replyImagesInEvent(pin('/w/notes.md'), '/w', home), []);
  assert.deepEqual(replyImagesInEvent(ev(5, { type: 'tool.call', itemId: 'j', name: PIN_TOOL, kind: 'mcp', title: 'pin', input: { url: 'https://x.io/a.png' } }), '/w', home), []);
  const image = { path: '/w/c.png', mediaType: 'image/png' };
  assert.deepEqual(replyImagesInEvent(ev(6, { type: 'user.message', text: 'hi', images: [image] }), '/w', home), []);
  assert.deepEqual(replyImagesInEvent(ev(7, { type: 'tool.result', itemId: 'j', ok: true, text: '', truncated: false, images: [image] }), '/w', home), []);
});

test('reply images: a file has to really be a picture', () => {
  const dir = tmpDir();
  const png = path.join(dir, 'real.png');
  const header = Buffer.alloc(24);
  header.writeUInt32BE(0x89504e47, 0);
  header.writeUInt32BE(0x0d0a1a0a, 4);
  header.writeUInt32BE(800, 16);
  header.writeUInt32BE(600, 20);
  fs.writeFileSync(png, header);
  const read = readReplyImage(png);
  assert.ok(!('skip' in read));
  assert.deepEqual([read.mediaType, read.width, read.height], ['image/png', 800, 600]);
  const fake = path.join(dir, 'secrets.png');
  fs.writeFileSync(fake, 'API_KEY=hunter2');
  assert.deepEqual(readReplyImage(fake), { skip: "it isn't a picture" });
  assert.deepEqual(readReplyImage(path.join(dir, 'gone.png')), { skip: 'the file is gone' });
  assert.deepEqual(readReplyImage(dir + '/'), { skip: "it can't be read" });
});
