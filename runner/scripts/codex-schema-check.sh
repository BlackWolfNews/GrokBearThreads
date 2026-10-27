#!/bin/bash
# Checks a Codex CLI's app-server protocol against what Threadbare relies on
# (src/adapters/codex/surface.ts): the methods, item types and fields the
# Codex adapter and normaliser use. E's update gate runs the same check
# before activating a new Codex; run this by hand to see what an update
# would change.
#
#   runner/scripts/codex-schema-check.sh [codex]
#
# codex defaults to THREADBARE_CODEX_PATH, else the codex next to the
# runner's Node. `app-server generate-ts` is offline and needs no login; it
# runs with a temp CODEX_HOME so it can't touch ~/.codex.
#
# Exit status: 0 when nothing Threadbare uses is missing (new names are
# listed but fine), 1 when something is missing, 2 when it couldn't check.
set -euo pipefail

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE="${THREADBARE_NODE:-$HOME/.nvm/versions/node/v24.22.1/bin/node}"
CODEX="${1:-${THREADBARE_CODEX_PATH:-$(dirname "$NODE")/codex}}"

if [ ! -x "$CODEX" ]; then
  echo "No codex at $CODEX" >&2
  exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/codex-schema.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home" "$WORK/ts"

# The launcher needs node on PATH.
export PATH="$(dirname "$NODE"):$PATH"
VERSION="$(CODEX_HOME="$WORK/home" "$CODEX" --version 2>/dev/null | awk '{print $NF}' || true)"
if ! CODEX_HOME="$WORK/home" "$CODEX" app-server generate-ts --experimental --out "$WORK/ts" >"$WORK/gen.log" 2>&1; then
  echo "codex app-server generate-ts failed:" >&2
  tail -20 "$WORK/gen.log" >&2
  exit 2
fi

"$NODE" --input-type=module -e '
const { checkSurface, testedVersion } = await import(process.argv[1]);
const { missing, added } = checkSurface(process.argv[2]);
const version = process.argv[3] || "unknown";
console.log(`Codex ${version} against the surface tested on ${testedVersion}:`);
if (!missing.length && !added.length) console.log("  everything Threadbare uses is there, and nothing new.");
for (const m of missing) console.log(`  missing: ${m}`);
for (const a of added) console.log(`  new: ${a}`);
process.exit(missing.length ? 1 : 0);
' "$RUNNER/src/adapters/codex/surface.ts" "$WORK/ts" "$VERSION"
