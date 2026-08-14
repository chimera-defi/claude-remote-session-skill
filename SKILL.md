---
name: gstack-session-spawn
slug: gstack-session-spawn
version: "1.8.4"
tagline: "Create a persistent Claude remote session on agenthost"
description: "Use when asked to create a remote session, schedule a persistent agent, spin up a Claude session for a project, or start a background Claude process. Creates a tmux+systemd session with --dangerously-skip-permissions, --continue auto-resume, and smart backoff."
allowed-tools:
  - Bash
---

# gstack-session-spawn

Use when asked to: "create a session for X", "create a remote session in X", "spin up an agent for X", or "start a background Claude process for X".

## Naming Convention

```
tmux session:    ah_<alias>-<MMDD-HHMM>
remote-control:  ah-<alias>-<MMDD-HHMM>
workdir (repo):  /home/agents/workspace/<foldername>
workdir (util):  /home/agents/.sessions/<foldername>
```

Name-first, date last (`MMDD-HHMM`). Short aliases keep the whole name inside the
mobile-list window while reading naturally and grouping by project. Legacy
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
- **Alias values are validated (anti-poisoning).** An alias that itself looks like a full
  session name — an `ah-` prefix, an `MMDD-HHMM` timestamp, a trailing `-MMDD` date, or a
  long numeric run — is rejected and a clean alias re-inferred. This is enforced on **read**
  (a poisoned stored value is discarded and self-healed), on **write** (`--alias`), and as a
  `store_upsert` backstop, so a bad entry from an errant `--alias`, an external writer, or
  legacy data can never produce doubled `ah-ah-…-MMDD-MMDD` session names. A trailing 4-digit
  group (or an `MMDD-HHMM`-shaped pair) is only treated as poisoned when the digits validate as
  a real calendar date/time (month 01-12, day 01-31, hour 00-23, minute 00-59) — an arbitrary
  digit run (a year, port, chain id, a second unrelated number, ...) is left alone, so folders
  like `sprint-2024`/`sprint-2025` or `port-8080-9090` keep distinct aliases instead of
  collapsing onto one. `session-alias --audit-store` read-only-scans the whole store and reports
  entries where fresh inference now disagrees with what's stored (e.g. a pre-fix collision) —
  it never rewrites anything; a human decides whether to leave, re-`--alias`, or clear the line.
  Inference strips session-name decoration to a **fixed point** (not just once), so a folder
  name that is poisoned more than one layer deep — e.g. `ah-ah-x-0722-0725`, the very doubled
  name a prior poisoning incident produces — still yields a fully clean alias instead of a
  partially stripped one that keeps re-doubling.

## Key Rules

- `--dangerously-skip-permissions` always — sessions must never prompt
- Sentinel file `.sessions-init` prevents 0s exit on fresh workdirs triggering 300s backoff
- Auto-wire `using-superpowers` and all global skills into every session — do not wait for user to request it
- One Bash call for the entire recipe — do not split into multiple tool calls
- Scripts are local-only (`~/.local/bin/`, `~/.config/systemd/user/`) — no repo commits
- Git-aware run dir: when the workdir is a git repo, sessions start from the **default branch** — never a stale feature branch — and parallel sessions never collide (see below)
- Model default: spawned sessions run with `--model sonnet` (latest Sonnet, the builder default); override per-spawn with `CLAUDE_SESSION_MODEL=<model>`. A bare alias (`opus`/`sonnet`) tracks the latest release and can silently resolve to different models between spawns — `new-session` warns and recommends pinning an exact id (e.g. `CLAUDE_SESSION_MODEL=claude-opus-4-8`) for reproducibility

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

Connect from Claude Code app: look for `ah-<alias>-<MMDD-HHMM>` in remote sessions.
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
