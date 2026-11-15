Create a persistent Claude remote session with `crss` (the gstack-session-spawn skill).

If the user named a project or folder, use it. Otherwise ask which folder the session should run in.

1. Pick a NAME: lowercase letters, digits and dashes, short enough to read on a phone.
2. If the user also gave the session a task, write it to a file as a brief: a checkable finish
   line, a stop rule, and the anti-patterns that apply (`handoff/SKILL.md`).
3. Spawn in one Bash call. Add `--worktree` when the folder is a shared git repo the session will
   commit in:
   ```bash
   crss spawn NAME DIR --model sonnet [--worktree] [--brief FILE]
   # examples: planner: --model opus --effort medium; sweeps: --model haiku --effort low
   # add --title "short task name" for a first title; otherwise Claude titles the session
   ```
   If `crss` is not on `PATH`, install it from this repo: `install -m 755 scripts/crss.sh ~/.local/bin/crss`.
   Do not hand-roll a tmux session or a systemd unit.

You are done when `crss ls NAME` shows `idle`, `busy` or `shell` with a version and a session id
(`crss wait NAME --timeout 60` waits for idle). If it still shows `?` (tmux up, no
live claude) after a minute, run `crss peek NAME` and say what the pane shows. If it shows `down`
(no tmux session, so nothing to peek), run `crss up NAME` and check again. Don't report success
until the first check holds.

Then tell the user to connect from Claude Code → Remote sessions. The session is listed under the
title in `crss ls`, or `ah-NAME` when `CRSS_NAMES=plain`.
