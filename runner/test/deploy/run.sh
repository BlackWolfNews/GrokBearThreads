#!/bin/bash
# Runs the deploy tests: deploy-runner.sh, install-runner.sh and launch.mjs
# against a throwaway repo, a temp data dir and a fake launchctl, on the
# pinned Node. About a minute. TB_DEPLOY_KEEP=1 keeps the temp folder.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
NODE="${THREADBARE_NODE:-$HOME/.nvm/versions/node/v24.22.1/bin/node}"
exec "$NODE" --test --test-reporter=spec --test-concurrency=1 test/deploy/*.test.ts
