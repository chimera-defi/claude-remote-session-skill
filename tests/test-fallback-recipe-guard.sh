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
#
# Since #104 (configurable CRSS_SESSION_PREFIX/CRSS_LEGACY_PREFIXES), the
# guard's prefix check reads $CRSS_SESSION_PREFIX instead of a hardcoded
# "px-"/"px_" — so this test also pulls the doc's own default-resolution line
# (pinning it stays "cs", matching new-session.sh's generic default) and adds
# cases proving the guard actually tracks a reconfigured prefix rather than
# still being hardcoded under the hood.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DOC="$HERE/../references/fallback-recipe.md"
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }

# Pull the CRSS_SESSION_PREFIX default-resolution line and the
# _fr_has_mmdd_group()/_fr_poisoned() function bodies out of the fenced bash
# block (_fr_poisoned reads $CRSS_SESSION_PREFIX and calls
# _fr_has_mmdd_group(), so all three are needed).
unset CRSS_SESSION_PREFIX   # isolation: test the doc's own default, not an inherited value
FUNC="$(sed -n '/^: "\${CRSS_SESSION_PREFIX:=cs}"$/p; /^_fr_has_mmdd_group() {$/,/^}$/p; /^_fr_poisoned() {$/,/^}$/p' "$DOC")"
[ -n "$FUNC" ] || { echo "FAIL: could not locate CRSS_SESSION_PREFIX default / _fr_poisoned()/_fr_has_mmdd_group() in $DOC"; exit 1; }
eval "$FUNC"

poisoned(){ _fr_poisoned "$1" && echo POISONED || echo clean; }

# The doc's own default must match new-session.sh's generic default — this
# IS what "kept in sync" means for a prefix that's now configurable.
ok "prefix-default-matches-new-session" "$CRSS_SESSION_PREFIX" "cs"

# Genuine poisoned shapes under the default prefix (must still be caught).
ok "prefix-match"            "$(poisoned cs-universe-expand-0722)"          "POISONED"
ok "prefix-underscore-match" "$(poisoned cs_universe_expand)"               "POISONED"
# Case-insensitivity (found via review, chatgpt-codex-connector, PR #34): a
# mixed-case stored alias must not bypass the prefix check either.
ok "prefix-match-mixed-case" "$(poisoned CS-foo-bar)"                       "POISONED"

# The guard must track a RECONFIGURED CRSS_SESSION_PREFIX, not a value
# hardcoded at doc-authoring time — this is the actual behavior #104 added.
# Fixtures here carry NO digits at all (unlike the -0722-shaped ones above,
# which a trailing-MMDD real-date match would also catch regardless of
# prefix) — isolating the prefix check specifically. A value shaped like the
# OLD default must be clean once the prefix no longer matches it, and the
# newly configured prefix must be caught instead.
ok "old-default-not-caught-once-unconfigured" "$(poisoned px-foo-bar)" "clean"
CRSS_SESSION_PREFIX=px
ok "reconfigured-prefix-caught"                 "$(poisoned px-foo-bar)" "POISONED"
ok "prior-default-not-caught-once-reconfigured" "$(poisoned cs-foo-bar)" "clean"
CRSS_SESSION_PREFIX=cs   # restore for the remaining default-prefix fixtures below

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

# Long-numeric-run false positives (same bug class, un-gated -[0-9]{5,} check —
# a single trailing 5+-digit group with no accompanying real MMDD field is a
# legitimate identifier, not a poisoned timestamp/random suffix. Mirrors
# test-session-alias.sh's "not-longrun-*" cases).
ok "not-longrun-port"    "$(poisoned port-12345)"    "clean"
ok "not-longrun-port-2"  "$(poisoned port-54321)"     "clean"
ok "not-longrun-client"  "$(poisoned client-99999)"   "clean"
ok "not-longrun-invoice" "$(poisoned invoice-123456)" "clean"
# A long numeric run PAIRED with a real MMDD date fragment elsewhere in the
# string is still caught.
ok "real-longrun-still-caught" "$(poisoned release-0715-123456)" "POISONED"

# An invalid digit pair BEFORE a real embedded timestamp must not let the real
# pair slide through: "project-2024-2025-0715-2359" contains TWO
# [0-9]{4}-[0-9]{4} matches — "2024-2025" (fails date validation) and
# "0715-2359" (a real MMDD-HHMM) — only checking the first would miss it.
ok "multi-pair-later-real-timestamp" "$(poisoned project-2024-2025-0715-2359)" "POISONED"
# Same class, three digit-pairs instead of two (extra coverage, found in review).
ok "multi-pair-three-candidates" "$(poisoned release-2024-2025-x-0715-0630-copy)" "POISONED"

echo "fallback-recipe guard: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
