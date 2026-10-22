#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
Q="$HERE/../scripts/quota-check.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
isolate_overlay
out=$(printf '%s\n' 'Error: hit your usage limit' | "$Q" classify); rc=$?; ok 'codex classification status' "$rc" 10; has 'codex classification' "$out" codex-quota
out=$(printf '%s\n' "You've hit your monthly spend limit" | "$Q" classify); rc=$?; ok 'claude classification status' "$rc" 11; has 'claude classification' "$out" claude-quota
out=$(printf '%s\n' 'API Error: Rate limited' | "$Q" classify); ok 'transient classification' "$out" none
out=$(printf '%s\n' 'ordinary failure' | "$Q" classify); ok 'plain classification' "$out" none
mkdir -p "$TMP/overlay"; export CRSS_HOME="$TMP/overlay"; printf 'codex-quota\tcustom marker\n' > "$CRSS_HOME/quota-patterns.txt"
out=$(printf '%s\n' 'hit your usage limit' | "$Q" classify); ok 'overlay replaces defaults' "$out" none
out=$(printf '%s\n' 'CUSTOM MARKER' | "$Q" classify); rc=$?; ok 'overlay match' "$rc" 10
mkdir -p "$TMP/codex"; export CRSS_CODEX_SESSIONS_DIR="$TMP/codex"
printf '%s\n' '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":100,"resets_at":1},"rate_limit_reached_type":null}}}' > "$TMP/codex/old.jsonl"
out=$("$Q" codex-status); has 'past reset is okay' "$out" 'ok used_percent=100'
export CRSS_ROUTING_LOG="$TMP/routing/log.jsonl"
"$Q" log event=test key=value
python3 - "$CRSS_ROUTING_LOG" <<'PY'
import json,sys
with open(sys.argv[1]) as f: d=json.loads(f.readline())
assert d['event']=='test' and d['key']=='value' and 'ts' in d
PY
ok 'routing log writes JSON' "$?" 0
finish test-quota-check
