#!/usr/bin/env bash
# session-send.sh is a thin passthrough to `session-handoff.sh send`: errors/exit codes come through
# from the helper, the helper resolves in both the repo layout (co-located .sh) and the deployed layout
# (flat copy on PATH), and a missing helper fails loudly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
SEND="$HERE/../scripts/session-send.sh"
NOSESS="no-such-session-send-test-$$"

out="$(bash "$SEND" "$NOSESS" hello 2>&1)"; rc=$?
has "forwards the helper's error" "$out" "no such tmux session"; ok "forwards exit 2" "$rc" "2"

# deployed layout: session-send alone next to a flat `session-handoff` on PATH
DEPLOY="$(mktemp -d)"; ISOLATED="$(mktemp -d)"; trap 'rm -rf "$DEPLOY" "$ISOLATED"' EXIT
cp "$SEND" "$DEPLOY/session-send.sh"
cp "$HERE/../scripts/session-handoff.sh" "$DEPLOY/session-handoff"; chmod +x "$DEPLOY/session-handoff"
out="$(PATH="$DEPLOY:$PATH" bash "$DEPLOY/session-send.sh" "$NOSESS" hello 2>&1)"; rc=$?
has "PATH fallback resolves the helper" "$out" "no such tmux session"; ok "PATH fallback exit 2" "$rc" "2"

# neither co-located nor on PATH
cp "$SEND" "$ISOLATED/session-send.sh"
out="$(env -i PATH=/usr/bin:/bin HOME="$HOME" bash "$ISOLATED/session-send.sh" missing-helper-test hello 2>&1)"; rc=$?
has "missing helper: clear error" "$out" "could not locate session-handoff"; ok "missing helper: exit 2" "$rc" "2"

# live throwaway pane whose foreground command is `claude`
if command -v tmux >/dev/null 2>&1; then
  S="sendtest-$$"
  tmux new-session -d -s "$S" 2>/dev/null
  tmux send-keys -t "$S" 'exec -a claude cat' Enter
  for _ in $(seq 1 50); do
    [ "$(tmux list-panes -t "$S" -F '#{pane_current_command}' 2>/dev/null | head -1)" = claude ] && break
    sleep 0.2
  done
  out="$(bash "$SEND" "$S" "   " 2>&1)"; rc=$?
  has "whitespace-only message rejected" "$out" "message is empty or whitespace-only"; ok "whitespace exit 2" "$rc" "2"
  out="$(bash "$SEND" "$S" --file "/no/such/path-$$" 2>&1)"; rc=$?
  has "unreadable --file reported as such" "$out" "could not read --file path"; ok "unreadable --file exit 2" "$rc" "2"
  hasnt "unreadable --file not misreported as empty" "$out" "empty or whitespace-only"
  MSGFILE="$(mktemp)"; printf 'relayed via --file\n' > "$MSGFILE"
  out="$(bash "$SEND" "$S" --file "$MSGFILE" 2>&1)"
  hasre "--file content is sent (reaches a verdict)" "$out" 'landed on|UNVERIFIED on'
  rm -f "$MSGFILE"; tmux kill-session -t "$S" 2>/dev/null || true
fi

finish "session-send"
