#!/usr/bin/env bash
# Per-tier auto-compact window: resolution via --dry-run, and that the generated start script
# exports it into the launch environment (hermetic: stub tmux/systemctl, fake HOME).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
NS="$HERE/../scripts/new-session.sh"
isolate_overlay
export CRSS_SESSION_PREFIX=px
WORKHOME="$(mktemp -d)"; trap 'rm -rf "$WORKHOME"' EXIT
export HOME="$WORKHOME"; mkdir -p "$HOME/workspace/proj"

dry() {
  local envs=(); while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  env -u CLAUDE_SESSION_PROFILE -u CLAUDE_SESSION_MODEL -u CLAUDE_SESSION_EFFORT -u CLAUDE_SESSION_ADVISOR \
    -u CLAUDE_SESSION_COMPACT_WINDOW -u CRSS_COMPACT_WINDOW_LIGHT -u CRSS_COMPACT_WINDOW_STANDARD -u CRSS_COMPACT_WINDOW_HEAVY \
    -u CRSS_SESSION_BACKEND "${envs[@]}" bash "$NS" proj workspace --dry-run "$@" 2>&1
}

o="$(dry A=1 -- --tier heavy)"; hasre "unset-is-host" "$o" '^COMPACT_WINDOW=host$'
o="$(dry CRSS_COMPACT_WINDOW_HEAVY=600000 -- --tier heavy)"; hasre "heavy-tier-value" "$o" '^COMPACT_WINDOW=600000$'
o="$(dry CRSS_COMPACT_WINDOW_HEAVY=600000 -- --tier standard)"; hasre "standard-unaffected" "$o" '^COMPACT_WINDOW=host$'
o="$(dry CRSS_COMPACT_WINDOW_HEAVY=600000 --)"; hasre "no-tier-unaffected" "$o" '^COMPACT_WINDOW=host$'
o="$(dry CRSS_COMPACT_WINDOW_STANDARD=400000 -- --tier standard)"; hasre "standard-tier-value" "$o" '^COMPACT_WINDOW=400000$'
o="$(dry CRSS_COMPACT_WINDOW_HEAVY=600000 CLAUDE_SESSION_COMPACT_WINDOW=450000 -- --tier heavy)"; hasre "explicit-wins" "$o" '^COMPACT_WINDOW=450000$'
o="$(dry CRSS_COMPACT_WINDOW_HEAVY=600000 CLAUDE_SESSION_COMPACT_WINDOW=host -- --tier heavy)"; hasre "explicit-host" "$o" '^COMPACT_WINDOW=host$'
o="$(dry CLAUDE_SESSION_COMPACT_WINDOW=abc -- --tier heavy)"; hasre "bad-value" "$o" 'compact window .* invalid'
o="$(dry CLAUDE_SESSION_COMPACT_WINDOW=50 -- --tier heavy)"; hasre "too-small" "$o" 'out of range'
o="$(dry CRSS_COMPACT_WINDOW_HEAVY=9999999 -- --tier heavy)"; hasre "too-big" "$o" 'out of range'
o="$(dry CRSS_COMPACT_WINDOW_HEAVY=600000 -- --tier heavy --backend codex)"; hasre "codex-ignored" "$o" '^COMPACT_WINDOW=host$'

# Generated start script: the export is in the typed supervisor text, before claude is launched.
mkdir -p "$HOME/.local/bin" "$HOME/.config/systemd/user"
printf "#!/bin/sh\nexit 0\n" > "$HOME/.local/bin/systemctl"; chmod +x "$HOME/.local/bin/systemctl"
gen() {
  local envs=(); while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  rm -rf "$HOME/.sessions" "$HOME"/.local/bin/*-start.sh
  env -u CLAUDE_SESSION_COMPACT_WINDOW -u CRSS_COMPACT_WINDOW_HEAVY "${envs[@]}" PATH="$HOME/.local/bin:$PATH" bash "$NS" proj workspace --alias cw "$@" >/dev/null 2>&1
  cat "$HOME"/.local/bin/*-start.sh 2>/dev/null
}
s="$(gen CRSS_COMPACT_WINDOW_HEAVY=600000 -- --tier heavy)"
hasre "start-script-export" "$s" "^tmux send-keys -t .* 'export CLAUDE_CODE_AUTO_COMPACT_WINDOW=600000' Enter$"
s="$(gen A=1 -- --tier heavy)"
hasnt "start-script-no-export-by-default" "$s" 'CLAUDE_CODE_AUTO_COMPACT_WINDOW'
hasre "start-script-generated" "$s" 'tmux send-keys'

# Telemetry carries it.
T="$(mktemp -d)"
CLAUDE_SKILLS_DIR="$T/s" TELEMETRY_ROOT="$T/r" bash "$HERE/../scripts/record-spawn-telemetry.sh" f a r s workspace sonnet "$T" heavy "" "why" 600000 >/dev/null
hasre "telemetry-compact-window" "$(cat "$T/r/artifacts/telemetry/events.jsonl")" '"compact_window": "600000"'
rm -rf "$T"
finish test-new-session-compact-window
