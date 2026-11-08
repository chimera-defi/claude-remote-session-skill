# claude-remote-session-skill

A [gstack](https://github.com/garrytan/gstack)-compatible Claude Code skill for long-lived Claude
sessions on a Linux host, reachable from any device through Claude Code Remote Control.

The whole tool is one script, `scripts/crss.sh`. Each session is a tmux session `ah_NAME` running
`claude --remote-control ah-NAME` in a restart loop that resumes the same conversation after a crash,
restart or reboot. State is one env file per session in `~/.local/state/crss/`; `crss-up.timer`
(every 5 minutes) and `crss-up.service` (at boot) start any session that should run and isn't.

```bash
crss spawn my-lane ~/workspace/my-repo --model sonnet --worktree --brief brief.md
crss send my-lane --file next-task.md     # delivered | queued (exit 0), UNVERIFIED (1), refused (2)
crss ls
crss restart --all --wait-idle            # onto a new claude binary, same conversations
crss reap my-lane                         # keeps any worktree with unpushed or uncommitted work
```

Commands, receipts and safety rules: [`SKILL.md`](SKILL.md).

## Requirements and install

Linux with systemd user services, tmux, jq, git, and the Claude Code CLI on `PATH`.

```bash
git clone https://github.com/chimera-defi/claude-remote-session-skill.git
ln -sf "$PWD/claude-remote-session-skill" ~/.claude/skills/gstack-session-spawn
```

Then install the script and timer as in `SKILL.md` "Setup". Connect from Claude Code → Remote
sessions → `ah-NAME`.

## Layout

| Path | For |
|---|---|
| `CLAUDE.md` | agents working on this repo: what done means, anti-patterns, deploy table |
| `SKILL.md` | spawning and operating sessions |
| `scripts/` | `crss.sh`, and `crss-compat.sh` for the old command names |
| `tests/` | end-to-end test against a fake Claude TUI, plus the public-repo leak check |
| `handoff/` | routing a task to another session and writing its brief |
| `references/` | spawn guide, orchestration flow, troubleshooting, deliverables |
| `agents/` | subagent definitions deployed to `~/.claude/agents/` (diff before `install`) |

## License

MIT
