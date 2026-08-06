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

# Name-first, date last: ah-<alias>-<MMDD-HHMM>.
out="$(bash "$NS" --dry-run some-very-long-project-name 2>/dev/null)"
has "remote-alias-id" "$out" 'REMOTE_NAME=ah-svlpn-[0-9]\{4\}-[0-9]\{4\}'
has "tmux-underscore" "$out" 'SESSION=ah_svlpn-[0-9]\{4\}-[0-9]\{4\}'
has "service-name"    "$out" 'SERVICE=.*/ah-svlpn-[0-9]\{4\}-[0-9]\{4\}\.service'
out2="$(bash "$NS" --dry-run some-proj --alias myproj 2>/dev/null)"
has "explicit-alias"  "$out2" 'REMOTE_NAME=ah-myproj-[0-9]\{4\}-[0-9]\{4\}'
# this repo's folder contains "claude-remote" but is NOT alias-protected (only
# openclaw|hermes are); it shortens to its acronym like any long dev folder.
out3="$(bash "$NS" --dry-run claude-remote-session-skill 2>/dev/null)"
has "claude-remote-substring-shortens" "$out3" 'REMOTE_NAME=ah-crss-[0-9]\{4\}-[0-9]\{4\}'
# regression: a folder literally named `sessions`/`workspace`/`auto` must be
# spawnable — the type keyword is only a TYPE as the SECOND positional.
out4="$(bash "$NS" --dry-run sessions 2>/dev/null)"
has "folder-named-sessions" "$out4" 'REMOTE_NAME=ah-sessions-[0-9]\{4\}-[0-9]\{4\}'
# and the type positional still works after the folder
out5="$(bash "$NS" --dry-run myproj workspace 2>/dev/null)"
has "type-positional-after-folder" "$out5" 'REMOTE_NAME=ah-myproj-[0-9]\{4\}-[0-9]\{4\}'

# Regression: spawning the same folder twice inside the same clock-minute must
# NOT collide on SESSION/REMOTE_NAME. Simulate the collision with a live tmux
# session under the name the first call would resolve to, then confirm a
# second resolution for the same folder disambiguates instead of reusing it
# (a silent reuse would make the second spawn's already-running guard exit
# without applying its own --alias/model, while still reporting success).
if command -v tmux >/dev/null 2>&1; then
  first="$(bash "$NS" --dry-run collide-folder-test 2>/dev/null)"
  first_session="$(printf '%s' "$first" | sed -n 's/^SESSION=//p')"
  tmux new-session -d -s "$first_session" 2>/dev/null
  second="$(bash "$NS" --dry-run collide-folder-test 2>/dev/null)"
  second_session="$(printf '%s' "$second" | sed -n 's/^SESSION=//p')"
  tmux kill-session -t "$first_session" 2>/dev/null || true
  if [ "$first_session" != "$second_session" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: same-minute collision — got identical SESSION '$second_session' twice"; fi
  has "same-minute-collision-suffixed" "$second_session" '^ah_cft-[0-9]\{4\}-[0-9]\{4\}-2$'
fi

echo "new-session names: pass=$pass fail=$fail"; [ "$fail" -eq 0 ]
