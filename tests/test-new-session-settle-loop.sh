#!/usr/bin/env bash
# Regression coverage for new-session.sh's ready-settle loop (the
# NEW_SESSION_TASK_SETTLE consecutive-polls requirement, plus its
# state=menu/trust-dialog early break — see the loop's own comment,
# scripts/new-session.sh just above `ready=no`).
#
# This loop only runs after a REAL tmux+systemd spawn (`--task`/--task-file`
# kickoff, gated behind `if [ -n "$TASK" ]`), which test-new-session-task.sh
# deliberately does not exercise (its own header comment says so — only
# --dry-run paths, which exit before the spawn). That left the loop's actual
# code — now with a second exit path (menu detection) added on top of the
# consecutive-settle counting — completely unexercised: green shellcheck and
# a green suite over code nothing had ever run.
#
# Rather than hand-retype the loop's logic into a test (which drifts silently
# from the real file the next time it's edited — the exact failure mode this
# repo's CLAUDE.md warns about), this EXTRACTS the literal lines from the
# CURRENT scripts/new-session.sh between the unique anchors `    ready=no`
# and `    fi` (verified unique — see the grep below) and sources that
# extract directly, so what's under test is always byte-identical to what
# ships. A fake `session-handoff.sh` (fake-handoff-sequence.sh, same
# directory) answers `check` calls from a pre-set sequence of states so each
# scenario is deterministic.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NS="$HERE/../scripts/new-session.sh"
FAKE_HANDOFF="$HERE/fake-handoff-sequence.sh"
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }
has(){ if printf '%s' "$2" | grep -qF "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — pattern not found: $3 in: $2"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

START="$(grep -n '^    ready=no$' "$NS" | head -1 | cut -d: -f1)"
END="$(grep -n '^    fi$' "$NS" | head -1 | cut -d: -f1)"
# Both anchors must be unique in the file — a future edit that introduces a
# second bare `    ready=no` or `    fi` at this exact indentation would
# silently extract the wrong span rather than fail loudly, so check that
# explicitly instead of trusting `head -1`.
START_COUNT="$(grep -c '^    ready=no$' "$NS")"
END_COUNT="$(grep -c '^    fi$' "$NS")"
if [ -z "$START" ] || [ -z "$END" ] || [ "$START_COUNT" != 1 ] || [ "$END_COUNT" != 1 ]; then
  echo "session-handoff-settle-loop: SKIP (extraction anchors not uniquely found in $NS — has the loop been restructured? update this test's anchors)"
  exit 0
fi
EXTRACTED="$WORK/settle-loop.sh"
sed -n "${START},${END}p" "$NS" > "$EXTRACTED"
bash -n "$EXTRACTED" || { echo "FAIL: extracted settle-loop is not valid bash on its own"; exit 1; }

# run_settle <comma-separated-states> <settle> <tries> -> sets $RESULT to
# "ready=<yes|no> trust_dialog=<yes|no> polls=<N>" by sourcing the REAL
# extracted lines in a subshell (so each call starts from a clean variable
# slate) against a fresh sequence file.
run_settle() {
  local seq="$1" settle="$2" tries="$3"
  local seq_file="$WORK/seq"; local pos_file="$WORK/pos"
  printf '%s' "$seq" | tr ',' '\n' > "$seq_file"
  echo 0 > "$pos_file"
  RESULT="$(
    export HANDOFF="$FAKE_HANDOFF" SESSION="fake-settle-session" \
           NEW_SESSION_TASK_SETTLE="$settle" NEW_SESSION_TASK_READY_TRIES="$tries" \
           SEQ_FILE="$seq_file" POS_FILE="$pos_file" TASK=x REMOTE_NAME=fake
    # shellcheck disable=SC1090
    source "$EXTRACTED" >/dev/null 2>&1
    # shellcheck disable=SC2154  # ready/trust_dialog come from the sourced extract, not this file
    echo "ready=$ready trust_dialog=$trust_dialog polls=$(cat "$pos_file")"
  )"
}

# 1. Default settle (3): three consecutive `ready` reports land exactly at
# poll 3 — not 1 (proves it's not just "first ready wins", the bug this
# loop exists to fix) and not more than 3 (proves it doesn't over-wait).
run_settle "ready,ready,ready" 3 90
has "default-settle-ready-yes"   "$RESULT" "ready=yes"
has "default-settle-no-dialog"   "$RESULT" "trust_dialog=no"
has "default-settle-three-polls" "$RESULT" "polls=3"

# 2. A non-ready poll in the middle RESETS the consecutive counter: three
# ready reports, then one non-ready, then three MORE ready reports are
# needed — six polls total, not four (which is what a buggy "only reset on
# explicit failure, not on a non-ready reading" implementation would give).
run_settle "ready,ready,starting,ready,ready,ready" 3 90
has "reset-on-nonready-ready-yes" "$RESULT" "ready=yes"
has "reset-on-nonready-six-polls" "$RESULT" "polls=6"

# 3. state=menu breaks IMMEDIATELY, before exhausting the sequence or the
# try budget — the poll count must stop AT the menu entry (position 3), not
# continue consuming the `ready,ready,ready` that follows it in the
# sequence (which would happen if menu were mistaken for just another
# non-ready reading that only resets the settle counter).
run_settle "starting,ready,menu,ready,ready,ready" 3 90
has "menu-sets-trust-dialog" "$RESULT" "trust_dialog=yes"
has "menu-ready-still-no"    "$RESULT" "ready=no"
has "menu-stops-at-3-polls"  "$RESULT" "polls=3"

# 4. NEW_SESSION_TASK_SETTLE is a real override, not just documentation —
# settle=2 must resolve after 2 consecutive ready polls, not the default 3.
run_settle "ready,ready" 2 90
has "settle-override-ready-yes"  "$RESULT" "ready=yes"
has "settle-override-two-polls"  "$RESULT" "polls=2"

# 5. Never reaching settle exhausts the try budget (not the sequence) and
# reports ready=no, trust_dialog=no — the ordinary "give up and say so"
# path, still reachable now that menu has its own separate early-exit.
run_settle "starting,starting" 3 2
has "exhausts-budget-ready-no"  "$RESULT" "ready=no"
has "exhausts-budget-no-dialog" "$RESULT" "trust_dialog=no"
has "exhausts-budget-two-polls" "$RESULT" "polls=2"

echo "new-session-settle-loop: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
