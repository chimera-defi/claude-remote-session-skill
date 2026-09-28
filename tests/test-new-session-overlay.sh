#!/usr/bin/env bash
# Tests for new-session.sh's overlay visibility line: "overlay: <CRSS_HOME>
# (config: found|absent, rules: found|absent)", printed in --dry-run output
# (this test's hook — --dry-run is the documented pure preview) and also
# used verbatim in the real spawn's final confirmation. No external test
# framework.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NS="$HERE/../scripts/new-session.sh"
pass=0; fail=0
has(){ if printf '%s' "$2" | grep -qE "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — pattern not found: $3 in: $2"; fi; }

# Expose session-alias on PATH the same way test-new-session-names.sh does,
# so --dry-run's alias resolution doesn't fall through to the sanitize-only
# fallback for an unrelated reason.
BIN="$(mktemp -d)"; trap 'rm -rf "$BIN"' EXIT
ln -sf "$HERE/../scripts/session-alias.sh" "$BIN/session-alias"
export PATH="$BIN:$PATH"
STORE="$(mktemp)"; rm -f "$STORE"; export SESSION_ALIAS_STORE="$STORE"

# ── absent overlay ───────────────────────────────────────────────────────
# Isolation: also override CRSS_CLAUDE_HOME (not just CRSS_HOME) — otherwise
# the "rules: absent" expectation below is only true on a host with no real
# ~/.claude/rules/crss-host.md, and silently reads the operator's real overlay
# rules pointer on a host that has one set up (see the same isolation note in
# test-session-alias.sh).
ABSENT="/tmp/crss-newsession-overlay-absent-$$-nonexistent"
out="$(CRSS_HOME="$ABSENT" CRSS_CLAUDE_HOME="$ABSENT" bash "$NS" --dry-run overlay-test-absent 2>&1)"
has "absent-overlay-line" "$out" "overlay: $ABSENT \(config: absent, rules: absent\)"

# ── overlay present: config.sh found, rules pointer found ───────────────
GOOD="$(mktemp -d)"; mkdir -p "$GOOD/rules"
touch "$GOOD/config.sh"
touch "$GOOD/rules/crss-host.md"
out2="$(CRSS_HOME="$GOOD" CRSS_CLAUDE_HOME="$GOOD" bash "$NS" --dry-run overlay-test-good 2>&1)"
has "good-overlay-line" "$out2" "overlay: $GOOD \(config: found, rules: found\)"
rm -rf "$GOOD"

# ── partial: config.sh found, rules pointer absent ───────────────────────
PARTIAL="$(mktemp -d)"
touch "$PARTIAL/config.sh"
out3="$(CRSS_HOME="$PARTIAL" CRSS_CLAUDE_HOME="$PARTIAL" bash "$NS" --dry-run overlay-test-partial 2>&1)"
has "partial-overlay-line" "$out3" "overlay: $PARTIAL \(config: found, rules: absent\)"
rm -rf "$PARTIAL"

echo "test-new-session-overlay: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
