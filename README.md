# claude-remote-session-skill

A [gstack](https://github.com/garrytan/gstack)-compatible Claude Code skill that creates persistent remote Claude sessions via tmux + systemd.

Say "create a session for my-project" and Claude will spin up a session you can connect to from any device — iPhone, desktop, or browser — via the Claude Code remote control feature.

## What it does

- Creates a named tmux session running `claude --remote-control <name>` in a restart loop
- Wraps it in a systemd user service so it survives reboots and restarts automatically
- Uses `--dangerously-skip-permissions` so sessions never block on tool approval prompts
- Sentinel file + `--continue` so sessions resume conversation context after restarts
- Smart backoff: 300s pause on quick exits (rate limit / crash), 10s otherwise
- Defaults to `--model sonnet` (latest Sonnet); override with `CLAUDE_SESSION_MODEL=opus` for orchestrator sessions

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

Back-compat wrapper (same calling convention as the original script):

```bash
FOLDERNAME=my-project bash scripts/create-session.sh
```

The session will appear in the Claude Code app under Remote sessions as `ah-<alias>-<MMDD-HHMM>` (e.g. `ah-my-project-0715-0630`), where `<alias>` is `my-project` as-is if short, or a persisted acronym/explicit alias if long — see "Naming convention" below.

## Model default

Spawned sessions use `--model sonnet` (resolves to the latest Sonnet release). Convention: builder/worker sessions use Sonnet; orchestrator sessions use Opus. Override per-spawn:

```bash
CLAUDE_SESSION_MODEL=opus new-session my-orchestrator sessions
```

A bare alias (`opus`/`sonnet`/`haiku`) resolves to *the latest* release, which can change
between spawns (e.g. `opus` → `claude-opus-5` one week, Opus 4.8 the next, with identical
flags). `new-session` prints a warning when a moving alias is used; pass an exact model id
to pin it reproducibly:

```bash
CLAUDE_SESSION_MODEL=claude-opus-4-8 new-session my-orchestrator sessions
```

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
