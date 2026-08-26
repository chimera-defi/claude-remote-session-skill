Create a persistent Claude remote session using the gstack-session-spawn skill.

If the user provided a project name or folder, use that. Otherwise ask: "Which project/folder should the session run in?"

Follow the full recipe in `~/.claude/skills/gstack-session-spawn/SKILL.md` (or this repo's `SKILL.md`):

1. Set FOLDERNAME to the project name (use the folder name exactly as it appears in `/home/agents/workspace/` or `/home/agents/.sessions/`).
2. Run the `new-session` script for the whole recipe in one Bash call:
   ```bash
   new-session "$FOLDERNAME"              # auto-detects workspace/ vs .sessions/
   ```
   If `~/.local/bin/new-session` is missing, install it from `scripts/new-session.sh` (copy to `~/.local/bin/new-session`, `chmod +x`) and re-run the command above — do not hand-roll the start script/systemd unit inline; the script already handles aliasing (`session-alias`), git-aware run-dir resolution (`session-git-prep`), sentinel-file/backoff logic, and the first-party `ANTHROPIC_BASE_URL` settings override. Only if the repo itself is unavailable, fall back to the one-off manual recipe in `references/fallback-recipe.md` (paste its whole block in a single Bash call) — that file documents exactly what the reduced last resort drops vs. the installed script.
3. The script prints the resolved `REMOTE_NAME` (`ah-<alias>-<MMDD-HHMM>`) and enables + starts the systemd unit.

After success, tell the user:
- The remote-control name to connect with (`ah-<alias>-<MMDD-HHMM>`, printed by the script)
- That it appears in Claude Code app → Remote sessions

Do NOT commit the generated scripts anywhere — per `SKILL.md`, they are local-only (`~/.local/bin/`, `~/.config/systemd/user/`), not repo artifacts.

Full recipe is in `~/.claude/skills/gstack-session-spawn/SKILL.md`.
