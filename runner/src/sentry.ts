// Error reporting to Sentry (project `threadbear`, tag component: runner),
// for the installed runner only. Agents start dev runners, tests and
// sandbox installs all day, and an agent watcher opens a thread for what
// reaches Sentry, so only a release snapshot (release.json beside src/)
// running on the real data dir reports. Anything run from a checkout
// (scripts/dev-runner.sh, `npm start`, the tests) has no release.json, and
// a sandbox install has another home. THREADBEAR_SENTRY=off turns it off.
// And only Mike's own copies (origin is mikecann/threadbear): someone's
// fork never reports to Mike's Sentry, nor opens threads in his watcher
// (docs/on-your-mac.md).
//
// Errors only: no tracing, no breadcrumbs (CLI output and URLs can carry
// a thread's text or a token), no PII or local variables. What it sends is the
// runner's own uncaught exceptions and its ERROR and WARN log lines, by
// message (WARN as Sentry warnings).
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { defaultHome } from './config.ts';
import { RELEASE, readRelease } from './release.ts';
import { repoKey } from './upstream.ts';

const MIKES_REPO = 'github.com/mikecann/threadbear';

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

// The origin remote of the checkout this release follows, if any.
function releaseOrigin(): string | undefined {
  const checkout = readRelease()?.checkout;
  if (!checkout) return undefined;
  const r = spawnSync('git', ['-C', checkout, 'remote', 'get-url', 'origin'], { encoding: 'utf8' });
  return r.status === 0 ? r.stdout.trim() : undefined;
}

// Whether this runner reports: a release of Mike's own repo, on the real
// data dir, not switched off. Pure but for the default origin, for the tests.
export function sentryWanted(home: string, env: NodeJS.ProcessEnv = process.env, release: string | undefined = RELEASE.release, origin: string | undefined = release ? releaseOrigin() : undefined): boolean {
  if (!release) return false;
  if (env.THREADBEAR_SENTRY === 'off' || env.NODE_ENV === 'test') return false;
  if (!origin || repoKey(origin) !== MIKES_REPO) return false;
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
      // v11 attaches a stack to captureMessage by default, which turns each
      // log line into a nameless exception titled after reportLogLine.
      // Without it the issue is titled with the log message.
      attachStacktrace: false,
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
const UUID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi;

export type LogLevel = 'error' | 'warning';

// Log lines that aren't Threadbear bugs, so they never become issues: a
// model call failing is a login's limit or a provider being down, and
// Convex sync retries its network blips by itself.
function notOurBug(msg: string, extra: Record<string, unknown> | undefined): boolean {
  if (msg === 'model call failed') return true;
  return msg === 'convex sync failed; will retry' && /fetch failed/i.test(String(extra?.error ?? ''));
}

// What to send for one ERROR or WARN line, or null to send nothing. Grouped
// by the message (the fixed text, not the error inside it), with any thread
// or session id taken out so one fault is one issue. Pure but for the
// once-an-hour memory, for the tests.
export function logLineEvent(level: LogLevel, msg: string, extra: Record<string, unknown> | undefined, now = Date.now()) {
  if (REPORTED_AS_EXCEPTIONS.has(msg) || notOurBug(msg, extra)) return null;
  // One message can cover many causes: 'request failed' is logged for every
  // RPC method, so the method goes in the title to keep their issues apart.
  const method = typeof extra?.method === 'string' ? extra.method : undefined;
  const title = (method ? `${msg} (${method})` : msg).replace(UUID, '<id>');
  const key = `${level} ${title}`;
  const last = lastSent.get(key);
  if (last !== undefined && now - last < SAME_MESSAGE_MS) return null;
  lastSent.set(key, now);
  return { title, level, fingerprint: ['runner-log', level, title], extra: safeFields(extra) };
}

// The logger's hooks for each ERROR and WARN line.
export function reportLoggedError(msg: string, extra?: Record<string, unknown>): void {
  reportLogLine('error', msg, extra);
}

export function reportLoggedWarning(msg: string, extra?: Record<string, unknown>): void {
  reportLogLine('warning', msg, extra);
}

function reportLogLine(level: LogLevel, msg: string, extra: Record<string, unknown> | undefined): void {
  if (!sentry) return;
  const event = logLineEvent(level, msg, extra);
  if (!event) return;
  try {
    sentry.captureMessage(event.title, { level: event.level, fingerprint: event.fingerprint, extra: event.extra });
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
