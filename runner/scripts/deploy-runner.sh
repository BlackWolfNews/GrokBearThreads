#!/bin/bash
# Builds a runner release from this checkout and switches the live runner to
# it, restarting it once no thread is running. --help lists the steps and
# options; docs/dev-tools.md has the whole design. The work is in
# deploy.mjs; this only picks the pinned Node, the one install-runner.sh
# puts in the plist, so the checks and the release run on the same Node.
#
#   scripts/deploy-runner.sh             build, smoke test, switch, restart
#   scripts/deploy-runner.sh --list      show the releases
#   scripts/deploy-runner.sh --rollback  back to the previous release
#
# THREADBEAR_LAUNCHCTL replaces launchctl (the tests stub it).
set -euo pipefail

# THREADBARE_* was the old name for these variables: each stands in for its new name.
for v in $(compgen -e | grep '^THREADBARE_' || true); do n="THREADBEAR_${v#THREADBARE_}"; [ -n "${!n+x}" ] || export "$n=${!v}"; done
NODE="${THREADBEAR_NODE:-$HOME/.nvm/versions/node/v24.22.1/bin/node}"
if [ ! -x "$NODE" ]; then
  echo "No Node binary at $NODE. Set THREADBEAR_NODE to a Node 24 binary." >&2
  exit 1
fi
exec "$NODE" "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/deploy.mjs" "$@"
