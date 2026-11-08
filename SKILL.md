---
name: gstack-session-spawn
description: "Use to start, message, list, restart or retire long-lived Claude sessions on this host (tmux + Remote Control, visible in the Claude app). Triggers: spawn a session, new session for <repo>, send/hand this to <session>, restart the fleet, reap a finished session."
---

# crss: long-lived Claude sessions

One script, `crss`, runs every long-lived session on this host. Each session is a tmux session
named `ah_NAME` running `claude --remote-control ah-NAME` in a restart loop. It shows in the Claude
app under Remote sessions as `ah-NAME` and comes back after a crash or reboot.

State is one small file per session, `~/.local/state/crss/NAME.env`: folder, launch arguments and
conversation id. There is no registry and there are no per-session units. `crss-up.timer` (every 5
minutes) and `crss-up.service` (at boot) start any session whose file exists and whose tmux session
does not.

## Commands

```bash
crss spawn NAME DIR [--model M] [--worktree] [--brief FILE] [-- extra claude args]
crss send NAME "text"            # or: crss send NAME --file brief.md
crss ls [--json]                 # name, status (idle|busy|shell|waiting|down|?), version, conversation id, folder;
                                 # also lists ah_* sessions started by other tools: send reaches them, restart and reap don't
crss restart NAME... | --all [--wait-idle]
crss up [NAME...]                # start what should be running and isn't
crss reap NAME [--force]
```

- **spawn**
  - Names are lowercase letters, digits and dashes.
  - `--worktree` makes `~/.claude/worktrees/NAME` on branch `session/NAME` from `origin/main`. Use it
    for any session that will commit in a shared repo.
  - `--brief` is the first prompt. Write it as a finish line, a stop rule and the anti-patterns that
    apply, not as steps (`handoff/references/massaging.md`).
  - Launch arguments start from `CRSS_DEFAULT_ARGS` in `~/.config/crss/crss.env`. Add `--effort`,
    `--advisor`, `--disallowedTools` and the like after `--`.
  - Model: `--model claude-opus-5-5 -- --effort medium` for orchestrators, `--model sonnet` for
    builders, `--model haiku` for sweeps.
- **send** pastes the text as one message and presses Enter. Status comes from Claude's own session
  record:
  - `delivered` (exit 0): the session went from idle to busy.
  - `queued` (exit 0): it was already busy, so Claude queued the message.
  - `UNVERIFIED` (exit 1): nothing changed. Look at the pane (`tmux capture-pane -p -t =ah_NAME:`)
    before resending.
  - Refused (exit 2): no such session, the session is down or starting, or a dialog is open
    (status `waiting`).
- **restart**
  - Moves sessions onto the installed `claude` binary and keeps the conversation.
  - Skips busy sessions unless you pass `--wait-idle`.
  - Skips a session with in-session scheduled tasks, because exiting would stop them.
  - After a batch restart, tell each session that its wakeups and crons died with the old process.
- **reap**
  - Refuses a busy session unless you pass `--force`.
  - Removes the session's worktree only when it has no uncommitted and no unpushed work. Ignored
    files are archived to `~/backups/reaped-worktree-ignored/` first.
  - Never deletes a branch.

## Handing work to another session

1. If a live session already owns the area (`crss ls`), `crss send` it the brief.
2. Otherwise `crss spawn` a new one with `--brief`.
3. Check the result yourself: a session's report is a claim, not proof.

Before relaying a big task, check how big the target already is. If it is bloated, send it
`/compact` first, or spawn a fresh session. The full routing judgment is in the `handoff` skill.

## Old command names

`new-session`, `session-send`, `session-handoff ready` and `session-doctor reap|opus-subagents` are
kept as symlinks to `crss-compat` (`session-preserve` only says it is retired). They exist only for callers outside this
repo: the bus router, `spawn_orchestrator.sh`, `bus-request-watchdog` and `env-refresh`. They accept
tmux (`ah_NAME`) or phone (`ah-NAME`) names. Don't use them in new work.

## What not to do

- Don't hand-roll tmux sessions or systemd units for agents. `crss spawn` is the only path, so
  `ls`, `up` and `reap` see every session.
- Don't `tmux kill-session` a session you mean to retire. Its state file brings it back within 5
  minutes. Use `crss reap`.
- Don't delete `session/*` branches to clean up. The branch is what keeps a reaped session's commits
  reachable.
- Don't run `git worktree remove` by hand on a session worktree. It deletes ignored files (an
  `artifacts/` folder was lost this way).

## Setup

```bash
install -m 755 scripts/crss.sh ~/.local/bin/crss
install -m 755 scripts/crss-compat.sh ~/.local/bin/crss-compat   # only if old callers exist
install -m 644 systemd/crss-up.service systemd/crss-up.timer ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now crss-up.timer
loginctl enable-linger "$USER"   # so sessions start at boot without a login
```

`~/.config/crss/crss.env` is sourced by `crss` and holds host defaults, for example:

```bash
CRSS_DEFAULT_ARGS="--dangerously-skip-permissions --exclude-dynamic-system-prompt-sections"
export CLAUDE_CODE_AUTO_COMPACT_WINDOW=234000
```

## Native Claude Code features to prefer

- Between Claude sessions, the SendMessage tool with `to: "uds:<socket>"` delivers directly. The
  socket is `messagingSocketPath` in `~/.claude/sessions/<pid>.json`.
- `claude --bg` background sessions (`claude agents`, `respawn`, `rm`) can replace crss once three
  things are confirmed: a script can send to them, they show on the phone, and they come back after a
  reboot. Until then, the fleet stays on crss.
