#!/usr/bin/env bash
# Debug builds of the app for an agent to look at and drive: each in a temp
# bundle, against the mock runner or a dev runner, with its window kept
# behind whatever Mike is working in. Several can run at once without
# crosstalk: each has its own id, bundle id (so its own settings), data
# folder, automation channel and pasteboard. Nothing here touches the
# installed app, the live runner or its data folder.
#
#   Tools/dev-app.sh start [--mock [--fixtures DIR]...] [--home DIR]
#                          [--appearance light|dark] [--size WxH] [--id NAME]
#   Tools/dev-app.sh do '<json>'... [--timeout S]
#   Tools/dev-app.sh shot <file.png>
#   Tools/dev-app.sh dump [--json]
#   Tools/dev-app.sh log [-f] [-n N] [--mock | --automation]
#   Tools/dev-app.sh stop [--all]
#   Tools/dev-app.sh status
#
# start  builds the debug app, starts the mock runner (its demo threads, or
#        only the --fixtures folders given: `tb export` puts one thread in
#        app/.fixtures/threads/<id>) or points at a dev runner's --home
#        (runner/scripts/dev-runner.sh), launches the app with --automation,
#        waits until it's connected and prints the instance id.
# do     sends each command and prints its result line ("open ok ...");
#        exits 1 on an error result or a timeout. The commands are in
#        app/README.md, "Driving it from a script".
# shot   saves the window as a PNG (screencapture -l, or drawn in-process
#        when the screen is locked).
# dump   what the window shows: the sidebar's rows by section, the open
#        thread's rows (id, kind, height, open or closed, text; > marks the
#        ones on screen), the selection, the composer and the banner.
# log    the app's own log: connection, RPC errors, automation commands.
# stop   quits the app and its mock and deletes the instance's temp files.
#
# Every command but start takes --id ID; the default is the instance started
# last. Pass it whenever more than one is running.
set -Eeuo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$TOOLS_DIR/.." && pwd)"
TMP_ROOT="${TMPDIR:-/tmp}"
mkdir -p "${TMP_ROOT%/}/threadbare-dev-app"
# With symlinks resolved (/var is /private/var): it's how the app's own
# path reads in ps and pgrep.
STATE_ROOT="$(cd "${TMP_ROOT%/}/threadbare-dev-app" && pwd -P)"
REAL_HOME="$HOME/Library/Application Support/Threadbare"
BUNDLE_PREFIX="com.mikerosoft.threadbare.dev"
CHANNEL_PREFIX="com.mikerosoft.threadbare.automation"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# A start that fails part way stops what it had started.
CLEANUP_ID=""
die() {
  echo "dev-app: $*" >&2
  if [ -n "$CLEANUP_ID" ]; then
    local id="$CLEANUP_ID"
    CLEANUP_ID=""
    stop_one "$id" >/dev/null 2>&1 || true
  fi
  exit 1
}
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

node_bin() {
  local pinned="${THREADBARE_NODE:-$HOME/.nvm/versions/node/v24.22.1/bin/node}"
  if [ -x "$pinned" ]; then printf '%s' "$pinned"; else command -v node || die "no node binary (set THREADBARE_NODE)"; fi
}

# The folder with symlinks resolved, or as given if it doesn't exist.
real_dir() {
  if [ -d "$1" ]; then (cd "$1" && pwd -P); else printf '%s' "${1%/}"; fi
}

# A JSON string for a shell string (paths, mostly).
json_string() {
  local s="${1//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

# The pid of the app running from this bundle, if any. The bundle's path is
# the instance's own, so this never finds the installed app or another
# instance.
bundle_pid() {
  pgrep -f "^$1/Contents/MacOS/Threadbare( |\$)" | head -n 1 || true
}

# ------------------------------------------------------------------ instances

instance_dir() { printf '%s/%s' "$STATE_ROOT" "$1"; }

# Reads <instance>/instance (KEY=value lines written by start) into I_*.
load_instance() {
  local dir; dir="$(instance_dir "$1")"
  [ -f "$dir/instance" ] || die "no instance $1 (Tools/dev-app.sh status lists them)"
  I_ID="$1"; I_DIR="$dir"
  I_PID=""; I_MOCK_PID=""; I_DATA=""; I_BUNDLE=""; I_BUNDLE_ID=""; I_RUNNER=""
  while IFS='=' read -r key value; do
    case "$key" in
      pid) I_PID="$value" ;;
      mock_pid) I_MOCK_PID="$value" ;;
      data) I_DATA="$value" ;;
      bundle) I_BUNDLE="$value" ;;
      bundle_id) I_BUNDLE_ID="$value" ;;
      runner) I_RUNNER="$value" ;;
    esac
  done <"$dir/instance"
  I_LOG="$dir/automation.log"
  I_CHANNEL="$CHANNEL_PREFIX.$1"
}

