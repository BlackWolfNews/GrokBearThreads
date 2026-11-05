import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { tmpDir } from '../helpers/fakes.ts';
import { FILES_LIST_MAX, listFolderFor, readFileFor } from '../../src/files.ts';
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

test('files.list says what a folder holds, following links', () => {
  const dir = tmpDir();
  fs.writeFileSync(path.join(dir, 'notes.md'), 'hello');
  fs.writeFileSync(path.join(dir, '.env'), 'X=1');
  fs.mkdirSync(path.join(dir, 'exports'));
  fs.symlinkSync(path.join(dir, 'exports'), path.join(dir, 'to-exports'));
  fs.symlinkSync(path.join(dir, 'never-there'), path.join(dir, 'broken'));

  const r = listFolderFor({ path: dir });
  assert.equal(r.truncated, false);
  const byName = Object.fromEntries(r.entries.map((e) => [e.name, e]));
  assert.equal(byName['notes.md'].isFolder, false);
  assert.equal(byName['notes.md'].size, 5);
  assert.ok(byName['notes.md'].modifiedAt);
  assert.equal(byName['exports'].isFolder, true);
  assert.equal(byName['exports'].size, undefined, 'a folder has no size of its own');
  assert.equal(byName['to-exports'].isFolder, true, 'a link to a folder opens as one');
  assert.equal(byName['.env'].hidden, true);
  assert.equal(byName['notes.md'].hidden, false);
  assert.deepEqual(byName['broken'], { name: 'broken', isFolder: false, hidden: false }, 'a broken link is still listed');
});

test('files.list says what is wrong with a path', () => {
  const message = (p: unknown) => {
    try {
      listFolderFor({ path: p });
    } catch (e) {
      assert.equal((e as RpcError).code, ErrorCode.badParams);
      return (e as Error).message;
    }
    return '';
  };
  assert.match(message('relative/folder'), /must be absolute/);
  assert.match(message(42), /must be a string/);
  assert.match(message('/nope/never/here'), /No such folder/);
  const dir = tmpDir();
  fs.writeFileSync(path.join(dir, 'a.txt'), 'a');
  assert.match(message(path.join(dir, 'a.txt')), /Not a folder/);
});

test('files.list stops at its cap and says so', () => {
  const dir = tmpDir();
  for (let i = 0; i < FILES_LIST_MAX + 3; i += 1) fs.closeSync(fs.openSync(path.join(dir, `f${i}`), 'w'));
  const r = listFolderFor({ path: dir });
  assert.equal(r.entries.length, FILES_LIST_MAX);
  assert.equal(r.truncated, true);
});
