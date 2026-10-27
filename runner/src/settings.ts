// settings.get, settings.update and settings.setKey (docs/protocol.md):
// the runner's side of the Settings window. Everything but the key lives
// in runner.json; the key lives in secrets/openrouter-key and never goes
// back out, only whether it's set and its last 4 characters.
import fs from 'node:fs';
import path from 'node:path';
import type { Config } from './config.ts';
import { expandHome, readRunnerJson, writeRunnerJson } from './config.ts';
import type { Clock } from './clock.ts';
import { ErrorCode, RpcError } from './protocol.ts';
import type { Notification } from './runner.ts';
import { keyHint, readKey, writeKey } from './models/index.ts';
import type { Models } from './models/index.ts';

export type Settings = {
  defaultCwd: string;
  idleMinutes: number;
  maxLiveCLIs: number;
  followMain: boolean;
  models: {
    openRouterKey: { set: boolean; hint?: string };
    dailyBudgetUsd: number;
    spentTodayUsd: number;
    spentMonthUsd: number;
    privateFolders: string[];
  };
};

export type SettingsUpdate = {
  defaultCwd?: string;
  idleMinutes?: number;
  maxLiveCLIs?: number;
  followMain?: boolean;
  models?: { dailyBudgetUsd?: number; privateFolders?: string[] };
};

// While calls are adding to the spend, clients hear about it at most this often.
const SPEND_NOTIFY_MS = 60_000;

export class SettingsService {
  private cfg: Config;
  private models: Models;
  private publish: (n: Notification) => void;
  private clock: Clock;
  private spendTimer?: { cancel(): void };

  constructor(opts: { config: Config; models: Models; publish: (n: Notification) => void; clock: Clock }) {
    this.cfg = opts.config;
    this.models = opts.models;
    this.publish = opts.publish;
    this.clock = opts.clock;
  }

  get(): Settings {
    const key = readKey(this.cfg.home);
    const hint = keyHint(key);
    return {
      defaultCwd: this.cfg.defaults.cwd,
      idleMinutes: Math.round((this.cfg.idleMs / 60_000) * 100) / 100,
      maxLiveCLIs: this.cfg.maxLive,
      // What the next start will do, which is what the switch means.
      followMain: readRunnerJson(this.cfg.home).followMain !== false,
      models: {
        openRouterKey: hint ? { set: true, hint } : { set: Boolean(key) },
        dailyBudgetUsd: this.cfg.models.dailyBudgetUsd,
        spentTodayUsd: round(this.models.spentTodayUsd()),
        spentMonthUsd: round(this.models.spentMonthUsd()),
        privateFolders: [...this.cfg.models.privateFolders],
      },
    };
  }

  // Checks everything before saving anything, so a bad field changes nothing.
  update(u: SettingsUpdate): Settings {
    let cwd: string | undefined;
    if (u.defaultCwd !== undefined) {
      cwd = u.defaultCwd.trim();
      const full = path.resolve(expandHome(cwd));
      if (!cwd || !isDirectory(full)) throw bad(`Folder not found: ${cwd || '(blank)'}`);
    }
    if (u.idleMinutes !== undefined && !(u.idleMinutes >= 1 && u.idleMinutes <= 24 * 60)) throw bad('idleMinutes must be from 1 to 1440');
    if (u.maxLiveCLIs !== undefined && !(Number.isInteger(u.maxLiveCLIs) && u.maxLiveCLIs >= 1 && u.maxLiveCLIs <= 20)) {
      throw bad('maxLiveCLIs must be a whole number from 1 to 20');
    }
    const budget = u.models?.dailyBudgetUsd;
    if (budget !== undefined && !(budget >= 0 && budget <= 100)) throw bad('dailyBudgetUsd must be from 0 to 100');
    const folders = u.models?.privateFolders?.map((f) => f.trim()).filter(Boolean);

    const json = readRunnerJson(this.cfg.home);
    if (cwd !== undefined) {
      json.defaults = { ...json.defaults, cwd };
      this.cfg.defaults.cwd = path.resolve(expandHome(cwd));
    }
    if (u.idleMinutes !== undefined) {
      json.idleMinutes = u.idleMinutes;
      this.cfg.idleMs = u.idleMinutes * 60_000;
    }
    if (u.maxLiveCLIs !== undefined) {
      json.maxLiveCLIs = u.maxLiveCLIs;
      this.cfg.maxLive = u.maxLiveCLIs;
    }
    // Saved only: the updater reads it when the runner starts.
    if (u.followMain !== undefined) json.followMain = u.followMain;
    if (budget !== undefined || folders !== undefined) {
      json.models = { ...json.models };
      if (budget !== undefined) json.models.dailyBudgetUsd = this.cfg.models.dailyBudgetUsd = budget;
      if (folders !== undefined) json.models.privateFolders = this.cfg.models.privateFolders = [...new Set(folders)];
    }
    writeRunnerJson(this.cfg.home, json);
    return this.changed();
  }

