#!/usr/bin/env bash
# telemetry-report.sh — summarize artifacts/telemetry/events.jsonl: spawn
# count and the global-skills-catalog size trend (the context-bloat proxy
# record-spawn-telemetry.sh captures on every spawn).
set -uo pipefail

# ── Host-local overlay config ────────────────────────────────────────────────
# See examples/crss-overlay/README.md. Parses (never sources) $CRSS_HOME/config.sh
# for CRSS_* vars; an env var already set wins over the file; a missing/unreadable
# file is fine (generic defaults below apply). Copied verbatim in every script
# that reads overlay config — see tests/test-crss-overlay-config.sh.
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
    case "$_crss_val" in
      \"*\") _crss_val="${_crss_val#\"}"; _crss_val="${_crss_val%\"}" ;;
      \'*\') _crss_val="${_crss_val#\'}"; _crss_val="${_crss_val%\'}" ;;
    esac
    [ -z "${!_crss_key+x}" ] && export "${_crss_key}=${_crss_val}"
  done < "$_crss_cfg"
}
_crss_load_config
# CRSS-CONFIG-LOADER-END
: "${CRSS_WORKSPACE:=$HOME/workspace}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# See record-spawn-telemetry.sh for why the fallback is derived from
# CRSS_WORKSPACE (host-local overlay, see examples/crss-overlay/) rather than
# from $SCRIPT_DIR: this script is also deployed as a flat copy to
# ~/.local/bin, where git rev-parse has nothing to find and a fallback
# derived from the deployed location would silently point at the wrong
# directory. "claude-remote-session-skill" is this project's own repo name,
# not a host-specific value.
REPO_ROOT="${TELEMETRY_ROOT:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$CRSS_WORKSPACE/claude-remote-session-skill")}"
EVENTS_FILE="$REPO_ROOT/artifacts/telemetry/events.jsonl"

if [ ! -f "$EVENTS_FILE" ]; then
  echo "No telemetry yet: $EVENTS_FILE does not exist."
  exit 0
fi

python3 - "$EVENTS_FILE" <<'PYEOF'
import json, sys

path = sys.argv[1]
events = []
with open(path, encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue

print(f"spawns recorded: {len(events)}")
if not events:
    sys.exit(0)

skills_counts = [e.get("meta", {}).get("global_skills_count") for e in events if e.get("meta", {}).get("global_skills_count") is not None]
if skills_counts:
    print(f"global_skills_count: first={skills_counts[0]} latest={skills_counts[-1]} max={max(skills_counts)}")

print("last 5 spawns:")
for e in events[-5:]:
    meta = e.get("meta", {})
    print(f"  {e.get('timestamp')}  {e.get('remote_name')}  type={e.get('type')}  "
          f"skills={meta.get('global_skills_count')}  skills_md_bytes={meta.get('global_skills_md_bytes')}  "
          f"claude_md_bytes={meta.get('claude_md_bytes')}")
PYEOF
