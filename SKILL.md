---
name: gstack-session-spawn
slug: gstack-session-spawn
version: "1.9.0"
tagline: "Create a persistent Claude remote session on agenthost"
description: "Use when asked to create a remote session, schedule a persistent agent, spin up a Claude session for a project, or start a background Claude process. Creates a tmux+systemd session with --dangerously-skip-permissions, --continue auto-resume, and smart backoff."
allowed-tools:
  - Bash
---

# gstack-session-spawn

Use when asked to: "create a session for X", "create a remote session in X", "spin up an agent for X", or "start a background Claude process for X".

**Done** for a spawn means: `new-session` printed a `REMOTE_NAME`, the unit is active
(`systemctl --user is-active <REMOTE_NAME>.service`), and — if you gave it a task —
`--task` printed `verified landed` (on `UNVERIFIED`, check the pane and resend with
`session-send` — it happens often on first send). Then tell the user the
`ah-<alias>-<MMDD-HHMM>` name.

## Recipe

```bash
new-session <foldername>              # auto-detects workspace/ vs .sessions/
new-session <foldername> workspace    # force workspace/
new-session <foldername> sessions     # force .sessions/
new-session <foldername> --alias x    # explicit short alias (THIS spawn only)
new-session <foldername> --alias x --set-default-alias   # ...and make it the folder default
new-session <foldername> --dry-run    # print resolved names and exit (no session spawned, store untouched)
new-session <foldername> --force      # spawn despite the low-RAM preflight refusal (the gate is advisory otherwise)
new-session --help                    # print usage and exit (no session spawned)

new-session <foldername> --task "..."        # spawn AND kick off, in one shot
new-session <foldername> --task-file <path>  # same, task text read from a file
```

**Prefer `--task`/`--task-file` over typing the kickoff by hand.** It polls until claude is
ready in the pane, sends, then verifies the message landed — the manual type/verify/Enter
dance drops the Enter often enough to matter, leaving the session idle with no error. The
two flags are mutually exclusive; an unreadable `--task-file` fails *before* anything spawns.
How to *write* that task is its own section below.

Relaying into an already-running session, and tearing one down:

```bash
session-send <name> "..."             # relay a follow-up (or --file <path>)
session-doctor reap <name> [--force]  # teardown of a named ALIVE session (tmux + unit)
session-doctor land-check             # report-only: per-worktree real-dirty + unlanded
```

`reap` refuses protected names outright, and refuses a session with unlanded/uncommitted
work unless `--force` — rescue first via `session-preserve <name> --rescue --wip`.

Script lives at `~/.local/bin/new-session`. If it's missing, recreate it from
`references/fallback-recipe.md` (or copy `scripts/new-session.sh` directly).

**Deployed copies drift.** The skill dir and `/create-session` symlink into this repo's
canonical checkout; `~/.local/bin/*` are real copies — after landing a fix, redeploy
(`install -m 755 scripts/<x>.sh ~/.local/bin/<x>`) or it stays inert, and **diff before
overwriting** or you silently revert a deployed-only hand-patch (how `advisor` fell out of
`BUILDER_TOOLS`).

## Key Rules

