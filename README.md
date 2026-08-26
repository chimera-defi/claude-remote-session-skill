# claude-remote-session-skill

A [gstack](https://github.com/garrytan/gstack)-compatible Claude Code skill that creates persistent remote Claude sessions via tmux + systemd.

Say "create a session for my-project" and Claude will spin up a session you can connect to from any device — iPhone, desktop, or browser — via the Claude Code remote control feature.

## What it does

- Creates a named tmux session running `claude --remote-control <name>` in a restart loop
- Wraps it in a systemd user service so it survives reboots and restarts automatically
- Uses `--dangerously-skip-permissions` so sessions never block on tool approval prompts
- Sentinel file + `--continue` so sessions resume conversation context after restarts
- Smart backoff: 300s pause on quick exits (rate limit / crash), 10s otherwise
- Per-role default model via `CLAUDE_SESSION_PROFILE` (orchestrator→opus, builder→sonnet, copywriter→haiku), each a bare alias that auto-tracks the latest release; override with `CLAUDE_SESSION_MODEL=<model>`

## Requirements

- Linux with systemd user services
- tmux
- Claude Code CLI (`claude`) installed at `/usr/bin/claude` (or adjust paths)

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
new-session my-project              # auto-detects workspace/ vs .sessions/
new-session my-project workspace    # force workspace/
new-session my-project sessions     # force .sessions/
new-session my-long-project-name --alias mpn   # explicit short alias (persisted)
new-session my-project --dry-run    # print resolved names and exit (no session spawned, store untouched)
new-session --help                  # print usage and exit (no session spawned)
```

The session will appear in the Claude Code app under Remote sessions as `ah-<alias>-<MMDD-HHMM>` (e.g. `ah-my-project-0715-0630`), where `<alias>` is `my-project` as-is if short, or a persisted acronym/explicit alias if long — see "Naming convention" below.

## Model default

The model follows the **profile** (`CLAUDE_SESSION_PROFILE`), one default per role:

| Profile | Role | Default model |
|---|---|---|
| `orchestrator` (default) | thinking / multi-agent fan-out | `opus` |
| `builder` | hands-on implementation | `sonnet` |
| `copywriter` | lightweight doc/copy work | `haiku` |

Each default is a **bare alias** on purpose — it auto-tracks Anthropic's latest release
for that tier, so spawns pick up a newer Opus/Sonnet/Haiku with no edit here.

Override per-spawn with `CLAUDE_SESSION_MODEL`. **Bare alias vs. pinned id — pick by intent:**

```bash
CLAUDE_SESSION_PROFILE=copywriter new-session my-docs-pass sessions        # role default: haiku
CLAUDE_SESSION_MODEL=opus         new-session my-orchestrator sessions     # bare alias: still auto-tracks latest
CLAUDE_SESSION_MODEL=claude-opus-4-8 new-session my-orchestrator sessions  # pinned: one reproducible spawn
```

Use a **bare alias for defaults you want to auto-upgrade**; **pin an exact id only when a
specific spawn must be reproducible**. `new-session` prints a moving-alias warning only when
you pass a bare alias *explicitly* — never for a role default (that drift is the point).

## Naming convention

| What | Format |
|------|--------|
| tmux session | `ah_<alias>-<MMDD-HHMM>` (underscore prefix) |
| remote-control name | `ah-<alias>-<MMDD-HHMM>` (shown in Claude Code app) |
| start script | `~/.local/bin/ah-<alias>-<MMDD-HHMM>-start.sh` |
| systemd service | `~/.config/systemd/user/ah-<alias>-<MMDD-HHMM>.service` |

Name-first, date last (`MMDD-HHMM`). Short aliases keep the whole name inside the
mobile-list window while reading naturally and grouping by project. `<alias>`
is the folder name as-is when short, otherwise a short inferred/persisted acronym (or
an explicit `--alias`) — see `SKILL.md` for the resolution rules. Legacy
`agenthost_`/`agenthost-` sessions created before this change keep working;
`session-doctor` matches both prefixes during the transition.

## How to connect

Once running: open Claude Code on any device → Remote sessions → look for `ah-<alias>-<MMDD-HHMM>`. The session keeps your conversation context across restarts via `--continue`. The systemd user service survives reboots.

## License

MIT
