#!/bin/bash
# Runs the deploy tests: deploy-runner.sh, install-runner.sh and launch.mjs
# against a throwaway repo, a temp data dir and a fake launchctl, on the
# pinned Node. Under two minutes. TB_DEPLOY_KEEP=1 keeps the temp folder.
set -euo pipefail
# THREADBARE_* was the old name for these variables: each stands in for its new name.
for v in $(compgen -e | grep '^THREADBARE_' || true); do n="THREADBEAR_${v#THREADBARE_}"; [ -n "${!n+x}" ] || export "$n=${!v}"; done
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
NODE="${THREADBEAR_NODE:-$HOME/.nvm/versions/node/v24.22.1/bin/node}"
exec "$NODE" --test --test-reporter=spec --test-concurrency=1 test/deploy/*.test.ts
