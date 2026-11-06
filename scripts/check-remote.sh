#!/bin/bash
# Runs ./check.sh on another Mac, so test suites and the app's test windows
# don't load the Mac you're working on. check.sh calls this itself when a
# check host is set (THREADBEAR_CHECK_HOST, or "checkHost" in runner.json);
# you don't run it by hand.
#
#   scripts/check-remote.sh <ssh host>[,<ssh host>...] [check.sh options]
#
# With several hosts (Mike's are Tinker Desk and the cloud box), each run
# goes to the first one that's free and can run it, or waits for the first
# that can. A Linux host only takes what needs no Mac: a --quick run that
# doesn't touch ios/ (ThreadbearKit's tests are Swift), with no --shots.
# Mike asked on 6 Nov, when nine threads' checks queued at once.
#
# Mike asked on 6 Nov 2026, after three threads' unit suites, a swift test
# and three debug apps took his M5 to a load of 75 and a test's window came
# up over his browser. The host he picked (Tinker Desk) is also where he
# tries clean installs of Threadbear, so a run leaves nothing behind that
# looks like an install: no runner, no data dir, no checkout. Each run
# copies this checkout's files (tracked and untracked, as check.sh sees
# them) into ~/.cache/threadbear-check/runs/<id> there, runs check.sh on
# it, and deletes it. What's kept there between runs is only what makes
# the next run quick: node_modules per lockfile, the Swift build folders,
# and a mirror of each checkout that sends to it (mirror/<key>), so a run
# sends only what changed since that checkout's last, compressed: a whole
# copy is 17 MB, and on a congested link (6 Nov) that took minutes. Each
# run's copy is made from the mirror there. Delete ~/.cache/threadbear-check
# to take it all away.
#
# One run at a time on the host (lockf); a second waits and says so. The
# copy always runs from the same path, src/, as SwiftPM's build cache only
# works where it was made. Logs of failed steps, and --shots, come back
# here. --e2e never comes here: it needs the claude login, and on Tinker
# Desk a CLI signed in over SSH broke the desktop's login (2 Nov), so
# check.sh runs those on this Mac.
#
# Exit 255: no host that can run it could be reached (check.sh then runs here).
set -uo pipefail

BASE_REL=".cache/threadbear-check"

# ---- On the check host: scripts/check-remote.sh --on-host <id> [options]
if [ "${1:-}" = "--on-host" ]; then
  id="$2"
  shift 2
  base="$HOME/$BASE_REL"
  src="$base/src"
  NODE="$HOME/.nvm/versions/node/v24.22.1/bin/node"
  export PATH="$(dirname "$NODE"):/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
  # Everything the tests make in a temp folder goes here and is deleted
  # with the run, so nothing piles up in /var/folders.
  export TMPDIR="$base/tmp-$id"
  rm -rf "$src" "$TMPDIR"
  # Anything a run cut short left (a copy that never got the lock, logs
  # nobody fetched) goes after half a day.
  find "$base/runs" "$base" -mindepth 1 -maxdepth 1 \( -name '[0-9]*' -o -name 'tmp-*' -o -name 'kept-*' -o -name 'shots-*' \) \
    -mmin +720 -exec rm -rf {} + 2>/dev/null
  # A checkout's mirror that hasn't sent a run for a week (a removed worktree).
  find "$base/mirror" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} + 2>/dev/null
  mkdir -p "$TMPDIR"
  mv "$base/runs/$id" "$src" || { echo "The copy for run $id isn't on $(hostname -s)." >&2; exit 1; }
  # A failed check keeps its logs in $TMPDIR; they move aside for this
  # Mac to fetch, and everything else goes.
  keep_logs() {
    cd "$base" || return
    for d in "$TMPDIR"/threadbear-check.*; do
      [ -d "$d" ] && mkdir -p "$base/kept-$id" && mv "$d" "$base/kept-$id/"
    done
    rm -rf "$src" "$TMPDIR"
  }
  trap keep_logs EXIT

  # A git repo of its own, on main, as some tests run git in the repo
  # (deploy-backend.mjs reads HEAD). Its one commit is the copy as sent.
  (cd "$src" && git init -q -b main && git add -A && git -c user.name=check -c user.email=check@localhost commit -qm "check copy") \
    || { echo "Couldn't make the copy a git repo." >&2; exit 1; }

  # node_modules per package-lock, kept between runs (the newest three of
  # each). npm ci only when the lockfile is new.
  for dir in . runner app/Tools/mock-runner; do
    [ -f "$src/$dir/package-lock.json" ] || continue
    name="$(printf '%s' "$dir" | tr -c 'a-zA-Z0-9' '-')"
    hash="$(shasum -a 256 "$src/$dir/package-lock.json" | cut -c1-16)"
    # The folder itself has to be called node_modules: Node finds a
    # package's own dependencies from its real path, by looking for
    # node_modules folders above it.
    cache="$base/deps/$name-$hash/node_modules"
    if [ ! -d "$cache" ]; then
      echo "npm ci in $dir (its lockfile is new here)"
      (cd "$src/$dir" && npm ci --no-audit --no-fund --loglevel=error >/dev/null) || { echo "npm ci failed in $dir" >&2; exit 1; }
      mkdir -p "$(dirname "$cache")"
      mv "$src/$dir/node_modules" "$cache"
    fi
    touch "$(dirname "$cache")"
    rm -rf "$src/$dir/node_modules"
    ln -s "$cache" "$src/$dir/node_modules"
    ls -td "$base/deps/$name-"* 2>/dev/null | tail -n +4 | xargs rm -rf
  done
  # The Swift build folders, kept between runs.
  for dir in app dock ios/ThreadbearKit; do
    [ -d "$src/$dir" ] || continue
    name="$(printf '%s' "$dir" | tr -c 'a-zA-Z0-9' '-')"
    mkdir -p "$base/build/$name"
    rm -rf "$src/$dir/.build"
    ln -s "$base/build/$name" "$src/$dir/.build"
  done

  cd "$src" || exit 1
  THREADBEAR_CHECK_CHANGED_FILE="$src/.check-changed" THREADBEAR_NODE="$NODE" ./check.sh --local "$@"
  exit $?
