# claude-remote-session-skill

A [gstack](https://github.com/garrytan/gstack)-compatible Claude Code skill that creates persistent remote Claude sessions via tmux + systemd.

Say "create a session for my-project" and Claude will spin up a session you can connect to from any device — iPhone, desktop, or browser — via the Claude Code remote control feature.

## What it does

- Creates a named tmux session running `claude --remote-control <name>` in a loop
- Wraps it in a systemd user service so it survives reboots and restarts automatically
- Uses `--dangerously-skip-permissions` so sessions never block on tool approval prompts
- Sentinel file + `--continue` so sessions resume conversation context after restarts
- Smart backoff: 300s pause on quick exits (rate limit / crash), 10s otherwise

## Requirements

- Linux with systemd user services
- tmux
- Claude Code CLI (`claude`) installed at `/usr/bin/claude` (or adjust paths)
- Python 3 (for trust pre-acceptance)

## Install

```bash
# Option A — symlink into global Claude skills (available in every Claude session)
ln -sf "$(pwd)" ~/.claude/skills/gstack-session-spawn

# Option B — clone and symlink
git clone https://github.com/chimera-defi/claude-remote-session-skill.git
ln -sf ~/workspace/claude-remote-session-skill ~/.claude/skills/gstack-session-spawn
```

## Use from Claude Code

In any Claude Code session, type:

```
/gstack-session-spawn
```

Then tell Claude which project to create a session for. It will generate the scripts, enable the systemd service, and tell you the remote-control name to connect with.

## Use the script directly

```bash
FOLDERNAME=my-project bash scripts/create-session.sh
```

The session will appear in the Claude Code app under Remote sessions as `agenthost-my-project-<date>`.

## Naming convention

| What | Format |
|------|--------|
| tmux session | `agenthost_<folder>-<YYYYMMDD>` (underscore — tmux converts `:` to `_`) |
| remote-control name | `agenthost-<folder>-<YYYYMMDD>` (hyphens — shown in Claude Code app) |
| start script | `~/.local/bin/agenthost-<folder>-<YYYYMMDD>-start.sh` |
| systemd service | `~/.config/systemd/user/agenthost-<folder>-<YYYYMMDD>.service` |

## How connect works

Once the session is running, open Claude Code on any device → Remote sessions → look for `agenthost-<folder>-<date>`. The session keeps your conversation context across restarts via `--continue`.

## License

MIT
