Create a persistent Claude remote session using the gstack-session-spawn skill.

If the user provided a project name or folder, use that. Otherwise ask: "Which project/folder should the session run in?"

Then follow the full recipe from the gstack-session-spawn skill (see `SKILL.md`):

1. Set FOLDERNAME to the project name (use the folder name exactly as it appears in `/home/agents/workspace/` or `/home/agents/.sessions/`).
2. Run `new-session <FOLDERNAME>` (auto-detects `workspace/` vs `.sessions/`; pass `workspace` or `sessions` to force one, `--alias <x>` for an explicit short alias). This resolves the alias via `session-alias`, generates the `MMDD-HHMM` id, prepares the git run directory via `session-git-prep`, writes the start script + systemd unit, and enables + starts the service — all in one call.
3. If `~/.local/bin/new-session` is missing, use `references/fallback-recipe.md` instead.

After success, tell the user:
- The remote-control name to connect with (`ah-<alias>-<MMDD-HHMM>`, printed by the script)
- That it appears in Claude Code app → Remote sessions

Scripts are local-only (`~/.local/bin/`, `~/.config/systemd/user/`) — never commit them to a repo.

Full recipe is in `~/.claude/skills/gstack-session-spawn/SKILL.md`.
