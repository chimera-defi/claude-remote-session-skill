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
  env -u CLAUDE_SESSION_PROFILE -u CLAUDE_SESSION_MODEL -u CLAUDE_SESSION_EFFORT -u CRSS_SESSION_BACKEND -u CRSS_TIER_CODEX_TIERS \
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
o="$(dry A=1 -- --tier heavy --approve-opus)"
want "heavy-opus-approved" "$o" '^PROFILE=orchestrator$'; want "heavy-opus-model" "$o" '^MODEL=claude-opus-5-5$'
o="$(dry A=1 -- --tier standard --approve-opus)"
want "approve-opus-only-heavy" "$o" '^PROFILE=builder$'

# fan-out floor: trimmed profiles lifted to owner, effort of the tier kept.
o="$(dry A=1 -- --tier light --needs-fanout)"
want "fanout-floor" "$o" '^PROFILE=owner$'; want "fanout-floor-rule" "$o" 'fanout-floor=owner'
want "fanout-keeps-effort" "$o" '--effort low'

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
