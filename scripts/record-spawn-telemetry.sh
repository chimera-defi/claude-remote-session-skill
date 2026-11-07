#!/usr/bin/env bash
# record-spawn-telemetry.sh — append one spawn event + context-size proxies to
# artifacts/telemetry/events.jsonl. Best-effort: never exits non-zero, so a
# caller running under `set -e` can safely skip checking its result.
#
# Usage: record-spawn-telemetry.sh <foldername> <alias> <remote_name> <session> <type> <model> <workdir> [tier] [effort] [tier_reason] [compact_window]
#        record-spawn-telemetry.sh --reap <session> <forced:yes|no> [outcome] [note] [clean:yes|no|unknown]
#        record-spawn-telemetry.sh --tier-of <session>   # prints the tier of its latest spawn, else nothing
#        record-spawn-telemetry.sh --whoami   # prints launcher name and session id, tab-separated
#   --reap: teardown event from session-doctor. outcome is what the caller states; default unknown.
#
# Env overrides (tests / non-standard installs): CLAUDE_SKILLS_DIR; TELEMETRY_ROOT (else the repo
# root, then $CRSS_WORKSPACE/claude-remote-session-skill). CRSS_TEST_SUITE with no TELEMETRY_ROOT
# skips writes.
set -uo pipefail

