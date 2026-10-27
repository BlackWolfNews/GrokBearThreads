// Runner entry point: `node src/main.ts`. launchd runs this (see
// scripts/install-runner.sh); tests run it with THREADBARE_HOME and
// THREADBARE_PORT pointing at temp places.
import fs from 'node:fs';
import { loadConfig, ensureHome, readToken, paths, recordListening, DEFAULT_CWD, RUNNER_VERSION } from './config.ts';
import { RELEASE, markGoodLater, readRelease, takeRollbackNotice, tellLaunchListening } from './release.ts';
import { RunnerUpdater } from './update.ts';
import { Restarter, restartMethods } from './restart.ts';
import { Scheduler, scheduleMethods } from './schedules.ts';
import { createLogger } from './log.ts';
import { ThreadStore } from './store.ts';
import { AccountRegistry } from './accounts.ts';
import { ClaudeAdapter } from './adapters/claude/adapter.ts';
import { ProcessRegistry } from './proc.ts';
import { Runner } from './runner.ts';
import { CodexAdapter } from './adapters/codex/adapter.ts';
import { resolveCodexBinary } from './adapters/codex/appserver.ts';
import { checkSurface, testedVersion } from './adapters/codex/surface.ts';
import { CliUpdates } from './updates/manager.ts';
import { UsageStore } from './usage.ts';
import { RpcServer } from './rpc.ts';
import { realClock } from './clock.ts';
import { acquireLock } from './lock.ts';
import { removeTempFiles } from './fsutil.ts';
import { Models } from './models/index.ts';
import { SettingsService, modelMethods, settingsMethods } from './settings.ts';
import { ALWAYS_ASK_TOOLS, SERVER_NAME, buildThreadbareTools, threadbareMcpServer } from './threadbare-mcp.ts';

// Tells launch.mjs this runner calls its listening() hook (release.ts), so
// it may stop one that hasn't started listening in time.
export const REPORTS_LISTENING = true;

