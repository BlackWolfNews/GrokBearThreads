import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { tmpDir } from '../helpers/fakes.ts';
import { readFileFor } from '../../src/files.ts';
import { ErrorCode, RpcError } from '../../src/protocol.ts';

const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==', 'base64');

test('files.read sends a file’s bytes once, then says unchanged', () => {
  const dir = tmpDir();
  const pic = path.join(dir, 'shot');
  fs.writeFileSync(pic, PNG);
  const r = readFileFor({ path: pic });
  assert.ok(!('unchanged' in r));
  if ('unchanged' in r) return;
  assert.equal(r.mediaType, 'image/png', 'sniffed, no extension needed');
  assert.equal(Buffer.from(r.data, 'base64').equals(PNG), true);
  assert.equal(r.truncated, false);
  assert.deepEqual(readFileFor({ path: pic, known: { size: r.size, modifiedAt: r.modifiedAt } }), { path: pic, unchanged: true, size: r.size, modifiedAt: r.modifiedAt });

  const log = path.join(dir, 'out.txt');
  fs.writeFileSync(log, 'x'.repeat(100));
  const cut = readFileFor({ path: log, maxBytes: 10 });
  assert.ok(!('unchanged' in cut) && cut.truncated && Buffer.from(cut.data, 'base64').length === 10 && cut.mediaType === 'text/plain');
});

test('files.read says what is wrong with a path', () => {
  const code = (fn: () => unknown) => {
    try {
      fn();
    } catch (e) {
      return [(e as RpcError).code, (e as Error).message];
    }
    return [0, ''];
  };
  assert.equal(code(() => readFileFor({ path: 'relative.txt' }))[0], ErrorCode.badParams);
  assert.match(String(code(() => readFileFor({ path: '/nope/never/here' }))[1]), /No such file/);
  assert.match(String(code(() => readFileFor({ path: tmpDir() }))[1]), /Not a file/);
});
