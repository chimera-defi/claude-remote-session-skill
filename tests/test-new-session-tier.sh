#!/usr/bin/env bash
# --tier / effort / advisor resolution for new-session.sh, pinned via --dry-run.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
NS="$HERE/../scripts/new-session.sh"
isolate_overlay
export CRSS_SESSION_PREFIX=px
WORKHOME="$(mktemp -d)"; trap 'rm -rf "$WORKHOME"' EXIT
export HOME="$WORKHOME"; mkdir -p "$HOME/workspace/proj"

# dry ENV... -- ARGS...: dry-run spawn; prints the resolved fields (stderr included).
dry() {
  local envs=(); while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  env -u CLAUDE_SESSION_PROFILE -u CLAUDE_SESSION_MODEL -u CLAUDE_SESSION_EFFORT -u CLAUDE_SESSION_ADVISOR \
    -u CRSS_OPUS_MODEL -u CRSS_SESSION_BACKEND "${envs[@]}" bash "$NS" proj workspace --dry-run "$@" 2>&1
}

# No tier: orchestrator on the pinned Opus, no effort flag, no advisor (Opus has none).
o="$(dry A=1 --)"
hasre "default-profile" "$o" '^PROFILE=orchestrator$'; hasre "default-model" "$o" '^MODEL=claude-opus-5-5$'
hasre "default-tier" "$o" '^TIER=none$'; hasre "default-advisor-none" "$o" '^ADVISOR=none$'; hasre "default-effort" "$o" '^EFFORT=default$'

o="$(dry A=1 -- --tier light)"
hasre "light" "$o" '^PROFILE=copywriter$'; hasre "light-model" "$o" '^MODEL=haiku$'
hasnt "light-no-effort" "$o" '--effort'; hasre "light-effort-unset" "$o" '^EFFORT=default$'; hasre "light-advisor" "$o" '--advisor claude-opus-5-5'
o="$(dry A=1 -- --tier standard)"
hasre "standard" "$o" '^PROFILE=builder$'; hasre "standard-model" "$o" '^MODEL=sonnet$'; hasre "standard-effort-low" "$o" '--effort low'
o="$(dry CLAUDE_SESSION_EFFORT=high -- --tier standard)"; hasre "standard-explicit-effort-wins" "$o" '--effort high'
o="$(dry A=1 -- --tier heavy)"
hasre "heavy" "$o" '^PROFILE=owner$'; hasre "heavy-model" "$o" '^MODEL=sonnet$'

# A tier never selects Opus; explicit env wins one value at a time.
o="$(dry CLAUDE_SESSION_PROFILE=orchestrator -- --tier heavy)"; hasre "explicit-profile-wins" "$o" '^PROFILE=orchestrator$'; hasre "explicit-opus-no-advisor" "$o" '^ADVISOR=none$'
o="$(dry CLAUDE_SESSION_MODEL=claude-opus-5-5 -- --tier standard)"; hasre "explicit-model-wins" "$o" '^MODEL=claude-opus-5-5$'; hasre "model-opus-no-advisor" "$o" '^ADVISOR=none$'
o="$(dry CLAUDE_SESSION_EFFORT=high -- --tier light)"; hasre "explicit-effort-wins" "$o" '--effort high'

# Advisor: one Opus source, overridable, validated.
o="$(dry CRSS_OPUS_MODEL=claude-opus-9-9 -- --tier standard)"; hasre "opus-id-feeds-advisor" "$o" '--advisor claude-opus-9-9'
o="$(dry CRSS_OPUS_MODEL=claude-opus-9-9 --)"; hasre "opus-id-feeds-orchestrator" "$o" '^MODEL=claude-opus-9-9$'
o="$(dry CLAUDE_SESSION_ADVISOR=fable -- --tier standard)"; hasre "advisor-override" "$o" '--advisor fable'
o="$(dry CLAUDE_SESSION_ADVISOR=none -- --tier standard)"; hasre "advisor-none" "$o" '^ADVISOR=none$'; hasnt "advisor-none-no-flag" "$o" '--advisor'
o="$(dry CLAUDE_SESSION_ADVISOR='x;y' -- --tier standard)"; hasre "advisor-bad-id" "$o" 'invalid'
o="$(dry CRSS_OPUS_MODEL='a b' -- --tier standard)"; hasre "opus-bad-id" "$o" 'must match'
o="$(dry CRSS_OPUS_MODEL='a b' -- --backend codex)"; hasre "bad-opus-id-ok-for-codex" "$o" '^BACKEND=codex$'; hasre "codex-advisor-none" "$o" '^ADVISOR=none$'
o="$(CRSS_OPUS_MODEL='a b' bash "$NS" --help 2>&1)"; hasre "bad-opus-id-help-ok" "$o" '^Usage:'

