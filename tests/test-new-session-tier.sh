#!/usr/bin/env bash
# Tier -> backend/profile/model/effort resolver for new-session.sh, pinned via --dry-run.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
NS="$HERE/../scripts/new-session.sh"
isolate_overlay
export CRSS_SESSION_PREFIX=px
WORKHOME="$(mktemp -d)"; trap 'rm -rf "$WORKHOME"' EXIT
export HOME="$WORKHOME"; mkdir -p "$HOME/workspace/proj"

# dry ENV... -- ARGS...: run a dry-run spawn, print its resolved fields.
dry() {
  local envs=(); while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  env -u CLAUDE_SESSION_PROFILE -u CLAUDE_SESSION_MODEL -u CLAUDE_SESSION_EFFORT -u CRSS_SESSION_BACKEND -u CRSS_TIER_CODEX_TIERS -u CLAUDE_SESSION_ADVISOR -u CRSS_OPUS_MODEL -u CRSS_ADVISOR_MODEL \
    "${envs[@]}" bash "$NS" proj workspace --dry-run "$@" 2>&1
}
want() { # name output pattern
  if grep -qE -- "$3" <<<"$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — missing /$3/ in: $2"; fi; }
nowant() { if grep -qE -- "$3" <<<"$2"; then fail=$((fail+1)); echo "FAIL: $1 — unexpected /$3/"; else pass=$((pass+1)); fi; }

# No tier: today's behaviour is untouched (orchestrator, opus-5-5, no --effort flag).
o="$(dry A=1 --)"
want "default-profile" "$o" '^PROFILE=orchestrator$'; want "default-model" "$o" '^MODEL=claude-opus-5-5$'
nowant "default-no-effort" "$o" '--effort'; want "default-tier-none" "$o" '^TIER=none$'

o="$(dry A=1 -- --tier light)"
want "light-profile" "$o" '^PROFILE=copywriter$'; want "light-model" "$o" '^MODEL=haiku$'
want "light-effort" "$o" 'CLAUDE_EXTRA_FLAGS=.*--effort low'; want "light-rules" "$o" 'TIER_RULES=.*effort=low'

o="$(dry A=1 -- --tier standard)"
want "standard-profile" "$o" '^PROFILE=builder$'; want "standard-model" "$o" '^MODEL=sonnet$'
nowant "standard-no-effort-flag" "$o" '--effort'

# heavy never reaches Opus implicitly; needs --approve-opus.
o="$(dry A=1 -- --tier heavy)"
want "heavy-owner" "$o" '^PROFILE=owner$'; want "heavy-sonnet" "$o" '^MODEL=sonnet$'
o="$(dry A=1 -- --tier heavy --approve-opus --task "decide the schema")"
want "heavy-opus-approved" "$o" '^PROFILE=orchestrator$'; want "heavy-opus-model" "$o" '^MODEL=claude-opus-5-5$'
o="$(dry A=1 -- --tier standard --approve-opus)"
want "approve-opus-only-heavy" "$o" '^PROFILE=builder$'

o="$(dry A=1 -- --tier heavy --approve-opus)"
want "opus-tier-needs-task" "$o" "pass --task"
o="$(dry A=1 -- --tier heavy --approve-opus --task "x")"; nowant "opus-tier-no-advisor" "$o" '--advisor'

E="$WORKHOME/empty.txt"; : > "$E"; printf '  \n' > "$WORKHOME/blank.txt"; echo "do the thing" > "$WORKHOME/task.txt"
o="$(dry A=1 -- --tier heavy --approve-opus --task-file "$E")"; want "opus-empty-taskfile-refused" "$o" "pass --task"
o="$(dry A=1 -- --tier heavy --approve-opus --task-file "$WORKHOME/blank.txt")"; want "opus-blank-taskfile-refused" "$o" "pass --task"
o="$(dry A=1 -- --tier heavy --approve-opus --task "   ")"; want "opus-blank-task-refused" "$o" "pass --task"
o="$(dry A=1 -- --tier heavy --approve-opus --task-file "$WORKHOME/task.txt")"; want "opus-real-taskfile-ok" "$o" '^PROFILE=orchestrator$'
o="$(dry CLAUDE_SESSION_PROFILE=bulder -- --tier light)"; want "typo-profile-refused-under-tier" "$o" "not a valid profile"
o="$(dry CLAUDE_SESSION_PROFILE=bulder -- )"; want "typo-profile-legacy-fallback-no-tier" "$o" '^PROFILE=orchestrator$'
o="$(dry CRSS_OPUS_MODEL='a b' -- --backend codex)"; want "bad-opus-id-ok-for-codex" "$o" '^BACKEND=codex$'
o="$(CRSS_OPUS_MODEL='a b' bash "$NS" --help 2>&1)"; want "bad-opus-id-help-ok" "$o" '^Usage:'

