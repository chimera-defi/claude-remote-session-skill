#!/usr/bin/env bash
# session-handoff.sh `send` / `check` / `ready` end to end against a REAL tmux pane running
# tests/fake-claude-tui.py (the pane's process is renamed `claude`, so the script classifies it as a
# live Claude pane). Each case checks the outcome that matters: did the message land exactly once,
# did we refuse before touching the pane, and does `send` stay honest when it cannot prove landing.
#   drop-first       first paste silently eaten  -> one retry, lands, exactly one submit
#   silent-accept    every paste accepted, no repaint -> UNVERIFIED (never a false "landed"), documented double paste
#   busy-after-send  ordinary success            -> one paste, no retry on top of a success
#   collapsed-paste  "[Pasted text +N lines]" placeholder counts as buffered -> second Enter lands it
#   trust-dialog     first-launch trust menu     -> check/ready/send all refuse, nothing pasted
#   bare shell       `sleep 300` backoff pane    -> send refuses, pane byte-identical (no injection)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
FIXTURE="$HERE/fake-claude-tui.py"
HANDOFF="$HERE/../scripts/session-handoff.sh"

command -v tmux >/dev/null 2>&1    || { echo "session-handoff-tui: SKIP (no tmux)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "session-handoff-tui: SKIP (no python3)"; exit 0; }

WORK="$(mktemp -d)"
trap 'tmux ls -F "#{session_name}" 2>/dev/null | grep "^hoff-tui-$$-" | while read -r s; do tmux kill-session -t "$s" 2>/dev/null || true; done; rm -rf "$WORK"' EXIT

# spawn_tui <mode> [ready-pattern]: tmux session running the fixture in <mode>; log at $WORK/<session>.log
spawn_tui() {
  local mode="$1" want="${2:-❯}" s tries=0 cap
  s="hoff-tui-$$-$RANDOM-$RANDOM"
  : > "$WORK/$s.log"
  tmux new-session -d -s "$s" -x 80 -y 24 2>/dev/null
  tmux send-keys -t "$s" "FAKE_TUI_LOG='$WORK/$s.log' exec -a claude python3 '$FIXTURE' '$mode'" Enter
  while [ "$tries" -lt 50 ]; do
    if [ "$(tmux list-panes -t "$s" -F '#{pane_current_command}' 2>/dev/null | head -1)" = claude ] \
       && cap="$(tmux capture-pane -p -t "$s" 2>/dev/null && printf x)" && cap=${cap%x} && [ -n "$cap" ] \
       && grep -qF -- "$want" <<<"${cap%$'\n'}"; then break; fi
    sleep 0.1; tries=$((tries+1))
  done
  printf '%s' "$s"
}
MSG="handoff race probe"

# drop-first: retry fires exactly once, one copy reaches the transcript
S="$(spawn_tui drop-first)"
out="$(bash "$HANDOFF" send "$S" "$MSG" 2>&1)"; rc=$?
has "drop-first: landed" "$out" "landed on $S"; ok "drop-first: exit 0" "$rc" "0"
ok "drop-first: two pastes (one retry)" "$(grep -c '^PASTE ' "$WORK/$S.log")" "2"
ok "drop-first: one submit" "$(grep -c '^SUBMIT:' "$WORK/$S.log")" "1"
ok "drop-first: one echo on screen" "$(tmux capture-pane -p -t "$S" | grep -oF "$MSG" | wc -l | tr -d ' ')" "1"

# silent-accept: indistinguishable from drop-first by design; must stay honest
S="$(spawn_tui silent-accept)"
out="$(bash "$HANDOFF" send "$S" "$MSG" 2>&1)"; rc=$?
has "silent-accept: UNVERIFIED, not landed" "$out" "UNVERIFIED on $S"; ok "silent-accept: exit 1" "$rc" "1"
ok "silent-accept: documented double delivery" "$(grep -c '^PASTE ' "$WORK/$S.log")" "2"

# busy-after-send: success on the first poll must not trigger the retry path
S="$(spawn_tui busy-after-send)"
out="$(bash "$HANDOFF" send "$S" "$MSG" 2>&1)"; rc=$?
has "busy-after-send: landed" "$out" "landed on $S"; ok "busy-after-send: exit 0" "$rc" "0"
ok "busy-after-send: one paste" "$(grep -c '^PASTE ' "$WORK/$S.log")" "1"

# collapsed-paste: placeholder on the input line is "buffered": a second Enter lands it
S="$(spawn_tui collapsed-paste)"
out="$(bash "$HANDOFF" send "$S" "$MSG" 2>&1)"; rc=$?
has "collapsed-paste: landed" "$out" "landed on $S"; ok "collapsed-paste: exit 0" "$rc" "0"
ok "collapsed-paste: two Enters, one submit" "$(grep -c '^ENTER$' "$WORK/$S.log")/$(grep -c '^SUBMIT:' "$WORK/$S.log")" "2/1"

# trust-dialog: a menu widget is not a ready pane; refuse before touching tmux
S="$(spawn_tui trust-dialog 'trust this folder')"
out="$(bash "$HANDOFF" check "$S" 2>&1)"; rc=$?
has "trust-dialog: check state=menu" "$out" "state=menu"; ok "trust-dialog: check exit 1" "$rc" "1"
has "trust-dialog: ready NOT-SAFE" "$(bash "$HANDOFF" ready "$S" 2>&1)" "NOT-SAFE reason=menu"
out="$(bash "$HANDOFF" send "$S" "hello" 2>&1)"; rc=$?
has "trust-dialog: send names the hazard" "$out" "folder-trust"; ok "trust-dialog: send exit 2" "$rc" "2"
ok "trust-dialog: send touched nothing" "$(wc -l < "$WORK/$S.log" | tr -d ' ')" "0"

# a ready pane whose transcript merely QUOTES the dialog text is not a menu
S="hoff-tui-$$-quote"
tmux new-session -d -s "$S" -x 80 -y 24 2>/dev/null
cat > "$WORK/quote.py" <<'PY'
import time
print("● the dialog said: Yes, I trust this folder / Enter to confirm · Esc to cancel")
print()
print("● done.")
print()
print("─" * 40)
print("❯ ")
print("─" * 40)
print("  [Opus 5.5] x")
time.sleep(60)
PY
tmux send-keys -t "$S" "exec -a claude python3 '$WORK/quote.py'" Enter
for _ in $(seq 1 20); do
  cap="$(tmux capture-pane -p -t "$S" && printf x)" && cap=${cap%x} && grep -q '\[Opus 5.5\]' <<<"$cap" && break
  sleep 0.2
done
has "quoted dialog text is not menu" "$(bash "$HANDOFF" check "$S" 2>&1)" "state=ready"

# bare shell (supervisor backoff `sleep`): refuse, and prove nothing was pasted
S="hoff-tui-$$-sleep"
tmux new-session -d -s "$S" -x 80 -y 24 2>/dev/null
tmux send-keys -t "$S" "sleep 300" Enter
for _ in $(seq 1 50); do [ "$(tmux list-panes -t "$S" -F '#{pane_current_command}' | head -1)" = sleep ] && break; sleep 0.1; done
before="$(tmux capture-pane -p -t "$S")"
has "bare shell: check state=starting" "$(bash "$HANDOFF" check "$S" 2>&1)" "state=starting"
out="$(bash "$HANDOFF" send "$S" 'echo pwned $(id) `whoami`' 2>&1)"; rc=$?
has "bare shell: send refuses" "$out" "claude not running in pane (sleep)"; ok "bare shell: send exit 2" "$rc" "2"
ok "bare shell: pane byte-identical (no injection)" "$([ "$before" = "$(tmux capture-pane -p -t "$S")" ] && echo yes || echo no)" "yes"

finish "session-handoff-tui"
