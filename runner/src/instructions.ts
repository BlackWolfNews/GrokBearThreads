// Mike's standing instructions for every session: what every thread's agent
// should keep in mind, on every login, Claude and Codex alike. Kept in
// instructions.md in the data dir. '' for none.
import fs from 'node:fs';
import path from 'node:path';
import { ErrorCode, RpcError } from './protocol.ts';
import type { Notification } from './runner.ts';

export class InstructionsStore {
  private file: string;
  private publish: (n: Notification) => void;

  constructor(opts: { home: string; publish: (n: Notification) => void }) {
    this.file = path.join(opts.home, 'instructions.md');
    this.publish = opts.publish;
  }

  instructions(): string {
    try {
      return fs.readFileSync(this.file, 'utf8');
    } catch {
      return '';
    }
  }

  setInstructions(text: string): { instructions: string } {
    if (text.length > 20_000) throw new RpcError(ErrorCode.badParams, 'instructions are at most 20,000 characters');
    const clean = text.replace(/\r\n/g, '\n').trim();
    if (clean) {
      fs.writeFileSync(`${this.file}.tmp`, clean + '\n');
      fs.renameSync(`${this.file}.tmp`, this.file);
    } else {
      fs.rmSync(this.file, { force: true });
    }
    // Running threads hear it before their next message (Runner.instructionsNews).
    this.publish({ method: 'instructions.updated', params: { instructions: this.instructions() } });
    return { instructions: this.instructions() };
  }
}
