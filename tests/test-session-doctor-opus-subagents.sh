#!/usr/bin/env bash
# session-doctor.sh `opus-subagents`: lists parent sessions whose subagent transcripts ran on Opus.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
isolate_overlay
SD="$HERE/../scripts/session-doctor.sh"

FH="$(mktemp -d)"; trap 'rm -rf "$FH" "$TELEMETRY_ROOT"' EXIT
NOW="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
turn() { printf '{"type":"assistant","sessionId":"%s","cwd":"/w/demo","timestamp":"%s","attributionAgent":"%s","message":{"model":"%s","usage":{"output_tokens":%s}}}\n' "$@"; }
run() { HOME="$FH" bash "$SD" opus-subagents 2>&1; }
SUB="$FH/.claude/projects/-w-demo/11111111-aaaa/subagents"; mkdir -p "$SUB"

turn 11111111-aaaa "$NOW" builder claude-sonnet-5-5 10 > "$SUB/agent-s.jsonl"
turn 11111111-aaaa "$NOW" general-purpose claude-opus-5-5 1 > "$FH/.claude/projects/-w-demo/11111111-aaaa.jsonl"  # parent on Opus: expected
has "sonnet-only says none" "$(run)" "no Opus subagent transcripts"

{ turn 11111111-aaaa "$NOW" "" claude-opus-5-5 300; turn 11111111-aaaa "$NOW" "" "<synthetic>" 0; } > "$SUB/agent-o.jsonl"
printf '{"agentType":"claude"}\n' > "$SUB/agent-o.meta.json"
turn 11111111-aaaa 2020-01-01T00:00:00.000Z general-purpose claude-opus-5-5 999 > "$SUB/agent-old.jsonl"  # outside the window by event time
out="$(run)"; rc=$?
has "counts one opus subagent" "$out" "Opus subagents: 1 across 1 session(s)"
has "row: session, tokens, meta type, cwd" "$out" "11111111 n=1   out=300"
has "row: agent type from meta.json" "$out" "types=claude models=claude-opus-5-5 cwd=/w/demo"
ok "rc 0 (report-only)" "$rc" "0"

# a symlinked transcript FILE is never opened
printf 'SECRETSENTINEL "assistant"\n' > "$FH/cred.txt"; ln -s "$FH/cred.txt" "$SUB/agent-link.jsonl"
hasnt "symlinked file not read" "$(run)" "SECRETSENTINEL"
has "report carries the summary line" "$(HOME="$FH" bash "$SD" report 2>&1)" "Opus subagents: 1 across 1 session(s)"
finish "session-doctor-opus-subagents"
