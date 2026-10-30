#!/usr/bin/env bash
# session-send.sh — relay a follow-up message into an ALREADY-RUNNING session,
# under a shorter name than `session-handoff send`. All the mechanics (queued-
# input handling, bracketed paste, whitespace-only rejection, Enter + landed/
# unverified verdict) live in session-handoff.sh's `send` mode — this is a
# thin passthrough, not a second copy of that logic. A codex: target goes to
# codex-send instead: a Codex desktop thread, queued through its local
# app-server socket (replies still come by the bus).
#
# Usage:
#   session-send <tmux-session> <msg>
#   session-send <tmux-session> --file <path>
#   session-send codex:list [--limit N] [--json]
#   session-send codex:<cs-ref> [--expect-identity <id>] (<msg> | --file <path>)
# Exit (both kinds): 0 sent, 1 unverified/uncertain (codex: do NOT resend), 2 refused (not sent).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# tmux rewrites ':' in session names to '_', so codex: can never be a tmux session.
if [[ "${1:-}" == codex:* ]]; then
  target="${1#codex:}"; shift
  if [ "$target" = list ]; then set -- list "$@"; else set -- send "$target" "$@"; fi
  if [ -f "$HERE/codex-send.py" ]; then
    exec python3 "$HERE/codex-send.py" "$@"
  elif [ -f "$HERE/codex-send" ]; then
    exec python3 "$HERE/codex-send" "$@"
  elif command -v codex-send >/dev/null 2>&1; then
    exec codex-send "$@"
  else
    echo "session-send: could not locate codex-send (next to this script or on PATH)" >&2
    exit 2
  fi
fi

# Resolve session-handoff co-located first, in the repo layout (.sh) and then the
# deployed layout (flat copies in ~/.local/bin with the .sh dropped, see
# session-git-prep.sh's header comment for why), and only then on PATH: systemd
# user units run with a PATH that lacks ~/.local/bin.
if [ -f "$HERE/session-handoff.sh" ]; then
  exec bash "$HERE/session-handoff.sh" send "$@"
elif [ -f "$HERE/session-handoff" ]; then
  exec bash "$HERE/session-handoff" send "$@"
elif command -v session-handoff >/dev/null 2>&1; then
  exec bash "$(command -v session-handoff)" send "$@"
else
  echo "session-send: could not locate session-handoff (looked next to this script and on PATH)" >&2
  exit 2
fi
