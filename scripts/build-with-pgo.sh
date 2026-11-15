#!/usr/bin/env bash

set -o errexit
set -o nounset

# One-command PGO pipeline for Oracle GraalVM:
#   1. PGO=instrument build
#   2. automated training run (scripts/train-pgo.sh)
#   3. PGO=apply build
#
# Usage: scripts/build-with-pgo.sh [path-to-botmark-binary]
#        (or export BOTMARK_BIN; the bot client is optional)

SCRIPT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
REPO_DIR=$( dirname "${SCRIPT_DIR}" )
BOTMARK_BIN="${1:-${BOTMARK_BIN:-}}"

echo "== [1/3] Instrumented build =="
PGO=instrument "${REPO_DIR}/build.sh"

echo ""
echo "== [2/3] Automated training run =="
"${REPO_DIR}/scripts/train-pgo.sh" "${BOTMARK_BIN}"

echo ""
echo "== [3/3] Final PGO build =="
PGO=apply "${REPO_DIR}/build.sh"
