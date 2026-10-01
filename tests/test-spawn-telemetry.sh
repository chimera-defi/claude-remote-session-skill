#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
isolate_overlay
RECORD="$HERE/../scripts/record-spawn-telemetry.sh"
REPORT="$HERE/../scripts/telemetry-report.sh"

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
mkdir -p "$TMPD/skills/foo" "$TMPD/skills/bar" "$TMPD/repo" "$TMPD/workdir/.claude"
echo "some skill content" > "$TMPD/skills/foo/SKILL.md"
echo "more skill content" > "$TMPD/skills/bar/SKILL.md"
echo "project instructions" > "$TMPD/workdir/.claude/CLAUDE.md"
EVENTS="$TMPD/repo/artifacts/telemetry/events.jsonl"

# rec SKILLS_DIR ARGS...: record one spawn event; leaves its exit code in $rc.
rec() { local sd=$1; shift; CLAUDE_SKILLS_DIR="$sd" TELEMETRY_ROOT="$TMPD/repo" bash "$RECORD" "$@" >/dev/null; rc=$?; }

rec "$TMPD/skills" myproj myp px-myp-0101-0000 px_myp-0101-0000 workspace sonnet "$TMPD/workdir"
ok "events-file-created" "$(yn test -f "$EVENTS")" yes
line="$(cat "$EVENTS" 2>/dev/null)"
has "skill-name"        "$line" '"skill": "gstack-session-spawn"'
has "remote-name"       "$line" '"remote_name": "px-myp-0101-0000"'
has "skills-count-two"  "$line" '"global_skills_count": 2'
has "claude-md-nonzero" "$line" '"claude_md_bytes": 21'

rec "$TMPD/skills" myproj myp px-myp-0101-0001 px_myp-0101-0001 workspace sonnet "$TMPD/workdir"
ok "appends-not-overwrites" "$(wc -l < "$EVENTS" | tr -d ' ')" 2

# Missing skills dir / workdir: best-effort, zeroed fields, exit 0.
rec "$TMPD/does-not-exist" other o px-o-0101-0000 px_o-0101-0000 sessions sonnet "$TMPD/no-such-workdir"
ok "missing-dirs-exit-zero" "$rc" 0
has "missing-dirs-zeroed" "$(tail -1 "$EVENTS")" '"global_skills_count": 0'

# An empty WORKDIR must not probe "/CLAUDE.md": same zeroed behaviour as a missing workdir.
rec "$TMPD/skills" empty e px-e-0101-0000 px_e-0101-0000 sessions sonnet ""
ok "empty-workdir-exit-zero" "$rc" 0
has "empty-workdir-zeroed-claude-md" "$(tail -1 "$EVENTS")" '"claude_md_bytes": 0'

has "report-counts-spawns" "$(TELEMETRY_ROOT="$TMPD/repo" bash "$REPORT")" 'spawns recorded: 4'

finish "spawn telemetry"
