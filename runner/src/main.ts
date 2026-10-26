// Runner entry point: `node src/main.ts`. launchd runs this (see
// scripts/install-runner.sh); tests run it with THREADBARE_HOME and
// THREADBARE_PORT pointing at temp places.
import fs from 'node:fs';
import { loadConfig, ensureHome, readToken, paths, recordListening, DEFAULT_CWD, RUNNER_VERSION } from './config.ts';
import { createLogger } from './log.ts';
import { ThreadStore } from './store.ts';
import { AccountRegistry } from './accounts.ts';
import { ClaudeAdapter } from './adapters/claude/adapter.ts';
import { ProcessRegistry } from './proc.ts';
import { Runner } from './runner.ts';
import { RpcServer } from './rpc.ts';
import { realClock } from './clock.ts';
import { acquireLock } from './lock.ts';
import { removeTempFiles } from './fsutil.ts';

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
  const accounts = new AccountRegistry(cfg);
  const runner = new Runner({
    config: cfg,
    store,
    adapters: { claude: new ClaudeAdapter({ claudePath: cfg.claudePath, registry, log }) },
    accounts,
    clock: realClock,
    log,
  });
  runner.start();
  if (swept) runner.startupNotice('info', `Stopped ${swept === 1 ? 'a process group' : `${swept} process groups`} left running by the previous runner.`);

  const server = new RpcServer({ host: cfg.host, port: cfg.port, token: readToken(cfg.home), runner, log });
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

  let stopping = false;
  const stop = async (signal: string) => {
    if (stopping) return;
    stopping = true;
    log.info('runner stopping', { signal });
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

main().catch((e) => {
  process.stderr.write(`runner failed to start: ${e?.stack ?? e}\n`);
  process.exit(1);
});
