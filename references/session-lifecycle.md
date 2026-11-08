# Session lifecycle: start, restart, reap

A crss session has three pieces, and `crss` manages all of them:

| Piece | Where | Cleaned by |
|---|---|---|
| env file | `~/.local/state/crss/NAME.env` (folder, launch arguments, conversation id) | `crss reap` |
| tmux session | `ah_NAME` on the host | `crss reap` (it kills it) |
| git worktree | `~/.claude/worktrees/NAME`, branch `session/NAME`, only for `--worktree` spawns | `crss reap`, when clean |

There are no per-session systemd units. `crss-up.timer` (every 5 minutes) and `crss-up.service`
(at boot) run `crss up`, which restarts any session that has an env file but no tmux session.
That is why `tmux kill-session` does not retire a session: the env file brings it back.

Claude's own registry of Remote Control sessions (org-wide, all devices) is separate and not
managed by crss. A crashed or rebooted session can leave a disconnected or zombie entry there;
removing one is a manual step in the Claude app or API, not part of `reap`.

## Reap

`crss reap NAME [--force]` is the only teardown. Its safety rules are the code in `cmd_reap`
(`scripts/crss.sh`), pinned by `tests/test-crss.sh`; `SKILL.md` lists what it refuses and keeps.
The lessons behind them:

- Before any reap, look at on-disk state yourself (`git status`, untracked files, `git worktree
  list`); a tool's "nothing to preserve" verdict once measured the wrong thing.
- Never judge pushed work with `git log @{u}..`: with no upstream it prints nothing. Use
  `git log HEAD --not --remotes` and check `git remote`; with no remote the branch refs are the
  only copy.
- Keep `session/*` and research branches. Deleting the ref is what orphans commits; reaping the
  session or its worktree does not.
- A hand-run `git worktree remove` deletes gitignored results (a research `artifacts/` folder was
  lost this way). `crss reap` archives them to `~/backups/reaped-worktree-ignored/` first.
- A worktree reap keeps (does not remove) when it has uncommitted files, commits on no remote, or
  more than 2 GB of ignored files. Leftover worktrees from sessions reaped before this are cleaned
  by hand, after checking each one's work is merged, pushed or unneeded.
- A respawn after a bloated or wedged session starts from a fresh worktree. Put the prior branch,
  transcript path and in-progress work in the kickoff so nothing is re-derived.

## Restart and resume

`crss restart NAME... | --all [--wait-idle]` sends `/exit`; the loop in the pane relaunches
`claude --resume <conversation id>`, so the conversation survives and the process moves onto the
installed binary. `crss ls` shows each session's version. Installing a new `claude` does not touch
running sessions.

After a fleet restart:

1. Read the output line per session: `skipped, busy` (rerun with `--wait-idle`), `skipped, waiting
   on a dialog`, `skipped: has scheduled tasks` (exiting would stop them), or `restart not
   confirmed`.
2. Tell each restarted session that its wakeups and crons died with the old process.

A session that is down (`crss ls` shows `down`) comes back with `crss up NAME`, which resumes the
same conversation id. `/clear` and in-TUI `/resume` change the id; `crss ls` and `crss up` follow
the live record and update the env file.

Why not relaunch by hand: a hand-launched session lacks the launch arguments (such as
`--dangerously-skip-permissions`), may run a different binary, and has no loop, so it stalls on
approval prompts. A bare restart of an externally killed session also used to start a fresh
conversation instead of resuming.

## Cadence

1. Weekly: `crss ls`; reap what is finished. Reap a finished session when its report lands.
2. After a host reboot: the timer restarts what should run. Check `crss ls` for `down`, and expect
   stale Remote Control registry entries for the sessions that died.
3. After `claude update`: `crss restart --all --wait-idle`.

## A new session never appears on the phone

The Remote Control bridge only enables when `ANTHROPIC_BASE_URL` is absent or its host is
`api.anthropic.com`; a proxy base URL (for example a local `127.0.0.1` proxy) silently disables
registration. See [troubleshooting](troubleshooting.md#a-new-session-never-appears-on-the-phone).
