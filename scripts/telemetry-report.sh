#!/usr/bin/env bash
# telemetry-report.sh — summarize artifacts/telemetry/events.jsonl: spawn
# count and the global-skills-catalog size trend (the context-bloat proxy
# record-spawn-telemetry.sh captures on every spawn).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# See record-spawn-telemetry.sh for why the fallback is a hardcoded canonical
# path rather than a path derived from $SCRIPT_DIR: this script is also
# deployed as a flat copy to ~/.local/bin, where git rev-parse has nothing to
# find and a derived fallback silently points at the wrong directory.
REPO_ROOT="${TELEMETRY_ROOT:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo /home/agents/workspace/claude-remote-session-skill)}"
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
