#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NS="$HERE/../scripts/new-session.sh"
# Expose the helper as `session-alias` (no .sh) via a throwaway bin dir on PATH,
# so new-session's `command -v session-alias` resolves it — WITHOUT polluting the
# repo's scripts/ dir with a stray symlink.
BIN="$(mktemp -d)"; trap 'rm -rf "$BIN"' EXIT
ln -sf "$HERE/../scripts/session-alias.sh" "$BIN/session-alias"
export PATH="$BIN:$PATH"
STORE="$(mktemp)"; rm -f "$STORE"; export SESSION_ALIAS_STORE="$STORE"
pass=0; fail=0
has(){ if printf '%s' "$2" | grep -q "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }

out="$(bash "$NS" --dry-run some-very-long-project-name 2>/dev/null)"
has "remote-ah-id-alias" "$out" 'REMOTE_NAME=ah-[0-9]\{4\}-[0-9]\{4\}-svlpn'
has "tmux-underscore"    "$out" 'SESSION=ah_[0-9]\{4\}-[0-9]\{4\}-svlpn'
has "service-name"       "$out" 'SERVICE=.*/ah-[0-9]\{4\}-[0-9]\{4\}-svlpn\.service'
out2="$(bash "$NS" --dry-run some-proj --alias myproj 2>/dev/null)"
has "explicit-alias"     "$out2" 'REMOTE_NAME=ah-[0-9]\{4\}-[0-9]\{4\}-myproj'
# this repo's folder contains "claude-remote" but is NOT alias-protected (only
# openclaw|hermes are); it shortens to its acronym like any long dev folder.
out3="$(bash "$NS" --dry-run claude-remote-session-skill 2>/dev/null)"
has "claude-remote-substring-shortens" "$out3" 'REMOTE_NAME=ah-[0-9]\{4\}-[0-9]\{4\}-crss'

echo "new-session names: pass=$pass fail=$fail"; [ "$fail" -eq 0 ]
