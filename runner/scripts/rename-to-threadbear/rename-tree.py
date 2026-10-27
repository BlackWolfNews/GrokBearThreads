#!/usr/bin/env python3
"""One-off, 27 Oct 2026: renames a checkout of main from Threadbare to
Threadbear, in place, ready to commit. Deterministic, so it can run on
whatever main is when the rename finally happens (a branch prepared hours
earlier went stale as other threads moved main on).

    python3 rename-tree.py <checkout> <kit dir>

1. Renames every tracked path with threadbare in it.
2. Swaps threadbare/Threadbare/THREADBARE for threadbear/... in every
   tracked text file, except design history (docs/cat-herder,
   docs/threadbear-design), recorded Claude fixtures (their streamed text
   splits words across deltas) and the lines that name the old variables on
   purpose (it runs on main as it is, before step 3 adds those).
3. Adds the old-name compatibility: config.ts adoptOldNames, both names in
   threadEnv, a line at the top of each Node and bash entry point, check.sh
   clearing both, tests stripping both, and old-names.test.ts.
4. Notes the rename in AGENTS.md and keeps the kit under
   runner/scripts/rename-to-threadbear.

Exits non-zero, having said why, if something it anchors on has changed.
"""
import os
import re
import subprocess
import sys

root, kit = sys.argv[1], sys.argv[2]
os.chdir(root)

KEEP_DIRS = ('docs/cat-herder/', 'docs/threadbear-design/', 'runner/scripts/rename-to-threadbear/')


def fail(msg):
    print(f'rename-tree: {msg}', file=sys.stderr)
    sys.exit(1)


def git(*args):
    return subprocess.run(['git', *args], check=True, capture_output=True, text=True).stdout


def renamed(s):
    return s.replace('threadbare', 'threadbear').replace('Threadbare', 'Threadbear').replace('THREADBARE', 'THREADBEAR')


def skip_text(path):
    if path.startswith(KEEP_DIRS):
        return True
    # Recorded Claude streams; Codex ones name the tool namespace and do change.
    if path.startswith('runner/test/fixtures/') and not path.startswith('runner/test/fixtures/codex/') and path.endswith('.ndjson'):
        return True
    if path.startswith('app/Tools/mock-runner/fixtures/'):
        return True
    return False


# 1. paths
for path in git('ls-files').splitlines():
    if path.startswith(KEEP_DIRS):
        continue
    new = renamed(path)
    if new != path:
        os.makedirs(os.path.dirname(new) or '.', exist_ok=True)
        git('mv', path, new)

# 2. text
for path in git('ls-files').splitlines():
    if skip_text(path) or not os.path.isfile(path):
        continue
    try:
        with open(path, encoding='utf-8') as f:
            text = f.read()
    except (UnicodeDecodeError, IsADirectoryError):
        continue
    if not re.search('threadbare', text, re.I):
        continue
    # Main has no lines that name the old variables on purpose yet; step 3
    # adds them after this.
    out = renamed(text)
    if out != text:
        with open(path, 'w', encoding='utf-8') as f:
            f.write(out)


def edit(path, fn):
    with open(path, encoding='utf-8') as f:
        text = f.read()
    out = fn(text)
    if out is None:
        fail(f'{path}: what it looks for has changed')
    if out != text:
        with open(path, 'w', encoding='utf-8') as f:
            f.write(out)


# 3a. config.ts
ADOPT = '''// The app was called Threadbare until 27 Oct 2026, and its variables were
// THREADBARE_*. Threads, skills and launchd jobs from before then may still
// set the old names, so each one stands in for its new name when that
// isn't set. On import, so every entry point (the runner, tb) gets it.
export function adoptOldNames(env: NodeJS.ProcessEnv): void {
  for (const [k, v] of Object.entries(env)) {
    if (!k.startsWith('THREADBARE_') || v === undefined) continue;
    const name = 'THREADBEAR_' + k.slice('THREADBARE_'.length);
    if (env[name] === undefined) env[name] = v;
  }
}
adoptOldNames(process.env);

'''
LOAD = 'export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {\n'


def config(text):
    if 'adoptOldNames' in text:
        return text
    if LOAD not in text:
        return None
    return text.replace(LOAD, ADOPT + LOAD + '  adoptOldNames(env);\n', 1)


edit('runner/src/config.ts', config)


# 3b. threadEnv
def thread_env(text):
    if 'THREADBARE_THREAD_ID: threadId' in text:
        return text
    anchor = '    THREADBEAR_RUNNER_VERSION: RUNNER_VERSION,\n'
    if anchor not in text:
        return None
    return text.replace(anchor, anchor + '''    // The old names too, for skills and scripts written before the rename.
    THREADBARE_THREAD_ID: threadId,
    THREADBARE_HOME: home,
    THREADBARE_RUNNER_HOME: home,
''', 1)


