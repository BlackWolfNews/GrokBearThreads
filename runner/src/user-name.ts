// Who the person reading the threads is, for the instructions and prompts
// the runner gives models. Everything an agent reads says "the user", as
// Threadbear runs on other people's Macs too, and this one line gives the
// agent their name. It's the first word of the Mac account's full name
// ("Mike Cann" -> "Mike"); left out when there isn't one.
import { execFileSync } from 'node:child_process';

export function firstName(fullName: string): string | undefined {
  return fullName.trim().split(/\s+/)[0] || undefined;
}

function accountName(): string | undefined {
  try {
    return firstName(execFileSync('id', ['-F'], { encoding: 'utf8', timeout: 2000 }));
  } catch {
    return undefined;
  }
}

export const USER_NAME = accountName();

// "The user is Mike. ", or nothing without a name.
export function userLine(name = USER_NAME): string {
  return name ? `The user is ${name}. ` : '';
}