# The instance a command means: --id, else the one started last that's
# still running.
resolve_id() {
  if [ -n "$ID" ]; then printf '%s' "$ID"; return; fi
  local latest=""
  [ -f "$STATE_ROOT/latest" ] && latest="$(cat "$STATE_ROOT/latest")"
  if [ -n "$latest" ] && [ -f "$(instance_dir "$latest")/instance" ]; then printf '%s' "$latest"; return; fi
  local newest
  newest="$(ls -t "$STATE_ROOT"/*/instance 2>/dev/null | head -n 1 || true)"
  [ -n "$newest" ] || die "no dev app is running (Tools/dev-app.sh start)"
  basename "$(dirname "$newest")"
}

# ------------------------------------------------------------------ commands

# Posts one command (a JSON object) to the instance and waits for its
# result line. Prints the line; returns 1 for an error result or a timeout.
send() {
  local command="$1" timeout="${2:-}" rid meta name wait line
  rid="$(date +%s)-$$-$RANDOM"
  # JavaScript for Automation reaches Foundation without compiling
  # anything; it also checks the JSON and tags it with the request id.
  meta="$(/usr/bin/osascript -l JavaScript - "$command" "$I_CHANNEL" "$rid" 2>&1 <<'JXA'
ObjC.import('Foundation');
function run(argv) {
  var command;
  try { command = JSON.parse(argv[0]); } catch (e) { return 'BAD not JSON: ' + argv[0]; }
  if (typeof command !== 'object' || command === null || Array.isArray(command) || typeof command.cmd !== 'string') {
    return 'BAD a command is a JSON object with "cmd": ' + argv[0];
  }
  command.rid = argv[2];
  $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately(
    argv[1], JSON.stringify(command), $(), true);
  return command.cmd + ' ' + (typeof command.timeout === 'number' ? command.timeout : '');
}
JXA
)" || { echo "dev-app: couldn't post $command: $meta" >&2; return 1; }
  case "$meta" in BAD\ *) echo "dev-app: ${meta#BAD }" >&2; return 1 ;; esac
  name="${meta%% *}"
  wait="${meta#* }"
  if [ -z "$timeout" ]; then
    case "$name" in
      # They wait in the app for up to their own timeout (10 s by default).
      waitFor|open) timeout=$(( ${wait%.*} + 10 )); [ -n "$wait" ] || timeout=20 ;;
      *) timeout=30 ;;
    esac
  fi
  local deadline=$(( SECONDS + timeout ))
  while :; do
    line="$(grep -m 1 -F "#$rid " "$I_LOG" 2>/dev/null || true)"
    [ -z "$line" ] || break
    if [ "$name" != quit ] && ! alive "$I_PID"; then
      echo "dev-app: the app quit before answering $name (see Tools/dev-app.sh --id $I_ID log)" >&2
      return 1
    fi
    if [ $SECONDS -ge $deadline ]; then
      echo "$name error no answer in ${timeout}s" >&2
      return 1
    fi
    sleep 0.05
  done
  line="${line#\#$rid }"
  echo "$line"
  case "$line" in "$name error"*) return 1 ;; esac
  return 0
}

