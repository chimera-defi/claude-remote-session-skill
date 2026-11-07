---
name: gstack-session-spawn
slug: gstack-session-spawn
version: "1.9.1"
tagline: "Create a persistent Claude remote session via tmux + systemd"
description: "Use when asked to create a remote session, schedule a persistent agent, spin up a Claude session for a project, or start a background Claude process. Creates a tmux+systemd session with --dangerously-skip-permissions, --continue auto-resume, and smart backoff."
triggers:
  - "create a remote session"
  - "spawn a session"
  - "new session for"
  - "schedule a persistent agent"
  - "start a background claude process"
allowed-tools:
  - Bash
---

# gstack-session-spawn

**Done:** `new-session` prints `REMOTE_NAME`, the unit passes
`systemctl --user is-active <REMOTE_NAME>.service`, and, when given a task, `--task` prints
`Task sent … and verified landed.` Readiness polling and refusal: kickoff block in
`scripts/new-session.sh`, pinned by `tests/test-new-session-kickoff.sh`.
Undelivered tasks exit 3 with session/reason instead of `Session created`; resend with
`session-handoff send` when ready. Menu/trust default: "No, exit"; see
[troubleshooting](references/troubleshooting.md). Report `<prefix>-<alias>-<MMDD-HHMM>`
(default `cs`, configurable via `CRSS_SESSION_PREFIX`).

## Recipe

```bash
new-session <foldername>              # auto-detects workspace/ vs .sessions/
new-session <foldername> workspace    # force workspace/
new-session <foldername> sessions     # force .sessions/
new-session <foldername> --alias x    # explicit short alias (THIS spawn only)
new-session <foldername> --alias x --set-default-alias   # ...and make it the folder default
new-session <foldername> --dry-run    # print resolved names and exit (no session spawned, store untouched)
new-session <foldername> --force      # spawn despite the low-RAM preflight refusal (the gate is advisory otherwise)
new-session <foldername> --backend codex  # launch Codex CLI instead of Claude Code
new-session <foldername> --tier standard --tier-reason "..."  # right-size (see "Choosing a tier"); bare spawn = Opus; a tier is never Opus (heavy = Sonnet owner + Opus advisor)
new-session --help                    # print usage and exit (no session spawned)

new-session <foldername> --task "..."        # spawn AND kick off, in one shot
new-session <foldername> --task-file <path>  # same, task text read from a file
```

Prefer `--task`/`--task-file`: they poll/send/verify; hand-typing can drop Enter and leave
an idle session without error. Mutual exclusion and unreadable-file preflight:
`scripts/new-session.sh`, pinned by `tests/test-new-session-kickoff.sh`.
Task contract: [Writing the kickoff task](references/spawn-guide.md#writing-the-kickoff-task).

Relaying into an already-running session, and tearing one down:

```bash
session-send <name> "..."             # relay a follow-up (or --file <path>)
# Message a Codex desktop thread via its local app-server socket instead of a poll-only bus; exit 1 = uncertain, do not resend; replies still arrive by the bus.
session-send codex:list
session-send codex:<cs-ref> --expect-identity <id> "..."
session-doctor reap <name> [--force] [--allow-young] [--keep-registry] [--keep-worktree] [--dry-run]
                                       # teardown (tmux + unit) + registry entry + worktree; refuses young sessions
                                       # (CRSS_REAP_MIN_AGE_H, default 24h; see _reap_age_gate, tests/test-reap-min-age.sh)
session-doctor land-check             # report-only: per-worktree real-dirty + unlanded
session-resume <name> [--dry-run] [--uuid <id>] [--model <m>]
                                       # bring a DEAD session back on its own unit + transcript
session-restart <name> [--dry-run] [--wait-idle] [--nudge]
                                       # move a LIVE idle session onto the installed CLI, same transcript
```

**Start sessions from the phone** with a Remote Control spawn server: `session-spawn-server install <dir>`
makes `<dir>` an environment in the Claude app, where "new session" starts one on this host. Runbook:
[`references/phone-spawn.md`](references/phone-spawn.md).

**Resume dead sessions with `session-resume`** (Codex included); run `--dry-run` first.
Manual `claude --resume <uuid> …` can lose the binary/`--dangerously-skip-permissions`
and stall on approval; bare `systemctl --user start` can open a fresh conversation.
Own-unit/transcript/flag preservation and live-holder refusal: header of
`scripts/session-resume.sh`, pinned by `tests/test-session-resume.sh`.

**Update live sessions with `session-restart`**, not by killing panes: it refuses a busy
session (`--wait-idle` waits for an idle point instead), pins the running sessionId, sends
`/exit`, and checks that the start-script loop relaunched the same conversation on the new
version. Busy rules, refusals and exit codes are in the header of `scripts/session-restart.sh`,
pinned by `tests/test-session-restart.sh`. Fleet procedure:
[`references/session-lifecycle.md`](references/session-lifecycle.md).

**One unit's restart must not kill the tmux server.** Start scripts launch tmux through
`systemd-run --user --scope`, so the shared server never sits in a session unit's cgroup
(2026-10-24: one restart killed 29 sessions). `crss-tmux-scope` shows any server still
TRAPPED in a `.service` cgroup; `adopt --apply` moves it to its own scope without a signal.
For scripts generated before this fix, `migrate-scripts --apply` (backup kept). Header of
`scripts/crss-tmux-scope.sh`.

Before `reap`: `session-preserve <name> --rescue --wip`. Protected-name and
unlanded/uncommitted-work guards (`--force`), removal of `~/.claude/worktrees/<name>`
(branch kept; `--keep-worktree` opts out): `references/session-lifecycle.md`,
`scripts/session-doctor.sh`, pinned by `tests/test-session-doctor-reap-worktree.sh`.

### Codex Backend

`new-session --backend codex` shares Claude's envelope (tmux, systemd unit, start script,
alias/name parsing, telemetry, `--task`/`--task-file` kickoff, `session-send`/
`session-handoff` verification, `session-doctor reap`). Switch and command:
`scripts/new-session.sh`; pane-state detection: `scripts/session-handoff.sh`. Host defaults
in `$CRSS_HOME/config.sh`: `CRSS_SESSION_BACKEND=codex` (generic default: Claude),
`CRSS_CODEX_BIN`, `CRSS_CODEX_ARGS` (model/sandbox/approval flags — check `codex --help`
first). Skipped for Codex: model/profile pinning, `BUILDER_TOOLS`, `advisor`, `--settings`,
remote-control registration, the global `.claude/skills` symlink; Claude registry and
transcript history stay Claude-specific.

