#!/usr/bin/env bash
# fleet-status.sh composes session-doctor + a server-health-audit JSON
# snapshot + rtk into one report. These tests isolate that composition from
# the real host (fake HOME, fake/missing session-doctor) so they're
# deterministic regardless of what's actually running on the box.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FS="$HERE/../scripts/fleet-status.sh"
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }
has(){ if printf '%s' "$2" | grep -qF "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — pattern not found: $3 in: $2"; fi; }
lacks(){ if printf '%s' "$2" | grep -qF "$3"; then fail=$((fail+1)); echo "FAIL: $1 — unwanted pattern present: $3"; else pass=$((pass+1)); fi; }

# Fake HOME with no ~/.gbrain at all, and no session-doctor on PATH, so every
# test below is isolated from whatever's actually running on this host.
FAKE_HOME="$(mktemp -d)"; trap 'rm -rf "$FAKE_HOME"' EXIT

# 1. Bad flag -> usage on stderr + exit 2.
out="$(bash "$FS" --bogus 2>&1)"; rc=$?
has "bad-flag-usage" "$out" "usage: fleet-status.sh"
ok  "bad-flag-exit2" "$rc" "2"

# 2. --sessions prints the SESSIONS header, not HOST.
out="$(HOME="$FAKE_HOME" bash "$FS" --sessions 2>&1)"
has   "sessions-only-has-sessions" "$out" "SESSIONS"
lacks "sessions-only-lacks-host"   "$out" "HOST / GBRAIN"

# 3. --host prints the HOST header, not SESSIONS, and reports missing
# session-doctor cleanly rather than crashing (no ~/.local/bin on PATH here).
out="$(HOME="$FAKE_HOME" PATH="/usr/bin:/bin" bash "$FS" --host 2>&1)"; rc=$?
has   "host-only-has-host"       "$out" "HOST / GBRAIN"
lacks "host-only-lacks-sessions" "$out" "SESSIONS"
ok    "host-only-exit0"          "$rc" "0"

# 4. No server-health-audit snapshot at all (fresh fake HOME) -> graceful
# fallback message, not a crash/empty-glob literal path.
has "no-snapshot-message" "$out" "no server-health-audit snapshot found"

# 5. session-doctor genuinely missing (neither co-located nor on PATH) ->
# --sessions says so instead of silently printing nothing (mirrors
# session-send.sh's "could not locate" clarity — a composing script should
# surface a missing dependency, not hide it behind blank output). Copy
# fleet-status.sh ALONE into an isolated dir so co-located resolution misses
# too, same trick test-session-send.sh uses for its own helper.
ISOLATED="$(mktemp -d)"
cp "$FS" "$ISOLATED/fleet-status.sh"
out="$(HOME="$FAKE_HOME" PATH="/usr/bin:/bin" bash "$ISOLATED/fleet-status.sh" --sessions 2>&1)"
has "session-doctor-missing-reported" "$out" "session-doctor not found"
rm -rf "$ISOLATED"

# 6. Newest run dir present but its summary.json hasn't landed yet (audit
# service mid-write race) -> falls back to the newest COMPLETE run instead
# of reporting "no snapshot found". Regression test for that race.
RUNS="$FAKE_HOME/.gbrain/server-health/runs"
mkdir -p "$RUNS/20260101T000000Z"
printf '{"status":"ok","resources":{"disk_used_pct":1,"memory_used_pct":1,"load_1m":"0.1"},"gbrain":{"doctor_status":"ok","doctor_failures":0,"stale_embeddings":0},"failed_units":{}}\n' \
  > "$RUNS/20260101T000000Z/summary.json"
mkdir -p "$RUNS/20260102T000000Z"   # newer dir, no summary.json yet
out="$(HOME="$FAKE_HOME" PATH="/usr/bin:/bin" bash "$FS" --host 2>&1)"
has   "picks-newest-complete-run" "$out" "20260101T000000Z"
lacks "skips-incomplete-run"      "$out" "snapshot: 20260102T000000Z"

# 7. A complete newest run's fields are surfaced (status/resources/gbrain),
# proving the jq extraction actually runs end to end, not just the fallback
# path exercised above.
has "surfaces-status"    "$out" "status: ok"
has "surfaces-resources" "$out" "disk=1% mem=1% load_1m=0.1"
has "surfaces-gbrain"    "$out" "doctor_status=ok failures=0"

# 8. Default (no args) == --all: both sections present.
out="$(HOME="$FAKE_HOME" PATH="/usr/bin:/bin" bash "$FS" 2>&1)"
has "default-has-sessions" "$out" "SESSIONS"
has "default-has-host"     "$out" "HOST / GBRAIN"

echo "fleet-status: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
