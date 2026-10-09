#!/usr/bin/env bash
# record-spawn-telemetry.sh + telemetry-report.sh end to end: spawn events (best-effort when dirs are missing),
# reap events (outcome allow-list, clean fact), tier lookup, and the report joining reaps to spawns across both
# session-name spellings (unmatched reaps counted, reused names paired with their own spawn).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
isolate_overlay
RECORD="$HERE/../scripts/record-spawn-telemetry.sh"
REPORT="$HERE/../scripts/telemetry-report.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/skills/foo" "$T/skills/bar" "$T/workdir/.claude"
echo "some skill content" > "$T/skills/foo/SKILL.md"
echo "more skill content" > "$T/skills/bar/SKILL.md"
echo "project instructions" > "$T/workdir/.claude/CLAUDE.md"
ev="$T/r/artifacts/telemetry/events.jsonl"
rec() { TELEMETRY_ROOT="$T/r" CLAUDE_SKILLS_DIR="${SKILLS:-$T/skills}" bash "$RECORD" "$@"; }
report() { TELEMETRY_ROOT="$T/r" bash "$REPORT"; }

# spawn events
rec myproj myp px-myp-0101-0000 px_myp-0101-0000 workspace sonnet "$T/workdir" light low "doc typo fix" 600000 >/dev/null
line="$(cat "$ev")"
has "spawn: remote name" "$line" '"remote_name": "px-myp-0101-0000"'
has "spawn: global skills counted" "$line" '"global_skills_count": 2'
has "spawn: CLAUDE.md bytes" "$line" '"claude_md_bytes": 21'
hasre "spawn: routing" "$line" '"routing": \{"compact_window": "600000", "effort": "low", "reason": "doc typo fix", "tier": "light"\}'
CRSS_ESCALATED_FROM=px_l-1 rec myproj myp px-myp-0101-0001 px_myp-0101-0001 workspace sonnet "$T/workdir" standard "" why >/dev/null
has "spawn: appends, records escalated_from" "$(tail -1 "$ev")" '"escalated_from": "px_l-1"'
ok "spawn: second event appended" "$(wc -l < "$ev" | tr -d ' ')" 2
SKILLS="$T/missing" rec other o px-o-0101-0000 px_o-0101-0000 sessions sonnet "$T/no-such-workdir" >/dev/null; rc=$?
ok "missing dirs: best-effort exit 0" "$rc" 0; has "missing dirs: zeroed" "$(tail -1 "$ev")" '"global_skills_count": 0'
rec empty e px-e-0101-0000 px_e-0101-0000 sessions sonnet "" >/dev/null
has "empty workdir does not probe /CLAUDE.md" "$(tail -1 "$ev")" '"claude_md_bytes": 0'
has "report counts spawns" "$(report)" 'spawns recorded: 4'

# reap events
rm -f "$ev"
rec --reap ah_x-0001 yes ok "finish line met"; rec --reap ah_x-0002 no bogus
hasre "reap: event shape" "$(sed -n 1p "$ev")" '"event": "reap".*"forced": true.*"outcome": "ok"'
hasre "reap: unknown outcome collapses to unknown" "$(sed -n 2p "$ev")" '"outcome": "unknown"'
ok "reap: recorder never fails" "$(rec --reap 2>&1; echo $?)" "0"
rec --reap ah_c-1 no ok "" yes; rec --reap ah_c-2 yes ok
ok "reap: only an audited non-forced reap says clean=yes" "$(tail -2 "$ev" | grep -o '"clean": "[a-z]*"' | tr '\n' ' ')" '"clean": "yes" "clean": "unknown" '

# report join: tmux-spelled reap joins a hyphen-spelled spawn and vice versa; no-routing spawn is the "none" row
cat > "$ev" <<'J'
{"event":"spawn","timestamp":"2026-10-05T10:00:00+00:00","session":"ah_a-0001","remote_name":"ah-a-0001","routing":{"tier":"light","effort":"","reason":"x"},"meta":{}}
{"event":"spawn","timestamp":"2026-10-05T10:00:00+00:00","session":"ah_old-0002","remote_name":"ah-old-0002","meta":{}}
{"event":"reap","timestamp":"2026-10-05T10:30:00+00:00","session":"ah-a-0001","forced":false,"outcome":"ok"}
{"event":"reap","timestamp":"2026-10-05T11:00:00+00:00","session":"ah_old-0002","forced":true,"outcome":"unknown"}
{"event":"reap","timestamp":"2026-10-05T11:00:00+00:00","session":"ah_ghost-9","forced":true,"outcome":"unknown"}
J
o="$(report)"
hasre "report: join across spellings" "$o" 'light +1 +1 +0 +0 +30 +ok=1'
hasre "report: none row" "$o" 'none +1 +1 +1 +0 +60 +unknown=1'
has "report: unmatched reap counted" "$o" "unmatched to a spawn: 1"
cat > "$ev" <<'J'
{"event":"spawn","timestamp":"2026-10-05T10:00:00+00:00","session":"ah_r-1","remote_name":"ah-r-1","routing":{"tier":"light"},"meta":{}}
{"event":"reap","timestamp":"2026-10-05T10:10:00+00:00","session":"ah_r-1","forced":false,"outcome":"ok"}
{"event":"spawn","timestamp":"2026-10-05T10:20:00+00:00","session":"ah_r-1","remote_name":"ah-r-1","routing":{"tier":"heavy"},"meta":{}}
{"event":"reap","timestamp":"2026-10-05T10:50:00+00:00","session":"ah-r-1","forced":false,"outcome":"failed"}
J
o="$(report)"
hasre "report: reused name pairs reap with its own spawn (light)" "$o" 'light +1 +1 +0 +0 +10 +ok=1'
hasre "report: reused name pairs reap with its own spawn (heavy)" "$o" 'heavy +1 +1 +0 +0 +30 +failed=1'

# tier lookup across spellings
cat > "$ev" <<'J'
{"event":"spawn","timestamp":"2026-10-05T10:00:00+00:00","session":"ah_e-1","remote_name":"ah-e-1","routing":{"tier":"light"},"meta":{}}
{"event":"spawn","timestamp":"2026-10-05T10:00:00+00:00","session":"ah_e-2","remote_name":"ah-e-2","routing":{"tier":"heavy"},"meta":{}}
{"event":"spawn","timestamp":"2026-10-05T10:00:00+00:00","session":"ah_e-3","remote_name":"ah-e-3","meta":{}}
J
ok "tier-of underscore spelling" "$(rec --tier-of ah_e-1)" light
ok "tier-of hyphen spelling" "$(rec --tier-of ah-e-2)" heavy
ok "tier-of untiered" "$(rec --tier-of ah_e-3)" ""

# session-doctor refuses an unknown outcome before touching anything
o="$(bash "$HERE/../scripts/session-doctor.sh" reap ah_nope-0001 --outcome bogus 2>&1)"; rc=$?
ok "doctor: bad --outcome exit 2" "$rc" "2"; has "doctor: bad --outcome message" "$o" "--outcome must be"

finish "telemetry"
