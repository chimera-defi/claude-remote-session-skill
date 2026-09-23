Create a persistent Claude remote session using the gstack-session-spawn skill.

If the user provided a project name or folder, use that. Otherwise ask: "Which project/folder should the session run in?"

Follow the full recipe in `~/.claude/skills/gstack-session-spawn/SKILL.md` (or this repo's `SKILL.md`):

1. Set FOLDERNAME to the project name (use the folder name exactly as it appears in `/home/agents/workspace/` or `/home/agents/.sessions/`).
2. Run the `new-session` script for the whole recipe in one Bash call:
   ```bash
   new-session "$FOLDERNAME"              # auto-detects workspace/ vs .sessions/
   ```
   If `~/.local/bin/new-session` is missing, install it from `scripts/new-session.sh` (copy to `~/.local/bin/new-session`, `chmod +x`) and re-run the command above — do not hand-roll the start script/systemd unit inline; the script already handles aliasing (`session-alias`), git-aware run-dir resolution (`session-git-prep`), sentinel-file/backoff logic, and the first-party `ANTHROPIC_BASE_URL` settings override. Only if the repo itself is unavailable, fall back to the one-off manual recipe in `references/fallback-recipe.md` (paste its whole block in a single Bash call) — that file documents exactly what the reduced last resort drops vs. the installed script.
   If the user also gave the session something to do, pass it in the same call with `--task "..."` (or `--task-file <path>`) rather than typing it into the pane afterwards — `--task` waits for the session to be ready and verifies the message landed. Shape the task per `handoff/references/massaging.md`: a checkable finish line, a stop rule, concrete anti-patterns.
3. The script prints the resolved `REMOTE_NAME` (`ah-<alias>-<MMDD-HHMM>`) and enables + starts the systemd unit.

You're done when `systemctl --user is-active "$REMOTE_NAME.service"` prints `active` and, if you passed `--task`, the script printed `Task sent to … and verified landed.` On `WARNING: task send UNVERIFIED`, capture the pane (`tmux capture-pane -p -t ah_<alias>-<MMDD-HHMM>`) and resend with `session-send` if the task isn't there — this happens often enough on first send that it isn't an edge case. If either check fails, say so — don't report success.

After success, tell the user:
- The remote-control name to connect with (`ah-<alias>-<MMDD-HHMM>`, printed by the script)
- That it appears in Claude Code app → Remote sessions

Do NOT commit the generated scripts anywhere — per `SKILL.md`, they are local-only (`~/.local/bin/`, `~/.config/systemd/user/`), not repo artifacts.

Full recipe is in `~/.claude/skills/gstack-session-spawn/SKILL.md`.
