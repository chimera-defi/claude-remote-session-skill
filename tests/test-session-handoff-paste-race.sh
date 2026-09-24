#!/usr/bin/env bash
# Regression coverage for the dropped-first-paste race (2026-09-24 incident,
# observed 8/8 on first sends via `new-session --task-file`, most recently
# ah_pf-process-0924-0734 07:34): session-handoff.sh's `send` polls `check`
# until the ❯ prompt renders, then bracket-pastes the message. On a freshly
# booted Claude Code the prompt can render before the TUI's paste handling is
# fully wired up, so the very first paste is silently dropped — the input box
# stays empty and the text never reaches the transcript — and the original
# Enter-retry loop (which only re-presses Enter while the text is still
# BUFFERED on the input line) has nothing to re-press, so it correctly gives
# up as UNVERIFIED rather than lying about success. The fix adds one more
# signal: if the pane reads _safety_reason=safe (truly idle) and the fragment
# is nowhere on screen, there's nothing to duplicate, so retry the paste once.
#
# Exercised against a REAL tmux pane running a tiny fake Claude-like TUI
# (fake-claude-tui.py, same directory) that can be told to drop its first
# paste, accept-but-never-render, or go busy right after Enter — the three
# shapes this fix has to tell apart. See that script's own docstring for what
# each mode models and why.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FIXTURE="$HERE/fake-claude-tui.py"
NEW_HANDOFF="$HERE/../scripts/session-handoff.sh"
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }
has(){ if printf '%s' "$2" | grep -qF "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — pattern not found: $3 in: $2"; fi; }

