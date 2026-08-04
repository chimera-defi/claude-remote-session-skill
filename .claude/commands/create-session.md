Create a persistent Claude remote session using the gstack-session-spawn skill.

If the user provided a project name or folder, use that. Otherwise ask: "Which project/folder should the session run in?"

Follow the full recipe in `~/.claude/skills/gstack-session-spawn/SKILL.md` (or, if that skill isn't installed, `references/fallback-recipe.md` / `scripts/new-session.sh` in this repo). Do not hand-derive the session name, start script, or systemd unit here — the naming convention (alias resolution, `ah-<alias>-<MMDD-HHMM>`), git-aware run directory, and remote-control settings are implemented and maintained in `new-session.sh`, and duplicating that logic inline drifts out of sync with it.

1. Set FOLDERNAME to the project name (use the folder name exactly as it appears in `/home/agents/workspace/`).
2. Run `new-session <FOLDERNAME>` (add `workspace` or `sessions` to force the type; `-a/--alias <x>` for an explicit alias).
3. Verify with the `tmux list-sessions` output the script prints.

After success, tell the user:
- The remote-control name to connect with (printed by the script as `ah-<alias>-<MMDD-HHMM>`).
- That it appears in Claude Code app → Remote sessions.

Scripts are local-only (`~/.local/bin/`, `~/.config/systemd/user/`) — do not commit them to any repo.
