# claude-remote-session-skill

A [gstack](https://github.com/garrytan/gstack)-compatible Claude Code skill that creates persistent remote Claude sessions via tmux + systemd.

Say "create a session for my-project" and Claude spins up a session you can connect to from any device (iPhone, desktop, browser) via Claude Code remote control.

## What it does

- Creates a named tmux session running `claude --remote-control <name>` in a restart loop
- Wraps it in a systemd user service so it survives reboots and restarts automatically
- Uses `--dangerously-skip-permissions` so sessions never block on tool approval prompts
- Sentinel file + `--continue` so sessions resume conversation context after restarts
- Smart backoff: 300s pause on quick exits (rate limit / crash), 10s otherwise
- Per-role default model via `CLAUDE_SESSION_PROFILE`; override with `CLAUDE_SESSION_MODEL=<model>` (see "Model default")

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

Then tell Claude which project to create a session for. It generates the scripts, enables the systemd service, and tells you the remote-control name to connect with.

## Use the script directly

```bash
new-session my-project              # auto-detects workspace/ vs .sessions/
new-session my-project workspace    # force workspace/
new-session my-project sessions     # force .sessions/
new-session my-long-project-name --alias mpn   # explicit short alias (THIS spawn only)
new-session my-long-project-name --alias mpn --set-default-alias   # ...and persist it as the folder default
new-session my-project --dry-run    # print resolved names and exit (no session spawned, store untouched)
new-session --help                  # print usage and exit (no session spawned)
```

The session appears in the Claude Code app under Remote sessions as `<prefix>-<alias>-<MMDD-HHMM>` (default `<prefix>` is `cs` — e.g. `cs-my-project-0101-0630`); see "Naming convention". Full flag list and recipe: `SKILL.md`.

## Model default

The model follows the **profile** (`CLAUDE_SESSION_PROFILE`), one default per role:

| Profile | Role | Default model |
|---|---|---|
| `orchestrator` (default) | thinking / multi-agent fan-out | `claude-opus-5-5` (pinned) |
| `builder` | hands-on implementation | `sonnet` (bare alias) |
| `copywriter` | lightweight doc/copy work | `haiku` (bare alias) |

builder/copywriter default to a **bare alias** on purpose — it auto-tracks Anthropic's
latest release for that tier. orchestrator is **pinned** to an exact id because the bare
`opus` alias has been observed resolving to different releases across spawns. See
`scripts/new-session.sh`'s Model selection comment for the pin, its history, and the checks
before bumping it. Opus 5.x has no `advisor` tool (Sonnet does), which is why implementation
subagents are pinned to Sonnet — see `agents/builder.md`.

Override per-spawn with `CLAUDE_SESSION_MODEL`. **Bare alias vs. pinned id — pick by intent:**

```bash
CLAUDE_SESSION_PROFILE=copywriter new-session my-docs-pass sessions        # role default: haiku
CLAUDE_SESSION_MODEL=opus         new-session my-orchestrator sessions     # bare alias: still auto-tracks latest
CLAUDE_SESSION_MODEL=claude-opus-4-8 new-session my-orchestrator sessions  # pinned: one reproducible spawn
```

Use a **bare alias for defaults you want to auto-upgrade**; **pin an exact id only when a
specific spawn must be reproducible**. `new-session` prints a moving-alias warning only when
you pass a bare alias *explicitly* — never for a role default.

## Naming convention

| What | Format |
|------|--------|
| tmux session | `<prefix>_<alias>-<MMDD-HHMM>` (underscore prefix) |
| remote-control name | `<prefix>-<alias>-<MMDD-HHMM>` (shown in Claude Code app) |
| start script | `~/.local/bin/<prefix>-<alias>-<MMDD-HHMM>-start.sh` |
| systemd service | `~/.config/systemd/user/<prefix>-<alias>-<MMDD-HHMM>.service` |

Alias resolution, prefix (`CRSS_SESSION_PREFIX`, `CRSS_LEGACY_PREFIXES`) and the rest of the
naming rules: `SKILL.md` "Naming".

## How to connect

Claude Code on any device → Remote sessions → `<prefix>-<alias>-<MMDD-HHMM>`. Context survives restarts (`--continue`) and reboots (systemd user service).

## Agent instructions in this repo

| File | For |
|---|---|
| `CLAUDE.md` | agents working *on* this repo: finish line for a change, stop-vs-continue rule, anti-patterns, deploy table |
| `SKILL.md` | spawning and operating sessions, incl. how to write a kickoff task |
| `handoff/` | routing a task to another session; `handoff/references/massaging.md` is the handoff-prompt contract |
| `references/` | runbooks and reference docs: troubleshooting/recycling, session lifecycle, fallback recipe |
| `agents/builder.md` | the Sonnet-pinned `builder` subagent; deployed to `~/.claude/agents/` (diff before `install`) |

## License

MIT
