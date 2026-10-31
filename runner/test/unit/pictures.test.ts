import { test } from 'node:test';
import assert from 'node:assert/strict';
import { placePictures } from '../../src/pictures.ts';
import type { ImageRef } from '../../src/protocol.ts';

const red: ImageRef = { path: '/media/red.png', mediaType: 'image/png' };
const blue: ImageRef = { path: '/media/blue.png', mediaType: 'image/png' };

// docs/protocol.md, "Pictures in a message".
test('each picture goes straight after the marker naming it, the marker kept in the words', () => {
  assert.deepEqual(placePictures('this [Picture 1] should look like this [Picture 2] please', [red, blue]), [
    { text: 'this [Picture 1]' },
    { image: red },
    { text: ' should look like this [Picture 2]' },
    { image: blue },
    { text: ' please' },
  ]);
});

test('the markers can name pictures out of order', () => {
  assert.deepEqual(placePictures('[Picture 2] then [Picture 1]', [red, blue]), [
    { text: '[Picture 2]' },
    { image: blue },
    { text: ' then [Picture 1]' },
    { image: red },
  ]);
});

test('with no markers, the pictures go before the words, as they always did', () => {
  assert.deepEqual(placePictures('what colour?', [red, blue]), [{ image: red }, { image: blue }, { text: 'what colour?' }]);
  assert.deepEqual(placePictures('', [red]), [{ image: red }]);
});

test('a picture no marker names goes first; a marker naming no picture is just words', () => {
  assert.deepEqual(placePictures('See [Picture 2] and [Picture 7]', [red, blue]), [
    { image: red },
    { text: 'See [Picture 2]' },
    { image: blue },
    { text: ' and [Picture 7]' },
  ]);
  assert.deepEqual(placePictures('[Picture 1] [Picture 0]', []), [{ text: '[Picture 1] [Picture 0]' }]);
});

test('a picture named twice goes once, at its first marker', () => {
  assert.deepEqual(placePictures('[Picture 1] and again [Picture 1]', [red]), [
    { text: '[Picture 1]' },
    { image: red },
    { text: ' and again [Picture 1]' },
  ]);
});

test('nothing but whitespace between or after pictures is left out', () => {
  assert.deepEqual(placePictures('[Picture 1]\n[Picture 2]\n', [red, blue]), [
    { text: '[Picture 1]' },
    { image: red },
    { text: '\n[Picture 2]' },
    { image: blue },
  ]);
  assert.deepEqual(placePictures('  ', [red]), [{ image: red }]);
  assert.deepEqual(placePictures('  ', []), []);
});

test('only the exact marker counts', () => {
  assert.deepEqual(placePictures('[picture 1] [Picture1] [Picture 1 ]', [red]), [
    { image: red },
    { text: '[picture 1] [Picture1] [Picture 1 ]' },
  ]);
});
