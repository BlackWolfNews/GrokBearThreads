import fs from 'node:fs';
import path from 'node:path';
import type { Account, ModelChoice } from './protocol.ts';
import type { Config } from './config.ts';
import { isDirectory } from './fsutil.ts';

// Reads only oauthAccount.emailAddress from a .claude.json. Tokens live in
// the Keychain and are never read; this file only names the login.
export function readLoginEmail(claudeJsonPath: string): string | undefined {
  try {
    const raw = fs.readFileSync(claudeJsonPath, 'utf8');
    const parsed = JSON.parse(raw) as { oauthAccount?: { emailAddress?: unknown } };
    const email = parsed.oauthAccount?.emailAddress;
    return typeof email === 'string' && email ? email : undefined;
  } catch {
    return undefined;
  }
}

// Claude logins: ~/.claude is claude-main (its .claude.json sits at
// ~/.claude.json), and each Token Stats account folder claude-N is its own
// CLAUDE_CONFIG_DIR with .claude.json inside.
// The model an account's own settings.json names ("claude-fable-5-1[1m]"),
// which the CLI uses for a session that names none. Only that one key is
// read. Absent, blank or not a string: the CLI's own default.
export function readSettingsModel(settingsPath: string): string | undefined {
  try {
    const parsed = JSON.parse(fs.readFileSync(settingsPath, 'utf8')) as { model?: unknown };
    return typeof parsed.model === 'string' && parsed.model.trim() ? parsed.model.trim() : undefined;
  } catch {
    return undefined;
  }
}

// "claude-fable-5-1[1m]" is the 1M-context form of "claude-fable-5-1".
export function stripModelSuffix(model: string): string {
  return model.replace(/\[[^\]]*\]$/, '');
}

// What the runner has learned about an account since it started: the
// CLI's model list (asked once), and the model a thread with none ran on.
export type LearnedAccountInfo = { models?: ModelChoice[]; defaultModel?: string };

// The full id a thread with no model runs on. A turn that showed it wins;
// otherwise the account's settings.json, turned into a full id through the
// CLI's model list when that's known. Nothing set: unknown, since the CLI's
// own default is only reported once it runs.
export function resolveDefaultModel(settingsModel: string | undefined, learned: LearnedAccountInfo | undefined): string | undefined {
  if (learned?.defaultModel) return learned.defaultModel;
  if (!settingsModel) return undefined;
  const row = learned?.models?.find((m) => m.id === settingsModel || m.model === settingsModel);
  return row?.model ?? stripModelSuffix(settingsModel);
}

export function discoverAccounts(cfg: Pick<Config, 'claudeMainDir' | 'claudeMainJson' | 'tokenStatsAccountsDir'>): Account[] {
  const out: Account[] = [];
  if (isDirectory(cfg.claudeMainDir)) {
    out.push(withDefaultModel({
      id: 'claude-main',
      provider: 'claude',
      title: readLoginEmail(cfg.claudeMainJson) ?? readLoginEmail(path.join(cfg.claudeMainDir, '.claude.json')) ?? 'claude-main',
      configDir: cfg.claudeMainDir,
    }));
  }
  let names: string[] = [];
  try {
    names = fs.readdirSync(cfg.tokenStatsAccountsDir);
  } catch {
    names = [];
  }
  const numbered = names
    .map((n) => /^claude-(\d+)$/.exec(n))
    .filter((m): m is RegExpExecArray => m !== null)
    .sort((a, b) => Number(a[1]) - Number(b[1]));
  for (const m of numbered) {
    const dir = path.join(cfg.tokenStatsAccountsDir, m[0]);
    if (!isDirectory(dir)) continue;
    out.push(withDefaultModel({
      id: m[0],
      provider: 'claude',
      title: readLoginEmail(path.join(dir, '.claude.json')) ?? m[0],
      configDir: dir,
    }));
  }
  return out;
}

function withDefaultModel(account: Account): Account {
  const model = resolveDefaultModel(readSettingsModel(path.join(account.configDir, 'settings.json')), undefined);
  if (model) account.defaultModel = model;
  return account;
}

export class AccountRegistry {
  private cfg: Pick<Config, 'claudeMainDir' | 'claudeMainJson' | 'tokenStatsAccountsDir'>;
  private cache: Account[] = [];
  private at = 0;
  private learned = new Map<string, LearnedAccountInfo>();

  constructor(cfg: Pick<Config, 'claudeMainDir' | 'claudeMainJson' | 'tokenStatsAccountsDir'>) {
    this.cfg = cfg;
  }

  // Re-scans at most every 10 seconds so a newly added login shows up
  // without restarting the runner.
  list(): Account[] {
    if (Date.now() - this.at > 10_000 || this.cache.length === 0) {
      this.cache = discoverAccounts(this.cfg).map((a) => this.enrich(a));
      this.at = Date.now();
    }
    return this.cache;
  }

  // Keeps what a probe or a turn showed about an account. Returns whether
  // anything changed, so the runner can tell its clients.
  learn(id: string, info: LearnedAccountInfo): boolean {
    const have = this.learned.get(id) ?? {};
    const next: LearnedAccountInfo = { ...have };
    if (info.models && JSON.stringify(info.models) !== JSON.stringify(have.models)) next.models = info.models;
    if (info.defaultModel && info.defaultModel !== have.defaultModel) next.defaultModel = info.defaultModel;
    if (JSON.stringify(next) === JSON.stringify(have)) return false;
    this.learned.set(id, next);
    this.cache = this.cache.map((a) => (a.id === id ? this.enrich(a) : a));
    return true;
  }

  private enrich(account: Account): Account {
    const learned = this.learned.get(account.id);
    if (!learned) return account;
    const out: Account = { ...account };
    const settingsModel = readSettingsModel(path.join(account.configDir, 'settings.json'));
    const model = resolveDefaultModel(settingsModel, learned);
    if (model) out.defaultModel = model;
    else delete out.defaultModel;
    if (learned.models) out.models = learned.models;
    return out;
  }

  get(id: string): Account | undefined {
    return this.list().find((a) => a.id === id);
  }
}
