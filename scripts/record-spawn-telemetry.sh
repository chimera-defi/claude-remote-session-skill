#!/usr/bin/env bash
# record-spawn-telemetry.sh — append one spawn event + context-size proxies to
# artifacts/telemetry/events.jsonl. Best-effort: never exits non-zero, so a
# caller running under `set -e` can safely skip checking its result.
#
# Usage: record-spawn-telemetry.sh <foldername> <alias> <remote_name> <session> <type> <model> <workdir>
#
# Env overrides (for testing / non-standard installs):
#   CLAUDE_SKILLS_DIR   default: $HOME/.claude/skills
#   TELEMETRY_ROOT       default: this script's repo root (git rev-parse), else its grandparent dir
set -uo pipefail

FOLDERNAME="${1:-}"; ALIAS="${2:-}"; REMOTE_NAME="${3:-}"; SESSION="${4:-}"; TYPE="${5:-}"; MODEL="${6:-}"; WORKDIR="${7:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# This script is deployed as a flat copy to ~/.local/bin (see SKILL.md — "Scripts
# are local-only") for every real spawn, so `git -C "$SCRIPT_DIR" rev-parse` fails
# there (no .git above ~/.local/bin) and must NOT fall back to a path derived from
# the deployed location — that silently scatters events under ~/.local/artifacts/
# instead of the repo (caught via a live spawn: event landed at
# ~/.local/artifacts/telemetry/events.jsonl, not the repo, before this fix).
# git rev-parse still succeeds when this script runs from the repo checkout
# (tests/, or scripts/ during dev), so prefer it there; otherwise use the known
# canonical repo path.
REPO_ROOT="${TELEMETRY_ROOT:-}"
if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" || REPO_ROOT="/home/agents/workspace/claude-remote-session-skill"
fi
SKILLS_DIR="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
EVENTS_FILE="$REPO_ROOT/artifacts/telemetry/events.jsonl"

# Context-size proxies: how much a freshly spawned session's global skill
# catalog and project CLAUDE.md weigh, so a future scoping change has a
# before/after baseline instead of guessing. Every lookup is best-effort —
# a missing/unreadable dir just reports 0, it never aborts the spawn.
skills_count=0
skills_bytes=0
if [ -d "$SKILLS_DIR" ]; then
  skills_count=$(find "$SKILLS_DIR" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
  skills_bytes=$(find "$SKILLS_DIR" -iname 'SKILL.md' -type f -exec cat {} + 2>/dev/null | wc -c | tr -d ' ')
fi

claude_md_bytes=0
# An empty WORKDIR (arg 7 omitted) would otherwise probe "/.claude/CLAUDE.md"
# and "/CLAUDE.md" — real filesystem paths, not "missing" ones — and
# misattribute whatever happens to live at filesystem root to this spawn.
if [ -n "$WORKDIR" ]; then
  for candidate in "$WORKDIR/.claude/CLAUDE.md" "$WORKDIR/CLAUDE.md"; do
    if [ -f "$candidate" ]; then
      claude_md_bytes=$(wc -c < "$candidate" 2>/dev/null | tr -d ' ')
      break
    fi
  done
fi

mkdir -p "$(dirname "$EVENTS_FILE")" 2>/dev/null || exit 0

python3 - "$EVENTS_FILE" "$FOLDERNAME" "$ALIAS" "$REMOTE_NAME" "$SESSION" "$TYPE" "$MODEL" "$WORKDIR" "$skills_count" "$skills_bytes" "$claude_md_bytes" <<'PYEOF' 2>/dev/null || exit 0
import json, sys, datetime

(events_file, foldername, alias, remote_name, session, typ, model, workdir,
 skills_count, skills_bytes, claude_md_bytes) = sys.argv[1:12]

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
with open(events_file, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(payload, sort_keys=True) + "\n")
PYEOF

exit 0
