#!/usr/bin/env bash
# new-session.sh --dry-run resolution: --tier / effort / advisor / --escalate-from / per-tier compact window /
# overlay line, plus the generated start script exporting the compact window into the launch environment.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
NS="$HERE/../scripts/new-session.sh"
isolate_overlay
export CRSS_SESSION_PREFIX=px
WORKHOME="$(mktemp -d)"; trap 'rm -rf "$WORKHOME"' EXIT
export HOME="$WORKHOME"; mkdir -p "$HOME/workspace/proj"

# dry ENV... -- ARGS...: dry-run spawn; prints the resolved fields (stderr included).
dry() {
  local envs=(); while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  env -u CLAUDE_SESSION_PROFILE -u CLAUDE_SESSION_MODEL -u CLAUDE_SESSION_EFFORT -u CLAUDE_SESSION_ADVISOR \
    -u CLAUDE_SESSION_COMPACT_WINDOW -u CRSS_COMPACT_WINDOW_HEAVY -u CRSS_COMPACT_WINDOW_STANDARD \
    -u CRSS_OPUS_MODEL -u CRSS_SESSION_BACKEND "${envs[@]}" bash "$NS" proj workspace --dry-run "$@" 2>&1
}

# tiers
o="$(dry A=1 --)"
hasre "default: orchestrator on pinned Opus, no tier/advisor/effort" "$o" '^PROFILE=orchestrator$'
hasre "default model" "$o" '^MODEL=claude-opus-5-5$'; hasre "default advisor" "$o" '^ADVISOR=none$'; hasre "default effort" "$o" '^EFFORT=default$'
o="$(dry A=1 -- --tier light)"
hasre "light: copywriter/haiku" "$o" '^PROFILE=copywriter$'; hasre "light model" "$o" '^MODEL=haiku$'
hasre "light advisor is Opus" "$o" '--advisor claude-opus-5-5'; hasnt "light sets no effort flag" "$o" '--effort'
o="$(dry A=1 -- --tier standard)"; hasre "standard: builder/sonnet" "$o" '^PROFILE=builder$'; hasre "standard effort low" "$o" '--effort low'
o="$(dry CLAUDE_SESSION_EFFORT=high -- --tier standard)"; hasre "explicit effort beats tier default" "$o" '--effort high'
o="$(dry A=1 -- --tier heavy)"; hasre "heavy: owner/sonnet" "$o" '^PROFILE=owner$'
o="$(dry CLAUDE_SESSION_PROFILE=orchestrator -- --tier heavy)"; hasre "explicit profile beats tier" "$o" '^PROFILE=orchestrator$'; hasre "Opus has no advisor" "$o" '^ADVISOR=none$'

# advisor: one Opus source, overridable, validated
o="$(dry CRSS_OPUS_MODEL=claude-opus-9-9 -- --tier standard)"; hasre "Opus id feeds the advisor" "$o" '--advisor claude-opus-9-9'
o="$(dry CLAUDE_SESSION_ADVISOR=none -- --tier standard)"; hasnt "advisor=none drops the flag" "$o" '--advisor'
o="$(dry CLAUDE_SESSION_ADVISOR='x;y' -- --tier standard)"; hasre "bad advisor id refused" "$o" 'invalid'
o="$(dry CRSS_OPUS_MODEL='a b' -- --backend codex)"; hasre "bad Opus id harmless for codex" "$o" '^BACKEND=codex$'

# bad inputs
o="$(dry A=1 -- --tier bogus)"; hasre "bad tier" "$o" 'unknown --tier'
o="$(dry CLAUDE_SESSION_EFFORT=turbo -- --tier light)"; hasre "bad effort" "$o" 'invalid'
o="$(dry CLAUDE_SESSION_PROFILE=bulder -- --tier light)"; hasre "typo'd profile refused under a tier" "$o" 'unknown CLAUDE_SESSION_PROFILE'
o="$(dry CLAUDE_SESSION_PROFILE=bulder --)"; hasre "typo'd profile falls back without a tier" "$o" '^PROFILE=orchestrator$'

