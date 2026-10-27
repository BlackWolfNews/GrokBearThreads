import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { atomicWriteFileSync } from './fsutil.ts';
import { RELEASE } from './release.ts';
import { CLI_POLICIES, isEffortLevel, isProvider, type CliPolicy, type EffortLevel, type Provider } from './protocol.ts';

// <package version>+<release id>, or +source when run from a checkout.
export const RUNNER_VERSION = RELEASE.version;
export const DEFAULT_CWD = '~/dev/me/misc';
export const DEFAULT_PORT = 8797;
export const DEFAULT_MAX_LIVE = 6;

// Notes shown with an account in the app's account menu. In the code rather
// than Mike's runner.json so nobody has to edit that; a runner.json
// accountNotes replaces the whole map.
export const DEFAULT_ACCOUNT_NOTES: Record<string, string> = { 'claude-2': 'Convex work only' };

export type CliUpdatesConfig = {
  claude: CliPolicy;
  codex: CliPolicy;
  checkMinutes: number;
  keepCodexVersions: number; // Codex copies kept under <home>/tools/codex
};
export const DEFAULT_CLI_UPDATES: CliUpdatesConfig = { claude: 'auto', codex: 'auto', checkMinutes: 60, keepCodexVersions: 2 };

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
  // model: what threads.create uses when it isn't given one (a dev runner
  // sets the cheapest, so a thread started from a debug app's composer
  // doesn't run on the account's default). Unset means the account's own.
  // models and efforts are the same per provider (models.claude wins over
  // model); unset means the account's own default or the model's own level.
  defaults: {
    cwd: string;
    accountId?: string;
    model?: string;
    models?: Partial<Record<Provider, string>>;
    efforts?: Partial<Record<Provider, EffortLevel>>;
  };
  // Where accounts are discovered. Tests can narrow these.
  claudeMainDir: string;
  claudeMainJson: string;
  tokenStatsAccountsDir: string;
  // A Codex binary set by hand, used as is and never updated. Unset means
  // Threadbare's own copy (<home>/tools/codex/current), or until there is
  // one the codex next to the runner's Node; never ~/.local/bin/codex.
  codexPath?: string;
  codexArgs: string[]; // extra `codex app-server` arguments
  codexMainDir: string; // codex-main's CODEX_HOME
  tokenStatsLimitsFile: string; // Token Stats' limits.json, read only
  cliUpdates: CliUpdatesConfig;
  accountNotes: Record<string, string>;
};

export type RunnerJson = {
  port?: number;
  defaults?: {
    cwd?: string;
    accountId?: string;
    model?: string;
    models?: Partial<Record<Provider, string>>;
    efforts?: Partial<Record<Provider, EffortLevel>>;
  };
  claudePath?: string;
  idleMinutes?: number;
  maxLiveCLIs?: number;
  codexPath?: string;
  codexArgs?: string[];
  cliUpdates?: Partial<CliUpdatesConfig>;
  accountNotes?: Record<string, string>;
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
  const codexPath = nonEmpty(env.THREADBARE_CODEX_PATH) ?? nonEmpty(json.codexPath);
  const models = providerMap(json.defaults?.models, nonEmpty);
  const efforts = providerMap(json.defaults?.efforts, (v) => (isEffortLevel(v) ? v : undefined));
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
      model: nonEmpty(json.defaults?.model),
      ...(models ? { models } : {}),
      ...(efforts ? { efforts } : {}),
    },
    claudeMainDir: expandHome(env.THREADBARE_CLAUDE_MAIN_DIR || '~/.claude'),
    claudeMainJson: expandHome(env.THREADBARE_CLAUDE_MAIN_JSON || '~/.claude.json'),
    tokenStatsAccountsDir: expandHome(
      env.THREADBARE_ACCOUNTS_DIR || '~/Library/Application Support/Token Stats/Accounts',
    ),
    ...(codexPath ? { codexPath: expandHome(codexPath) } : {}),
    codexArgs: Array.isArray(json.codexArgs) ? json.codexArgs.filter((a): a is string => typeof a === 'string') : [],
    codexMainDir: expandHome(env.THREADBARE_CODEX_MAIN_DIR || '~/.codex'),
    tokenStatsLimitsFile: expandHome(
      env.THREADBARE_TOKEN_STATS_LIMITS || '~/Library/Application Support/Token Stats/limits.json',
    ),
    cliUpdates: cliUpdatesConfig(json.cliUpdates, env.THREADBARE_CLI_UPDATES),
    accountNotes: stringMap(json.accountNotes) ?? { ...DEFAULT_ACCOUNT_NOTES },
  };
}

function nonEmpty(v: unknown): string | undefined {
  return typeof v === 'string' && v.trim() ? v.trim() : undefined;
}

// { claude?, codex? } with only the providers that have a usable value;
// undefined when none has, so an unset map stays absent.
function providerMap<V>(raw: unknown, read: (v: unknown) => V | undefined): Partial<Record<Provider, V>> | undefined {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return undefined;
  const out: Partial<Record<Provider, V>> = {};
  for (const [p, v] of Object.entries(raw)) {
    const value = read(v);
    if (isProvider(p) && value !== undefined) out[p] = value;
  }
  return Object.keys(out).length ? out : undefined;
}

function stringMap(raw: unknown): Record<string, string> | undefined {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return undefined;
  return Object.fromEntries(Object.entries(raw).filter((e): e is [string, string] => typeof e[1] === 'string'));
}

// THREADBARE_CLI_UPDATES=off turns both off whatever runner.json says: tests
// and dev runners must never install a CLI.
function cliUpdatesConfig(raw: Partial<CliUpdatesConfig> | undefined, envValue: string | undefined): CliUpdatesConfig {
  const policy = (v: unknown, fallback: CliPolicy): CliPolicy =>
    typeof v === 'string' && (CLI_POLICIES as readonly string[]).includes(v) ? (v as CliPolicy) : fallback;
  const count = (v: unknown, fallback: number, min: number): number =>
    typeof v === 'number' && Number.isFinite(v) && v >= min ? Math.floor(v) : fallback;
  const off = envValue === 'off';
  return {
    claude: off ? 'off' : policy(raw?.claude, DEFAULT_CLI_UPDATES.claude),
    codex: off ? 'off' : policy(raw?.codex, DEFAULT_CLI_UPDATES.codex),
    checkMinutes: count(raw?.checkMinutes, DEFAULT_CLI_UPDATES.checkMinutes, 1),
    // Fewer than 2 would leave nothing for "Go back".
    keepCodexVersions: count(raw?.keepCodexVersions, DEFAULT_CLI_UPDATES.keepCodexVersions, 2),
  };
}

// Where a client (tb) finds the runner. THREADBARE_PORT=0 tells a runner to
// take any free port, and the CLIs a dev or sandbox runner starts inherit
// it, so then the port it got, in runner.json, is the one to use.
export function runnerUrl(cfg: Config, env: NodeJS.ProcessEnv = process.env): string {
  if (env.THREADBARE_URL) return env.THREADBARE_URL;
  const port = cfg.port || readRunnerJson(cfg.home).port || DEFAULT_PORT;
  return `ws://127.0.0.1:${port}/rpc`;
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
