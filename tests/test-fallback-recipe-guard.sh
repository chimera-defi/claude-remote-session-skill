#!/usr/bin/env bash
# Regression test: references/fallback-recipe.md embeds its own copy of the
# anti-poisoning alias guard (session-alias.sh is not guaranteed to be on PATH
# in the emergency path it exists for). That duplication drifted once already
# (the doc carried the old, non-date-validated regex that misfired on
# legitimate aliases like sprint-2024/chain-8453/port-8080/sprint-2024-2025 —
# see test-session-alias.sh's "Trailing-4-digit false positives" /
# "Two-group false positives" cases). Extract the guard straight out of the
# doc and run the SAME fixtures against it, so any future drift back to a
# naive regex fails CI instead of silently reappearing in production.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DOC="$HERE/../references/fallback-recipe.md"
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }

# Pull just the _fr_poisoned() function body out of the fenced bash block.
FUNC="$(sed -n '/^_fr_poisoned() {$/,/^}$/p' "$DOC")"
[ -n "$FUNC" ] || { echo "FAIL: could not locate _fr_poisoned() in $DOC"; exit 1; }
eval "$FUNC"

poisoned(){ _fr_poisoned "$1" && echo POISONED || echo clean; }

# Genuine poisoned shapes (must still be caught).
ok "ah-prefix"            "$(poisoned ah-universe-expand-0722)"            "POISONED"
ok "ah-underscore-prefix" "$(poisoned ah_universe_expand)"                 "POISONED"
ok "long-numeric-run"     "$(poisoned discovery-0718-153051-4107171)"      "POISONED"
ok "real-mmdd-hhmm"       "$(poisoned foo-0715-0630)"                      "POISONED"
ok "real-trailing-mmdd"   "$(poisoned tranche1-ready-0728)"                "POISONED"

# False-positive fixtures (must survive untouched — same set as
# test-session-alias.sh's date-validation regression cases).
ok "not-mmdd-year-2024"      "$(poisoned sprint-2024)"        "clean"
ok "not-mmdd-year-2025"      "$(poisoned sprint-2025)"        "clean"
ok "not-mmdd-chainid"        "$(poisoned chain-8453)"         "clean"
ok "not-mmdd-port"           "$(poisoned port-8080)"          "clean"
ok "not-mmdd-bad-day"        "$(poisoned client-1042)"        "clean"
ok "not-mmdd-hhmm-year-range" "$(poisoned sprint-2024-2025)"  "clean"
ok "not-mmdd-hhmm-port-pair"  "$(poisoned port-8080-9090)"    "clean"

echo "fallback-recipe guard: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