# advisor: Opus by default for sessions that have the advisor tool; none for Opus/Fable/codex.
o="$(dry A=1 -- --tier standard)"; want "advisor-default-opus" "$o" 'CLAUDE_EXTRA_FLAGS=.*--advisor claude-opus-5-5'; want "advisor-field" "$o" '^ADVISOR=claude-opus-5-5$'
o="$(dry CRSS_OPUS_MODEL=claude-opus-9-9 -- --tier standard)"; want "opus-id-single-source" "$o" '--advisor claude-opus-9-9'
o="$(dry CRSS_OPUS_MODEL=claude-opus-9-9 -- --task x)"; want "opus-id-orchestrator" "$o" '^MODEL=claude-opus-9-9$'
o="$(dry CRSS_ADVISOR_MODEL=fable -- --tier standard)"; want "advisor-overlay-override" "$o" '--advisor fable'
o="$(dry CLAUDE_SESSION_ADVISOR=none -- --tier standard)"; nowant "advisor-none" "$o" '--advisor'
o="$(dry CLAUDE_SESSION_ADVISOR='x;y' -- --tier standard)"; want "advisor-bad-id" "$o" "invalid"
o="$(dry CRSS_OPUS_MODEL='a b' -- --tier standard)"; want "opus-bad-id" "$o" "must match"
o="$(dry A=1 -- --backend codex)"; want "codex-advisor-none" "$o" '^ADVISOR=none$'

# heuristic flags a short mechanical task given a heavier tier; never overrides; quiet on guardrail words.
o="$(dry A=1 -- --tier standard --task "fix a typo in the readme")"
want "heuristic-flags-light" "$o" 'heuristic=light'; want "heuristic-keeps-tier" "$o" '^PROFILE=builder$'
o="$(dry A=1 -- --tier standard --task "never force-push or delete branches; migrate the schema in production")"
nowant "heuristic-quiet-on-guardrails" "$o" 'heuristic='
# light = no advisor by default (cheap tier), explicit wins.
o="$(dry A=1 -- --tier light)"; nowant "light-no-advisor" "$o" '--advisor'; want "light-advisor-field" "$o" '^ADVISOR=none$'
o="$(dry CLAUDE_SESSION_ADVISOR=opus -- --tier light)"; want "light-advisor-explicit" "$o" '--advisor opus'

# fan-out floor: trimmed profiles lifted to owner, effort of the tier kept.
o="$(dry A=1 -- --tier light --needs-fanout)"
want "fanout-floor" "$o" '^PROFILE=owner$'; want "fanout-floor-rule" "$o" 'fanout-floor=owner'
want "fanout-keeps-effort" "$o" '--effort low'

o="$(dry CLAUDE_SESSION_PROFILE=builder -- --needs-fanout)"; want "fanout-vs-explicit-trimmed-refused" "$o" "contradicts"
o="$(dry CLAUDE_SESSION_PROFILE=owner -- --needs-fanout)"; want "fanout-explicit-owner-ok" "$o" '^PROFILE=owner$'

# explicit env wins piecewise.
o="$(dry CLAUDE_SESSION_MODEL=claude-opus-5-5 -- --tier standard)"
want "explicit-model-wins" "$o" '^MODEL=claude-opus-5-5$'; want "explicit-model-src" "$o" '^MODEL_SRC=explicit$'
o="$(dry CLAUDE_SESSION_EFFORT=high -- --tier light)"
want "explicit-effort-wins" "$o" '--effort high'; nowant "explicit-effort-no-low" "$o" '--effort low'
o="$(dry CLAUDE_SESSION_PROFILE=hub -- --tier light)"
want "explicit-profile-wins" "$o" '^PROFILE=hub$'

# bad inputs refused before any side effect.
o="$(dry A=1 -- --tier bogus)"; want "bad-tier" "$o" "unknown --tier"
o="$(dry A=1 -- --tier-reason x)"; want "reason-needs-tier" "$o" "needs --tier"
o="$(dry CLAUDE_SESSION_EFFORT=turbo -- --tier light)"; want "bad-effort" "$o" "invalid"

# backend routing: overlay-configured tiers go to codex; fan-out and explicit backend override.
o="$(dry CRSS_TIER_CODEX_TIERS="light standard" -- --tier standard)"
want "codex-tier" "$o" '^BACKEND=codex$'; nowant "codex-no-effort-flag" "$o" 'CLAUDE_EXTRA_FLAGS=.*--effort'
o="$(dry CRSS_TIER_CODEX_TIERS="light standard" -- --tier standard --needs-fanout)"
want "codex-fanout-stays-claude" "$o" '^BACKEND=claude$'
o="$(dry CRSS_TIER_CODEX_TIERS="standard" CRSS_SESSION_BACKEND=claude -- --tier standard)"
want "explicit-backend-wins" "$o" '^BACKEND=claude$'
o="$(dry CRSS_TIER_CODEX_TIERS="light" -- --tier heavy)"
want "unlisted-tier-claude" "$o" '^BACKEND=claude$'

# telemetry carries the routing decision.
T="$(mktemp -d)"; REC="$HERE/../scripts/record-spawn-telemetry.sh"
CLAUDE_SKILLS_DIR="$T/s" TELEMETRY_ROOT="$T/r" bash "$REC" f a r s workspace haiku "$T" light low "profile=copywriter,effort=low" "doc typo fix" >/dev/null
want "telemetry-routing" "$(cat "$T/r/artifacts/telemetry/events.jsonl")" '"routing": \{"effort": "low", "reason": "doc typo fix", "rules": "profile=copywriter,effort=low", "tier": "light"\}'
rm -rf "$T"
finish test-new-session-tier
