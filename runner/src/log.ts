import fs from 'node:fs';
import path from 'node:path';

export type Logger = {
  info(msg: string, extra?: Record<string, unknown>): void;
  warn(msg: string, extra?: Record<string, unknown>): void;
  error(msg: string, extra?: Record<string, unknown>): void;
  debug(msg: string, extra?: Record<string, unknown>): void;
};

// Plain line logger. Never pass secrets in `extra`; callers log names and
// paths only.
export function createLogger(file: string | null, opts: { echo?: boolean; debug?: boolean } = {}): Logger {
  let fd: number | null = null;
  if (file) {
    try {
      fs.mkdirSync(path.dirname(file), { recursive: true });
      fd = fs.openSync(file, 'a');
    } catch {
      fd = null;
    }
  }
  const write = (level: string, msg: string, extra?: Record<string, unknown>) => {
    const line = `${new Date().toISOString()} ${level} ${msg}${extra ? ' ' + safeJson(extra) : ''}\n`;
    if (fd !== null) {
      try {
        fs.writeSync(fd, line);
      } catch {
        // Logging must never take the runner down.
      }
    }
    if (opts.echo) process.stderr.write(line);
  };
  return {
    info: (m, e) => write('INFO', m, e),
    warn: (m, e) => write('WARN', m, e),
    error: (m, e) => write('ERROR', m, e),
    debug: (m, e) => {
      if (opts.debug) write('DEBUG', m, e);
    },
  };
}

function safeJson(v: unknown): string {
  try {
    return JSON.stringify(v);
  } catch {
    return String(v);
  }
}

export const nullLogger: Logger = { info() {}, warn() {}, error() {}, debug() {} };