- `--dangerously-skip-permissions` always — sessions must never prompt
- Sentinel file `.sessions-init-<remote_name>` prevents 0s exit on fresh workdirs triggering 300s backoff
- `using-superpowers` and the global skills are wired into every session automatically — don't wait for the user to ask
- One Bash call for the whole recipe — `new-session` is one command; don't split it into manual steps
- The *generated* start scripts and units are local-only (`~/.local/bin/`, `~/.config/systemd/user/`) — never commit them to any repo
- Git-aware run dir: a git workdir starts on the **default branch** (or a fresh worktree off it), never a stale feature branch — see below
- Model default is **per role** via `CLAUDE_SESSION_PROFILE`: `builder`→`sonnet`, `copywriter`→`haiku` (bare aliases, auto-track the latest release for their tier); `orchestrator`→`claude-opus-5`, **pinned** to an exact id (see `scripts/new-session.sh`'s "Model selection" comment for why). Override per-spawn with `CLAUDE_SESSION_MODEL=<model>`

## Writing the kickoff task

A spawned session starts with none of your context, and it will work unattended for a long
time. What makes it succeed is the shape of the first message, not how hard you tell it to
try. The full contract lives in [`handoff/references/massaging.md`](handoff/references/massaging.md);
the parts that matter most for a fresh spawn:

- **A finish line, not an activity.** "PR merged with `shell-tests` green and the script
  redeployed" — not "look into the compaction bug". Current models sustain long multi-step
  work well *when they know what done looks like*; an open-ended ask is where they drift.
- **A stop rule.** Say when to keep going and when to stop and ask. Default wording:
  *"When a step doesn't need me, keep going and put status in the same message as your next
  action. Stop and ask only if you can't continue without a decision from me, or before
  anything destructive (deleting data, force-pushing, touching anything outside this repo)."*
- **Concrete anti-patterns, not "be careful".** Name the specific mistakes to avoid in this
  domain ("don't branch from local `main`", "no orders without `EXECUTION_APPROVED_HUMAN=1`").
  A named habit gets avoided; a general caution gets ignored.
- **A task file for long runs.** For anything multi-hour or multi-PR: *"keep a TASKS.md
  checklist with the finish line at the top; update it as you go; re-read it after any
  compaction."* Context gets summarized; the file doesn't.
- **Subagents with evidence checks for large audits/migrations.** *"Give each slice its own
  subagent (`subagent_type: builder`); check each one's evidence before accepting its
  report."*
- **Leave out "think carefully / step by step / ultrathink".** Current Claude models decide
  how much to think on their own; those lines add length, not quality.

While it runs, **add context with `session-send`** rather than killing and respawning — the
session picks up a mid-run message without losing its work. When it reports done, **first
check what it needs from you** (a decision, an approval, a merge, a credential) and unblock
that, then read the rest of its summary.

## Naming

```
tmux session:    ah_<alias>-<MMDD-HHMM>
remote-control:  ah-<alias>-<MMDD-HHMM>
workdir (repo):  /home/agents/workspace/<foldername>
workdir (util):  /home/agents/.sessions/<foldername>
```

Name-first, date last. Use `workspace/` for repo sessions, `.sessions/` for utilities
(managers, monitors, etc.). Legacy `agenthost_`/`agenthost-` sessions keep working;
`session-doctor` matches both prefixes.

`<alias>` comes from the `session-alias` helper, persisted in `~/.claude/session-aliases`
(`folder<TAB>alias` per line):

- Folder names `<= 18` chars are used as-is; longer ones become an initials acronym
  (`claude-remote-session-skill` → `crss`), saved so later spawns reuse it.
- **`--alias` is per-spawn.** Sessions habitually pass the *task* (`--alias crss-prs`), so it
  no longer rewrites the folder default. Add `--set-default-alias` only when the name
  describes the **folder**, not the task.
- **Protected folders are never aliased**: a folder matching `openclaw|hermes` keeps its full
  name, because `session-doctor` needs that token to protect it. (`ALIAS_PROTECT` is narrower
  than `session-doctor`'s reap `PROTECT`, which also covers the `claude-remote` bridge
  sessions — a folder that merely contains `claude-remote`, like this repo, shortens normally.)
- **Alias values are validated (anti-poisoning)** on read, write, and store upsert, so a
  stored alias that looks like a full session name can't produce `ah-ah-…-MMDD-MMDD`. The
  rules live in `scripts/session-alias.sh`, pinned by `tests/test-session-alias.sh` — read
  those rather than restating them here.
- `session-alias --audit-store` read-only-reports stored entries that fresh inference now
  disagrees with; it never rewrites. A human decides what to change.

## Git-aware run directory (RUNDIR)

When the workdir is a git repo, the start script resolves where to run via
`session-git-prep`:

- **canonical tree is free + clean** → check it out on the default branch
  (`origin/HEAD` → `main` → `master`), pull latest when an `origin` exists, and claim it with
  an owner-lock under `~/.claude/session-locks/`
- **canonical tree is dirty or already owned by a live session** → create a fresh
  per-session worktree under `~/.claude/worktrees/<remote_name>` on a new
  `session/<remote_name>` branch cut from the default branch

The helper never fails a spawn — on any error it falls back to `$WORKDIR` as-is. Non-git
workdirs skip it entirely, **silently**.

**So check the folder is the repo you mean before spawning** — a project's *name* is not
always its folder, and a same-named non-git stub can carry its own `CLAUDE.md`/`AGENTS.md`
that make it look right (seen 2026-08-24: `workspace/portfolio-ssot` is a stub; the real
checkout is `workspace/portfolio-single-source-of-truth`):

```bash
git -C /home/agents/workspace/<foldername> rev-parse --show-toplevel
```

`fatal: not a git repository` on a folder you expected to be a repo means wrong folder, not
a broken repo.

## Operating the fleet

| Question | Command | Notes |
|---|---|---|
| Is the fleet/server healthy? | `fleet-status` (`--sessions`, `--host`) | composes `session-doctor report`, `worktree-stale`, the ~15-min `server-health-audit` snapshot (prints its age), and `rtk gain`. On demand only. |
| Which sessions are older than N? | `session-registry --older-than 3d` | age = *first-ever* spawn from `~/.sessions/session-starts.log`, so a restart doesn't reset it |
| What ran in this folder before / now? | `session-doctor history <folder-or-substring>` | NOW (live, idle mins) + PAST (from transcripts, which outlive worktrees) + branch/landed/dirty |
| Relay into an idle/stale session | `session-compact before-relay <name> "task"` | compacts, verifies, then relays; fails closed. Don't compact under ~60 min idle — the 1h cache is still live |
| Recycle a bloated session | `session-preserve <s> --rescue --wip` → must print `SAFE-TO-REAP` | then stop the unit and respawn; **never reap before this** |
| Session went silent | `tmux capture-pane -p -t <s>` | bloat vs. hook wedge vs. stuck menu — see runbooks |

Runbooks for compaction, recycling, hook-wedged sessions, and stuck-menu sessions:
[`references/troubleshooting.md`](references/troubleshooting.md). Session layers, reaping and
registry expiry: [`references/session-lifecycle.md`](references/session-lifecycle.md).

Two rules from those runbooks that bite hardest:

- **Never use `git log @{u}..` to decide whether work is pushed** — it prints nothing when
  there's no upstream. Use `git log HEAD --not --remotes` and check `git remote` separately.
- **Deleting a branch is the dangerous operation, not reaping.** A reap is safe when HEAD is
  reachable from a named local branch; leave `session/*` and research branches alone.

A respawned session starts on a fresh worktree from the default branch, **not** the old
session's branch — name the prior branch, transcript path, and where it was mid-way in the
kickoff, or the replacement re-derives it all at full cost.

## Cross-session knowledge: agent-memory, not a new bus

For durable facts other sessions should inherit, write a markdown note to
`/home/agents/agent-memory/agents/claude/public/` (cross-agent: `shared/public/`), then run
`gbrain-sync-memory` — an unsynced note is invisible to every other session. Read back via
gbrain search/recall and cite source ids (`brain:agent-claude-public:<slug>`); don't dump
folders into context. The per-namespace `MEMORY.md` index is stale — not a table of contents.
And `agents/claude/public/` is a nested git repo whose tracking has silently stopped, so
durability rests on the gbrain index, not on git.

"Who else is working here right now" is a different question — use
`session-doctor history`, which derives presence from live processes.

## Sessions agent scope

A sessions management agent (workdir `/home/agents/.sessions/agenthost-sessions`) has a
**bounded scope**, enforced by its own `.claude/CLAUDE.md`:

- **Allowed**: create sessions, write handoffs to `memory/` in target repos, relay context, monitor session status
- **Not allowed**: run scripts, execute optimizers, make code changes, or do project work for another repo

When project work lands in a sessions agent: write a handoff to that repo's `memory/`,
spawn or connect to the project session (use the `handoff` skill), and tell the user which
session has it — don't do the work yourself.
