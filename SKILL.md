---
name: gstack-session-spawn
description: "Use to start, message, list, restart or retire long-lived Claude sessions on this host (tmux + Remote Control, visible in the Claude app). Triggers: spawn a session, new session for <repo>, send/hand this to <session>, restart the fleet, reap a finished session."
---

# crss: long-lived Claude sessions

One script, `crss`, runs every long-lived session. Each is a tmux session `ah_NAME` running
`claude --remote-control` in a restart loop; it shows in the Claude app under Remote sessions
and comes back after a crash or reboot.

State is one file per session, `~/.local/state/crss/NAME.env` (folder, launch arguments,
conversation id). No registry, no per-session units: `crss-up.timer` runs
`crss up` at boot and every 5 minutes; it starts any session whose file exists and whose tmux
session doesn't.

## Commands

```bash
crss spawn NAME DIR [--model M] [--effort E] [--title T] [--worktree] [--brief FILE] [-- extra claude args]
crss send NAME "text"            # or: crss send NAME --file brief.md
crss ls [NAME...] [--json]       # name, status (idle|busy|shell|parked|waiting|down|?), version, conversation id, folder, title; exit 2 if a NAME is no session. `--json` adds `by`: who spawned it (a session NAME or title, else the raw id; empty if unknown)
crss peek NAME [LINES]           # "NAME STATUS TITLE" line + last LINES (30) non-blank pane lines; exit 2 if no such session
crss wait NAME... [--timeout S]  # until each is idle or parked, on a dialog, or down; exit 0 all idle or parked, 1 timeout, 2 other (a NAME that is no session is refused at once)
crss restart NAME... | --all [--wait-idle]
crss up [NAME...]                # start what should be running and isn't
crss reap NAME [--force]
```

**Names:** NAME is for `crss` and tmux (`ah_NAME`). In the app, a session is listed by its
title. By default Claude titles each session itself (`crss ls` shows the title in its last
column), and the title survives `crss restart`. `--title T` sets the first title; `CRSS_NAMES=plain` (config file or environment, read
at spawn) names it `ah-NAME` instead. Sessions spawned before this keep `ah-NAME`. Rename a live
one: `crss send NAME "/rename New title"`. On an `ah-NAME` session the rename lasts until its next
restart; to keep it, add the line `NAMES=auto` to its state file first (a loop started by an older
`crss` reads that line only after its tmux session is recreated). `crss SUB --help` prints usage.

Use `crss wait` and `crss peek` instead of a sleep loop or a raw `tmux capture-pane`. Idle means the
turn ended (and, for a session spawned with `--brief`, that the brief was sent), not that the task
is done: read the report or the result before you rely on it. `parked` is a finished turn that
left a background command running (a waiter): `wait` counts it as done, and a message sent to it
starts a turn at once.

`crss ls` also lists `ah_*` sessions started by other tools: `send` reaches them, `restart` and
`reap` don't.

- **spawn:** NAME is lowercase letters, digits and dashes. `--worktree` makes
  `~/.claude/worktrees/NAME` on branch `session/NAME` from `origin/main` (from `HEAD` when the repo
  has no `origin/main`); use it for any session that commits in a shared repo. `--brief` is the first prompt: a finish line, a stop rule and the
  anti-patterns that apply, not steps (`handoff/SKILL.md`). Launch arguments start from
  `CRSS_DEFAULT_ARGS` in `~/.config/crss/crss.env`; `--model` and `--effort` are spawn flags, other
  claude flags (`--advisor`, `--disallowedTools`) go after `--`, for example
  `--model sonnet --effort low -- --advisor claude-opus-5-5` (choosing a model:
  `references/spawn-guide.md`; env knobs: `examples/crss-overlay/README.md#env-knobs`).
- **send** pastes the text as one message and presses Enter; status comes from Claude's session
  record. `delivered` (exit 0): idle or parked went to busy or shell, a `/rename T` shows as the title, the conversation id changed (as after `/clear`), or a local slash command such as `/mcp ...` wrote to the transcript (its output line follows, indented). `queued` (0): it was busy or running a shell
  command. `UNVERIFIED` (1): nothing changed; `crss peek NAME` before resending. Refused
  (2): no such session, down or starting, or a dialog is open (`waiting`).
- **restart** moves sessions onto the installed `claude` and keeps the conversation. It skips busy
  sessions unless `--wait-idle`, and skips a parked one or one with in-session scheduled tasks (exiting would stop
  them): ask a parked session to stop its background command first. After a batch, tell each session its wakeups and crons died with the old process. Run
  `crss restart --all --wait-idle` after `claude update`; an install alone doesn't touch running
  sessions. `/clear` and in-TUI `/resume` change the conversation id; `crss ls` and `crss up` follow it.
- **reap** refuses a busy session unless `--force`, removes the worktree only when nothing is
  uncommitted or unpushed (ignored files are archived to `~/backups/reaped-worktree-ignored/`
  first; over 2 GB of them keeps the worktree), and never deletes a branch.

## Handing work to another session

If a live session owns the area (`crss ls`), `crss send` it the brief; otherwise `crss spawn` with
`--brief`. Check the result yourself: a report is a claim, not proof. Check the target's size before
you send ([troubleshooting](references/troubleshooting.md#compact-or-recycle)). Routing judgment: the
`handoff` skill.

## Old command names

`new-session`, `session-send`, `session-handoff ready`, `session-doctor reap` and `session-preserve`
(retired: it only prints a notice) are symlinks to `crss-compat` for outside callers. They accept
`ah_NAME` or `ah-NAME`. Don't use them in new work.

## What not to do

- Don't hand-roll tmux sessions or systemd units for agents; only `crss spawn` writes the state
  file that `up`, `restart` and `reap` need.
- Don't `tmux kill-session` a session you mean to retire: its state file brings it back within 5
  minutes. Use `crss reap`.
- Don't delete `session/*` branches or run `git worktree remove` on a session worktree
  ([why](references/troubleshooting.md#compact-or-recycle)).

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

Between Claude sessions on one machine, the SendMessage tool with `to: "uds:<socket>"` delivers
directly (the socket is `messagingSocketPath` in `~/.claude/sessions/<pid>.json`). `claude --bg` could replace
crss once a script can send to it, it shows on the phone, and it survives a reboot.