cmd_start() {
  local mode="" home="" appearance="" size="" fixtures=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --mock) mode=mock ;;
      --fixtures) fixtures+=("$(real_dir "${2:?--fixtures needs a folder}")"); mode=mock; shift ;;
      --home) home="${2:?--home needs a folder}"; shift ;;
      --appearance) appearance="${2:?--appearance needs light or dark}"; shift ;;
      --size) size="${2:?--size needs WxH}"; shift ;;
      --id) ID="${2:?--id needs a name}"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option for start: $1" ;;
    esac
    shift
  done
  if [ -n "$home" ] && [ "$mode" = mock ]; then die "--home and --mock go to different runners; pick one"; fi
  [ -z "$appearance" ] || [ "$appearance" = light ] || [ "$appearance" = dark ] || die "--appearance is light or dark"
  [ -z "$size" ] || [[ "$size" =~ ^[0-9]+x[0-9]+$ ]] || die "--size is WxH, like 1240x820"
  local fixture live
  live="$(real_dir "$REAL_HOME")"
  for fixture in ${fixtures[@]+"${fixtures[@]}"}; do
    # The live runner's thread folders aren't fixtures: tb export makes one.
    case "$fixture/" in "$live"/*) die "that's inside the live runner's data folder; tb export the thread instead" ;; esac
    [ -f "$fixture/thread.json" ] || ls "$fixture"/*/thread.json >/dev/null 2>&1 || die "no fixtures in $fixture (a tb export folder, or a folder of them)"
  done

  local data
  if [ -n "$home" ]; then
    case "$home" in /*) ;; *) home="$PWD/$home" ;; esac
    # The live runner's data folder holds its token; a debug app driven by
    # an agent never connects to it.
    [ "$(real_dir "$home")" != "$(real_dir "$REAL_HOME")" ] || die "that's the live runner's data folder. Start a dev runner (runner/scripts/dev-runner.sh) and pass its home."
    [ -f "$home/runner.json" ] && [ -f "$home/secrets/runner-token" ] || die "no runner.json and token in $home; is a dev runner running there?"
    data="$(real_dir "$home")"
  fi

  if [ -n "$ID" ]; then
    [[ "$ID" =~ ^[A-Za-z0-9_-]{1,24}$ ]] || die "an id is up to 24 letters, digits, - or _"
  else
    ID="$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
  fi
  local dir; dir="$(instance_dir "$ID")"
  [ ! -e "$dir" ] || die "there's already an instance $ID (stop it first)"
  mkdir -p "$dir"
  local bundle="$dir/Threadbare.app" bundle_id="$BUNDLE_PREFIX.$ID"
  # Written as it goes, so stop can clean up after a start that failed.
  {
    echo "bundle=$bundle"
    echo "bundle_id=$bundle_id"
  } >"$dir/instance"
  printf '%s' "$ID" >"$STATE_ROOT/latest"
  CLEANUP_ID="$ID"
  trap 'die "start failed"' ERR

  echo "Building the debug app..."
  if ! swift build --package-path "$APP_ROOT" --product Threadbare >"$dir/build.log" 2>&1; then
    tail -n 30 "$dir/build.log" >&2
    false
  fi
  local bin; bin="$(swift build --package-path "$APP_ROOT" --show-bin-path 2>/dev/null)/Threadbare"
  # Its own bundle id gives it its own settings (window size, sidebar
  # width, last account), so it neither reads nor changes the installed
  # app's, nor another instance's.
  mkdir -p "$bundle/Contents/MacOS"
  cp "$bin" "$bundle/Contents/MacOS/Threadbare"
  cp "$APP_ROOT/Resources/Info.plist" "$bundle/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" \
    -c "Set :CFBundleName Threadbare dev $ID" -c "Set :CFBundleDisplayName Threadbare dev $ID" "$bundle/Contents/Info.plist"
  codesign --force --sign - "$bundle" >/dev/null 2>&1

  local runner
  if [ -z "$home" ]; then
    runner=mock
    data="$dir/data"
    mkdir -p "$data"
    local node; node="$(node_bin)"
    if [ ! -d "$TOOLS_DIR/mock-runner/node_modules" ]; then
      (cd "$TOOLS_DIR/mock-runner" && PATH="$(dirname "$node"):$PATH" npm install --silent)
    fi
    # The demo threads unless fixtures were given: the private ones in
    # app/.fixtures are real conversations and stay out of screenshots
    # unless asked for.
    local args=()
    if [ ${#fixtures[@]} -eq 0 ]; then fixtures=("$TOOLS_DIR/mock-runner/fixtures"); fi
    for fixture in "${fixtures[@]}"; do args+=(--fixtures "$fixture"); done
    nohup "$node" "$TOOLS_DIR/mock-runner/server.mjs" --data-dir "$data" "${args[@]}" --ready-file "$dir/mock.port" \
      >"$dir/mock.log" 2>&1 </dev/null &
    echo "mock_pid=$!" >>"$dir/instance"
    local i
    for i in $(seq 1 200); do [ -f "$dir/mock.port" ] && break; sleep 0.05; done
    [ -f "$dir/mock.port" ] || { tail -n 20 "$dir/mock.log" >&2; die "the mock runner didn't start"; }
  else
    runner="home $data"
  fi
  {
    echo "data=$data"
    echo "runner=$runner"
  } >>"$dir/instance"

  # open -g launches it without bringing it forward; the app then puts its
  # window behind everything as soon as it's there (Automation.swift).
  local app_args=(--data-dir "$data" --automation "$dir/automation.log" --automation-id "$ID" --app-log "$dir/app.log")
  [ -z "$appearance" ] || app_args+=(--appearance "$appearance")
  [ -z "$size" ] || app_args+=(--window-size "$size")
  open -g -n "$bundle" --stdout "$dir/app.stdout" --stderr "$dir/app.stderr" --args "${app_args[@]}"
  local pid=""
  for i in $(seq 1 200); do
    pid="$(bundle_pid "$bundle")"
    [ -n "$pid" ] && break
    sleep 0.05
  done
  [ -n "$pid" ] || die "the app didn't start (see $dir/app.stderr)"
  echo "pid=$pid" >>"$dir/instance"
  echo "started=$(date +%s)" >>"$dir/instance"
  for i in $(seq 1 400); do grep -qx ready "$dir/automation.log" 2>/dev/null && break; sleep 0.05; done
  grep -qx ready "$dir/automation.log" 2>/dev/null || die "the app didn't take commands (see $dir/app.stderr)"
  load_instance "$ID"
  send '{"cmd":"waitFor","ready":true,"timeout":20}' >/dev/null || { tail -n 20 "$dir/app.log" >&2; die "the app didn't connect to the runner"; }
  trap - ERR
  CLEANUP_ID=""

  echo "Started dev app $ID (pid $pid) on $( [ "$runner" = mock ] && echo "the mock runner" || echo "the runner at $data" )."
  echo "  data folder: $data"
  echo "  Tools/dev-app.sh --id $ID do '{\"cmd\":\"open\",\"id\":\"<thread>\"}'   dump   shot <file.png>   log   stop"
}

cmd_do() {
  local timeout="" commands=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout) timeout="${2:?--timeout needs seconds}"; shift ;;
      --id) ID="${2:?--id needs an id}"; shift ;;
      *) commands+=("$1") ;;
    esac
    shift
  done
  [ ${#commands[@]} -gt 0 ] || die "do needs at least one '<json>' command"
  load_instance "$(resolve_id)"
  local command
  for command in "${commands[@]}"; do
    send "$command" "$timeout" || exit 1
  done
}

cmd_shot() {
  local file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --id) ID="${2:?--id needs an id}"; shift ;;
      *) [ -z "$file" ] || die "shot takes one file"; file="$1" ;;
    esac
    shift
  done
  [ -n "$file" ] || die "shot needs a file (.png)"
  case "$file" in /*) ;; *) file="$PWD/$file" ;; esac
  load_instance "$(resolve_id)"
  send "{\"cmd\":\"screenshot\",\"path\":$(json_string "$file")}"
}

cmd_dump() {
  local format=text
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) format=json ;;
      --id) ID="${2:?--id needs an id}"; shift ;;
      *) die "unknown option for dump: $1" ;;
    esac
    shift
  done
  load_instance "$(resolve_id)"
  local out="$I_DIR/dump.$format"
  send "{\"cmd\":\"dump\",\"format\":\"$format\",\"out\":$(json_string "$out")}" >/dev/null || exit 1
  cat "$out"
}

cmd_log() {
  local follow="" lines=200 which=app
  while [ $# -gt 0 ]; do
    case "$1" in
      -f) follow=-f ;;
      -n) lines="${2:?-n needs a number}"; shift ;;
      --mock) which=mock ;;
      --automation) which=automation ;;
      --id) ID="${2:?--id needs an id}"; shift ;;
      *) die "unknown option for log: $1" ;;
    esac
    shift
  done
  load_instance "$(resolve_id)"
  local file="$I_DIR/$which.log"
  [ -f "$file" ] || die "no $which log for $I_ID"
  tail -n "$lines" $follow "$file"
}

# Quits the app (the quit command, then a kill of the pid start recorded if
# it's still that bundle's binary), stops the mock if it's this instance's,
# and removes everything the instance made, settings included.
stop_one() {
  load_instance "$1"
  # A start that failed before it wrote the pid down.
  [ -n "$I_PID" ] || [ -z "$I_BUNDLE" ] || I_PID="$(bundle_pid "$I_BUNDLE")"
  if alive "$I_PID"; then
    send '{"cmd":"quit"}' 5 >/dev/null 2>&1 || true
    local i
    for i in $(seq 1 100); do alive "$I_PID" || break; sleep 0.05; done
    if alive "$I_PID" && ps -p "$I_PID" -o command= | grep -qF "$I_BUNDLE/Contents/MacOS/Threadbare"; then
      kill "$I_PID" 2>/dev/null || true
    fi
  fi
  if alive "$I_MOCK_PID" && ps -p "$I_MOCK_PID" -o command= | grep -qF "$I_DIR/data"; then
    kill "$I_MOCK_PID" 2>/dev/null || true
  fi
  [ -z "$I_BUNDLE" ] || [ ! -d "$I_BUNDLE" ] || "$LSREGISTER" -u "$I_BUNDLE" >/dev/null 2>&1 || true
  # Only ever this instance's own bundle id.
  case "$I_BUNDLE_ID" in
    "$BUNDLE_PREFIX".?*)
      defaults delete "$I_BUNDLE_ID" >/dev/null 2>&1 || true
      rm -rf "$HOME/Library/Preferences/$I_BUNDLE_ID.plist" "$HOME/Library/Saved Application State/$I_BUNDLE_ID.savedState" \
        "$HOME/Library/Caches/$I_BUNDLE_ID" "$HOME/Library/HTTPStorages/$I_BUNDLE_ID" "$HOME/Library/HTTPStorages/$I_BUNDLE_ID.binarycookies"
      ;;
  esac
  rm -rf "$I_DIR"
  if [ -f "$STATE_ROOT/latest" ] && [ "$(cat "$STATE_ROOT/latest")" = "$1" ]; then rm -f "$STATE_ROOT/latest"; fi
  echo "Stopped dev app $1."
}

cmd_stop() {
  local everything=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --all) everything=1 ;;
      --id) ID="${2:?--id needs an id}"; shift ;;
      *) die "unknown option for stop: $1" ;;
    esac
    shift
  done
  if [ -n "$everything" ]; then
    local file any=""
    for file in "$STATE_ROOT"/*/instance; do
      [ -f "$file" ] || continue
      any=1
      stop_one "$(basename "$(dirname "$file")")"
    done
    [ -n "$any" ] || echo "No dev apps."
    return
  fi
  stop_one "$(resolve_id)"
}