Script lives at `~/.local/bin/new-session`; if missing, recreate it from
`references/fallback-recipe.md` (or copy `scripts/new-session.sh`, with `scripts/crss-lib.sh`
beside it as `crss-lib.sh`: without it the script exits 2).

**Deployed copies drift:** `~/.local/bin/*` are real copies of `scripts/`. Diff before
`install`, and redeploy after landing — `CLAUDE.md` "Deploying".

## Key Rules

- `--dangerously-skip-permissions` always — sessions must never prompt
- Sentinel file `.sessions-init-<remote_name>` (touched before the first launch) makes every later restart `--continue`; a one-shot resume pin from `session-resume` overrides it with `--resume <uuid>`
- One Bash call for the whole recipe — `new-session` is one command; don't split it into manual steps
- The *generated* start scripts and units are local-only (`~/.local/bin/`, `~/.config/systemd/user/`) — never commit them to any repo
- Git-aware run dir: a git workdir starts on the **default branch** (or a fresh worktree off it), never a stale feature branch — see below
- Before any `gh pr merge` under a general or standing auto-merge rule, run `merge-guard <pr>`
  ([script](scripts/merge-guard.sh), [test](tests/test-merge-guard.sh)). On a nonzero exit,
  leave the PR for the operator and report the reasons. A general rule never overrides a per-item veto.

- Role models (`CLAUDE_SESSION_PROFILE`, override `CLAUDE_SESSION_MODEL=<model>`), tiers,
  advisor, second-opinion order and builder turn cap: [`references/spawn-guide.md`](references/spawn-guide.md).
  Build/research/repair/review routing and quota failover: [`references/orchestration-flow.md`](references/orchestration-flow.md).
  [`haiku-reviewer`](agents/haiku-reviewer.md) is advisory. Reports, benchmarks and new repos
  (private first, data-checked numbers, review passes): [`references/research-deliverables.md`](references/research-deliverables.md).

## Tier, kickoff and naming (read before spawning)

[`references/spawn-guide.md`](references/spawn-guide.md) holds the detail. The short form:

