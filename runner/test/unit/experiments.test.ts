// Experiments (src/experiments.ts): each new feature still being tried
// out is off by default, with a switch in runner.json, and names the
// schedule that asks Mike whether to turn it on for everyone (AGENTS.md,
// "Experiments"), so none is left half-on and forgotten.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { EXPERIMENTS, experimentOn } from '../../src/experiments.ts';
import { tmpDir } from '../helpers/fakes.ts';

test('experiments: each has a unique id, a landing date, a title and the schedule that asks about it', () => {
  const ids = new Set<string>();
  for (const x of EXPERIMENTS) {
    assert.ok(/^[a-z][a-zA-Z0-9]*$/.test(x.id), `${x.id}: an id in camelCase`);
    assert.ok(!ids.has(x.id), `${x.id}: listed twice`);
    ids.add(x.id);
    assert.ok(/^\d{4}-\d{2}-\d{2}$/.test(x.added) && !Number.isNaN(Date.parse(x.added)), `${x.id}: added is a YYYY-MM-DD date`);
    assert.ok(x.title.trim().length > 10, `${x.id}: says what it does`);
    // schedule_message's id: book the check-in with it when the
    // experiment lands, and put the id here.
    assert.ok(/^[0-9a-f]{8}$/.test(x.reminder), `${x.id}: reminder is the id of the schedule that asks the user whether to turn it on for everyone`);
  }
});

test("experiments: runner.json's switch wins over the default, read afresh each time", () => {
  const home = tmpDir();
  assert.equal(experimentOn(home, 'labReview'), false);
  fs.writeFileSync(path.join(home, 'runner.json'), JSON.stringify({ experiments: { labReview: true } }));
  assert.equal(experimentOn(home, 'labReview'), true);
  fs.writeFileSync(path.join(home, 'runner.json'), JSON.stringify({ experiments: { labReview: 'yes' } }));
  assert.equal(experimentOn(home, 'labReview'), false, 'only a true or false counts');
});
