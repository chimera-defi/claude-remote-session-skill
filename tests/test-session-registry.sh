#!/usr/bin/env bash
# Plain-bash assertions for session-registry. No external test framework.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REG="$HERE/../scripts/session-registry.sh"
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }

if ! command -v tmux >/dev/null 2>&1; then
  echo "session-registry: pass=0 fail=0 (tmux not available, skipped)"
  exit 0
fi

WORK="$(mktemp -d)"
cleanup() {
  tmux kill-session -t ah_test-old-0101-0100 2>/dev/null || true
  tmux kill-session -t ah_test-new-0101-0100 2>/dev/null || true
  tmux kill-session -t ah_test-nolog-0101-0100 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

export HOME="$WORK"
mkdir -p "$HOME/.sessions"
LOG="$HOME/.sessions/session-starts.log"

# Old session: first-seen log line is 10 days ago. A LATER restart line exists
# too — age must come from the EARLIEST line, not the most recent one (a
# systemd-bounced session must not read as freshly spawned).
OLD_TS=$(date -u -d '10 days ago' +%Y-%m-%dT%H:%M:%SZ)
RESTART_TS=$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)
printf '[%s] host=test session=ah_test-old-0101-0100 remote=ah-test-old-0101-0100 workdir=/tmp event=started\n' "$OLD_TS" >> "$LOG"
printf '[%s] host=test session=ah_test-old-0101-0100 remote=ah-test-old-0101-0100 workdir=/tmp event=already-running\n' "$RESTART_TS" >> "$LOG"

# New session: spawned just now.
NEW_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '[%s] host=test session=ah_test-new-0101-0100 remote=ah-test-new-0101-0100 workdir=/tmp event=started\n' "$NEW_TS" >> "$LOG"

tmux new-session -d -s ah_test-old-0101-0100 2>/dev/null
tmux new-session -d -s ah_test-new-0101-0100 2>/dev/null
tmux new-session -d -s ah_test-nolog-0101-0100 2>/dev/null

out="$(bash "$REG" 2>&1)"
ok "old-session-listed"    "$(printf '%s' "$out" | grep -qF 'ah_test-old-0101-0100' && echo yes || echo no)" "yes"
ok "old-session-age-10d"   "$(printf '%s' "$out" | grep -F 'ah_test-old-0101-0100' | grep -qF '(10d old)' && echo yes || echo no)" "yes"
ok "new-session-age-0d"    "$(printf '%s' "$out" | grep -F 'ah_test-new-0101-0100' | grep -qF '(0d old)' && echo yes || echo no)" "yes"
ok "nolog-uses-tmux-fallback" "$(printf '%s' "$out" | grep -F 'ah_test-nolog-0101-0100' | grep -qF 'tmux session_created' && echo yes || echo no)" "yes"

filtered="$(bash "$REG" --older-than 3d 2>&1)"
ok "older-than-includes-old" "$(printf '%s' "$filtered" | grep -qF 'ah_test-old-0101-0100' && echo yes || echo no)" "yes"
ok "older-than-excludes-new" "$(printf '%s' "$filtered" | grep -qF 'ah_test-new-0101-0100' && echo yes || echo no)" "no"

ok "bad-unit-rejected" "$(bash "$REG" --older-than 3x >/dev/null 2>&1; echo $?)" "2"
# Non-numeric/malformed values before splicing into arithmetic must hit the
# clean usage error (exit 2), not an unbound-variable or arithmetic-syntax
# crash from bash itself (set -u; see session-registry.sh --older-than).
ok "non-numeric-rejected"      "$(bash "$REG" --older-than xd >/dev/null 2>&1; echo $?)" "2"
ok "decimal-rejected"          "$(bash "$REG" --older-than 3.5d >/dev/null 2>&1; echo $?)" "2"
ok "trailing-junk-rejected"    "$(bash "$REG" --older-than 3xd >/dev/null 2>&1; echo $?)" "2"
ok "bare-unit-rejected"        "$(bash "$REG" --older-than d >/dev/null 2>&1; echo $?)" "2"
ok "missing-unit-rejected"     "$(bash "$REG" --older-than 3 >/dev/null 2>&1; echo $?)" "2"
ok "leading-zero-hours-accepted" "$(bash "$REG" --older-than 08h >/dev/null 2>&1; echo $?)" "0"

echo "session-registry: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
