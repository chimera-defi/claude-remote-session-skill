# claude-remote-session-skill

A [gstack](https://github.com/garrytan/gstack)-compatible Claude Code skill for long-lived Claude
sessions on a Linux host. You can reach each session from any device (phone, desktop, browser)
through Claude Code Remote Control.

The whole tool is one script, `scripts/crss.sh`, of about 300 lines:

- Each session is a tmux session `ah_NAME` running `claude --remote-control ah-NAME` in a restart
  loop. A crash within 30 s of start backs off 300 s; any other exit restarts after 5 s.
- The loop resumes the same conversation id after a crash, a restart or a reboot.
- State is one env file per session in `~/.local/state/crss/`.
- `crss-up.timer` (every 5 minutes) and `crss-up.service` (at boot) start any session that should
  be running and isn't.

```bash
crss spawn my-lane ~/workspace/my-repo --model sonnet --worktree --brief brief.md
crss send my-lane --file next-task.md     # delivered | queued (exit 0), UNVERIFIED (1), refused (2)
crss ls
crss restart --all --wait-idle            # onto a new claude binary, same conversations
crss reap my-lane                         # keeps any worktree with unpushed or uncommitted work
```

The commands, the send receipts and the safety rules are in [`SKILL.md`](SKILL.md).

## Requirements

- Linux with systemd user services (`loginctl enable-linger "$USER"` for start at boot)
- tmux, jq, git
- Claude Code CLI (`claude`) on `PATH`

## Install

```bash
git clone https://github.com/chimera-defi/claude-remote-session-skill.git
ln -sf "$PWD/claude-remote-session-skill" ~/.claude/skills/gstack-session-spawn
```

Then install the script and the timer as described in `SKILL.md`, under "Setup".

## Connect

Claude Code on any device → Remote sessions → `ah-NAME`.

## What is in this repo

| File | For |
|---|---|
| `CLAUDE.md` | agents working *on* this repo: what done means, anti-patterns, the deploy table |
| `SKILL.md` | spawning and operating sessions |
| `scripts/crss.sh` | the tool |
| `scripts/crss-compat.sh` | old command names (`new-session`, `session-send`, …) for callers outside this repo |
| `tests/test-crss.sh` | end-to-end tests against a fake Claude TUI on a private tmux socket |
| `handoff/` | routing a task to another session; `handoff/references/massaging.md` is the brief contract |
| `references/` | runbooks and reference docs |
| [`agents/`](agents/) | subagent definitions deployed to `~/.claude/agents/` (diff before `install`) |

## License

MIT
