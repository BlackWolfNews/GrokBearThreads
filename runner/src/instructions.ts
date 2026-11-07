// Mike's standing instructions for every session (docs/protocol.md,
// "Standing instructions"): what every thread's agent should keep in mind,
// on every login, Claude and Codex alike. After Wayne Sutton's PR.
//
// They go into the brief of every future session in every folder, including
// threads that ask before they do anything, so writing them is a way for one
// thread to steer all the others. So the file alone doesn't count: only what
// instructions.set saved does, bound by an HMAC keyed by the runner's RPC
// token. A plain hash beside the file would only catch a careless edit, as
// anything that can write the file can write the hash; with the token,
// signing a file takes exactly what calling instructions.set takes, so
// there's one thing to protect and one line to draw (the protocol doc has
// where it stops, on Full access).
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { readToken } from './config.ts';
import { experimentOn } from './experiments.ts';
import { atomicWriteFileSync } from './fsutil.ts';
import { ErrorCode, RpcError } from './protocol.ts';
import type { Notification } from './runner.ts';

export type StandingInstructions = {
  text: string;
  // The file isn't what Settings last saved, so no agent is given it.
  outside?: true;
};

const MAX_CHARS = 20_000;
// What 20,000 characters can come to, and well past anything saved here.
const MAX_BYTES = 64 * 1024;
const SIGNING_CONTEXT = 'threadbear-standing-instructions-v1\n';
const OUTSIDE_NOTICE = "Your standing instructions were changed outside Settings, so agents aren't being given them. Look in Settings > General to keep or clear them.";

export class InstructionsStore {
  private home: string;
  private file: string;
  private sig: string;
  private publish: (n: Notification) => void;
  // The version of an outside change last said, so it's said once.
  private noticed?: string;

  constructor(opts: { home: string; publish: (n: Notification) => void }) {
    this.home = opts.home;
    this.file = path.join(opts.home, 'instructions.md');
    this.sig = path.join(opts.home, 'instructions.sig');
    this.publish = opts.publish;
  }

  on(): boolean {
    return experimentOn(this.home, 'standingInstructions');
  }

  // What a session is told: the text only if Settings saved it. '' for none,
  // with the experiment off, or when the file is anything else.
  given(): string {
    if (!this.on()) return '';
    const now = this.read();
    return now.outside ? '' : now.text;
  }

  status(): StandingInstructions {
    return this.read();
  }

  set(text: string): StandingInstructions {
    if (text.length > MAX_CHARS) throw new RpcError(ErrorCode.badParams, 'Standing instructions are at most 20,000 characters.');
    const clean = text.replace(/\r\n/g, '\n').trim();
    if (clean) {
      const bytes = Buffer.from(clean + '\n', 'utf8');
      if (bytes.length > MAX_BYTES) throw new RpcError(ErrorCode.badParams, 'Standing instructions are too long.');
      // Atomic renames over whatever's there, a link included, so nothing
      // this writes goes through something an agent put in its place. The
      // signature goes first: a crash between them reads as changed outside
      // rather than as trusted.
      atomicWriteFileSync(this.sig, this.mac(bytes) + '\n');
      atomicWriteFileSync(this.file, bytes);
    } else {
      fs.rmSync(this.file, { force: true });
      fs.rmSync(this.sig, { force: true });
    }
    this.noticed = undefined;
    const instructions = this.read();
    // Running threads hear it before their next message (Runner.instructionsNews).
    this.publish({ method: 'instructions.updated', params: { instructions } });
    return instructions;
  }

  // While they're changed outside, for a client that's just said hello.
  helloNotices(): { level: 'warning'; message: string }[] {
    return this.on() && this.read().outside ? [{ level: 'warning', message: OUTSIDE_NOTICE }] : [];
  }

  // One read of each file, so what's checked is what's given.
  private read(): StandingInstructions {
    const body = readPlain(this.file);
    const sig = readPlain(this.sig);
    if (body === 'missing' && sig === 'missing') return this.settled({ text: '' });
    const text = Buffer.isBuffer(body) ? body.toString('utf8') : '';
    if (Buffer.isBuffer(body) && Buffer.isBuffer(sig) && this.signedBy(body, sig)) return this.settled({ text });
    return this.changedOutside(text, Buffer.isBuffer(body) ? crypto.createHash('sha256').update(body).digest('hex') : String(body));
  }

  private settled(now: StandingInstructions): StandingInstructions {
    this.noticed = undefined;
    return now;
  }

  private changedOutside(text: string, version: string): StandingInstructions {
    const now: StandingInstructions = { text, outside: true };
    if (this.noticed !== version) {
      this.noticed = version;
      // Never its text: the warning is the runner's words, not the file's.
      this.publish({ method: 'runner.notice', params: { level: 'warning', message: OUTSIDE_NOTICE } });
      this.publish({ method: 'instructions.updated', params: { instructions: now } });
    }
    return now;
  }

  private mac(bytes: Buffer): string {
    return crypto.createHmac('sha256', readToken(this.home)).update(SIGNING_CONTEXT).update(bytes).digest('hex');
  }

  private signedBy(bytes: Buffer, sig: Buffer): boolean {
    let want: Buffer;
    try {
      want = Buffer.from(this.mac(bytes));
    } catch {
      return false; // no token to check with
    }
    const got = Buffer.from(sig.toString('utf8').trim());
    return got.length === want.length && crypto.timingSafeEqual(got, want);
  }
}

// A plain file's bytes. Not through a link, and never opening something that
// would block (a FIFO put here would hang the runner on every message), as
// this runs on every send. Anything else that isn't a small plain file is
// 'unusable', which reads as changed outside.
function readPlain(file: string): Buffer | 'missing' | 'unusable' {
  let fd: number;
  try {
    fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
  } catch (e) {
    return (e as NodeJS.ErrnoException).code === 'ENOENT' ? 'missing' : 'unusable';
  }
  try {
    const stat = fs.fstatSync(fd);
    if (!stat.isFile() || stat.size > MAX_BYTES) return 'unusable';
    const bytes = Buffer.alloc(stat.size);
    let got = 0;
    while (got < bytes.length) {
      const n = fs.readSync(fd, bytes, got, bytes.length - got, got);
      if (n === 0) break;
      got += n;
    }
    return bytes.subarray(0, got);
  } catch {
    return 'unusable';
  } finally {
    fs.closeSync(fd);
  }
}

export function instructionsMethods(s: InstructionsStore): Record<string, (p: Record<string, unknown>) => unknown> {
  // As a runner without them would: the app shows no box.
  const needOn = () => {
    if (!s.on()) throw new RpcError(ErrorCode.methodNotFound, 'Standing instructions are an experiment, and this one is off.');
  };
  return {
    'instructions.get': () => {
      needOn();
      return { instructions: s.status() };
    },
    'instructions.set': (p) => {
      needOn();
      if (typeof p.text !== 'string') throw new RpcError(ErrorCode.badParams, 'text must be a string');
      return { instructions: s.set(p.text) };
    },
  };
}
