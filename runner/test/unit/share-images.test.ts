import { test } from 'node:test';
import assert from 'node:assert/strict';
import { imagesInEvent, localImagePath, markdownImages } from '../../src/share-images.ts';

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