fi

# ---- On this Mac
HOST_LIST="${1:?usage: check-remote.sh <ssh host>[,<ssh host>...] [check.sh options]}"
shift
read -ra HOSTS <<<"$(printf '%s' "$HOST_LIST" | tr ',' ' ')"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# One connection per host, shared by every ssh and rsync this run makes:
# a run makes half a dozen, and on a congested link (6 Nov, 2 s pings) each
# new one took 20 s to set up. A short path, as a socket's can't be long.
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=30 -o ServerAliveCountMax=4
  -o ControlMaster=auto -o "ControlPath=/tmp/tbc-$(id -u)-%C" -o ControlPersist=60)

ARGS=()
SHOTS=""
QUICK=0
ALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --shots)
      case "$2" in /*) SHOTS="$2" ;; *) SHOTS="$PWD/$2" ;; esac
      shift ;;
    --quick) QUICK=1; ARGS+=("$1") ;;
    --all) ALL=1; ARGS+=("$1") ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done

# What this checkout changes from main, worked out here where the history
# is (the copy's git has just one commit), as check.sh skips steps by it
# (see `needed` there).
changed="$(mktemp)"
{
  base="$(git -C "$ROOT" merge-base HEAD main 2>/dev/null)" && git -C "$ROOT" diff --name-only "$base"
  git -C "$ROOT" ls-files --others --exclude-standard
} 2>/dev/null | sort -u >"$changed"

# Whether a Linux host can run this: only the runner's, Convex's and the
# website's checks, so --quick, nothing changed under ios/ (and something
# changed: with nothing, check.sh itself or --all, it runs everything), no
# shots.
linux_ok=0
if [ "$QUICK" = 1 ] && [ "$ALL" = 0 ] && [ -z "$SHOTS" ] && [ -s "$changed" ] && ! grep -qE '^ios/|^check\.sh$' "$changed"; then linux_ok=1; fi

# Each host: reachable, its system, and whether its lock is free now.
# The first free one that can run it wins; otherwise the first that can,
# which then waits for its lock. Two checks can both see a host free, so
# a run there takes the lock without waiting (exit 75 if it can't), and the
# one that lost chooses again; after three goes it waits in line.
probe='mkdir -p ~/'"$BASE_REL"'/runs && cd ~/'"$BASE_REL"' && pwd && uname -s && if [ "$(uname -s)" = Darwin ]; then /usr/bin/lockf -t 0 lock true 2>/dev/null && echo free || echo busy; else flock -n lock true 2>/dev/null && echo free || echo busy; fi'
choose() {
  HOST="" HOST_OS="" remote_base="" FREE=0
  local first="" first_os="" first_base="" h out b os state
  for h in "${HOSTS[@]}"; do
    # An ssh host, never something ssh would take for an option.
    case "$h" in -*|"") continue ;; esac
    # One that dropped out during a copy this run isn't tried again.
    case " $SKIP " in *" $h "*) continue ;; esac
    out="$("${SSH[@]}" "$h" "$probe" 2>/dev/null)" || { echo "Couldn't reach $h over ssh." >&2; continue; }
    { read -r b; read -r os; read -r state; } <<<"$out"
    # Every rm -rf over there is under this, so never let it be empty.
    case "$b" in */$BASE_REL) ;; *) echo "Unexpected folder on $h: '$b'" >&2; continue ;; esac
    case "$os" in
      Darwin) ;;
      Linux) [ "$linux_ok" = 1 ] || continue ;;
      *) continue ;;
    esac
    if [ "$state" = free ]; then HOST="$h" HOST_OS="$os" remote_base="$b" FREE=1; return 0; fi
    [ -n "$first" ] || { first="$h" first_os="$os" first_base="$b"; }
  done
  [ -n "$first" ] || return 1
  HOST="$first" HOST_OS="$first_os" remote_base="$first_base"
}

