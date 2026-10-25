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

Use when asked to: "create a session for X", "create a remote session in X", "spin up an agent for X", or "start a background Claude process for X".

**Done** for a spawn means: `new-session` printed a `REMOTE_NAME`, the unit is active
(`systemctl --user is-active <REMOTE_NAME>.service`), and — if you gave it a task —
`--task` printed `Task sent … and verified landed.` The kickoff settles first (several
consecutive ready polls) and refuses rather than pasting blind. If the task is not
(verifiably) delivered, `new-session` exits 3 naming the session and why instead of
printing `Session created` (see the kickoff block in `scripts/new-session.sh`); resend with
`session-handoff send` once the pane is ready. On a menu/trust dialog see
[`references/troubleshooting.md`](references/troubleshooting.md) (the default option there is
"No, exit").
Then tell the user the `<prefix>-<alias>-<MMDD-HHMM>` name (default `<prefix>` is `cs`,
configurable via `CRSS_SESSION_PREFIX`).

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

**Prefer `--task`/`--task-file` over typing the kickoff by hand** — hand-typing often drops
the Enter and leaves the session idle with no error; the flags poll/send/verify instead.
Mutually exclusive; an unreadable `--task-file` fails *before* anything spawns. How to
*write* the task: "Writing the kickoff task" below.

Relaying into an already-running session, and tearing one down:

```bash
session-send <name> "..."             # relay a follow-up (or --file <path>)
session-doctor reap <name> [--force] [--allow-young] [--keep-registry] [--keep-worktree] [--dry-run]
                                       # teardown (tmux + unit) + registry entry + worktree; refuses young sessions
                                       # (CRSS_REAP_MIN_AGE_H, default 24h; see _reap_age_gate, tests/test-reap-min-age.sh)
session-doctor land-check             # report-only: per-worktree real-dirty + unlanded
session-resume <name> [--dry-run] [--uuid <id>] [--model <m>]
                                       # bring a DEAD session back on its own unit + transcript
```

**Start sessions from the phone** with a Remote Control spawn server: `session-spawn-server install <dir>`
makes `<dir>` an environment in the Claude app, where "new session" starts one on this host. Runbook:
[`references/phone-spawn.md`](references/phone-spawn.md).

**A dead session comes back with `session-resume`, never by hand** (every agent, Codex
included). Do not type `claude --resume <uuid> …` into a new tmux pane or
`systemctl --user start` the unit bare: a hand relaunch drops the unit's
`--dangerously-skip-permissions` and binary (stalls on unseen approval prompts), and a bare
start can open a fresh conversation. `session-resume` resumes the session's own transcript
by uuid through its own unit, keeps its launch flags, and refuses while anything still holds
the session. Run `--dry-run` first. Steps: header of `scripts/session-resume.sh`, pinned by
`tests/test-session-resume.sh`.

**One unit's restart must not kill the tmux server.** Start scripts launch tmux through
`systemd-run --user --scope`, so the shared server never sits in a session unit's cgroup
(2026-10-24: one restart killed 29 sessions). `crss-tmux-scope` shows any server still
TRAPPED in a `.service` cgroup; `adopt --apply` moves it to its own scope without a signal.
For scripts generated before this fix, `migrate-scripts --apply` (backup kept). Header of
`scripts/crss-tmux-scope.sh`.

`reap` refuses protected names, and sessions with unlanded/uncommitted work unless `--force`
(rescue first: `session-preserve <name> --rescue --wip`). It also removes the session's own
`~/.claude/worktrees/<name>` worktree (branch kept; `--keep-worktree` opts out); guards:
`references/session-lifecycle.md`.

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
`references/fallback-recipe.md` (or copy `scripts/new-session.sh`).

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

