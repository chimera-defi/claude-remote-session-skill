#!/usr/bin/env bash
# session-send.sh — follow up with a running tmux session or Codex desktop thread.
# tmux sends delegate to session-handoff.sh; codex: targets use codex-send.
#
# Usage:
#   session-send <tmux-session> <msg>
#   session-send <tmux-session> --file <path>
#   session-send codex:list [--limit N] [--json]
#   session-send codex:<cs-ref> [--expect-identity <id>] (<msg> | --file <path>)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# tmux rewrites ':' in session names to '_', so codex: can never be a tmux session.
if [[ "${1:-}" == codex:* ]]; then
  target="${1#codex:}"; shift
  if [ "$target" = list ]; then set -- list "$@"; else set -- send "$target" "$@"; fi
  if [ -f "$HERE/codex-send.py" ]; then
    exec python3 "$HERE/codex-send.py" "$@"
  elif command -v codex-send >/dev/null 2>&1; then
    exec codex-send "$@"
  else
    echo "session-send: could not locate codex-send (next to this script or on PATH)" >&2
    exit 2
  fi
fi

# Resolve session-handoff co-located first (repo/dev layout), then on PATH
# (deployed layout: flat copies in ~/.local/bin with the .sh dropped, see
# session-git-prep.sh's header comment for why).
if [ -f "$HERE/session-handoff.sh" ]; then
  exec bash "$HERE/session-handoff.sh" send "$@"
elif command -v session-handoff >/dev/null 2>&1; then
  exec bash "$(command -v session-handoff)" send "$@"
else
  echo "session-send: could not locate session-handoff (looked next to this script and on PATH)" >&2
  exit 2
fi