cmd_status() {
  local file found=""
  local latest=""
  [ -f "$STATE_ROOT/latest" ] && latest="$(cat "$STATE_ROOT/latest")"
  for file in "$STATE_ROOT"/*/instance; do
    [ -f "$file" ] || continue
    found=1
    local id; id="$(basename "$(dirname "$file")")"
    load_instance "$id"
    local state="stopped (run stop to clean up)"
    alive "$I_PID" && state="running, pid $I_PID"
    printf '%s %-8s %s; %s\n' "$( [ "$id" = "$latest" ] && echo '*' || echo ' ')" "$id" "$state" \
      "$( [ "$I_RUNNER" = mock ] && echo "mock runner (data $I_DATA)" || echo "runner at ${I_RUNNER#home }")"
  done
  [ -n "$found" ] || echo "No dev apps. Start one with Tools/dev-app.sh start --mock."
}

# ------------------------------------------------------------------ main

ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --id) ID="${2:?--id needs an id}"; shift 2 ;;
    -h|--help|help) usage; exit 0 ;;
    *) break ;;
  esac
done
[ $# -gt 0 ] || { usage; exit 2; }
command="$1"
shift
case "$command" in
  start) cmd_start "$@" ;;
  do) cmd_do "$@" ;;
  shot) cmd_shot "$@" ;;
  dump) cmd_dump "$@" ;;
  log) cmd_log "$@" ;;
  stop) cmd_stop "$@" ;;
  status) cmd_status ;;
  *) usage >&2; exit 2 ;;
esac
