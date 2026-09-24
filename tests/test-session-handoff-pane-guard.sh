#!/usr/bin/env bash
# Regression coverage for two related 2026-09-24 incidents, both about
# session-handoff.sh correctly reading what's ACTUALLY in the pane before
# acting on it, rather than trusting a stale or oversimplified signal:
#
# 1. BUFFERED NOT DETECTED (ah_qt-gate-0924-0802, `new-session
#    questrade-ui-adapter --task-file`): Claude Code collapses a large/multi-
#    line paste to a placeholder ("[Pasted text #1 +17 lines]") instead of
#    echoing it verbatim. `send` reported UNVERIFIED while the pane showed
#    exactly that placeholder sitting on the input line — a single manual
#    Enter submitted it. The retry loop's _verdict never recognized the
#    placeholder as "still buffered" (frag can't literal-match a placeholder
#    that isn't the message), so it gave up instead of pressing Enter again.
#    Fixed by _is_collapsed_paste_in_input (session-handoff.sh), folded into
#    _verdict's "buffered" branch.
#
# 2. PASTE INTO A BARE SHELL (dangerous): claude had exited and the
#    supervisor loop was in its between-restarts `sleep 300` backoff.
#    `session-send --file` pasted a kickoff prompt (containing backticks and
#    $(...)) into that pane; caught and killed before the shell / next
#    claude invocation could read it back as input. `_state_of` used to
#    classify `sleep` as `busy`, and `send`'s `busy` arm only NOTES and
#    proceeds to paste — exactly the hole this incident fell through. Fixed
#    by reclassifying `sleep` as `starting` in _state_of (no claude process
#    in the pane at all, same as the supervisor-loop-not-yet-in-claude case
#    already refused there), plus a fresh pane_current_command re-check
#    immediately before the dropped-paste recovery's second paste attempt.
#
# Case 1 is exercised against fake-claude-tui.py's "collapsed-paste" mode
# (same fixture as test-session-handoff-paste-race.sh). Case 2 needs no
# fixture — a real `sleep` IS the bare-shell state being guarded against.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FIXTURE="$HERE/fake-claude-tui.py"
NEW_HANDOFF="$HERE/../scripts/session-handoff.sh"
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }
has(){ if printf '%s' "$2" | grep -qF "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — pattern not found: $3 in: $2"; fi; }