# Bad inputs are refused; a typo'd profile is a hard error under a tier, the old fallback without one.
o="$(dry A=1 -- --tier bogus)"; hasre "bad-tier" "$o" 'unknown --tier'
o="$(dry CLAUDE_SESSION_EFFORT=turbo -- --tier light)"; hasre "bad-effort" "$o" 'invalid'
o="$(dry CLAUDE_SESSION_PROFILE=bulder -- --tier light)"; hasre "typo-profile-refused-under-tier" "$o" 'unknown CLAUDE_SESSION_PROFILE'
o="$(dry CLAUDE_SESSION_PROFILE=bulder --)"; hasre "typo-profile-fallback-without-tier" "$o" '^PROFILE=orchestrator$'

# Telemetry carries the decision.
T="$(mktemp -d)"
CLAUDE_SKILLS_DIR="$T/s" TELEMETRY_ROOT="$T/r" bash "$HERE/../scripts/record-spawn-telemetry.sh" f a r s workspace haiku "$T" light low "doc typo fix" >/dev/null
hasre "telemetry-routing" "$(cat "$T/r/artifacts/telemetry/events.jsonl")" '"routing": \{"effort": "low", "reason": "doc typo fix", "tier": "light"\}'
CRSS_ESCALATED_FROM=px_l-1 CLAUDE_SKILLS_DIR="$T/s" TELEMETRY_ROOT="$T/r" bash "$HERE/../scripts/record-spawn-telemetry.sh" f a r s2 workspace sonnet "$T" standard "" "why" >/dev/null
hasre "telemetry-escalated-from" "$(tail -1 "$T/r/artifacts/telemetry/events.jsonl")" '"escalated_from": "px_l-1"'
rm -rf "$T"
# --escalate-from: one tier above the recorded tier; explicit --tier wins; top and unknown refused.
TR="$(mktemp -d)"; mkdir -p "$TR/artifacts/telemetry"
cat > "$TR/artifacts/telemetry/events.jsonl" <<'J'
{"event":"spawn","timestamp":"2026-10-05T10:00:00+00:00","session":"px_l-1","remote_name":"px-l-1","routing":{"tier":"light"},"meta":{}}
{"event":"spawn","timestamp":"2026-10-05T10:00:00+00:00","session":"px_s-1","remote_name":"px-s-1","routing":{"tier":"standard"},"meta":{}}
{"event":"spawn","timestamp":"2026-10-05T10:00:00+00:00","session":"px_h-1","remote_name":"px-h-1","routing":{"tier":"heavy"},"meta":{}}
{"event":"spawn","timestamp":"2026-10-05T10:00:00+00:00","session":"px_n-1","remote_name":"px-n-1","meta":{}}
J
o="$(dry TELEMETRY_ROOT="$TR" -- --escalate-from px_l-1)"; hasre "esc-light-to-standard" "$o" '^TIER=standard$'
o="$(dry TELEMETRY_ROOT="$TR" -- --escalate-from px-s-1)"; hasre "esc-standard-to-heavy" "$o" '^TIER=heavy$'
o="$(dry TELEMETRY_ROOT="$TR" -- --escalate-from px_h-1)"; has "esc-heavy-to-opus" "$o" "escalating past it to Opus"; hasre "esc-heavy-opus-profile" "$o" '^PROFILE=orchestrator$'
o="$(dry TELEMETRY_ROOT="$TR" -- --escalate-from px_n-1)"; has "esc-unknown-assumes-standard" "$o" "assuming standard"; hasre "esc-unknown-heavy" "$o" '^TIER=heavy$'
o="$(dry TELEMETRY_ROOT="$TR" -- --escalate-from px_l-1 --tier heavy)"; hasre "esc-explicit-wins" "$o" '^TIER=heavy$'
rm -rf "$TR"

finish test-new-session-tier