- Claude profile default is per role via `CLAUDE_SESSION_PROFILE` (`orchestrator` pinned Opus; `owner`/`hub`/`builder` Sonnet; `copywriter` Haiku); override per spawn with `CLAUDE_SESSION_MODEL=<model>`. Codex gpt-6.1-sol high builds first (Haiku low when Codex is quota-out) and Codex/ChatGPT gpt-6.1-sol researches first (bench and roles: [`references/orchestration-flow.md`](references/orchestration-flow.md)), Haiku low repairs a failed check (on a quota-out `new-session` fails over per the [quota ladder](references/orchestration-flow.md#quota-ladder)); [`haiku-reviewer`](agents/haiku-reviewer.md) checks are advisory. Tiers, advisor, second-opinion order, builder turn cap and the lane shape: [`references/spawn-guide.md`](references/spawn-guide.md). Reports, benchmarks and new repos (private first, data-checked numbers, review passes): [`references/research-deliverables.md`](references/research-deliverables.md).

## Tier, kickoff and naming (read before spawning)

[`references/spawn-guide.md`](references/spawn-guide.md) holds the detail. The short form:

- **Tier:** pass `--tier light|standard|heavy` with `--tier-reason "..."`, or `--tier auto --task-type <t>` (right-size the model; **a tier never selects Opus**: `light` = Haiku, `standard` = Sonnet builder, `heavy` = Sonnet owner (full tools) + Opus advisor; for an Opus orchestrator omit `--tier`. `new-session` prints a `resolved:` line (backend/profile/model/effort/advisor) on every spawn: read it. Resolution is in `scripts/new-session.sh`, pinned by `tests/test-new-session-tier.sh`).
- **Kickoff:** give a finish line, not an activity; a stop rule that names the channel (`session-send <launcher>`, or the bus/mailbox when the launcher is not a tmux session; `new-session --launcher` warns); concrete anti-patterns; Codex builders first; a `TASKS.md` for long runs. Prefer `--task`/`--task-file`.
- **Naming:** `<prefix>_<alias>-<MMDD-HHMM>`; `--alias` is per-spawn, add `--set-default-alias` only when the name describes the folder (rules: `scripts/session-alias.sh`, `tests/test-session-alias.sh`).

## Git-aware run directory (RUNDIR)

For a git workdir, the start script resolves where to run via `session-git-prep`: a
free+clean canonical checkout is used directly (on the default branch, never a stale feature
branch); a dirty or already-owned one gets a fresh worktree. Decision logic, locking, and
worktree reuse on restart: [`references/git-aware-rundir.md`](references/git-aware-rundir.md).

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

Two rules from those runbooks bite hardest
(["Preserve before reaping"](references/troubleshooting.md#preserve-before-reaping-recycling-a-bloated-session)):
never use `git log @{u}..` to judge whether work is pushed (silent on a branch with no
upstream — use `git log HEAD --not --remotes`, check `git remote` separately), and deleting
a branch is the dangerous operation, not reaping. A respawn also starts fresh, not on the old
session's branch — name the prior branch/transcript/progress in the kickoff, or the
replacement re-derives it all at full cost.

## Host-local overlay: where host facts go

This repo is public and generic. Anything specific to one machine or operator (paths,
`claude` binary, protected session names, escalation channel, project index, private
vocabulary) lives in the overlay directory `$CRSS_HOME` (default `~/.config/crss`), never
in this repo:

| File | Holds |
|---|---|
| `config.sh` | `CRSS_*=value` settings (parsed, never sourced); loaded by most `session-*` scripts, not `session-compact`, `session-git-prep`, `session-send` |
| `local.md` | host prose: operator handle, escalation channel, project index, routing; agents read it via a tiny user rules file that `@`-imports it |
| `leak-denylist.txt` | host-private terms that must never reach this repo; read only by `tests/test-no-host-leaks.sh` when `CRSS_LEAK_DENYLIST` is set |

To add a host fact: knobs go in `config.sh` (see `examples/crss-overlay/config.sh.example`),
prose in `local.md`; never edit `SKILL.md` or any file in this repo. Setup, the loader's
script list, denylist syntax and the stricter leak check:
[`examples/crss-overlay/README.md`](examples/crss-overlay/README.md). `session-doctor overlay`
reports overlay health.

## Cross-session knowledge: agent-memory, not a new bus

Durable facts other sessions should inherit go through the host's shared memory convention
(root, namespace, sync command, citation format), set up in the user-level
`~/.claude/CLAUDE.md` or `$CRSS_HOME/local.md` — not restated here. "Who else is working
here right now" is a different question: `session-doctor history` derives presence from
live processes. Lessons are saved at compaction, not by remembering: the opt-in `PreCompact`
hook `precompact-lessons` ([`references/precompact-lessons.md`](references/precompact-lessons.md)).

## Sessions agent scope

Some hosts run a bounded sessions-management agent (session ops only, no project work),
enforced by its own `.claude/CLAUDE.md` (see `$CRSS_HOME/local.md`). If project work lands
there: write a handoff to that project's `memory/`, spawn or connect to the project session
(`handoff` skill), and tell the user which session has it — don't do the work yourself.