command -v tmux >/dev/null 2>&1    || { echo "session-handoff-pane-guard: SKIP (no tmux)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "session-handoff-pane-guard: SKIP (no python3)"; exit 0; }

WORK="$(mktemp -d)"
trap 'tmux ls -F "#{session_name}" 2>/dev/null | grep "^hoff-guard-$$-" | while read -r s; do tmux kill-session -t "$s" 2>/dev/null || true; done; rm -rf "$WORK"' EXIT

OLD_HANDOFF="$WORK/session-handoff-old.sh"
if git -C "$HERE/.." show origin/main:scripts/session-handoff.sh > "$OLD_HANDOFF" 2>/dev/null; then
  HAVE_OLD=yes
else
  HAVE_OLD=no
fi

MSG="handoff race probe"

# ── Case 1: collapsed-multiline-paste placeholder must count as buffered ---
spawn_collapsed() {
  local s log
  s="hoff-guard-$$-$RANDOM-$RANDOM"
  log="$WORK/$s.log"; : > "$log"
  tmux new-session -d -s "$s" -x 80 -y 24 2>/dev/null
  tmux send-keys -t "$s" "FAKE_TUI_LOG='$log' exec -a claude python3 '$FIXTURE' collapsed-paste" Enter
  local tries=0
  while [ "$tries" -lt 50 ]; do
    if [ "$(tmux list-panes -t "$s" -F '#{pane_current_command}' 2>/dev/null | head -1)" = claude ] \
       && tmux capture-pane -p -t "$s" 2>/dev/null | grep -qF '❯'; then
      break
    fi
    sleep 0.1; tries=$((tries+1))
  done
  printf '%s' "$s"
}

# 1a. Pre-fix session-handoff.sh (origin/main) must report UNVERIFIED —
# proves the fixture reproduces the actual bug (only ONE Enter is ever sent,
# since the old _verdict never recognizes the placeholder as buffered).
if [ "$HAVE_OLD" = yes ]; then
  S1A="$(spawn_collapsed)"
  out1a="$(bash "$OLD_HANDOFF" send "$S1A" "$MSG" 2>&1)"; rc1a=$?
  has "old-collapsed-unverified" "$out1a" "UNVERIFIED on $S1A"
  ok  "old-collapsed-exit1"      "$rc1a" "1"
  ok  "old-collapsed-one-enter"  "$(grep -c '^ENTER$' "$WORK/$S1A.log")" "1"
  tmux kill-session -t "$S1A" 2>/dev/null || true
else
  echo "SKIP: old-collapsed-* (origin/main not reachable in this checkout)"
fi

# 1b. Fixed session-handoff.sh must retry the Enter and land — the fixture
# ignores exactly the FIRST Enter while the placeholder is showing, so
# landing here is only possible if the retry loop pressed Enter a second
# time, which only happens if _verdict classified it as "buffered".
S1B="$(spawn_collapsed)"
out1b="$(bash "$NEW_HANDOFF" send "$S1B" "$MSG" 2>&1)"; rc1b=$?
has "new-collapsed-landed"    "$out1b" "landed on $S1B"
ok  "new-collapsed-exit0"     "$rc1b" "0"
ok  "new-collapsed-two-enters" "$(grep -c '^ENTER$' "$WORK/$S1B.log")" "2"
ok  "new-collapsed-one-submit" "$(grep -c '^SUBMIT:' "$WORK/$S1B.log")" "1"
tmux kill-session -t "$S1B" 2>/dev/null || true

# ── Case 2: refuse to paste into a bare shell (sleep, or any non-claude
# pane) — no fixture needed, a real `sleep` IS the state being guarded. -----
spawn_sleep() {
  local s
  s="hoff-guard-$$-$RANDOM-$RANDOM"
  tmux new-session -d -s "$s" -x 80 -y 24 2>/dev/null
  tmux send-keys -t "$s" "sleep 300" Enter
  local tries=0
  while [ "$tries" -lt 50 ]; do
    [ "$(tmux list-panes -t "$s" -F '#{pane_current_command}' 2>/dev/null | head -1)" = sleep ] && break
    sleep 0.1; tries=$((tries+1))
  done
  printf '%s' "$s"
}

S2="$(spawn_sleep)"
before="$(tmux capture-pane -p -t "$S2")"

check2_out="$(bash "$NEW_HANDOFF" check "$S2" 2>&1)"; check2_rc=$?
has "sleep-check-starting" "$check2_out" "state=starting"
ok  "sleep-check-exit1"    "$check2_rc" "1"

# The dangerous payload from the live incident's shape: backticks + $(...).
# If this ever reaches a real shell's stdin, it would execute — the pane
# capture after `send` must be BYTE-IDENTICAL to before, proving nothing was
# pasted, not just that send() printed a refusal.
send2_out="$(bash "$NEW_HANDOFF" send "$S2" 'echo pwned $(id) `whoami`' 2>&1)"; send2_rc=$?
has "sleep-send-refuses"       "$send2_out" "claude not running in pane (sleep)"
ok  "sleep-send-exit2"         "$send2_rc" "2"
after="$(tmux capture-pane -p -t "$S2")"
ok "sleep-pane-untouched" "$([ "$before" = "$after" ] && echo yes || echo no)" "yes"
has "sleep-pane-no-injection" "$after" "sleep 300"
if printf '%s' "$after" | grep -q "pwned"; then
  fail=$((fail+1)); echo "FAIL: sleep-pane-no-injection — payload text leaked into the pane"
else
  pass=$((pass+1))
fi
tmux kill-session -t "$S2" 2>/dev/null || true

echo "session-handoff-pane-guard: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