  setKey(provider: string, key: string | null): Settings {
    if (provider !== 'openrouter') throw bad(`Unknown provider ${provider}; only "openrouter" for now`);
    if (key !== null) {
      key = key.trim();
      if (key.length < 20 || /\s/.test(key)) throw bad("That doesn't look like an OpenRouter key.");
    }
    writeKey(this.cfg.home, key);
    return this.changed();
  }

  // Models calls this after each call that went out.
  spendChanged(): void {
    if (this.spendTimer) return;
    this.spendTimer = this.clock.setTimeout(() => {
      this.spendTimer = undefined;
      this.publish({ method: 'settings.updated', params: { settings: this.get() } });
    }, SPEND_NOTIFY_MS);
  }

  stop(): void {
    this.spendTimer?.cancel();
    this.spendTimer = undefined;
  }

  private changed(): Settings {
    const settings = this.get();
    this.publish({ method: 'settings.updated', params: { settings } });
    return settings;
  }
}

export function settingsMethods(s: SettingsService): Record<string, (p: Record<string, unknown>) => unknown> {
  return {
    'settings.get': () => ({ settings: s.get() }),
    'settings.update': (p) => {
      const u: SettingsUpdate = {};
      if (p.defaultCwd !== undefined) u.defaultCwd = str(p.defaultCwd, 'defaultCwd');
      if (p.idleMinutes !== undefined) u.idleMinutes = num(p.idleMinutes, 'idleMinutes');
      if (p.maxLiveCLIs !== undefined) u.maxLiveCLIs = num(p.maxLiveCLIs, 'maxLiveCLIs');
      if (p.followMain !== undefined) {
        if (typeof p.followMain !== 'boolean') throw bad('followMain must be a boolean');
        u.followMain = p.followMain;
      }
      if (p.models !== undefined) {
        const m = p.models;
        if (!m || typeof m !== 'object' || Array.isArray(m)) throw bad('models must be an object');
        const mm = m as Record<string, unknown>;
        u.models = {};
        if (mm.dailyBudgetUsd !== undefined) u.models.dailyBudgetUsd = num(mm.dailyBudgetUsd, 'models.dailyBudgetUsd');
        if (mm.privateFolders !== undefined) {
          if (!Array.isArray(mm.privateFolders) || mm.privateFolders.some((f) => typeof f !== 'string')) {
            throw bad('models.privateFolders must be an array of strings');
          }
          u.models.privateFolders = mm.privateFolders as string[];
        }
      }
      return { settings: s.update(u) };
    },
    'settings.setKey': (p) => {
      if (p.key !== null && typeof p.key !== 'string') throw bad('key must be a string or null');
      return { settings: s.setKey(str(p.provider, 'provider'), p.key as string | null) };
    },
  };
}

// models.run: one call by hand, for `tb models try`. Spends like any other.
export function modelMethods(m: Models): Record<string, (p: Record<string, unknown>) => unknown> {
  return {
    'models.run': async (p) => {
      const job = str(p.job, 'job');
      const text = str(p.text, 'text');
      const cwd = p.cwd === undefined ? undefined : str(p.cwd, 'cwd');
      const feature = 'tb';
      switch (job) {
        case 'classify': {
          if (!Array.isArray(p.labels) || p.labels.length < 2 || p.labels.some((l) => typeof l !== 'string')) throw bad('labels must be 2 or more strings');
          return m.classify({ feature, cwd, text, labels: p.labels as string[], instructions: p.system === undefined ? undefined : str(p.system, 'system') });
        }
        case 'extract': {
          const f = p.fields;
          if (!f || typeof f !== 'object' || Array.isArray(f) || !Object.keys(f).length || Object.values(f).some((v) => typeof v !== 'string')) {
            throw bad('fields must map each name to a description');
          }
          return m.extract({ feature, cwd, text, fields: f as Record<string, string> });
        }
        case 'summarize':
          return m.summarize({ feature, cwd, text, maxWords: p.maxWords === undefined ? undefined : num(p.maxWords, 'maxWords') });
        case 'generate':
          return m.generate({ feature, cwd, prompt: text, system: p.system === undefined ? undefined : str(p.system, 'system') });
        default:
          throw bad('job must be classify, extract, summarize or generate');
      }
    },
  };
}

function bad(message: string): RpcError {
  return new RpcError(ErrorCode.badParams, message);
}

function str(v: unknown, k: string): string {
  if (typeof v !== 'string') throw bad(`${k} must be a string`);
  return v;
}

function num(v: unknown, k: string): number {
  if (typeof v !== 'number' || !Number.isFinite(v)) throw bad(`${k} must be a number`);
  return v;
}

function round(n: number): number {
  return Math.round(n * 1e6) / 1e6;
}

function isDirectory(p: string): boolean {
  try {
    return fs.statSync(p).isDirectory();
  } catch {
    return false;
  }
}
