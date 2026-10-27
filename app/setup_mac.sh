#!/usr/bin/env bash
set -euo pipefail

# THREADBARE_* was the old name for these variables: each stands in for its new name.
for v in $(compgen -e | grep '^THREADBARE_' || true); do n="THREADBEAR_${v#THREADBARE_}"; [ -n "${!n+x}" ] || export "$n=${!v}"; done
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${THREADBEAR_APP_DIR:-$HOME/Applications/Threadbear.app}"

THREADBEAR_BUILD_CONFIGURATION=release bash "$SCRIPT_DIR/build-app.sh"
echo ""
echo "Threadbear is installed at $APP_DIR"
echo "Launch it with: threadbear"