# Parses (never sources) $CRSS_HOME/config.sh; env vars win. Copied verbatim into every script
# that reads it (tests/test-crss-overlay-config.sh).
# CRSS-CONFIG-LOADER-START
_crss_load_config() {
  local _crss_home _crss_cfg _crss_line _crss_key _crss_val
  _crss_home="${CRSS_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/crss}"
  export CRSS_HOME="$_crss_home"
  _crss_cfg="$_crss_home/config.sh"
  [ -r "$_crss_cfg" ] || return 0
  while IFS= read -r _crss_line || [ -n "$_crss_line" ]; do
    [[ "$_crss_line" =~ ^(CRSS_[A-Z0-9_]+)=(.*)$ ]] || continue
    _crss_key="${BASH_REMATCH[1]}"
    _crss_val="${BASH_REMATCH[2]}"
    _crss_val="${_crss_val%$'\r'}"
    case "$_crss_val" in
      \"*\") _crss_val="${_crss_val#\"}"; _crss_val="${_crss_val%\"}" ;;
      \'*\') _crss_val="${_crss_val#\'}"; _crss_val="${_crss_val%\'}" ;;
    esac
    if [ -z "${!_crss_key+x}" ]; then export "${_crss_key}=${_crss_val}"; fi
  done < "$_crss_cfg"
  return 0
}
_crss_load_config
# CRSS-CONFIG-LOADER-END
: "${CRSS_WORKSPACE:=$HOME/workspace}"

FOLDERNAME="${1:-}"; ALIAS="${2:-}"; REMOTE_NAME="${3:-}"; SESSION="${4:-}"; TYPE="${5:-}"; MODEL="${6:-}"; WORKDIR="${7:-}"
TIER="${8:-}"; EFFORT="${9:-}"; TIER_REASON="${10:-}"; COMPACT_WINDOW="${11:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# Deployed as a flat copy to ~/.local/bin, where git finds no repo: never derive the path from
# SCRIPT_DIR, or events scatter outside the repo. Prefer git from a checkout, else CRSS_WORKSPACE.
REPO_ROOT="${TELEMETRY_ROOT:-}"
if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" || REPO_ROOT="$CRSS_WORKSPACE/claude-remote-session-skill"
fi
SKILLS_DIR="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
EVENTS_FILE="$REPO_ROOT/artifacts/telemetry/events.jsonl"

# Ask tmux only inside a pane: Desktop callers must not inherit an unrelated session.
# Never reads messaging, OAuth or account environment variables.
_launcher_detect() {
  L_NAME="${CRSS_LAUNCHER:-}"
  if [ -z "$L_NAME" ] && [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
    L_NAME="$(tmux display -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null || true)"
  fi
  L_NAME="${L_NAME:0:100}"
  L_ID="${CLAUDE_CODE_SESSION_ID:-}"
  [[ "$L_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || L_ID=""
}
if [ "${1:-}" = --whoami ]; then _launcher_detect; printf '%s\t%s\n' "$L_NAME" "$L_ID"; exit 0; fi

if [ "${1:-}" = --tier-of ]; then
  [ -f "$EVENTS_FILE" ] || exit 0
  python3 - "$EVENTS_FILE" "${2:-}" <<'PYEOF' 2>/dev/null || exit 0
import json, sys
path, want = sys.argv[1], sys.argv[2].lower().replace("_", "-")
tier = ""
for line in open(path, encoding="utf-8"):
    try: e = json.loads(line)
    except ValueError: continue
    if e.get("event", "spawn") != "spawn": continue
    if want in {(e.get("session") or "").lower().replace("_", "-"), (e.get("remote_name") or "").lower().replace("_", "-")}:
        tier = (e.get("routing") or {}).get("tier") or ""
print(tier)
PYEOF
  exit 0
fi

# Test quarantine: with CRSS_TEST_SUITE set and no TELEMETRY_ROOT, write nothing, so tests never
# pollute the live events.jsonl. Reads still work.
if [ -n "${CRSS_TEST_SUITE:-}" ] && [ -z "${TELEMETRY_ROOT:-}" ]; then exit 0; fi

if [ "${1:-}" = --reap ]; then
  mkdir -p "$(dirname "$EVENTS_FILE")" 2>/dev/null || exit 0
  python3 - "$EVENTS_FILE" "${2:-}" "${3:-no}" "${4:-}" "${5:-}" "${6:-}" <<'PYEOF' 2>/dev/null || exit 0
import json, sys, datetime
events_file, session, forced, outcome, note, clean = sys.argv[1:7]
payload = {
    "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "event": "reap",
    "skill": "gstack-session-spawn",
    "session": session,
    "forced": forced == "yes",
    "outcome": outcome if outcome in ("ok", "failed", "escalated", "abandoned") else "unknown",
    "note": note[:200],
    "clean": clean if clean in ("yes", "no") else "unknown",
}
with open(events_file, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(payload, sort_keys=True) + "\n")
PYEOF
  exit 0
fi

case "${1:-}" in --*) echo "unknown flag $1" >&2; exit 0 ;; esac

# Context-size proxies (before/after baseline for scoping changes). Best-effort: a missing dir reports 0.
skills_count=0
skills_bytes=0
if [ -d "$SKILLS_DIR" ]; then
  skills_count=$(find "$SKILLS_DIR" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
  skills_bytes=$(find "$SKILLS_DIR" -iname 'SKILL.md' -type f -exec cat {} + 2>/dev/null | wc -c | tr -d ' ')
fi

claude_md_bytes=0
# An empty WORKDIR must not probe /CLAUDE.md, which would misattribute a root-level file.
if [ -n "$WORKDIR" ]; then
  for candidate in "$WORKDIR/.claude/CLAUDE.md" "$WORKDIR/CLAUDE.md"; do
    if [ -f "$candidate" ]; then
      claude_md_bytes=$(wc -c < "$candidate" 2>/dev/null | tr -d ' ')
      break
    fi
  done
fi

mkdir -p "$(dirname "$EVENTS_FILE")" 2>/dev/null || exit 0

_launcher_detect
export CRSS_L_NAME="$L_NAME" CRSS_L_ID="$L_ID"
python3 - "$EVENTS_FILE" "$FOLDERNAME" "$ALIAS" "$REMOTE_NAME" "$SESSION" "$TYPE" "$MODEL" "$WORKDIR" "$skills_count" "$skills_bytes" "$claude_md_bytes" "$TIER" "$EFFORT" "$TIER_REASON" "${CRSS_ESCALATED_FROM:-}" "$COMPACT_WINDOW" <<'PYEOF' 2>/dev/null || exit 0
import json, sys, datetime

(events_file, foldername, alias, remote_name, session, typ, model, workdir,
 skills_count, skills_bytes, claude_md_bytes, tier, effort, tier_reason, escalated_from, compact_window) = sys.argv[1:17]

payload = {
    "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "event": "spawn",
    "skill": "gstack-session-spawn",
    "foldername": foldername,
    "alias": alias,
    "remote_name": remote_name,
    "session": session,
    "type": typ,
    "model": model,
    "workdir": workdir,
    "meta": {
        "global_skills_count": int(skills_count or 0),
        "global_skills_md_bytes": int(skills_bytes or 0),
        "claude_md_bytes": int(claude_md_bytes or 0),
    },
}
if tier or effort or compact_window:
    payload["routing"] = {"tier": tier, "effort": effort, "reason": tier_reason[:200]}
    if compact_window:
        payload["routing"]["compact_window"] = compact_window
    if escalated_from:
        payload["routing"]["escalated_from"] = escalated_from[:100]
import os
b = os.environ.get("CRSS_SPAWN_BACKEND", "")
if b: payload["backend"] = b[:20]
n, i = (os.environ.get(k, "") for k in ("CRSS_L_NAME", "CRSS_L_ID"))
if n or i:
    payload["launcher"] = {"name": n, "session_id": i}
with open(events_file, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(payload, sort_keys=True) + "\n")
PYEOF

exit 0
