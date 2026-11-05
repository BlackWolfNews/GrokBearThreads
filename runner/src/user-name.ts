// Who the person reading the threads is, for the instructions and prompts
// the runner gives models. Everything an agent reads says "the user", as
// Threadbear runs on other people's Macs too, and this one line gives the
// agent their name. It's the first word of the account's full name
// ("Mike Cann" -> "Mike"); left out when there isn't one.
import { execFileSync } from 'node:child_process';
import os from 'node:os';

export function firstName(fullName: string): string | undefined {
  return fullName.trim().split(/\s+/)[0] || undefined;
}

// macOS: `id -F`, which is the login name when the account has no full
// name. Linux has no `id -F`: the full name is the first comma-separated
// part of the passwd entry's comment (what `chfn` sets), falling back to
// the login name the same way.
function accountName(): string | undefined {
  try {
    if (process.platform === 'darwin') return firstName(execFileSync('id', ['-F'], { encoding: 'utf8', timeout: 2000 }));
    const user = os.userInfo().username;
    let gecos = '';
    try {
      gecos = execFileSync('getent', ['passwd', user], { encoding: 'utf8', timeout: 2000 }).split(':')[4] ?? '';
    } catch {
      // no getent: the login name
    }
    return firstName(gecos.split(',')[0] ?? '') ?? firstName(user);
  } catch {
    return undefined;
  }
}

export const USER_NAME = accountName();

// "The user is Mike. ", or nothing without a name.
export function userLine(name = USER_NAME): string {
  return name ? `The user is ${name}. ` : '';
}