edit('runner/src/restart.ts', thread_env)

# 3c/d. entry points
MJS = '''// THREADBARE_* was the old name for these variables (config.ts, adoptOldNames).
for (const [k, v] of Object.entries(process.env)) {
  const name = k.startsWith('THREADBARE_') ? 'THREADBEAR_' + k.slice(11) : undefined;
  if (name && process.env[name] === undefined) process.env[name] = v;
}
'''
BASH = '''# THREADBARE_* was the old name for these variables: each stands in for its new name.
for v in $(compgen -e | grep '^THREADBARE_' || true); do n="THREADBEAR_${v#THREADBARE_}"; [ -n "${!n+x}" ] || export "$n=${!v}"; done
'''
for path in git('ls-files').splitlines():
    if path.startswith(KEEP_DIRS) or '/node_modules/' in path or path == 'check.sh' or not os.path.isfile(path):
        continue
    try:
        with open(path, encoding='utf-8') as f:
            text = f.read()
    except (UnicodeDecodeError, IsADirectoryError):
        continue
    if 'THREADBEAR_' not in text or "'^THREADBARE_'" in text or "startsWith('THREADBARE_')" in text:
        continue
    lines = text.splitlines(keepends=True)
    if path.endswith('.mjs') and (path.startswith('runner/') or path.startswith('app/Tools/')) and '/test/' not in path:
        last = max((i for i, l in enumerate(lines) if l.startswith('import ') or l.startswith('} from ')), default=-1)
        lines.insert(last + 1, MJS)
    elif lines and lines[0].startswith('#!') and 'bash' in lines[0]:
        i = 1
        while i < len(lines) and (lines[i].startswith('#') or not lines[i].strip() or lines[i].startswith('set ')):
            i += 1
        lines.insert(i, BASH)
    else:
        continue
    with open(path, 'w', encoding='utf-8') as f:
        f.write(''.join(lines))


# 3e. check.sh clears both names
def check_sh(text):
    if "grep '^THREADBARE_'" in text:
        return text
    m = re.search(r'^unset THREADBEAR_HOME[^\n]*(?:\\\n[^\n]*)*\n', text, re.M)
    if not m:
        return None
    add = "# And their old names, which the runner and tb would otherwise take for these.\nfor v in $(compgen -e | grep '^THREADBARE_' || true); do unset \"$v\"; done\n"
    return text[: m.end()] + add + text[m.end():]


edit('check.sh', check_sh)

# 3f. the runner and its tests strip both names from environments they pass on
for path in git('ls-files', 'runner/src', 'runner/test').splitlines():
    if not path.endswith('.ts'):
        continue
    with open(path, encoding='utf-8') as f:
        text = f.read()
    out = text.replace("!k.startsWith('THREADBEAR_')", "!/^THREADB(EAR|ARE)_/.test(k)").replace("k.startsWith('THREADBEAR_') ||", "/^THREADB(EAR|ARE)_/.test(k) ||")
    if out != text:
        with open(path, 'w', encoding='utf-8') as f:
            f.write(out)
with open(os.path.join(kit, 'old-names.test.ts'), encoding='utf-8') as f:
    with open('runner/test/unit/old-names.test.ts', 'w', encoding='utf-8') as g:
        g.write(f.read())

# 4. AGENTS.md and the kit
NOTE = '''
The app was called Threadbare until 27 Oct 2026. Everything was renamed then
(repo, folders, data dir `~/Library/Application Support/Threadbear`, the
`com.mikerosoft.threadbear.*` labels and bundle id, `THREADBEAR_*`
variables). The old `THREADBARE_*` names still work as stand-ins for the
new ones, and threads still get both, for skills written before.
'''


def agents(text):
    if 'was called Threadbare until' in text:
        return text
    first = text.find('\n')
    return text[: first + 1] + NOTE + text[first + 1:] if first >= 0 else None


edit('AGENTS.md', agents)
os.makedirs('runner/scripts/rename-to-threadbear', exist_ok=True)
for name in ('rename-tree.py', 'migrate.sh', 'migrate-data.mjs', 'start.sh'):
    with open(os.path.join(kit, name), encoding='utf-8') as f:
        with open(os.path.join('runner/scripts/rename-to-threadbear', name), 'w', encoding='utf-8') as g:
            g.write(f.read())

left = subprocess.run(['git', 'grep', '-Ili', 'threadbare', '--', '.', ':!docs/cat-herder', ':!docs/threadbear-design',
                       ':!runner/scripts/rename-to-threadbear', ':!runner/test/fixtures', ':!app/Tools/mock-runner/fixtures'],
                      capture_output=True, text=True).stdout.split()
print(f'rename-tree: done; files still naming the old variables on purpose: {len(left)}')
