#!/bin/bash
# One-off, 27 Oct 2026: renames Threadbare to Threadbear on this Mac. Mike
# asked for everything to be renamed, done as soon as no thread is busy.
# start.sh stages this folder outside the repo and runs it as a launchd job,
# so it carries on after the runner (and the thread that started it) stop.
#
#   1. Waits until no thread is busy, nothing runs in the background and no
#      old runner is finishing turns (checked twice, 30 s apart).
#   2. Makes the rename branch afresh from main with rename-tree.py, and
#      checks it (a branch prepared earlier goes stale as main moves on).
#   3. Stops the runner (com.mikerosoft.threadbare.runner).
#   4. Fast-forwards main, moves ~/dev/me/threadbare to ~/dev/me/threadbear
#      and threadbare-threads (thread worktrees) to threadbear-threads
#      (worktrees repaired), and the data dir to .../Threadbear, leaving a
#      symlink at the old data dir so the installed app still connects;
#      rewrites paths and copies Claude transcripts (migrate-data.mjs).
#   5. Installs the runner as com.mikerosoft.threadbear.runner and checks it
#      answers. If not, puts everything back and starts the old runner.
#   6. Renames the GitHub repo, pushes, and tells the thread that started it.
#
# Log: ~/Library/Logs/threadbear-rename.log
set -uo pipefail

LOG="$HOME/Library/Logs/threadbear-rename.log"
exec >>"$LOG" 2>&1
STAGE="$(cd "$(dirname "$0")" && pwd)"
OLD="$HOME/dev/me/threadbare"
NEW="$HOME/dev/me/threadbear"
OLD_THREADS="$HOME/dev/me/threadbare-threads"
NEW_THREADS="$HOME/dev/me/threadbear-threads"
WT="$HOME/dev/me/threadbear-rename"
OLD_DATA="$HOME/Library/Application Support/Threadbare"
NEW_DATA="$HOME/Library/Application Support/Threadbear"
OLD_LABEL="com.mikerosoft.threadbare.runner"
NEW_LABEL="com.mikerosoft.threadbear.runner"
SELF_LABEL="com.mikerosoft.threadbear.rename"
DOMAIN="gui/$(id -u)"
AGENTS="$HOME/Library/LaunchAgents"
NODE="${THREADBEAR_NODE:-$HOME/.nvm/versions/node/v24.22.1/bin/node}"
THREAD="${RENAME_THREAD:-6484c2e3-13d1-4da0-862d-8d0afdaff140}"
BACKUP="$STAGE/backup"
WAIT_HOURS="${RENAME_WAIT_HOURS:-24}"

say() { echo "$(date '+%F %T') $*"; }
old_tb() { env -u THREADBEAR_HOME THREADBARE_HOME="$OLD_DATA" "$OLD/runner/bin/tb" "$@"; }
new_tb() { env -u THREADBARE_HOME THREADBEAR_HOME="$NEW_DATA" "$NEW/runner/bin/tb" "$@"; }

# Never run again at login, however this ends.
finish() {
  rm -f "$AGENTS/$SELF_LABEL.plist"
  say "done ($1)"
  exit "${2:-0}"
}

tell_old() { old_tb send "$THREAD" "$1" >/dev/null 2>&1 || say "couldn't message the thread on the old runner"; }

# Nothing busy, nothing in the background, no old runner finishing turns,
# no restart pending.
quiet_once() {
  old_tb status --json 2>/dev/null | "$NODE" -e '
    let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => {
      const d = JSON.parse(s);
      const busy = d.running.length || d.background.length || (d.draining || []).length || d.pendingRestart;
      process.exit(busy ? 1 : 0);
    });'
}
quiet() { quiet_once && sleep 30 && quiet_once; }

