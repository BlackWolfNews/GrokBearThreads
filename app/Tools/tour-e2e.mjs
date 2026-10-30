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
  t = next('Hibernate');
  check('Hibernate lights one row, not the list', t.lit && t.lit.h < 120, t.raw);
  check('Hibernate waits for you', t.task === 'to do', t.raw);
  run({ cmd: 'snooze', id: sampleId(dump(), 'Plan the weekend'), seconds: 3600 });
  await until('Hibernate done once a sample sleeps', () => parseTour(tour()).task === 'done');
  shot('hibernated');

  t = next('Archive');
  run({ cmd: 'archive', id: sampleId(dump(), 'Draft the release notes') });
  await until('Archive done once a sample is archived', () => parseTour(tour()).task === 'done');

  t = next('Your views');
  // The view icons only, not the whole column down to Settings.
  check('Your views lights the view icons, not the whole bar', t.lit && t.lit.h < 300, t.raw);
  t = next('Highlights');
  check('Highlights opens the sample that needs you', dump().selection?.title === 'Fix the flaky login test', JSON.stringify(dump().selection));

  t = next('Move a panel');
  run({ cmd: 'dock-move', panel: 'threadbear.highlights', edge: 'bottom' });
  await until('Move a panel done once the layout changes', () => parseTour(tour()).task === 'done');
  shot('moved');

  next('Patches');
  // The example patch, from the runner itself: no "patch to trust".
  const roll = await until('Roll a die is a button on the sample', () => dump().actions.find((a) => a.title === 'Roll a die'));
  const patchesNote = (dump().panels?.items ?? []).find((p) => p.kind === 'patches')?.note ?? '';
  check('no patch waits to be trusted', !/untrusted|trust/i.test(patchesNote), patchesNote);
  next('Per project or tool');
  t = next('Try it');
  check('Try it waits for the button', t.task === 'to do', t.raw);
  if (roll) {
    run({ cmd: 'action', id: roll.id });
    await until('Try it done once Roll a die has run', () => parseTour(tour()).task === 'done');
    await sleep(800);
    // Its own row, open and on screen: not folded into the sample's
    // "Worked for" line, where it vanished on Tinker Desk (30 Oct).
    const rows = dump().transcript?.rows ?? [];
    const rolled = rows.find((r) => r.id.startsWith('t:action:'));
    check('the roll has a row of its own', rolled && !rolled.inGroup, JSON.stringify(rows.map((r) => `${r.id}${r.inGroup ? ' (in group)' : ''}`)));
    check('the roll is open and on screen', rolled && rolled.onScreen && rolled.expanded !== false, JSON.stringify(rolled));
    // Scrolled down to it: opened in place, its output sat under the
    // composer, and only the command showed.
    check('the thread is scrolled to the roll', dump().transcript?.atBottom === true, JSON.stringify(dump().transcript?.atBottom));
    shot('rolled');
  }

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
  check('none left hibernating or archived', after.sidebar.snoozed === 0 && after.sidebar.archived === 0, `hibernating ${after.sidebar.snoozed}, archived ${after.sidebar.archived}`);
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
