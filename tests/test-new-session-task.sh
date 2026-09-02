#!/usr/bin/env bash
# Regression coverage for new-session.sh's --task/--task-file kickoff flags:
# the validation must fail loudly BEFORE anything spawns (mutual exclusivity,
# unreadable/missing --task-file). The actual poll-then-send-then-verify path
# reuses session-handoff.sh's check/send dispatch wholesale (see that script's
# own tests for the send/verify classifiers) — not re-tested here, since it
# cannot be exercised without a real claude spawn.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NS="$HERE/../scripts/new-session.sh"
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }
has(){ if printf '%s' "$2" | grep -qF "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — pattern not found: $3 in: $2"; fi; }

# --task and --task-file are mutually exclusive — must fail before any spawn
# attempt (asserted by the absence of any SESSION=/REMOTE_NAME= dry-run output).
out="$(bash "$NS" --dry-run mutex-test --task hi --task-file /etc/hostname 2>&1)"; rc=$?
has "mutex-rejected"        "$out" "mutually exclusive"
ok  "mutex-exit2"           "$rc" "2"
if printf '%s' "$out" | grep -q '^SESSION='; then fail=$((fail+1)); echo "FAIL: mutex-no-spawn-attempt — dry-run names were printed despite the rejection"; else pass=$((pass+1)); fi

# A missing --task-file must fail loudly, before spawning — not silently spawn
# with no task, and not fail only after the (expensive) spawn already happened.
out2="$(bash "$NS" --dry-run missing-file-test --task-file /no/such/path/xyz-$$ 2>&1)"; rc2=$?
has "missing-file-rejected" "$out2" "missing or unreadable"
ok  "missing-file-exit2"    "$rc2" "2"
if printf '%s' "$out2" | grep -q '^SESSION='; then fail=$((fail+1)); echo "FAIL: missing-file-no-spawn-attempt"; else pass=$((pass+1)); fi

# An unreadable (permission-denied) --task-file must be treated the same way.
if [ "$(id -u)" -ne 0 ]; then
  UNREADABLE="$(mktemp)"; chmod 000 "$UNREADABLE"
  out3="$(bash "$NS" --dry-run unreadable-file-test --task-file "$UNREADABLE" 2>&1)"; rc3=$?
  has "unreadable-file-rejected" "$out3" "missing or unreadable"
  ok  "unreadable-file-exit2"    "$rc3" "2"
  rm -f "$UNREADABLE"
fi

# A valid --task with --dry-run must NOT error — the validation passes and the
# (non-)spawn preview still resolves names normally. The task itself is never
# sent in dry-run (nothing spawns to send it into).
out4="$(bash "$NS" --dry-run valid-task-test --task "hello world" 2>&1)"; rc4=$?
has "valid-task-dry-run-still-resolves" "$out4" "SESSION=ah_valid-task-test-"
ok  "valid-task-dry-run-exit0"          "$rc4" "0"

# --task-file content is read (not just existence-checked) — content wired
# through as the TASK is exercised indirectly here by confirming a readable
# file with content does not trip the "missing or unreadable" rejection.
CONTENTFILE="$(mktemp)"; printf 'do the thing\nand the other thing\n' > "$CONTENTFILE"
out5="$(bash "$NS" --dry-run tfcontent --task-file "$CONTENTFILE" 2>&1)"; rc5=$?
has "task-file-content-accepted" "$out5" "SESSION=ah_tfcontent-"
ok  "task-file-content-exit0"    "$rc5" "0"
rm -f "$CONTENTFILE"

echo "new-session-task: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