# The rename branch, made afresh from main: rename-tree.py, a commit, and
# the runner's and the app's checks.
prepare_branch() {
  say "making the rename branch from main ($(git -C "$OLD" rev-parse --short main))"
  git -C "$WT" checkout -q -B rename main && git -C "$WT" clean -fdq || return 1
  (cd "$WT/runner" && npm ci --silent) && (cd "$WT/app/Tools/mock-runner" && npm ci --silent) || { say "npm ci failed"; return 1; }
  python3 "$STAGE/rename-tree.py" "$WT" "$STAGE" || return 1
  git -C "$WT" add -A && git -C "$WT" commit -qm "Rename Threadbare to Threadbear: repo, app, runner, data dir, labels, bundle id and variables

Made by runner/scripts/rename-to-threadbear/rename-tree.py on main as it was.
THREADBARE_* still stand in for THREADBEAR_*." || return 1
  if ! (cd "$WT" && ./check.sh --quick && ./check.sh --app); then
    say "the rename branch fails its checks"
    return 1
  fi
}

# ---------------------------------------------------------------- 1, 2
say "started; waiting for a quiet moment (up to $WAIT_HOURS h)"
deadline=$(( $(date +%s) + WAIT_HOURS * 3600 ))
last_note=0
while :; do
  if [ "$(date +%s)" -gt "$deadline" ]; then
    tell_old "[Threadbear rename] Gave up: nothing was quiet for $WAIT_HOURS hours. Nothing was changed. Log: $LOG"
    finish "never quiet" 1
  fi
  if quiet; then
    if ! prepare_branch; then
      tell_old "[Threadbear rename] Stopped before changing anything: rename-tree.py or the checks failed on main as it is now. Log: $LOG"
      finish "branch not ready" 1
    fi
    # Someone may have started something while that ran.
    quiet && break
  fi
  if [ $(( $(date +%s) - last_note )) -ge 600 ]; then say "still waiting: something is busy"; last_note=$(date +%s); fi
  sleep 30
done

# ---------------------------------------------------------------- 3
say "stopping $OLD_LABEL"
mkdir -p "$BACKUP"
cp "$AGENTS/$OLD_LABEL.plist" "$BACKUP/old-runner.plist"
launchctl bootout "$DOMAIN/$OLD_LABEL" || true
for _ in $(seq 1 90); do
  pgrep -f "$OLD_DATA/runner" >/dev/null || break
  sleep 1
done
if pgrep -f "$OLD_DATA/runner" >/dev/null; then
  say "the old runner is still running after 90 s; starting it again and stopping"
  launchctl bootstrap "$DOMAIN" "$BACKUP/old-runner.plist" || true
  finish "old runner wouldn't stop" 1
fi
rm -f "$AGENTS/$OLD_LABEL.plist"

PRE_MAIN="$(git -C "$OLD" rev-parse main)"
STASHED=0
restart_old() {
  say "putting the old runner back"
  cp "$BACKUP/old-runner.plist" "$AGENTS/$OLD_LABEL.plist"
  launchctl bootstrap "$DOMAIN" "$AGENTS/$OLD_LABEL.plist" || say "bootstrap of the old runner failed"
}

# ---------------------------------------------------------------- 4
say "fast-forwarding main"
if [ -n "$(git -C "$OLD" status --porcelain)" ]; then
  git -C "$OLD" stash push -u -q -m "threadbear-rename: uncommitted work in main's checkout" && STASHED=1
fi
if ! git -C "$OLD" merge --ff-only rename; then
  # Main moved after the branch was made: make it again (checks already
  # passed on a main a minute older, so only the quick ones).
  if git -C "$WT" checkout -q -B rename main && python3 "$STAGE/rename-tree.py" "$WT" "$STAGE" \
    && git -C "$WT" add -A && git -C "$WT" commit -qm "Rename Threadbare to Threadbear (rename-tree.py on main)" \
    && (cd "$WT" && ./check.sh --quick) && git -C "$OLD" merge --ff-only rename; then
    say "main had moved; made the branch again"
  else
    [ "$STASHED" = 1 ] && git -C "$OLD" stash pop -q
    restart_old
    sleep 15
    tell_old "[Threadbear rename] Stopped: main couldn't be fast-forwarded to the rename. Nothing moved and the runner is back. Log: $LOG"
    finish "main wouldn't fast-forward" 1
  fi
