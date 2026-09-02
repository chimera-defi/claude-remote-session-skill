#!/usr/bin/env bash
# session-send.sh — relay a follow-up message into an ALREADY-RUNNING session,
# under a shorter name than `session-handoff send`. All the mechanics (queued-
# input handling, bracketed paste, whitespace-only rejection, Enter + landed/
# unverified verdict) live in session-handoff.sh's `send` mode — this is a
# thin passthrough, not a second copy of that logic.
#
# Usage:
#   session-send <tmux-session> <msg>
#   session-send <tmux-session> --file <path>
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

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
