#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RECORD="$HERE/../scripts/record-spawn-telemetry.sh"
REPORT="$HERE/../scripts/telemetry-report.sh"
pass=0; fail=0
has(){ if printf '%s' "$2" | grep -q "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
mkdir -p "$TMPD/skills/foo" "$TMPD/skills/bar" "$TMPD/repo" "$TMPD/workdir/.claude"
echo "some skill content" > "$TMPD/skills/foo/SKILL.md"
echo "more skill content" > "$TMPD/skills/bar/SKILL.md"
echo "project instructions" > "$TMPD/workdir/.claude/CLAUDE.md"

# Basic event shape: one JSON line with the fields a report needs.
CLAUDE_SKILLS_DIR="$TMPD/skills" TELEMETRY_ROOT="$TMPD/repo" \
  bash "$RECORD" myproj myp ah-myp-0101-0000 ah_myp-0101-0000 workspace sonnet "$TMPD/workdir" >/dev/null

EVENTS="$TMPD/repo/artifacts/telemetry/events.jsonl"
[ -f "$EVENTS" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: events file created"; }
line="$(cat "$EVENTS" 2>/dev/null)"
has "skill-name"        "$line" '"skill": "gstack-session-spawn"'
has "remote-name"       "$line" '"remote_name": "ah-myp-0101-0000"'
has "skills-count-two"  "$line" '"global_skills_count": 2'
has "claude-md-nonzero" "$line" '"claude_md_bytes": 21'

# A second spawn appends rather than overwrites.
CLAUDE_SKILLS_DIR="$TMPD/skills" TELEMETRY_ROOT="$TMPD/repo" \
  bash "$RECORD" myproj myp ah-myp-0101-0001 ah_myp-0101-0001 workspace sonnet "$TMPD/workdir" >/dev/null
count="$(wc -l < "$EVENTS" | tr -d ' ')"
has "appends-not-overwrites" "$count" '^2$'

# Missing skills dir / workdir must not crash — best-effort, zeroed fields.
CLAUDE_SKILLS_DIR="$TMPD/does-not-exist" TELEMETRY_ROOT="$TMPD/repo" \
  bash "$RECORD" other o ah-o-0101-0000 ah_o-0101-0000 sessions sonnet "$TMPD/no-such-workdir" >/dev/null
rc=$?
has "missing-dirs-exit-zero" "$rc" '^0$'
last_line="$(tail -1 "$EVENTS")"
has "missing-dirs-zeroed" "$last_line" '"global_skills_count": 0'

# Report runs against the file this test just built.
report_out="$(TELEMETRY_ROOT="$TMPD/repo" bash "$REPORT")"
has "report-counts-spawns" "$report_out" 'spawns recorded: 3'

echo "spawn telemetry: pass=$pass fail=$fail"; [ "$fail" -eq 0 ]
