#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NS="$HERE/../scripts/new-session.sh"
export PATH="$HERE/../scripts:$PATH"   # so `session-alias` resolves to our helper
ln -sf session-alias.sh "$HERE/../scripts/session-alias" 2>/dev/null || true
STORE="$(mktemp)"; rm -f "$STORE"; export SESSION_ALIAS_STORE="$STORE"
pass=0; fail=0
has(){ if printf '%s' "$2" | grep -q "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }

# NOTE: deviates from the plan's literal test data, which used
# claude-remote-session-skill -> crss. That folder name contains the substring
# "claude-remote", which matches session-alias's PROTECT pattern
# (claude-remote|openclaw|hermes), so it is correctly passed through unaliased
# by rule 0 — the plan's example was inconsistent with its own PROTECT
# constraint (see tests/test-session-alias.sh for the same fix + rationale).
# Using a non-protected >18-char folder here so the acronym path is exercised.
out="$(bash "$NS" --dry-run some-very-long-project-name 2>/dev/null)"
has "remote-ah-id-alias" "$out" 'REMOTE_NAME=ah-[0-9]\{4\}-[0-9]\{4\}-svlpn'
has "tmux-underscore"    "$out" 'SESSION=ah_[0-9]\{4\}-[0-9]\{4\}-svlpn'
has "service-name"       "$out" 'SERVICE=.*/ah-[0-9]\{4\}-[0-9]\{4\}-svlpn\.service'
out2="$(bash "$NS" --dry-run some-proj --alias myproj 2>/dev/null)"
has "explicit-alias"     "$out2" 'REMOTE_NAME=ah-[0-9]\{4\}-[0-9]\{4\}-myproj'
# protected folder keeps its identity token even through new-session
out3="$(bash "$NS" --dry-run claude-remote-session-skill 2>/dev/null)"
has "protected-passthrough" "$out3" 'REMOTE_NAME=ah-[0-9]\{4\}-[0-9]\{4\}-claude-remote-session-skill'

echo "new-session names: pass=$pass fail=$fail"; [ "$fail" -eq 0 ]
