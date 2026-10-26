#!/usr/bin/env node
// Stands in for launchctl in the deploy tests (THREADBARE_LAUNCHCTL), so
// nothing reaches the real launchd. It runs one job the way launchd would:
// `bootstrap` reads the plist install-runner.sh wrote and starts its
// program with the plist's environment under a keep-alive loop; `kickstart
// -k` stops the program and the loop starts it again; `bootout` stops both.
// Every call is appended to <FAKE_LAUNCHD_DIR>/calls.ndjson.
//
// The keep-alive loop is this script run as `supervise`, detached, with its
// pid in supervisor.pid and the program's in child.pid.
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const dir = process.env.FAKE_LAUNCHD_DIR;
if (!dir) {
  console.error('FAKE_LAUNCHD_DIR is not set');
  process.exit(2);
}
fs.mkdirSync(dir, { recursive: true });
const jobFile = path.join(dir, 'job.json');
const supPidFile = path.join(dir, 'supervisor.pid');
const childPidFile = path.join(dir, 'child.pid');
const THROTTLE_MS = 300; // launchd's ThrottleInterval is 5 s

const readPid = (f) => {
  try {
    return Number(fs.readFileSync(f, 'utf8')) || null;
  } catch {
    return null;
  }
};
const alive = (pid) => {
  try {
    return pid !== null && (process.kill(pid, 0), true);
  } catch {
    return false;
  }
};
const job = () => {
  try {
    return JSON.parse(fs.readFileSync(jobFile, 'utf8'));
  } catch {
    return null;
  }
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// launchctl targets look like gui/501/<label>.
function loadedFor(target) {
  const j = job();
  return j && target === `gui/${process.getuid()}/${j.label}` ? j : null;
}

function startSupervisor() {
  if (alive(readPid(supPidFile))) return;
  const child = spawn(process.execPath, [import.meta.filename, 'supervise'], {
    detached: true,
    stdio: 'ignore',
    env: process.env,
  });
  fs.writeFileSync(supPidFile, String(child.pid));
  child.unref();
}

async function stopAll() {
  fs.writeFileSync(path.join(dir, 'stop'), '');
  const sup = readPid(supPidFile);
  const kid = readPid(childPidFile);
  for (const pid of [sup, kid]) if (alive(pid)) process.kill(pid, 'SIGTERM');
  for (let i = 0; i < 100 && (alive(sup) || alive(kid)); i++) await sleep(50);
  for (const pid of [sup, kid]) if (alive(pid)) process.kill(pid, 'SIGKILL');
  fs.rmSync(supPidFile, { force: true });
  fs.rmSync(childPidFile, { force: true });
}

async function supervise() {
  let child = null;
  process.on('SIGTERM', () => {
    if (child) child.kill('SIGTERM');
    process.exit(0);
  });
  while (!fs.existsSync(path.join(dir, 'stop'))) {
    const j = job();
    if (!j) break;
    const out = fs.openSync(j.log, 'a');
    child = spawn(j.program[0], j.program.slice(1), {
      cwd: j.cwd,
      env: { HOME: process.env.HOME, USER: process.env.USER, ...j.env },
      stdio: ['ignore', out, out],
    });
    fs.closeSync(out);
    fs.writeFileSync(childPidFile, String(child.pid));
    await new Promise((r) => child.once('exit', r));
    child = null;
    await sleep(THROTTLE_MS);
  }
}

async function main(args) {
  const [cmd, ...rest] = args;
  if (cmd === 'supervise') return supervise();
  fs.appendFileSync(path.join(dir, 'calls.ndjson'), JSON.stringify(args) + '\n');
  switch (cmd) {
    case 'bootstrap': {
      const plist = rest[1];
      const r = spawnSync('plutil', ['-convert', 'json', '-o', '-', plist], { encoding: 'utf8' });
      if (r.status !== 0) {
        console.error(r.stderr);
        return 5;
      }
      const p = JSON.parse(r.stdout);
      if (job()) return 37; // launchd: service already loaded
      fs.rmSync(path.join(dir, 'stop'), { force: true });
      fs.writeFileSync(
        jobFile,
        JSON.stringify({ label: p.Label, program: p.ProgramArguments, env: p.EnvironmentVariables ?? {}, cwd: p.WorkingDirectory, log: p.StandardOutPath }),
      );
      if (p.RunAtLoad) startSupervisor();
      return 0;
    }
    case 'bootout': {
      if (!loadedFor(rest[0])) return 3;
      await stopAll();
      fs.rmSync(jobFile, { force: true });
      return 0;
    }
    case 'print':
      return loadedFor(rest[0]) ? 0 : 113;
    case 'kickstart': {
      const kill = rest[0] === '-k';
      if (!loadedFor(rest.at(-1))) {
        console.error(`Could not find service "${rest.at(-1)}" in domain`);
        return 113;
      }
      const kid = readPid(childPidFile);
      if (alive(readPid(supPidFile))) {
        if (kill && alive(kid)) process.kill(kid, 'SIGTERM');
      } else {
        fs.rmSync(path.join(dir, 'stop'), { force: true });
        startSupervisor();
      }
      return 0;
    }
    default:
      console.error(`fake launchctl: ${cmd} isn't faked`);
      return 64;
  }
}

main(process.argv.slice(2)).then((code) => process.exit(code ?? 0));