command -v tmux >/dev/null 2>&1    || { echo "session-handoff-paste-race: SKIP (no tmux)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "session-handoff-paste-race: SKIP (no python3)"; exit 0; }

WORK="$(mktemp -d)"
trap 'tmux ls -F "#{session_name}" 2>/dev/null | grep "^hoff-race-$$-" | while read -r s; do tmux kill-session -t "$s" 2>/dev/null || true; done; rm -rf "$WORK"' EXIT

# Pull the pre-fix session-handoff.sh straight from origin/main so "old
# behavior" is proven against what actually merged, not a hand-copied guess
# that could silently drift from it. Skip that one comparison (not the whole
# file) if the ref isn't available in this checkout — everything else here
# only needs the current tree.
OLD_HANDOFF="$WORK/session-handoff-old.sh"
if git -C "$HERE/.." show origin/main:scripts/session-handoff.sh > "$OLD_HANDOFF" 2>/dev/null; then
  HAVE_OLD=yes
else
  HAVE_OLD=no
fi

# spawn_tui <mode> -> tmux session name running fake-claude-tui.py in <mode>,
# with the pane's foreground process renamed to `claude` (same `exec -a
# claude` trick as tests/test-session-send.sh) so _state_of/_pane_cmd
# classify it as a live claude pane instead of `dead`/`starting` and refuse
# to send into it. Each call's log file lives at "$WORK/<session>.log" —
# deterministic from the returned name, so callers don't need a second
# return channel just to find it.
spawn_tui() {
  local mode="$1" s
  s="hoff-race-$$-$RANDOM-$RANDOM"
  : > "$WORK/$s.log"
  tmux new-session -d -s "$s" -x 80 -y 24 2>/dev/null
  tmux send-keys -t "$s" "FAKE_TUI_LOG='$WORK/$s.log' exec -a claude python3 '$FIXTURE' '$mode'" Enter
  # Wait for the renamed process AND its first render (the ❯ prompt) before
  # returning — acting earlier races every classifier that follows, same
  # reasoning as test-session-preserve.sh's spawn_in wait-for-child loop.
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

MSG="handoff race probe"

# ── Case 1: the headline repro — drop-first ------------------------------
# Paste #1 is silently eaten (matches the observed bug); paste #2 (the fix's
# one retry) is accepted and submitted normally.

# 1a. Pre-fix session-handoff.sh (origin/main) against this pane must report
# UNVERIFIED — proves the fixture reproduces the actual bug, not a strawman.
if [ "$HAVE_OLD" = yes ]; then
  S1A="$(spawn_tui drop-first)"
  out1a="$(bash "$OLD_HANDOFF" send "$S1A" "$MSG" 2>&1)"; rc1a=$?
  has "old-drop-first-unverified" "$out1a" "UNVERIFIED on $S1A"
  ok  "old-drop-first-exit1"      "$rc1a" "1"
  # Old code never retries the paste — exactly one PASTE event delivered.
  ok "old-drop-first-one-paste" "$(grep -c '^PASTE ' "$WORK/$S1A.log")" "1"
  tmux kill-session -t "$S1A" 2>/dev/null || true
else
  echo "SKIP: old-drop-first-* (origin/main not reachable in this checkout)"
fi

# 1b. Fixed session-handoff.sh (this tree) must land, with the retry firing
# exactly once and exactly one copy of the message reaching the transcript
# (not a duplicate from the recovered retry).
S1B="$(spawn_tui drop-first)"
out1b="$(bash "$NEW_HANDOFF" send "$S1B" "$MSG" 2>&1)"; rc1b=$?
has "new-drop-first-landed" "$out1b" "landed on $S1B"
ok  "new-drop-first-exit0"  "$rc1b" "0"
ok  "new-drop-first-two-pastes"  "$(grep -c '^PASTE '  "$WORK/$S1B.log")" "2"
ok  "new-drop-first-one-submit"  "$(grep -c '^SUBMIT:' "$WORK/$S1B.log")" "1"
finalcap1b="$(tmux capture-pane -p -t "$S1B")"
ok "new-drop-first-one-echo-on-screen" "$(printf '%s' "$finalcap1b" | grep -oF "$MSG" | wc -l | tr -d ' ')" "1"
tmux kill-session -t "$S1B" 2>/dev/null || true

# ── Case 2: silent-accept — the documented residual risk -------------------
# This TUI genuinely receives every paste (logged) but never repaints, so the
# screen looks identically "safe"/idle throughout — from a pane-capture
# vantage point this is byte-for-byte indistinguishable from drop-first, and
# _safety_reason/_in_transcript/_on_input_line have no other signal to go on.
# The fix CANNOT tell these apart (that's the residual risk called out in
# session-handoff.sh's own comment), so it retries here too, and the far end
# genuinely receives the message twice. What the fix must still get right:
# it never claims false success — `send` stays honest (UNVERIFIED, since
# nothing on screen ever proves landing), so the operator is still told to
# check by hand, even though the underlying delivery WAS duplicated. This
# assertion documents that reality rather than pretending the double-send
# doesn't happen.
S2="$(spawn_tui silent-accept)"
out2="$(bash "$NEW_HANDOFF" send "$S2" "$MSG" 2>&1)"; rc2=$?
has "silent-accept-still-unverified" "$out2" "UNVERIFIED on $S2"
ok  "silent-accept-exit1"            "$rc2" "1"
ok  "silent-accept-double-delivered" "$(grep -c '^PASTE ' "$WORK/$S2.log")" "2"
tmux kill-session -t "$S2" 2>/dev/null || true

# ── Case 3: busy-after-send — the ordinary "it just worked" case -----------
# Paste #1 is accepted and Enter submits it immediately, flipping the pane to
# a busy/working render. _verdict's `_is_working` check catches this on the
# very first poll of the FIRST _paste_and_wait call, so verdict is already
# `landed` before the recovery block's `[ "$verdict" != landed ]` guard is
# even reached — the retry path must not fire on top of an attempt that
# already succeeded.
S3="$(spawn_tui busy-after-send)"
out3="$(bash "$NEW_HANDOFF" send "$S3" "$MSG" 2>&1)"; rc3=$?
has "busy-after-send-landed"    "$out3" "landed on $S3"
ok  "busy-after-send-exit0"     "$rc3" "0"
ok  "busy-after-send-one-paste" "$(grep -c '^PASTE '  "$WORK/$S3.log")" "1"
ok  "busy-after-send-one-submit" "$(grep -c '^SUBMIT:' "$WORK/$S3.log")" "1"
tmux kill-session -t "$S3" 2>/dev/null || true

echo "session-handoff-paste-race: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
