#!/usr/bin/env bash
# fake-handoff-sequence.sh — stand-in for `session-handoff.sh` used by
# tests/test-new-session-settle-loop.sh to exercise new-session.sh's REAL
# ready-settle loop (not a hand-retyped copy of its logic — see that test's
# header comment for why that distinction matters). Only `check` is
# meaningful here: it returns the NEXT state from $SEQ_FILE (one state per
# line) on each call, tracked via $POS_FILE since each invocation is a fresh
# process with no shared memory. Any other mode (the loop's own `send` call
# once it decides "ready") is a harmless stub — it must NOT consume a
# position from the sequence, or the poll count this test asserts on would
# be off by one (caught empirically while writing this fixture: an earlier,
# mode-unaware version of this script silently let the `send` call burn the
# last sequence entry too).
MODE="$1"; shift
SESSION="${1:-}"
if [ "$MODE" = check ]; then
  pos=0
  [ -f "$POS_FILE" ] && pos="$(cat "$POS_FILE")"
  line="$(sed -n "$((pos + 1))p" "$SEQ_FILE")"
  echo "$((pos + 1))" > "$POS_FILE"
  [ -n "$line" ] || line=ready  # sequence exhausted: stay ready (not expected to be hit)
  echo "check: $SESSION  state=$line  unit-active=no  model=?"
  [ "$line" = ready ] && exit 0 || exit 1
else
  echo "fake-handoff-sequence: $MODE stub"
  exit 0
fi
