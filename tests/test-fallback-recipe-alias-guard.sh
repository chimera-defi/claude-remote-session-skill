#!/usr/bin/env bash
# test-fallback-recipe-alias-guard.sh — extracts the ALIAS anti-poisoning guard
# from references/fallback-recipe.md (between the alias-guard-start/-end
# markers) and exercises it directly, so drift between the shipped doc and
# session-alias.sh's date-validated looks_like_session_name guard is caught
# here instead of only being noticed live. See tests/test-session-alias.sh for
# the equivalent fixtures against the real implementation.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RECIPE="$HERE/../references/fallback-recipe.md"
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }

GUARD="$(awk '/alias-guard-start/{f=1;next} /alias-guard-end/{f=0} f' "$RECIPE")"
[ -n "$GUARD" ] || { echo "FAIL: could not extract alias-guard block from $RECIPE"; exit 1; }

run_guard() { # $1 = candidate ALIAS value; prints resulting $poisoned
  ALIAS="$1"
  eval "$GUARD"
  printf '%s' "$poisoned"
}

# Values that ARE session-name-shaped and must be flagged poisoned.
ok "ah-prefix"            "$(run_guard 'ah-universe-expand-0722')"        "yes"
ok "ah-underscore-prefix" "$(run_guard 'ah_universe_expand')"             "yes"
ok "long-numeric-run"     "$(run_guard 'discovery-0718-153051-4107171')" "yes"
ok "real-mmdd-hhmm"       "$(run_guard 'foo-0715-0630')"                  "yes"
ok "real-trailing-mmdd"   "$(run_guard 'tranche1-ready-0728')"            "yes"
# Multi-candidate scan: an invalid-as-date pair (year range) before a genuine
# MMDD-HHMM must not stop the scan early.
ok "multi-pair-real-hidden" "$(run_guard 'release-2024-2025-x-0715-0630-copy')" "yes"

# Values that are NOT session-name-shaped and must be left alone (regression:
# the naive pre-fix regex flagged any 4-digit-4-digit / trailing-4-digit run,
# colliding sprint-2024/sprint-2025 and similar onto the same fallback alias).
ok "plain-alias"        "$(run_guard 'myproj')"           "no"
ok "year-suffix"        "$(run_guard 'sprint-2024')"      "no"
ok "year-suffix-2"      "$(run_guard 'sprint-2025')"      "no"
ok "chain-id"           "$(run_guard 'chain-8453')"       "no"
ok "port-number"        "$(run_guard 'port-8080')"        "no"
ok "bad-day-not-date"   "$(run_guard 'client-1042')"      "no"
ok "year-range-pair"    "$(run_guard 'sprint-2024-2025')" "no"
ok "port-pair"          "$(run_guard 'port-8080-9090')"   "no"

echo "fallback-recipe alias-guard: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
