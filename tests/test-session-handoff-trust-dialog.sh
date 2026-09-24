#!/usr/bin/env bash
# Regression coverage for Claude Code's first-launch workspace-trust dialog
# ("Do you trust the files in this folder?" ... "Enter to confirm · Esc to
# cancel") being treated as a menu widget, not a ready pane. Incident
# (2026-09-24): a kickoff paste's Enter landed on exactly this dialog on the
# very first launch in a fresh worktree and answered it with its default
# "No, exit" — Claude exited immediately and the supervisor loop went into a
# 300s restart backoff, while `send` reported UNVERIFIED (true, but not why).
#
# The fix: _is_on_menu (session-handoff.sh) now also matches "trust this
# folder" / "Enter to confirm" (it already matched "Esc to cancel"
# incidentally), and _state_of returns a distinct `menu` state — checked
# BEFORE busy/ready — so both `check` (which gates new-session.sh's kickoff)
# and `send`'s own initial gate refuse outright instead of falling through to
# a paste. There is no documented way to pre-accept trust for an INTERACTIVE
# session (verified against `claude --help` on the installed CLI, 2026-09-24
# — the only built-in bypass is `-p`/non-interactive mode, which does not
# apply to a persistent spawned TUI session); the honest fix is to refuse and
# say so, not to fabricate an auto-answer or write `~/.claude.json` by hand.
#
# Exercised against a REAL tmux pane running fake-claude-tui.py's
# "trust-dialog" mode (same fixture as test-session-handoff-paste-race.sh).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FIXTURE="$HERE/fake-claude-tui.py"
HANDOFF="$HERE/../scripts/session-handoff.sh"
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }
has(){ if printf '%s' "$2" | grep -qF "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — pattern not found: $3 in: $2"; fi; }

command -v tmux >/dev/null 2>&1    || { echo "session-handoff-trust-dialog: SKIP (no tmux)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "session-handoff-trust-dialog: SKIP (no python3)"; exit 0; }

WORK="$(mktemp -d)"
trap 'tmux kill-session -t "$S" 2>/dev/null || true; rm -rf "$WORK"' EXIT

S="hoff-trust-$$"
LOG="$WORK/tui.log"; : > "$LOG"
tmux new-session -d -s "$S" -x 80 -y 24 2>/dev/null
tmux send-keys -t "$S" "FAKE_TUI_LOG='$LOG' exec -a claude python3 '$FIXTURE' trust-dialog" Enter
tries=0
while [ "$tries" -lt 50 ]; do
  [ "$(tmux list-panes -t "$S" -F '#{pane_current_command}' 2>/dev/null | head -1)" = claude ] \
    && tmux capture-pane -p -t "$S" 2>/dev/null | grep -qF 'trust this folder' && break
  sleep 0.1; tries=$((tries+1))
done

# `check`: state must be `menu`, not `ready` — this is what gates
# new-session.sh's kickoff loop; if this were still `ready`, the kickoff
# would proceed straight to `send` below.
check_out="$(bash "$HANDOFF" check "$S" 2>&1)"; check_rc=$?
has "check-state-menu" "$check_out" "state=menu"
ok  "check-exit1"      "$check_rc" "1"

# `ready`: same signal via the positive predicate, with a diagnosable reason.
ready_out="$(bash "$HANDOFF" ready "$S" 2>&1)"; ready_rc=$?
has "ready-not-safe-menu" "$ready_out" "NOT-SAFE reason=menu"
ok  "ready-exit1"         "$ready_rc" "1"

# `send`: must refuse outright (exit 2) with a message naming the hazard —
# and, critically, the fixture's log must show ZERO paste/Enter events: send
# must refuse BEFORE ever touching tmux paste-buffer/send-keys, not paste
# first and hope for the best.
send_out="$(bash "$HANDOFF" send "$S" "hello race" 2>&1)"; send_rc=$?
has "send-refuses-menu"     "$send_out" "menu/dialog widget"
has "send-mentions-trust"   "$send_out" "folder-trust"
ok  "send-exit2"            "$send_rc" "2"
ok  "send-touched-nothing"  "$(wc -l < "$LOG" | tr -d ' ')" "0"

# Negative case: a normal idle session whose TRANSCRIPT quotes the dialog's
# hint text (e.g. one discussing this bug) must NOT read as `menu` — `send`
# hard-refuses on menu, so a whole-screen match would block every relay into
# it. Only the last few non-blank lines (where a live footer sits) count.
S2="hoff-quote-$$"
trap 'tmux kill-session -t "$S" 2>/dev/null || true; tmux kill-session -t "$S2" 2>/dev/null || true; rm -rf "$WORK"' EXIT
tmux new-session -d -s "$S2" -x 80 -y 24 2>/dev/null
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
tmux send-keys -t "$S2" "exec -a claude python3 '$WORK/quote.py'" Enter
for _ in $(seq 1 20); do tmux capture-pane -p -t "$S2" | grep -q '\[Opus 5.5\]' && break; sleep 0.2; done
has "quoted-hint-not-menu" "$(bash "$HANDOFF" check "$S2" 2>&1)" "state=ready"

echo "session-handoff-trust-dialog: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
