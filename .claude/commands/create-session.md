Create a persistent Claude remote session with `crss` (the gstack-session-spawn skill).

If the user named a project or folder, use it. Otherwise ask which folder the session should run in.

1. Pick a NAME: lowercase letters, digits and dashes, short enough to read on a phone.
2. If the user also gave the session a task, write it to a file as a brief: a checkable finish
   line, a stop rule, and the anti-patterns that apply (`handoff/SKILL.md`).
3. Spawn in one Bash call. Add `--worktree` when the folder is a shared git repo the session will
   commit in:
   ```bash
   crss spawn NAME DIR --model sonnet [--worktree] [--brief FILE]
   # orchestrator: --model claude-opus-5-5 -- --effort medium; sweeps: --model haiku
   ```
   If `crss` is not on `PATH`, install it from this repo: `install -m 755 scripts/crss.sh ~/.local/bin/crss`.
   Do not hand-roll a tmux session or a systemd unit.

You are done when `crss ls` shows NAME as `idle`, `busy` or `shell` with a version and a session id. If it
shows `down` or `?` (no live claude) after a minute, look at the pane (`tmux capture-pane -p -t =ah_NAME:`)
and say what failed. Don't report success.

Then tell the user to connect from Claude Code → Remote sessions → `ah-NAME`.
