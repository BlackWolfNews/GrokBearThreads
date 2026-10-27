#!/usr/bin/env bash
# Quits the Threadbear app. The runner (and every agent) keeps going.
set -euo pipefail

# THREADBARE_* was the old name for these variables: each stands in for its new name.
for v in $(compgen -e | grep '^THREADBARE_' || true); do n="THREADBEAR_${v#THREADBARE_}"; [ -n "${!n+x}" ] || export "$n=${!v}"; done
APP_DIR="${THREADBEAR_APP_DIR:-$HOME/Applications/Threadbear.app}"
# Match the staged app's binary path only, so nothing else named Threadbear
# (a perf run from .build, say) is touched.
pkill -f "^$APP_DIR/Contents/MacOS/Threadbear" 2>/dev/null || true
