---
name: gstack-session-spawn
slug: gstack-session-spawn
version: "1.7.1"
tagline: "Create a persistent Claude remote session on agenthost"
description: "Use when asked to create a remote session, schedule a persistent agent, spin up a Claude session for a project, or start a background Claude process. Creates a tmux+systemd session with --dangerously-skip-permissions, --continue auto-resume, and smart backoff."
allowed-tools:
  - Bash
---

# gstack-session-spawn

Use when asked to: "create a session for X", "create a remote session in X", "spin up an agent for X", or "start a background Claude process for X".

## Naming Convention

```
tmux session:    ah_<MMDD-HHMM>-<alias>
remote-control:  ah-<MMDD-HHMM>-<alias>
workdir (repo):  /home/agents/workspace/<foldername>
workdir (util):  /home/agents/.sessions/<foldername>
```

ID-first (`MMDD-HHMM`) so the unique token survives mobile truncation. Legacy
`agenthost_`/`agenthost-` sessions from before this change keep working;
`session-doctor` matches both prefixes during the transition.

Use `workspace/` for repo sessions, `.sessions/` for utilities (managers, monitors, etc.).

### Alias

`<alias>` is a short, stable name derived from `<foldername>`, resolved by the
`session-alias` helper and persisted in `~/.claude/session-aliases` (one
`folder<TAB>alias` per line):

- Folder names `<= 18` chars are used as-is.
- Longer names are reduced to an initials acronym (`claude-remote-session-skill` → `crss`),
  then the mapping is saved so every later spawn of that folder gets the same alias.
- Pass `-a`/`--alias <x>` to `new-session` to set (and persist) an explicit alias.
- **Protected folders are never aliased.** A folder whose name matches `openclaw|hermes`
  keeps its full name (aliasing would strip the token `session-doctor` needs to protect it;
  `--alias` is ignored for these). This `ALIAS_PROTECT` guard is deliberately narrower than
  `session-doctor`'s reap `PROTECT` (`claude-remote|openclaw|hermes`): the bare
  `claude-remote`/`claude-remote-b` bridge sessions aren't spawned via `new-session`, so a
  folder that merely contains `claude-remote` (like this repo) is a normal dev session that
  shortens and is reapable like any other.

## Key Rules

- `--dangerously-skip-permissions` always — sessions must never prompt
- Sentinel file `.sessions-init` prevents 0s exit on fresh workdirs triggering 300s backoff
- Auto-wire `using-superpowers` and all global skills into every session — do not wait for user to request it
- One Bash call for the entire recipe — do not split into multiple tool calls
- Scripts are local-only (`~/.local/bin/`, `~/.config/systemd/user/`) — no repo commits
- Git-aware run dir: when the workdir is a git repo, sessions start from the **default branch** — never a stale feature branch — and parallel sessions never collide (see below)
- Model default: spawned sessions run with `--model sonnet` (latest Sonnet, the builder default); override per-spawn with `CLAUDE_SESSION_MODEL=opus` for an orchestrator session

## Git-aware run directory (RUNDIR)

When the workdir is a git repo, the start script resolves where to run via the
`session-git-prep` helper (`~/.local/bin/session-git-prep`) instead of using the
checked-out branch as-is:

- **canonical tree is free + clean** → check it out on the default branch
  (`origin/HEAD` → `main` → `master`), pull latest when an `origin` exists, and
  claim it with an owner-lock under `~/.claude/session-locks/`
- **canonical tree is dirty or already owned by a live session** → create a
  fresh per-session worktree under `~/.claude/worktrees/<remote_name>` on a new
  `session/<remote_name>` branch cut from the default branch

This means a session never inherits a random current branch, and N agents can
work the same repo in parallel without stepping on each other. The helper never
fails a spawn — if anything goes wrong (or it's not on PATH) the start script
falls back to launching in `$WORKDIR` as-is. Non-git workdirs are unaffected.

## Recipe — use the script (preferred)

A standalone script handles the full recipe. Use it directly:

```bash
new-session <foldername>              # auto-detects workspace/ vs .sessions/
new-session <foldername> workspace    # force workspace/
new-session <foldername> sessions     # force .sessions/
new-session --help                    # print usage and exit (no session spawned)
```

Script lives at `~/.local/bin/new-session`. If it's missing, recreate it from
`references/fallback-recipe.md` (or copy `scripts/new-session.sh` directly).

## After Creating

Connect from Claude Code app: look for `ah-<MMDD-HHMM>-<alias>` in remote sessions.
Each spawn gets a unique name — never collides with same-minute sessions.
Scripts are local-only (`~/.local/bin/`, `~/.config/systemd/user/`) — no repo commits.

## Sessions Agent Scope

A sessions management agent (workdir `/home/agents/.sessions/agenthost-sessions`) has a **bounded scope**:

- **Allowed**: create sessions, write handoffs to `memory/` in target repos, relay context, monitor session status
- **NOT allowed**: run scripts, execute optimizers, make code changes, or do project work for another repo

If project-specific work arrives in a sessions agent's context (e.g. a handoff describing optimizer runs):
1. Write a handoff to that repo's `memory/` folder with the pending work
2. Spawn or connect to the appropriate project session
3. Tell the user what session to use — do NOT execute the work yourself

The sessions agent's `CLAUDE.md` at `/home/agents/.sessions/agenthost-sessions/.claude/CLAUDE.md` enforces these rules.
