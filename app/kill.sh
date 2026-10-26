#!/usr/bin/env bash
# Quits the Threadbare app. The runner (and every agent) keeps going.
set -euo pipefail

APP_DIR="${THREADBARE_APP_DIR:-$HOME/Applications/Threadbare.app}"
# Match the staged app's binary path only, so nothing else named Threadbare
# (a perf run from .build, say) is touched.
pkill -f "^$APP_DIR/Contents/MacOS/Threadbare" 2>/dev/null || true