- **Tier:** `--tier light|standard|heavy --tier-reason "..."`, or `--tier auto --task-type <t>`.
  Read the `resolved:` backend/profile/model/effort/advisor line. Model mapping and no-tier
  Opus: [Choosing a tier](references/spawn-guide.md#choosing-a-tier-right-size-the-model-save-quota);
  resolution in `scripts/new-session.sh`, pinned by `tests/test-new-session-tier.sh`.
- **Kickoff:** give a finish line, not an activity; a stop rule that names the channel (`session-send <launcher>`, or the bus/mailbox when the launcher is not a tmux session; `new-session --launcher` warns); concrete anti-patterns; Codex builders first; a `TASKS.md` for long runs. Prefer `--task`/`--task-file`.
- **Naming:** `<prefix>_<alias>-<MMDD-HHMM>`; `--alias` is per-spawn, add `--set-default-alias` only when the name describes the folder (rules: `scripts/session-alias.sh`, `tests/test-session-alias.sh`).

## Git-aware run directory (RUNDIR)

`session-git-prep` resolves the run directory: see
[`references/git-aware-rundir.md`](references/git-aware-rundir.md) for checkout/worktree
selection, locking and restart reuse; implementation `scripts/session-git-prep.sh`,
pinned by `tests/test-session-git-prep.sh`.

**Check the folder is the repo you mean before spawning** — a project's *name* is not
always its folder, and a same-named non-git stub can carry its own `CLAUDE.md`/`AGENTS.md`
that makes it look right:

```bash
git -C $CRSS_WORKSPACE/<foldername> rev-parse --show-toplevel
```

`fatal: not a git repository` on a folder you expected to be a repo means wrong folder, not
a broken repo.

## Operating the fleet

| Question | Command | Notes |
|---|---|---|
| Is the fleet/server healthy? | `fleet-status` (`--sessions`, `--host`) | composes `session-doctor report`, `worktree-stale`, a host health snapshot (prints its age) and a token-savings summary, where the host has them. On demand only. |
| Which sessions are older than N? | `session-registry --older-than 3d` | age = *first-ever* spawn from `~/.sessions/session-starts.log`, so a restart doesn't reset it |
| What ran in this folder before / now? | `session-doctor history <folder-or-substring>` | NOW (live, idle mins) + PAST (from transcripts, which outlive worktrees) + branch/landed/dirty |
| Relay into an idle/stale session | `session-compact before-relay <name> "task"` | compacts, verifies, then relays; fails closed. Don't compact under ~60 min idle — the 1h cache is still live |
| Recycle a bloated session | `session-preserve <s> --rescue --wip` → must print `SAFE-TO-REAP` | then stop the unit and respawn; **never reap before this** |
| Session went silent | `tmux capture-pane -p -t <s>` | bloat vs. hook wedge vs. stuck menu — see runbooks |
| Clean up stale registry entries | `session-doctor registry-prune [--days N] [--apply]` | dry-run by default; `reap <name>` also prunes its own entry unless `--keep-registry` |
| Reap sessions whose PR already merged | `session-doctor reap-merged [--apply] [--idle-min N]` | dry-run by default, one candidate/skipped line each; `--apply` runs plain `reap` only (never `--force`); rules in `_reap_merged_check`, pinned by `tests/test-reap-merged.sh` |
| Clean up a reaped session's leftover worktree | `session-doctor worktree-stale` | only for one NOT already handled — `reap <name>` removes its own worktree (`--keep-worktree` to skip) |

Both: `references/session-lifecycle.md`. Host-specific ops tooling lives outside this repo.

Runbooks (compaction, recycling, hook-wedged and stuck-menu sessions):
[`references/troubleshooting.md`](references/troubleshooting.md). Session layers, reaping,
registry expiry: [`references/session-lifecycle.md`](references/session-lifecycle.md).

Before recycling, read [Preserve before reaping](references/troubleshooting.md#preserve-before-reaping-recycling-a-bloated-session):
it covers the `git log @{u}..` trap, `git log HEAD --not --remotes` / `git remote`,
branch-ref preservation and the prior branch/transcript/progress needed in a fresh kickoff.

## Host-local overlay: where host facts go

This repo is public and generic. Anything specific to one machine or operator (paths,
`claude` binary, protected session names, escalation channel, project index, private
vocabulary) lives in the overlay directory `$CRSS_HOME` (default `~/.config/crss`), never
in this repo:

| File | Holds |
|---|---|
| `config.sh` | `CRSS_*=value` settings (parsed, never sourced); loaded by most `session-*` scripts, not `session-compact` or `session-git-prep`; `session-send` delegates Codex targets to `codex-send`, which parses `CRSS_CODEX_BRIDGE_*`/`CRSS_CODEX_BIN` |
| `local.md` | host prose: operator handle, escalation channel, project index, routing; agents read it via a tiny user rules file that `@`-imports it |
| `leak-denylist.txt` | host-private terms that must never reach this repo; read only by `tests/test-no-host-leaks.sh` when `CRSS_LEAK_DENYLIST` is set |

To add a host fact: knobs go in `config.sh` (see `examples/crss-overlay/config.sh.example`),
prose in `local.md`; never edit `SKILL.md` or any file in this repo. Setup, the loader's
script list, denylist syntax and the stricter leak check:
[`examples/crss-overlay/README.md`](examples/crss-overlay/README.md). `session-doctor overlay`
reports overlay health.
Optional module hooks: see [Modules](examples/crss-overlay/README.md#modules).

## Cross-session knowledge: agent-memory, not a new bus

Shared memory conventions (root, namespace, sync, citations) live in user-level
`~/.claude/CLAUDE.md` or `$CRSS_HOME/local.md`; live presence comes from
`session-doctor history`. The opt-in `PreCompact` hook `precompact-lessons` lives in the
host module; see [Modules](examples/crss-overlay/README.md#modules).

## Sessions agent scope

Some hosts run a bounded sessions-management agent (session ops only, no project work),
enforced by its own `.claude/CLAUDE.md` (see `$CRSS_HOME/local.md`). If project work lands
there: write a handoff to that project's `memory/`, spawn or connect to the project session
(`handoff` skill), and tell the user which session has it — don't do the work yourself.
