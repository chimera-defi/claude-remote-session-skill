# Troubleshooting

For a silent session run `crss ls`, then `tmux capture-pane -p -t =ah_NAME:` and match the shape:

| Pane or status | Shape | Section |
|---|---|---|
| `/clear to save NNNk tokens`, long idle | bloat | [Compact or recycle](#compact-or-recycle) |
| `UserPromptSubmit operation blocked by hook` | hook wedge | [Hook wedge](#hook-wedge) |
| numbered options, `↑/↓ to navigate`, trust dialog; `crss ls` says `waiting` | stuck on a menu | [Menu](#stuck-on-a-menu) |
| `crss ls` says `?` | tmux up, claude starting or in crash backoff (up to 300 s) | wait; `crss up` does nothing |
| `crss ls` says `down` | tmux session gone | `crss up NAME` |
| every session silent, `Login expired` | dead login | [Dead login](#dead-login) |

## Compact or recycle

- **Compact:** `crss send NAME "/compact"` only when the status is `idle` (a busy session queues it
  mid-workflow). Judge completion by the transcript's `type:"system"` entry with
  `subtype:"compact_boundary"`, not by pane text.
- **Not under about 60 minutes idle.** The prompt cache has a 1-hour sliding TTL; inside it a
  resume reads the cache at about 0.1x, so compacting then is the most expensive moment. Compact
  lazily, when someone is about to message a stale session.
- **Recycle:** commit what should survive (`git -C DIR add -A && git -C DIR commit -m "WIP: before recycle"`),
  `crss reap NAME`, `crss spawn NAME-2 DIR --brief next-brief.md`. Put the prior branch and
  in-progress work in the brief. A `--worktree` name stays taken while its `session/NAME` branch exists.
- **Before reaping a session in a plain folder** (reap only guards worktrees), check `git status`,
  `git log HEAD --not --remotes`, `git remote` and untracked files yourself. Never judge pushed work
  with `git log @{u}..`.
- **Don't paste onto a draft.** An idle prompt can hold an unsent draft or dim autosuggest text;
  `tmux capture-pane -p -e` shows dim as `ESC[2m` (placeholder, safe) versus real text.
  `crss send` checks status only, not the input box.

### Auto-compact

Settings `autoCompactEnabled` and `autoCompactWindow`, flag `--autocompact`, in-session
`/autocompact`. If the host's `~/.claude/settings.json` `env` sets `CLAUDE_CODE_AUTO_COMPACT_WINDOW`,
the flag and `--settings` forms are ignored; only the same variable exported in the launch
environment wins. For crss sessions export it in `~/.config/crss/crss.env`; it applies after
`crss restart`. `effectiveWindow` is the window minus 20000. Check any figure with
`claude -p ok -d config,settings,compact --debug-file F`, then `grep effectiveWindow F`.

## Hook wedge

A `UserPromptSubmit` or `PreToolUse` hook that throws (missing script, no fail-open guard) rejects
every prompt or tool call; resending cannot help. `crss ls` may show `idle` while `crss send` says
`UNVERIFIED`. Diagnose: `cat <rundir>/.claude/settings.json`. Recover: copy out the session's work
from its folder, `crss reap NAME`, respawn with a brief carrying the branch and task list. Hooks on
those two events must fail open (`[ -x script ] && script || exit 0`).

## Stuck on a menu

`crss send` refuses a `waiting` session because pasted text plus Enter would answer the dialog.
Recover without a reap: `tmux send-keys -t =ah_NAME: Down` and re-capture to prove the widget is
live; move to the wanted option (`Enter` toggles a checkbox, it does not submit); `Right` to
Submit, then `Enter` ("1. Submit answers"). Re-capture after each key.

The workspace-trust dialog is also `waiting`, and its default is "No, exit" (CLI 2.1.285). crss
pre-accepts trust before each launch (`trust` in `scripts/crss.sh`, pinned by `tests/test-crss.sh`)
and prints `could not pre-trust` if it can't.

## A new session never appears on the phone

Remote Control registers only when `ANTHROPIC_BASE_URL` is absent or on `api.anthropic.com`; a proxy
base URL silently disables it. Launch with a small `--settings` file setting
`{"env":{"ANTHROPIC_BASE_URL":"https://api.anthropic.com"}}` via `CRSS_DEFAULT_ARGS`. Pass exactly
one `--settings` flag: a later one replaces an earlier one. Check the live process carries it
(`ps`). Lane-wide `permissions.deny` entries go in that same file.

A session started from the phone is not a crss session (no tmux, env file or restart loop). For
anything long-lived, run `crss spawn` from it. To start sessions from the phone, run one
`claude remote-control --name N --spawn worktree --capacity 4` per directory under a unit that
survives logout; check `claude remote-control --help` for current flags.

## Prompt suggestions missing in the app

- The suggestion is a model call that stays silent when the next step is not obvious; check the TUI
  line first (`tmux capture-pane -e`, dim `ESC[2m` on the `❯` line).
- **Back-off:** after 20 unused suggestions in one interactive process the CLI writes
  `promptSuggestionUnusedStreak: 20` to `~/.claude.json` and stops suggesting, host-wide. Unattended
  `--remote-control` sessions feed it. Check `jq .promptSuggestionUnusedStreak ~/.claude.json`;
  reset it to 0 after a backup.
- To keep unattended sessions out of the counter, pass a `--settings` file whose `env` sets
  `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION` to `"0"` through `CRSS_DEFAULT_ARGS`. Don't add
  `--prompt-suggestions` (print mode only). Takes effect on `crss restart`.

## Dead login

Sessions share `~/.claude/.credentials.json`. When the refresh token dies, every session fails
after the access token expires, and idle sessions log nothing. Exact errors: `Failed to
authenticate: OAuth session expired and could not be refreshed` and `Login expired · Please run
/login`. Detect by grepping recent transcripts (`~/.claude/projects/*/*.jsonl`) for those strings;
never read the credentials file. `crss ls` looks healthy in this state. Fix: the operator runs
`/login` once in any `claude` pane; then `crss send NAME "login restored; continue"` to each stalled
lane. A spend-limit stop (`You've hit your monthly spend limit`) is different and recovers when the
limit is raised.
