#!/usr/bin/env bash
# create-session.sh — back-compat shim; delegates to new-session.sh.
# Usage: FOLDERNAME=my-project bash scripts/create-session.sh
# Override AGENTS_HOME to change the base path (default: /home/agents).
#
# This wrapper preserves the original calling convention while new-session.sh
# is the single source of truth for session generation.
set -euo pipefail

: "${FOLDERNAME:?Set FOLDERNAME to the project folder name, e.g. SharedStake-ui}"
: "${AGENTS_HOME:=/home/agents}"

# Delegate to new-session.sh, forcing workspace/ type (original behaviour).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEW_SESSION_BIN="${AGENTS_HOME}/.local/bin/new-session"

if [ -x "$NEW_SESSION_BIN" ]; then
  exec "$NEW_SESSION_BIN" "$FOLDERNAME" workspace
else
  exec bash "${SCRIPT_DIR}/new-session.sh" "$FOLDERNAME" workspace
fi