# --escalate-from: one tier above the recorded tier; explicit --tier wins
TR="$(mktemp -d)"; mkdir -p "$TR/artifacts/telemetry"
cat > "$TR/artifacts/telemetry/events.jsonl" <<'J'
{"event":"spawn","timestamp":"2026-10-05T10:00:00+00:00","session":"px_l-1","remote_name":"px-l-1","routing":{"tier":"light"},"meta":{}}
{"event":"spawn","timestamp":"2026-10-05T10:00:00+00:00","session":"px_h-1","remote_name":"px-h-1","routing":{"tier":"heavy"},"meta":{}}
{"event":"spawn","timestamp":"2026-10-05T10:00:00+00:00","session":"px_n-1","remote_name":"px-n-1","meta":{}}
J
o="$(dry TELEMETRY_ROOT="$TR" -- --escalate-from px_l-1)"; hasre "escalate light -> standard" "$o" '^TIER=standard$'
o="$(dry TELEMETRY_ROOT="$TR" -- --escalate-from px_h-1)"; has "escalate past heavy -> Opus" "$o" "escalating past it to Opus"; hasre "escalate past heavy profile" "$o" '^PROFILE=orchestrator$'
o="$(dry TELEMETRY_ROOT="$TR" -- --escalate-from px_n-1)"; hasre "unknown tier assumed standard -> heavy" "$o" '^TIER=heavy$'
o="$(dry TELEMETRY_ROOT="$TR" -- --escalate-from px_l-1 --tier heavy)"; hasre "explicit --tier wins" "$o" '^TIER=heavy$'
rm -rf "$TR"

# per-tier compact window
o="$(dry A=1 -- --tier heavy)"; hasre "compact window unset = host" "$o" '^COMPACT_WINDOW=host$'
o="$(dry CRSS_COMPACT_WINDOW_HEAVY=600000 -- --tier heavy)"; hasre "heavy tier value applies" "$o" '^COMPACT_WINDOW=600000$'
o="$(dry CRSS_COMPACT_WINDOW_HEAVY=600000 -- --tier standard)"; hasre "other tiers unaffected" "$o" '^COMPACT_WINDOW=host$'
o="$(dry CRSS_COMPACT_WINDOW_HEAVY=600000 CLAUDE_SESSION_COMPACT_WINDOW=450000 -- --tier heavy)"; hasre "explicit beats tier" "$o" '^COMPACT_WINDOW=450000$'
o="$(dry CLAUDE_SESSION_COMPACT_WINDOW=50 -- --tier heavy)"; hasre "too small refused" "$o" 'out of range'
o="$(dry CLAUDE_SESSION_COMPACT_WINDOW=abc -- --tier heavy)"; hasre "non-numeric refused" "$o" 'compact window .* invalid'
o="$(dry CRSS_COMPACT_WINDOW_HEAVY=600000 -- --tier heavy --backend codex)"; hasre "codex ignores it" "$o" '^COMPACT_WINDOW=host$'

# generated start script exports the window before claude launches (stub systemctl, fake HOME)
mkdir -p "$HOME/.local/bin" "$HOME/.config/systemd/user"
printf "#!/bin/sh\nexit 0\n" > "$HOME/.local/bin/systemctl"; chmod +x "$HOME/.local/bin/systemctl"
gen() {
  rm -rf "$HOME/.sessions" "$HOME"/.local/bin/*-start.sh
  env -u CLAUDE_SESSION_COMPACT_WINDOW -u CRSS_COMPACT_WINDOW_HEAVY "$@" PATH="$HOME/.local/bin:$PATH" bash "$NS" proj workspace --alias cw --tier heavy >/dev/null 2>&1
  cat "$HOME"/.local/bin/*-start.sh 2>/dev/null
}
hasre "start script exports the window" "$(gen CRSS_COMPACT_WINDOW_HEAVY=600000)" "'export CLAUDE_CODE_AUTO_COMPACT_WINDOW=600000' Enter$"
hasnt "start script exports nothing by default" "$(gen A=1)" 'CLAUDE_CODE_AUTO_COMPACT_WINDOW'

# overlay line: found/absent
GOOD="$(mktemp -d)"; mkdir -p "$GOOD/rules"; touch "$GOOD/config.sh" "$GOOD/rules/crss-host.md"
ABSENT="/tmp/crss-newsession-overlay-absent-$$-nonexistent"
has "overlay line: absent" "$(CRSS_HOME="$ABSENT" CRSS_CLAUDE_HOME="$ABSENT" bash "$NS" --dry-run ov-absent 2>&1)" "overlay: $ABSENT (config: absent, rules: absent)"
has "overlay line: found" "$(CRSS_HOME="$GOOD" CRSS_CLAUDE_HOME="$GOOD" bash "$NS" --dry-run ov-good 2>&1)" "overlay: $GOOD (config: found, rules: found)"
rm -rf "$GOOD"

finish test-new-session-tier
