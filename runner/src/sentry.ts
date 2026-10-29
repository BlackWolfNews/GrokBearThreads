// Error reporting to Sentry (project `threadbear`, tag component: runner),
// for the installed runner only. Agents start dev runners, tests and
// sandbox installs all day, and an agent watcher opens a thread for what
// reaches Sentry, so only a release snapshot (release.json beside src/)
// running on the real data dir reports. Anything run from a checkout
// (scripts/dev-runner.sh, `npm start`, the tests) has no release.json, and
// a sandbox install has another home. THREADBEAR_SENTRY=off turns it off.
//
// Errors only: no tracing, no breadcrumbs (CLI output and URLs can carry
// a thread's text or a token), no PII or local variables. What it sends is the
// runner's own uncaught exceptions and its ERROR log lines, by message.
import fs from 'node:fs';
import path from 'node:path';
import { defaultHome } from './config.ts';
import { RELEASE } from './release.ts';

// A public client key (it ships in every Sentry client); fine to commit.
const DSN = 'https://c69460318b1f938fd1703c6578a059f6@o4508736647266304.ingest.us.sentry.io/4512336956293120';

// Default integrations left out. main.ts's own handlers report every
// uncaught exception and rejection (Sentry's report only the first
// uncaught one, and may exit the process). ProcessSession sends release
// health sessions, which aren't errors. The rest only make breadcrumbs
// or read local variables.
const LEFT_OUT = new Set(['OnUncaughtException', 'OnUnhandledRejection', 'ProcessSession', 'Console', 'Http', 'NodeFetch', 'LocalVariablesAsync']);

type SentryModule = typeof import('@sentry/node');
let sentry: SentryModule | undefined;

function realPath(p: string): string {
  try {
    return fs.realpathSync(p);
  } catch {
    return path.resolve(p);
  }
}

// Whether this runner reports: a release, on the real data dir, not
// switched off. Pure, for the tests.
export function sentryWanted(home: string, env: NodeJS.ProcessEnv = process.env, release: string | undefined = RELEASE.release): boolean {
  if (!release) return false;
  if (env.THREADBEAR_SENTRY === 'off' || env.NODE_ENV === 'test') return false;
  return realPath(home) === realPath(defaultHome());
}

// Loads the SDK only when it's wanted, so a dev runner or a test never
// even imports it. Never throws: reporting must not stop the runner.
export async function startSentry(home: string): Promise<boolean> {
  if (!sentryWanted(home)) return false;
  try {
    const S = await import('@sentry/node');
    S.init({
      dsn: DSN,
      environment: 'production',
      release: `threadbear-runner@${RELEASE.version}`,
      // Not the Mac's own name, which the SDK sends by default.
      serverName: 'threadbear-runner',
      // v11's replacement for sendDefaultPii: false. Its defaults collect
      // all of these, local variables included (a thread's text, a token).
      dataCollection: {
        userInfo: false,
        cookies: false,
        httpHeaders: false,
        httpBodies: [],
        urlQueryParams: false,
        graphQL: { document: false, variables: false },
        genAI: { inputs: false, outputs: false },
        mcp: { inputs: false, outputs: false },
        databaseQueryData: false,
        queues: false,
        stackFrameVariables: false,
      },
      // The runtime module hooks are for tracing's instrumentation.
      enableRuntimeChannelInjection: false,
      beforeBreadcrumb: () => null,
      integrations: (all) => all.filter((i) => !LEFT_OUT.has(i.name)),
      initialScope: { tags: { component: 'runner' } },
    });
    sentry = S;
    return true;
  } catch {
    return false;
  }
}

export function reportException(e: unknown, what: string): void {
  if (!sentry) return;
  try {
    sentry.captureException(e, { tags: { what } });
  } catch {
    // never mind
  }
}

// Logged errors that main.ts reports as exceptions, with their stacks.
const REPORTED_AS_EXCEPTIONS = new Set(['uncaught exception', 'unhandled rejection']);
// Fields of a log line worth sending. Others (paths, prompts, a CLI's
// output under some other name) stay in runner.log.
const SAFE_FIELDS = new Set(['error', 'method', 'kind', 'provider', 'commit', 'port', 'pid', 'threadId', 'reviewId']);
// One event per message an hour is plenty for the watcher, and keeps a
// failure that repeats every second from using up the month's quota.
const SAME_MESSAGE_MS = 60 * 60_000;
const lastSent = new Map<string, number>();

// The logger's hook for each ERROR line: one Sentry event per message,
// grouped by the message (the fixed text, not the error inside it).
export function reportLoggedError(msg: string, extra: Record<string, unknown> | undefined, now = Date.now()): void {
  if (!sentry || REPORTED_AS_EXCEPTIONS.has(msg)) return;
  const last = lastSent.get(msg);
  if (last !== undefined && now - last < SAME_MESSAGE_MS) return;
  lastSent.set(msg, now);
  try {
    sentry.captureMessage(msg, { level: 'error', fingerprint: ['runner-log', msg], extra: safeFields(extra) });
  } catch {
    // never mind
  }
}

export function safeFields(extra: Record<string, unknown> | undefined): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(extra ?? {})) {
    if (!SAFE_FIELDS.has(k)) continue;
    if (typeof v === 'number' || typeof v === 'boolean') out[k] = v;
    else if (typeof v === 'string') out[k] = v.length > 1000 ? `${v.slice(0, 1000)}…` : v;
  }
  return out;
}

// Before a deliberate exit, so the last event goes out.
export async function flushSentry(ms = 2000): Promise<void> {
  if (!sentry) return;
  try {
    await sentry.flush(ms);
  } catch {
    // never mind
  }
}
