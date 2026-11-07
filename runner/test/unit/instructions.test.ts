// Where Mike's standing instructions are kept (instructions.ts).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { InstructionsStore } from '../../src/instructions.ts';
import { tmpDir } from '../helpers/fakes.ts';

test('standing instructions are kept in the data dir, and cleared by an empty box', () => {
  const home = tmpDir();
  const published: unknown[] = [];
  const s = new InstructionsStore({ home, publish: (n) => published.push(n) });
  assert.equal(s.instructions(), '');
  assert.deepEqual(s.setInstructions('  Be warm.\r\nBe brief.  '), { instructions: 'Be warm.\nBe brief.\n' });
  assert.equal(fs.readFileSync(path.join(home, 'instructions.md'), 'utf8'), 'Be warm.\nBe brief.\n');
  assert.equal(published.length, 1);
  s.setInstructions('   ');
  assert.equal(fs.existsSync(path.join(home, 'instructions.md')), false);
  assert.equal(s.instructions(), '');
  assert.throws(() => s.setInstructions('x'.repeat(20_001)), /20,000/);
});
