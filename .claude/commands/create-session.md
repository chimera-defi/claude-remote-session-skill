Create a persistent Claude remote session using the gstack-session-spawn skill.

If the user provided a project name or folder, use that. Otherwise ask: "Which project/folder should the session run in?"

Then follow the full recipe from the gstack-session-spawn skill (SKILL.md):

1. Set FOLDERNAME to the project name (use the folder name exactly as it appears in
   /home/agents/workspace/, or /home/agents/.sessions/ for utility sessions).
2. Run `~/.local/bin/new-session <FOLDERNAME>` (auto-detects workspace/ vs .sessions/;
   pass `workspace`/`sessions` to force one, `-a/--alias <x>` for an explicit alias). If
   the script is missing, install it by copying `scripts/new-session.sh` to
   `~/.local/bin/new-session` (`chmod +x`) so it's available for future spawns too. Only
   if that isn't possible, fall back to the one-off manual recipe in
   `references/fallback-recipe.md` — it spawns a single session but does **not** install
   the helper, so don't treat it as "recreating" `new-session`.
3. Pre-accept trust for WORKDIR in ~/.claude.json.
4. Verify with: tmux list-sessions | grep ah_

The script derives the session name (`ah_<alias>-<MMDD-HHMM>` / `ah-<alias>-<MMDD-HHMM>`)
via the `session-alias` helper, resolves the git-aware run directory via
`session-git-prep`, and enables + starts the systemd unit itself.

After success, tell the user:
- The remote-control name to connect with (`ah-<alias>-<MMDD-HHMM>`, printed by the script)
- That it appears in Claude Code app → Remote sessions

Scripts are local-only (`~/.local/bin/`, `~/.config/systemd/user/`) — do NOT commit them
to any repo.

Full recipe is in ~/.claude/skills/gstack-session-spawn/SKILL.md
