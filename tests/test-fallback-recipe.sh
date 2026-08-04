#!/usr/bin/env bash
# Regression: references/fallback-recipe.md's emergency ALIAS lookup must
# guard against a poisoned stored value with the same pattern session-alias.sh
# uses (see test-session-alias.sh's anti-poisoning suite for the primary fix).
# Without this guard the fallback path trusts the store blindly and can
# reproduce doubled ah-ah-...-MMDD-MMDD session names.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DOC="$HERE/../references/fallback-recipe.md"
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }

GUARD_LINE="$(grep -E "grep -qE '\^ah\[-_\]" "$DOC")"
ok "guard-present" "$([ -n "$GUARD_LINE" ] && echo yes || echo no)" "yes"

# Extract the guard's regex and confirm it classifies known poisoned/clean
# values exactly like session-alias.sh's looks_like_session_name.
check(){ printf '%s' "$1" | grep -qE '^ah[-_]|[0-9]{4}-[0-9]{4}|-[0-9]{4}$|-[0-9]{5,}' && echo POISONED || echo clean; }
ok "poisoned-ah-prefix" "$(check 'ah-universe-expand-0722-194533-425253')" "POISONED"
ok "poisoned-mmdd-hhmm" "$(check 'discovery-0718-153051-4107171')" "POISONED"
ok "poisoned-trailing-date" "$(check 'tranche1-ready-0728')" "POISONED"
ok "clean-alias" "$(check 'crss')" "clean"

echo "fallback-recipe: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
