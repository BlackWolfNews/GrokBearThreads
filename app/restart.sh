#!/usr/bin/env bash
# Rebuilds (debug) and relaunches the app.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${THREADBARE_APP_DIR:-$HOME/Applications/Threadbare.app}"

bash "$SCRIPT_DIR/kill.sh"
THREADBARE_BUILD_CONFIGURATION=debug bash "$SCRIPT_DIR/build-app.sh"
open "$APP_DIR"
echo "Threadbare launched."