fi
STASH_NOTE=""
if [ "$STASHED" = 1 ]; then
  if git -C "$OLD" stash pop -q; then
    say "uncommitted work in main's checkout put back"
  else
    STASH_NOTE=" Uncommitted work in main's checkout didn't go back on cleanly after the rename: it's in git stash (threadbear-rename) and the checkout may show conflicts."
    say "stash pop had conflicts; left in git stash"
  fi
fi

# Every worktree but the main one, where it is now and where it will be.
WT_OLD=()
WT_NEW=()
while IFS= read -r line; do
  case "$line" in "worktree "*)
    p="${line#worktree }"
    [ "$p" = "$OLD" ] && continue
    WT_OLD+=("$p")
    case "$p" in "$OLD_THREADS"/*) WT_NEW+=("$NEW_THREADS${p#"$OLD_THREADS"}") ;; *) WT_NEW+=("$p") ;; esac
  esac
done < <(git -C "$OLD" worktree list --porcelain)

say "moving $OLD to $NEW, its thread worktrees and the data dir"
mv "$OLD" "$NEW" || { restart_old; finish "couldn't move the checkout" 1; }
[ -d "$OLD_THREADS" ] && mv "$OLD_THREADS" "$NEW_THREADS"
git -C "$NEW" worktree repair "${WT_NEW[@]}" || say "worktree repair reported problems"
put_back_folders() {
  [ -d "$NEW_THREADS" ] && mv "$NEW_THREADS" "$OLD_THREADS"
  mv "$NEW" "$OLD"
  git -C "$OLD" worktree repair "${WT_OLD[@]}" || true
}
mv "$OLD_DATA" "$NEW_DATA" || { put_back_folders; restart_old; finish "couldn't move the data dir" 1; }
ln -s "$NEW_DATA" "$OLD_DATA"
"$NODE" "$STAGE/migrate-data.mjs" apply "$BACKUP" || say "migrate-data apply reported a problem"

rollback() {
  say "rolling back: $1"
  launchctl bootout "$DOMAIN/$NEW_LABEL" 2>/dev/null || true
  rm -f "$AGENTS/$NEW_LABEL.plist"
  "$NODE" "$STAGE/migrate-data.mjs" restore "$BACKUP" || say "migrate-data restore reported a problem"
  rm -f "$OLD_DATA"
  mv "$NEW_DATA" "$OLD_DATA"
  put_back_folders
  git -C "$OLD" reset -q --keep "$PRE_MAIN" || say "couldn't put main back to $PRE_MAIN"
  restart_old
  sleep 20
  tell_old "[Threadbear rename] Rolled back: $1. Everything is back where it was and the old runner is running. Log: $LOG"
  finish "rolled back" 1
}

# ---------------------------------------------------------------- 5
say "installing $NEW_LABEL"
if ! env -u THREADBARE_HOME -u THREADBEAR_HOME bash "$NEW/runner/scripts/install-runner.sh"; then
  rollback "install-runner.sh failed"
fi
ok=0
for _ in $(seq 1 40); do
  if new_tb status >/dev/null 2>&1; then ok=1; break; fi
  sleep 3
done
[ "$ok" = 1 ] || rollback "the new runner didn't answer within two minutes"
say "new runner up: $(new_tb status 2>/dev/null | head -1)"

# ---------------------------------------------------------------- 6
GH_NOTE=""
if gh repo rename threadbear -R mikecann/threadbare --yes; then
  git -C "$NEW" remote set-url origin https://github.com/mikecann/threadbear.git
  say "GitHub repo renamed"
else
  GH_NOTE=" The GitHub rename failed (see the log), so the repo is still mikecann/threadbare."
fi
git -C "$NEW" push -q origin main || GH_NOTE="$GH_NOTE Pushing main failed."
git -C "$NEW" worktree remove --force "$WT" && git -C "$NEW" branch -q -d rename || say "left the rename worktree in place"

new_tb send "$THREAD" "[Threadbear rename] Finished. Checkout at $NEW, data at $NEW_DATA (old path is a symlink), runner $NEW_LABEL.$STASH_NOTE$GH_NOTE Check it and tell Mike what's left. Log: $LOG" >/dev/null 2>&1 \
  || say "couldn't message the thread on the new runner"
finish "renamed" 0