# The files check.sh would see, less what no check reads: the pictures in
# docs/ and site/ (about 50 MB of the repo). TourTests reads site's JSON.
files="$(mktemp)"
(cd "$ROOT" && git ls-files -co --exclude-standard -z) | tr '\0' '\n' \
  | grep -vE '^(docs|site)/.*\.(png|gif|jpe?g|mp4|mov|webp)$' | tr '\n' '\0' >"$files"
BASE_ARGS=(${ARGS[@]+"${ARGS[@]}"})
SKIP=""
tries=0
# The copy lock this run holds, if any, goes with it however it ends.
held=""
trap '[ -n "$held" ] && rmdir "$held" 2>/dev/null' EXIT
while :; do
  if ! choose; then
    rm -f "$files" "$changed"
    echo "None of $HOST_LIST can run this check now." >&2
    exit 255
  fi
  id="$(date +%H%M%S)-$$-$tries"
  remote_run="$remote_base/runs/$id"
  start=$SECONDS
  # This checkout's mirror on the host: one per Mac and checkout, so two
  # worktrees never write the same one. Only what changed goes over the
  # link; the run's copy is made from it there, of exactly this run's files
  # (a file deleted here stays in the mirror but isn't copied).
  key="$(printf '%s' "$(hostname -s):$ROOT" | shasum | cut -c1-16)"
  mirror="$remote_base/mirror/$key"
  # Two checks from this checkout at once take turns at the mirror, from
  # the upload until the run's copy is made, so neither copies the other's
  # files. mkdir is the lock; one left by a run killed mid-copy goes after
  # ten minutes.
  copylock="${TMPDIR:-/tmp}/tb-check-copy-$key-$HOST"
  find "$copylock" -maxdepth 0 -mmin +10 -exec rmdir {} \; 2>/dev/null
  until mkdir "$copylock" 2>/dev/null; do sleep 1; done
  held="$copylock"
  # By content (-c), not size and time: an edit that keeps both would
  # otherwise leave the mirror's old copy in the run.
  if ! "${SSH[@]}" "$HOST" "mkdir -p '$mirror' '$remote_run' && touch '$mirror'" \
    || ! rsync -azc --from0 --files-from="$files" -e "${SSH[*]}" "$ROOT/" "$HOST:$mirror/" \
    || ! rsync -a -e "${SSH[*]}" "$files" "$HOST:$remote_run.files" \
    || ! "${SSH[@]}" "$HOST" "rsync -a --from0 --files-from='$remote_run.files' '$mirror/' '$remote_run/' && rm -f '$remote_run.files'" \
    || ! rsync -a -e "${SSH[*]}" "$changed" "$HOST:$remote_run/.check-changed"; then
    rmdir "$copylock" 2>/dev/null; held=""
    "${SSH[@]}" "$HOST" "rm -rf '$remote_run' '$remote_run.files'" 2>/dev/null
    # The next host that can run it, before this Mac (6 Nov: Tinker Desk
    # dropped off mid-copy and the check ran on the M5).
    echo "Couldn't copy this checkout to $HOST; trying the others." >&2
    SKIP+=" $HOST"
    continue
  fi
  rmdir "$copylock" 2>/dev/null; held=""
  echo "Checking on $HOST (copied in $((SECONDS - start))s; THREADBEAR_CHECK_HOST= ./check.sh --local runs here)"

  ARGS=(${BASE_ARGS[@]+"${BASE_ARGS[@]}"})
  remote_shots=""
  [ -z "$SHOTS" ] || { remote_shots="$remote_base/shots-$id"; ARGS+=(--shots "$remote_shots"); }

  quoted=""
  for a in ${ARGS[@]+"${ARGS[@]}"}; do quoted+=" $(printf '%q' "$a")"; done
  inner="/bin/bash $(printf '%q' "$remote_run/scripts/check-remote.sh") --on-host $id$quoted"
  # The design screenshots go through Desk Runner, which has Screen Recording
  # there; over plain ssh they'd be drawn in-process, with the sidebar's
  # glass a flat fill.
  [ -z "$SHOTS" ] || inner="\$HOME/.local/bin/desk $(printf '%q' "$inner")"
  lock="$remote_base/lock"
  # A free host is taken without waiting (75 if another check got there
  # first); otherwise this waits for its turn.
  now=0
  [ "$FREE" = 1 ] && [ "$tries" -lt 3 ] && now=1
  if [ "$HOST_OS" = Linux ]; then
    # A server that runs its own runner and threads: the check goes in under them.
    run="nice -n 10 /bin/bash -c $(printf '%q' "$inner")"
    if [ "$now" = 1 ]; then remote_cmd="flock -n -E 75 $lock $run"
    else remote_cmd="flock -n $lock true 2>/dev/null || echo 'Waiting for another check on $HOST to finish...'; flock $lock $run"; fi
  else
    run="/bin/bash -c $(printf '%q' "$inner")"
    if [ "$now" = 1 ]; then remote_cmd="/usr/bin/lockf -t 0 -k $lock $run"
    else remote_cmd="/usr/bin/lockf -t 0 $lock true 2>/dev/null || echo 'Waiting for another check on $HOST to finish...'; /usr/bin/lockf -k $lock $run"; fi
  fi

  # A failed step's log path is on the host: its logs come back here, and the
  # path in the output is changed to match.
  local_logs="$(mktemp -d "${TMPDIR:-/tmp}/threadbear-check-remote.XXXXXX")"
  "${SSH[@]}" "$HOST" "$remote_cmd" 2>&1 | sed -u "s#$remote_base/tmp-$id/threadbear-check\.[A-Za-z0-9]*#$local_logs#g"
  code=${PIPESTATUS[0]}
  if [ "$now" = 1 ] && [ "$code" = 75 ]; then
    # Never started: its copy goes, and another host is chosen.
    "${SSH[@]}" "$HOST" "rm -rf '$remote_run'" 2>/dev/null
    rmdir "$local_logs" 2>/dev/null
    echo "Another check took $HOST first; choosing again."
    tries=$((tries + 1))
    continue
  fi
  break
done
rm -f "$files" "$changed"
if [ "$code" = 255 ]; then
  # Not "unreachable": that would make check.sh run it all again here.
  echo "Lost the connection to $HOST during the check." >&2
  code=1
fi

# find, not a glob: the host's login shell may be zsh, which complains
# out loud when a glob matches nothing.
kept="$("${SSH[@]}" "$HOST" "find '$remote_base/kept-$id' -maxdepth 1 -name 'threadbear-check.*' 2>/dev/null | head -1")"
if [ -n "$kept" ]; then
  rsync -a -e "${SSH[*]}" "$HOST:$kept/" "$local_logs/" >/dev/null
fi
"${SSH[@]}" "$HOST" "rm -rf '$remote_base/kept-$id' '$remote_run'" 2>/dev/null
[ -n "$(ls -A "$local_logs")" ] || rmdir "$local_logs"

if [ -n "$SHOTS" ]; then
  mkdir -p "$SHOTS"
  rsync -a -e "${SSH[*]}" "$HOST:$remote_shots/" "$SHOTS/" >/dev/null && "${SSH[@]}" "$HOST" "rm -rf '$remote_shots'"
fi
exit "$code"
