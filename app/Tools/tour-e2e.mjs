#!/usr/bin/env node
// The first-run tour, end to end, against a real runner: a dev runner on a
// throwaway data folder (runner/scripts/dev-runner.sh) and a debug app on it
// (dev-app.sh --home). The mock runner fakes patches, samples and trust, so
// it passed tours that were broken on a real install: Roll a die waiting as
// "1 patch to trust" on Tinker Desk (Mike, 30 Oct). This plays every step as
// someone would, checks what each card lights up and what the step changed,
// and saves a shot of each step.
//
//   node app/Tools/tour-e2e.mjs [--shots DIR] [--keep]
//
// It sends the tour's first thread for real (the dev runner's cheap model,
// in its temp folder), so it needs a Claude login on this Mac. Exits 1 on
// any failed check. Never touches the live runner or the installed app.
import { execFileSync, spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const app = path.resolve(import.meta.dirname, '..');
const repo = path.resolve(app, '..');
const devApp = path.join(app, 'Tools', 'dev-app.sh');
const args = process.argv.slice(2);
const shots = args.includes('--shots') ? path.resolve(args[args.indexOf('--shots') + 1]) : fs.mkdtempSync(path.join(os.tmpdir(), 'tour-e2e-'));
const keep = args.includes('--keep');
const id = `tour-e2e-${process.pid}`;
fs.mkdirSync(shots, { recursive: true });

const failures = [];
function check(name, ok, detail = '') {
  console.log(`${ok ? 'ok  ' : 'FAIL'}  ${name}${ok || !detail ? '' : `: ${detail}`}`);
  if (!ok) failures.push(name);
  return ok;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// One automation command; its result line, without the command's name.
// An error result exits 1, and comes back as the line all the same.
function run(command) {
  let out;
  try {
    out = execFileSync('bash', [devApp, '--id', id, 'do', JSON.stringify(command)], { encoding: 'utf8', timeout: 120_000 });
  } catch (error) {
    out = String(error.stdout ?? '') + String(error.stderr ?? '');
  }
  return out.trim().split('\n').pop().replace(/^\S+ /, '');
}
const json = (line) => JSON.parse(line.slice(line.indexOf('{')));
const dump = () => json(run({ cmd: 'dump' }));
const tour = () => run({ cmd: 'tour' });
let shotNo = 0;
function shot(name) {
  const file = path.join(shots, `${String(++shotNo).padStart(2, '0')}-${name.replace(/[^a-z0-9]+/gi, '-').toLowerCase()}.png`);
  try {
    execFileSync('bash', [devApp, '--id', id, 'shot', file], { stdio: 'ignore', timeout: 60_000 });
  } catch {
    // A shot that fails doesn't fail the tour.
  }
}

// What `tour` says: "ok 3/14 Needs you (to do) lit: 52,264 313x51".
function parseTour(line) {
  const m = /^ok (\d+)\/(\d+) (.+?)(?: \((done|to do)\))? lit: (nothing|(-?\d+),(-?\d+) (\d+)x(\d+))$/.exec(line);
  if (!m) return { off: line === 'ok off', raw: line };
  return { step: +m[1], count: +m[2], title: m[3], task: m[4], lit: m[5] === 'nothing' ? null : { x: +m[6], y: +m[7], w: +m[8], h: +m[9] }, raw: line };
}

async function until(what, test, seconds = 20) {
  const end = Date.now() + seconds * 1000;
  for (;;) {
    const value = test();
    if (value) return value;
    if (Date.now() > end) return check(what, false, 'timed out');
    await sleep(500);
  }
}

const sampleTitles = ['Fix the flaky login test', 'Plan the weekend', 'Draft the release notes'];
const threadsIn = (d) => d.sidebar.sections.flatMap((s) => s.threads);
const sampleId = (d, title) => threadsIn(d).find((t) => t.title === title)?.id;

// The dev runner, in the background, on a temp data folder.
const runnerLog = path.join(shots, 'dev-runner.out');
const runner = spawn('bash', [path.join(repo, 'runner', 'scripts', 'dev-runner.sh')], { detached: true, stdio: ['ignore', fs.openSync(runnerLog, 'w'), fs.openSync(runnerLog, 'a')] });
runner.unref();
let home;
let appStarted = false;

async function main() {
  home = await until('dev runner started', () => /^ {2}data: (.+?)(?: \(deleted|$)/m.exec(fs.readFileSync(runnerLog, 'utf8'))?.[1], 120);
  if (!home) return;
  await until('dev runner listening', () => fs.existsSync(path.join(home, 'runner.json')) && fs.existsSync(path.join(home, 'secrets', 'runner-token')), 60);
  execFileSync('bash', [devApp, 'start', '--home', home, '--id', id], { stdio: 'inherit', timeout: 900_000 });
  appStarted = true;
  await until('app connected', () => /"connection":"connected"/.test(run({ cmd: 'dump' })), 30);
  run({ cmd: 'new' });

  // The first-run tour (no Skip), as a new Mac gets it.
  let t = parseTour(run({ cmd: 'tour', do: 'start' }));
  check('starts on Welcome', t.title === 'Welcome to Threadbear', t.raw);
  shot('welcome');
  const d0 = await until('samples made', () => {
    const d = dump();
    return sampleTitles.every((title) => sampleId(d, title)) && d;
  });
  if (!d0) return;

  const next = (expect, lit = true) => {
    const s = parseTour(run({ cmd: 'tour', do: 'next' }));
    check(`step ${expect}`, s.title === expect, s.raw);
    if (lit) check(`${expect} lights something up`, s.lit !== null, s.raw);
    shot(expect);
    return s;
  };

  next('Threads');
  // Shown, not pressed: the sample's row drawn hovered, its moon and box out.
  t = next('Star or put away');
  check("it lights the row's star, moon and box, not the whole row", t.lit && t.lit.h < 80 && t.lit.w < 160, t.raw);
  const hovered = threadsIn(dump()).find((th) => th.hovered);
  check('that row shows its hover buttons', hovered?.title === 'Plan the weekend', JSON.stringify(hovered?.title));

  t = next('Your views');
  // The view icons only, not the whole column down to Settings.
  check('Your views lights the view icons, not the whole bar', t.lit && t.lit.h < 300, t.raw);
  // Flips to each view to show what it's for, then back to the inbox.
  next('Projects');
  check('Projects shows the Projects view', dump().sidebar.mode === 'projects', dump().sidebar.mode);
  next('The librarian');
  check('The librarian shows its view', dump().sidebar.mode === 'librarian', dump().sidebar.mode);
  t = next('Highlights');
  check('Highlights is back in the inbox', dump().sidebar.mode === 'inbox', dump().sidebar.mode);
  check('Highlights opens the sample that needs you', dump().selection?.title === 'Fix the flaky login test', JSON.stringify(dump().selection));

  // Told, not done (Mike, 2 Nov): no drag, no press.
  t = next('Move a panel');
  check('Move a panel has nothing to do', t.task === undefined, t.raw);

  next('Patches');
  // The example patch, from the runner itself: no "patch to trust".
  await until('Roll a die is a button on the sample', () => dump().actions.find((a) => a.title === 'Roll a die'));
  const patchesNote = (dump().panels?.items ?? []).find((p) => p.kind === 'patches')?.note ?? '';
  check('no patch waits to be trusted', !/untrusted|trust/i.test(patchesNote), patchesNote);
  t = next('Per project or tool');
  check('Per project or tool has nothing to press', t.task === undefined, t.raw);

  t = next('Your first thread');
  check('the first message is written for them', /Make me a patch for this folder/.test(dump().composer.text), dump().composer.text);
  run({ cmd: 'return' });
  t = await until('sending moves on to Finish setting up', () => {
    const s = parseTour(tour());
    return s.title === 'Finish setting up' && s;
  });
  shot('finish-setting-up');
  check('Finish setting up lights its panel', t && t.lit !== null, t?.raw);

  run({ cmd: 'tour', do: 'next' });
  check('Done ends the tour', parseTour(tour()).off);
  await sleep(1500);
  const after = dump();
  const left = threadsIn(after).filter((th) => sampleTitles.includes(th.title)).map((th) => th.title);
  check('the samples are gone from the inbox', left.length === 0, left.join(', '));
  check('no row left drawn hovered', !threadsIn(after).some((th) => th.hovered));
  check('the first thread is still there', threadsIn(after).some((th) => /Make me a patch/.test(th.title) || th.id !== undefined), '');
  shot('after');

  // Again, from Help: fresh samples, and the patch still trusted.
  t = parseTour(run({ cmd: 'tour', do: 'start', skippable: true }));
  check('Help runs it again', t.title === 'Welcome to Threadbear', t.raw);
  await until('fresh samples the second time', () => sampleTitles.every((title) => sampleId(dump(), title)));
  run({ cmd: 'select', id: sampleId(dump(), 'Fix the flaky login test') });
  await until('Roll a die is there the second time', () => dump().actions.find((a) => a.title === 'Roll a die'));
  // The replay has Skip as well: the buttons still fit (look at the shot).
  for (let i = 0; i < 4; i++) run({ cmd: 'tour', do: 'next' });
  shot('replay-with-skip');
  run({ cmd: 'tour', do: 'end' });
  await sleep(1500);
  check('ending it removes the samples', !threadsIn(dump()).some((th) => sampleTitles.includes(th.title)));
}

try {
  await main();
} catch (error) {
  check('the run itself', false, error.message.split('\n')[0]);
} finally {
  if (appStarted) {
    try {
      execFileSync('bash', [devApp, '--id', id, 'stop'], { stdio: 'ignore', timeout: 60_000 });
    } catch {}
  }
  // The dev runner's own pid, as it printed it (never pkill: the live runner
  // runs the same file).
  const pid = /^ {2}pid: {2}(\d+)/m.exec(fs.readFileSync(runnerLog, 'utf8'))?.[1];
  if (pid && !keep) {
    try {
      process.kill(+pid);
    } catch {}
  }
  console.log(`\n${failures.length ? `${failures.length} failed` : 'all passed'}. Shots in ${shots}`);
  process.exitCode = failures.length ? 1 : 0;
}