async function main(): Promise<void> {
  const cfg = loadConfig();
  ensureHome(cfg.home);
  const log = createLogger(cfg.logFile, { echo: process.env.THREADBARE_LOG_STDERR === '1', debug: process.env.THREADBARE_DEBUG === '1' });
  log.info('runner starting', { version: RUNNER_VERSION, home: cfg.home, port: cfg.port, pid: process.pid });

  // The SDK warns when canUseTool is set in bypass mode; it's deliberate
  // (AskUserQuestion still goes through it), so keep it out of the log.
  process.removeAllListeners('warning');
  process.on('warning', (w) => {
    if ((w as { code?: string }).code !== 'CLAUDE_SDK_CAN_USE_TOOL_SHADOWED') log.warn('node warning', { message: w.message });
  });

  // Before anything else touches the data dir: only one runner may own it.
  const lock = acquireLock(paths.run(cfg.home));
  if ('heldBy' in lock) {
    log.error('another runner is already using this data dir', { pid: lock.heldBy, home: cfg.home });
    process.stderr.write(`Another runner (pid ${lock.heldBy}) is already using ${cfg.home}; not starting.\n`);
    process.exit(1);
  }
  process.on('exit', () => lock.release());

  if (!fs.existsSync(cfg.claudePath)) log.warn('claude CLI not found', { path: cfg.claudePath });

  // Temp files from atomic writes a crash interrupted.
  removeTempFiles(cfg.home, paths.run(cfg.home), paths.threads(cfg.home));

  const registry = new ProcessRegistry(paths.run(cfg.home), log);
  // Waits until the old CLIs are gone, so a resume never runs beside them.
  const swept = await registry.sweepOrphans();
  if (swept) log.warn('stopped process groups left from a previous run', { count: swept });

  const store = new ThreadStore(cfg.home);
  // Token Stats' limits.json as a baseline, plus what the threads' own
  // turns report; the registry puts it on every account.
  const usage = new UsageStore({ limitsFile: cfg.tokenStatsLimitsFile, dataDir: cfg.home, clock: realClock, log });
  usage.start();
  const accounts = new AccountRegistry(cfg, usage);
  // Every session gets tools for driving Threadbare itself, bound to its
  // own thread. Sessions only start after the runner exists.
  let runner!: Runner;
  let scheduler!: Scheduler;
  let restarter!: Restarter;
  // Keeps both CLIs current (E). Its hooks call back into the runner and
  // the Restarter, made below; nothing calls them before start().
  const updates = new CliUpdates({
    cfg,
    log,
    clock: realClock,
    hooks: {
      restartPending: () => Boolean(restarter?.status().pendingRestart),
      releaseIdle: (p, v) => runner.releaseIdle(p, v),
      versionsInUse: (p) => runner.versionsInUse(p),
      codexBinariesInUse: () => runner.codexBinariesInUse(),
    },
    codex: { resolve: (start) => resolveCodexBinary(start), checkSurface, testedVersion },
    notice: (level, message) => runner.notice(level, message),
  });
  const claude = new ClaudeAdapter({
    claudePath: cfg.claudePath,
    registry,
    log,
    mcpServersFor: (threadId) => ({ [SERVER_NAME]: threadbareMcpServer(runner, threadId, scheduler) }),
    alwaysAsk: ALWAYS_ASK_TOOLS,
  });
  // One app-server per live Codex thread, each starting what E says is
  // current, with the same threadbare tools as dynamic tools.
  const codex = new CodexAdapter({
    codexBinary: () => updates.codexBinary(),
    codexArgs: cfg.codexArgs,
    registry,
    log,
    toolsFor: (threadId) => buildThreadbareTools(runner, threadId, Date.now, scheduler),
    onNotice: (text) => runner.notice('warning', text),
  });
  // The runner's own small-model calls. Reads the key from secrets/ on
  // each call, so a key written by hand works without a restart.
  let settings!: SettingsService;
  const models = new Models({
    home: cfg.home,
    clock: realClock,
    log,
    settings: () => cfg.models,
    notice: (level, message) => runner.notice(level, message),
    onSpend: () => settings.spendChanged(),
  });
  runner = new Runner({
    config: cfg,
    store,
    adapters: { claude, codex },
    accounts,
    usage,
    clock: realClock,
    log,
    models,
  });
  settings = new SettingsService({ config: cfg, models, publish: (n) => runner.publish(n), clock: realClock });
  runner.start();
  // After the threads are loaded, so a schedule that came due while the
  // runner was stopped finds its thread.
  scheduler = new Scheduler({ runner, home: cfg.home, clock: realClock, log });
  scheduler.start();
  if (swept) runner.startupNotice('info', `Stopped ${swept === 1 ? 'a process group' : `${swept} process groups`} left running by the previous runner.`);

  // launch.mjs went back to this release because a newer one kept crashing
  // at startup. Every client that says hello hears about it, not just the
  // first few minutes' worth.
  const rollback = takeRollbackNotice(cfg.home, log);
  const rolledBack = rollback?.message;
  // runner.restart: when it's time, stop the same way SIGTERM does and
  // exit 0 so launchd starts the runner again.
  restarter = new Restarter({
    runner,
    home: cfg.home,
    clock: realClock,
    log,
    release: RELEASE.release,
    branch: RELEASE.branch,
    logFile: cfg.logFile,
    rolledBack,
    rolledBackFrom: rollback?.from,
    restart: () => void stop('restart'),
    updateStatus: () => updater.status(),
  });
  // Follows main once this release has been marked good (below).
  const updater = new RunnerUpdater({
    home: cfg.home,
    release: readRelease(),
    enabled: cfg.followMain,
    clock: realClock,
    log,
    notice: (level, message) => runner.notice(level, message),
    restart: (p) => restarter.request({ when: 'idle', ...p }),
    pendingRestart: () => Boolean(restarter.status().pendingRestart),
  });

  runner.attachClis(updates);
  const methods = { ...restartMethods(restarter), ...scheduleMethods(scheduler), ...settingsMethods(settings), ...modelMethods(models) };
  // runner.status carries the CLI statuses too (protocol, "runner.status").
  const restartStatus = methods['runner.status'];
  methods['runner.status'] = (p) => ({ ...(restartStatus(p) as Record<string, unknown>), clis: updates.list() });
  const codexWarning = missingCodex(updates.codexBinary(), cfg);
  if (codexWarning) log.warn('codex CLI not found', { path: updates.codexBinary() });
  const server = new RpcServer({
    host: cfg.host,
    port: cfg.port,
    token: readToken(cfg.home),
    runner,
    log,
    clis: updates,
    methods,
    helloNotices: () => {
      // Like a missing claude: said to every client, until it's there.
      const noCodex = missingCodex(updates.codexBinary(), cfg);
      return [
        ...(rolledBack ? [{ level: 'warning' as const, message: rolledBack }] : []),
        ...(noCodex ? [{ level: 'warning' as const, message: noCodex }] : []),
        ...restarter.helloNotices(),
      ];
    },
  });
  let port: number;
  try {
    ({ port } = await server.listen());
  } catch (e) {
    const err = e as NodeJS.ErrnoException;
    const why = err.code === 'EADDRINUSE' ? `port ${cfg.port} is already in use` : err.message;
    log.error('could not listen', { port: cfg.port, error: why });
    process.stderr.write(`runner can't listen on ${cfg.host}:${cfg.port}: ${why}\n`);
    await registry.killAll(1000);
    process.exit(1);
  }
  recordListening(cfg.home, port, DEFAULT_CWD);
  log.info('runner listening', { url: `ws://${cfg.host}:${port}/rpc` });
  // Tests read this line to know the runner is up.
  process.stdout.write(`threadbare-runner listening on ${port}\n`);
  tellLaunchListening();
  // Checks start a minute after this; installs never while a restart waits.
  updates.start();
  const cancelMarkGood = markGoodLater(cfg.home, RELEASE.release, log, process.env, () => {
    restarter.proven();
    updater.start();
  });
  // Only once listening: a runner that can't listen exits, and the next
  // one should still find the resume.
  restarter.resumeAfterRestart();

  let stopping = false;
  const stop = async (signal: string) => {
    if (stopping) return;
    stopping = true;
    cancelMarkGood();
    updater.stop();
    log.info('runner stopping', { signal });
    // Whatever stopped it, a pending restart has now happened.
    restarter.stopping();
    scheduler.stop();
    usage.stop();
    updates.stop();
    settings.stop();
    try {
      await runner.shutdown();
      await server.close().catch(() => {});
      await registry.killAll(3000);
    } finally {
      log.info('runner stopped');
      process.exit(0);
    }
  };
  process.on('SIGTERM', () => void stop('SIGTERM'));
  process.on('SIGINT', () => void stop('SIGINT'));
  process.on('SIGHUP', () => void stop('SIGHUP'));
  process.on('uncaughtException', (e) => {
    log.error('uncaught exception', { error: e?.stack ?? String(e) });
  });
  process.on('unhandledRejection', (e) => {
    log.error('unhandled rejection', { error: (e as Error)?.stack ?? String(e) });
  });
  // Last resort if the process exits some other way: kill the CLI groups
  // synchronously so they never outlive the runner.
  process.on('exit', () => {
    for (const pid of registry.pids()) {
      try {
        process.kill(-pid, 'SIGKILL');
      } catch {
        // gone
      }
    }
  });
}

// A warning when the Codex binary new sessions would start isn't there, or
// undefined. Threadbare's own copy may still be on its way.
function missingCodex(start: string, cfg: ReturnType<typeof loadConfig>): string | undefined {
  const bin = resolveCodexBinary(start);
  if (fs.existsSync(bin.command)) return undefined;
  if (cfg.codexPath) return `The codex CLI isn't at ${cfg.codexPath} (codexPath in runner.json), so Codex threads can't start.`;
  if (cfg.cliUpdates.codex !== 'off') return `The codex CLI isn't at ${start} yet, so Codex threads can't start until Threadbare has installed its own copy (Usage shows how that's going).`;
  return `The codex CLI isn't at ${start}, so Codex threads can't start. Install @openai/codex next to the runner's Node, or set codexPath in runner.json.`;
}

main().catch((e) => {
  process.stderr.write(`runner failed to start: ${e?.stack ?? e}\n`);
  process.exit(1);
});
