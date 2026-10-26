import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { atomicWriteFileSync } from './fsutil.ts';

export const RUNNER_VERSION = '0.1.0';
export const DEFAULT_CWD = '~/dev/me/misc';
export const DEFAULT_PORT = 8797;
export const DEFAULT_MAX_LIVE = 6;

// Everything that differs between the real install and a test lives here, so
// tests can point THREADBARE_HOME and THREADBARE_PORT somewhere harmless and
// never touch ~/Library/Application Support/Threadbare.
export type Config = {
  home: string; // data dir
  port: number;
  host: string;
  logFile: string;
  claudePath: string;
  idleMs: number;
  // Most CLIs kept live at once. Each one is a claude process plus its own
  // copy of the account's MCP servers (about 400 MB), so past this the
  // longest-idle one is released early.
  maxLive: number;
  defaults: { cwd: string; accountId?: string };
  // Where accounts are discovered. Tests can narrow these.
  claudeMainDir: string;
  claudeMainJson: string;
  tokenStatsAccountsDir: string;
};

export type RunnerJson = {
  port?: number;
  defaults?: { cwd?: string; accountId?: string };
  claudePath?: string;
  idleMinutes?: number;
  maxLiveCLIs?: number;
};

export function defaultHome(): string {
  return path.join(os.homedir(), 'Library', 'Application Support', 'Threadbare');
}

export function expandHome(p: string): string {
  if (p === '~') return os.homedir();
  if (p.startsWith('~/')) return path.join(os.homedir(), p.slice(2));
  return p;
}

export function readRunnerJson(home: string): RunnerJson {
  try {
    return JSON.parse(fs.readFileSync(path.join(home, 'runner.json'), 'utf8')) as RunnerJson;
  } catch {
    return {};
  }
}

export function writeRunnerJson(home: string, data: RunnerJson): void {
  atomicWriteFileSync(path.join(home, 'runner.json'), JSON.stringify(data, null, 2) + '\n');
}

// The app finds the runner through runner.json, so it always names the port
// the runner is actually listening on (THREADBARE_PORT and port 0 included),
// and shows the default folder so it's easy to change.
export function recordListening(home: string, port: number, defaultCwd: string): void {
  const json = readRunnerJson(home);
  if (json.port === port && json.defaults?.cwd) return;
  json.port = port;
  json.defaults = { cwd: defaultCwd, ...json.defaults };
  writeRunnerJson(home, json);
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  // THREADBARE_DATA_DIR is the name the Mac app uses for the same override.
  const home = path.resolve(expandHome(env.THREADBARE_HOME || env.THREADBARE_DATA_DIR || defaultHome()));
  const json = readRunnerJson(home);
  const port = Number(env.THREADBARE_PORT || json.port || DEFAULT_PORT);
  const idleMs = env.THREADBARE_IDLE_MS
    ? Number(env.THREADBARE_IDLE_MS)
    : (json.idleMinutes ?? 30) * 60_000;
  const maxLive = Number(env.THREADBARE_MAX_LIVE || json.maxLiveCLIs || DEFAULT_MAX_LIVE);
  return {
    home,
    port,
    host: '127.0.0.1',
    maxLive: Number.isFinite(maxLive) && maxLive >= 1 ? Math.floor(maxLive) : DEFAULT_MAX_LIVE,
    logFile: expandHome(env.THREADBARE_LOG || path.join(os.homedir(), 'Library', 'Logs', 'threadbare-runner.log')),
    claudePath: expandHome(env.THREADBARE_CLAUDE_PATH || json.claudePath || '~/.local/bin/claude'),
    idleMs,
    defaults: {
      cwd: expandHome(json.defaults?.cwd || DEFAULT_CWD),
      accountId: json.defaults?.accountId,
    },
    claudeMainDir: expandHome(env.THREADBARE_CLAUDE_MAIN_DIR || '~/.claude'),
    claudeMainJson: expandHome(env.THREADBARE_CLAUDE_MAIN_JSON || '~/.claude.json'),
    tokenStatsAccountsDir: expandHome(
      env.THREADBARE_ACCOUNTS_DIR || '~/Library/Application Support/Token Stats/Accounts',
    ),
  };
}

export const paths = {
  secrets: (home: string) => path.join(home, 'secrets'),
  token: (home: string) => path.join(home, 'secrets', 'runner-token'),
  threads: (home: string) => path.join(home, 'threads'),
  thread: (home: string, id: string) => path.join(home, 'threads', id),
  media: (home: string, id: string) => path.join(home, 'threads', id, 'media'),
  blobs: (home: string, id: string) => path.join(home, 'threads', id, 'blobs'),
  inbox: (home: string) => path.join(home, 'inbox'),
  run: (home: string) => path.join(home, 'run'),
};

// Creates the data dir layout and the bearer token (0600) if missing.
export function ensureHome(home: string): void {
  fs.mkdirSync(home, { recursive: true });
  fs.mkdirSync(paths.threads(home), { recursive: true });
  fs.mkdirSync(paths.inbox(home), { recursive: true });
  fs.mkdirSync(paths.run(home), { recursive: true });
  fs.mkdirSync(paths.secrets(home), { recursive: true, mode: 0o700 });
  fs.chmodSync(paths.secrets(home), 0o700);
  const tokenPath = paths.token(home);
  if (!fs.existsSync(tokenPath)) {
    fs.writeFileSync(tokenPath, crypto.randomBytes(32).toString('base64url') + '\n', { mode: 0o600 });
  }
  fs.chmodSync(tokenPath, 0o600);
}

export function readToken(home: string): string {
  return fs.readFileSync(paths.token(home), 'utf8').trim();
}
