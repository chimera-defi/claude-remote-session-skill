---
name: gstack-session-spawn
description: "Use to start, message, list, restart or retire long-lived Claude sessions on this host (tmux + Remote Control, visible in the Claude app). Triggers: spawn a session, new session for <repo>, send/hand this to <session>, restart the fleet, reap a finished session."
---

# crss: long-lived Claude sessions

One script, `crss`, runs every long-lived session. Each is a tmux session `ah_NAME` running
`claude --remote-control ah-NAME` in a restart loop; it shows in the Claude app under Remote
sessions as `ah-NAME` and comes back after a crash or reboot.

State is one file per session, `~/.local/state/crss/NAME.env` (folder, launch arguments,
conversation id). No registry, no per-session units: `crss-up.timer` (every 5 minutes) and
`crss-up.service` (at boot) start any session whose file exists and whose tmux session doesn't.

## Commands

```bash
crss spawn NAME DIR [--model M] [--worktree] [--brief FILE] [-- extra claude args]
crss send NAME "text"            # or: crss send NAME --file brief.md
crss ls [--json]                 # name, status (idle|busy|shell|waiting|down|?), version, conversation id, folder
crss restart NAME... | --all [--wait-idle]
crss up [NAME...]                # start what should be running and isn't
crss reap NAME [--force]
```

`crss ls` also lists `ah_*` sessions started by other tools: `send` reaches them, `restart` and
`reap` don't.

- **spawn:** NAME is lowercase letters, digits and dashes. `--worktree` makes
  `~/.claude/worktrees/NAME` on branch `session/NAME` from `origin/main`; use it for any session
  that commits in a shared repo. `--brief` is the first prompt: a finish line, a stop rule and the
  anti-patterns that apply, not steps (`handoff/SKILL.md`). Launch arguments start from
  `CRSS_DEFAULT_ARGS` in `~/.config/crss/crss.env`; add `--effort`, `--advisor`,
  `--disallowedTools` after `--`. Models: `--model claude-opus-5-5 -- --effort medium` for
  orchestrators, `sonnet` for builders, `haiku` for sweeps (`references/spawn-guide.md`).
- **send** pastes the text as one message and presses Enter; status comes from Claude's session
  record. `delivered` (exit 0): idle went to busy. `queued` (0): it was busy. `UNVERIFIED` (1):
  nothing changed; read the pane (`tmux capture-pane -p -t =ah_NAME:`) before resending. Refused
  (2): no such session, down or starting, or a dialog is open (`waiting`).
- **restart** moves sessions onto the installed `claude` and keeps the conversation. It skips busy
  sessions unless `--wait-idle`, and skips one with in-session scheduled tasks (exiting would stop
  them). After a batch, tell each session its wakeups and crons died with the old process. Run
  `crss restart --all --wait-idle` after `claude update`; an install alone doesn't touch running
  sessions. `/clear` and in-TUI `/resume` change the conversation id; `crss ls` and `crss up` follow it.
- **reap** refuses a busy session unless `--force`, removes the worktree only when nothing is
  uncommitted or unpushed (ignored files are archived to `~/backups/reaped-worktree-ignored/`
  first; over 2 GB of them keeps the worktree), and never deletes a branch.

## Handing work to another session

If a live session owns the area (`crss ls`), `crss send` it the brief; otherwise `crss spawn` with
`--brief`. Check the result yourself: a report is a claim, not proof. Check the target's size first
and `/compact` or respawn if bloated. Routing judgment: the `handoff` skill.

## Old command names

`new-session`, `session-send`, `session-handoff ready` and `session-doctor reap` are symlinks to
`crss-compat` for callers outside this repo (the bus router). They accept `ah_NAME` or `ah-NAME`.
Don't use them in new work.

## What not to do

- Don't hand-roll tmux sessions or systemd units for agents; only `crss spawn` is seen by `ls`,
  `up` and `reap`.
- Don't `tmux kill-session` a session you mean to retire: its state file brings it back within 5
  minutes. Use `crss reap`.
- Don't delete `session/*` branches, and don't run `git worktree remove` on a session worktree
  (it deletes ignored files).

## Setup

```bash
install -m 755 scripts/crss.sh ~/.local/bin/crss
install -m 755 scripts/crss-compat.sh ~/.local/bin/crss-compat   # only if old callers exist
install -m 644 systemd/crss-up.service systemd/crss-up.timer ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now crss-up.timer
loginctl enable-linger "$USER"   # start at boot without a login
```

`~/.config/crss/crss.env` is sourced by `crss`, for example:

```bash
CRSS_DEFAULT_ARGS="--dangerously-skip-permissions --exclude-dynamic-system-prompt-sections"
export CLAUDE_CODE_AUTO_COMPACT_WINDOW=234000
```

Between Claude sessions, the SendMessage tool with `to: "uds:<socket>"` delivers directly (the
socket is `messagingSocketPath` in `~/.claude/sessions/<pid>.json`). `claude --bg` could replace
crss once a script can send to it, it shows on the phone, and it survives a reboot.
