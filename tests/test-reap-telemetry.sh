#!/usr/bin/env bash
# reap telemetry: --reap event shape, outcome allow-list, and the report's join across
# both name spellings with pre-routing spawns and unmatched reaps mixed in.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
isolate_overlay

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
rec() { TELEMETRY_ROOT="$T/r" CLAUDE_SKILLS_DIR="$T/s" bash "$HERE/../scripts/record-spawn-telemetry.sh" "$@"; }
ev="$T/r/artifacts/telemetry/events.jsonl"

rec --reap ah_x-0001 yes ok "finish line met"
rec --reap ah_x-0002 no bogus
hasre "reap-event" "$(sed -n 1p "$ev")" '"event": "reap".*"forced": true.*"outcome": "ok"'
hasre "reap-outcome-allowlist" "$(sed -n 2p "$ev")" '"outcome": "unknown"'
ok "reap-never-fails" "$(rec --reap 2>&1; echo $?)" "0"

# Report: tmux-spelled reap joins a hyphen-spelled spawn and vice versa; a spawn with no
# routing is the "none" row; a reap with no spawn is counted, not dropped.
cat > "$ev" <<'J'
{"event":"spawn","timestamp":"2026-10-05T10:00:00+00:00","session":"ah_a-0001","remote_name":"ah-a-0001","routing":{"tier":"light","effort":"","reason":"x"},"meta":{}}
{"event":"spawn","timestamp":"2026-10-05T10:00:00+00:00","session":"ah_old-0002","remote_name":"ah-old-0002","meta":{}}
{"event":"reap","timestamp":"2026-10-05T10:30:00+00:00","session":"ah-a-0001","forced":false,"outcome":"ok"}
{"event":"reap","timestamp":"2026-10-05T11:00:00+00:00","session":"ah_old-0002","forced":true,"outcome":"unknown"}
{"event":"reap","timestamp":"2026-10-05T11:00:00+00:00","session":"ah_ghost-9","forced":true,"outcome":"unknown"}
J
o="$(TELEMETRY_ROOT="$T/r" bash "$HERE/../scripts/telemetry-report.sh")"
hasre "report-join-light" "$o" 'light +1 +1 +0 +0 +30 +ok=1'
hasre "report-none-row" "$o" 'none +1 +1 +1 +0 +60 +unknown=1'
has "report-unmatched" "$o" "unmatched to a spawn: 1"

# A reused name pairs each reap with its own spawn, never a later respawn.
cat > "$ev" <<'J'
{"event":"spawn","timestamp":"2026-10-05T10:00:00+00:00","session":"ah_r-1","remote_name":"ah-r-1","routing":{"tier":"light"},"meta":{}}
{"event":"reap","timestamp":"2026-10-05T10:10:00+00:00","session":"ah_r-1","forced":false,"outcome":"ok"}
{"event":"spawn","timestamp":"2026-10-05T10:20:00+00:00","session":"ah_r-1","remote_name":"ah-r-1","routing":{"tier":"heavy"},"meta":{}}
{"event":"reap","timestamp":"2026-10-05T10:50:00+00:00","session":"ah-r-1","forced":false,"outcome":"failed"}
J
o="$(TELEMETRY_ROOT="$T/r" bash "$HERE/../scripts/telemetry-report.sh")"
hasre "reuse-light" "$o" 'light +1 +1 +0 +0 +10 +ok=1'; hasre "reuse-heavy" "$o" 'heavy +1 +1 +0 +0 +30 +failed=1'

# clean fact: only an audited (non-forced) reap says yes; default unknown.
rec --reap ah_c-1 no ok "" yes; rec --reap ah_c-2 yes ok
ok "clean-fields" "$(tail -2 "$ev" | grep -o '"clean": "[a-z]*"' | tr '\n' ' ')" '"clean": "yes" "clean": "unknown" '

# --tier-of / --escalate-from: tier lookup across spellings, one tier up, top refused.
rm -f "$ev"
cat > "$ev" <<'J'
{"event":"spawn","timestamp":"2026-10-05T10:00:00+00:00","session":"ah_e-1","remote_name":"ah-e-1","routing":{"tier":"light"},"meta":{}}
{"event":"spawn","timestamp":"2026-10-05T10:00:00+00:00","session":"ah_e-2","remote_name":"ah-e-2","routing":{"tier":"heavy"},"meta":{}}
{"event":"spawn","timestamp":"2026-10-05T10:00:00+00:00","session":"ah_e-3","remote_name":"ah-e-3","meta":{}}
J
ok "tier-of-underscore" "$(rec --tier-of ah_e-1)" light; ok "tier-of-hyphen" "$(rec --tier-of ah-e-2)" heavy; ok "tier-of-unknown" "$(rec --tier-of ah_e-3)" ""

# The recorder is bounded: a stuck events file (e.g. a FIFO) must not stall teardown.
has "recorder-bounded" "$(cat "$HERE/../scripts/session-doctor.sh")" 'timeout 5 bash "$rt" --reap'

# session-doctor refuses an unknown outcome before touching anything.
o="$(bash "$HERE/../scripts/session-doctor.sh" reap ah_nope-0001 --outcome bogus 2>&1)"; rc=$?
ok "doctor-bad-outcome-rc" "$rc" "2"; has "doctor-bad-outcome-msg" "$o" "--outcome must be"
o="$(timeout 5 bash "$HERE/../scripts/session-doctor.sh" reap ah_nope-0001 --dry-run --outcome-note 2>&1)"; rc=$?
ok "doctor-note-needs-value" "$([ "$rc" -ne 124 ] && echo yes || echo hang)" yes
finish test-reap-telemetry
