#!/usr/bin/env bash
# Rebuilds (debug) and relaunches the app.
set -euo pipefail

# THREADBARE_* was the old name for these variables: each stands in for its new name.
for v in $(compgen -e | grep '^THREADBARE_' || true); do n="THREADBEAR_${v#THREADBARE_}"; [ -n "${!n+x}" ] || export "$n=${!v}"; done
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${THREADBEAR_APP_DIR:-$HOME/Applications/Threadbear.app}"

bash "$SCRIPT_DIR/kill.sh"
THREADBEAR_BUILD_CONFIGURATION=debug bash "$SCRIPT_DIR/build-app.sh"
open "$APP_DIR"
echo "Threadbear launched."
