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
session-doctor reap <name> [--force] [--keep-registry] [--keep-worktree] [--dry-run]
                                       # teardown (tmux + unit) + registry entry + worktree
session-doctor land-check             # report-only: per-worktree real-dirty + unlanded
session-resume <name> [--dry-run] [--uuid <id>] [--model <m>]
                                       # bring a DEAD session back on its own unit + transcript
```

**A dead session comes back with `session-resume`, never by hand** (every agent, Codex
included). Do not type `claude --resume <uuid> …` into a new tmux pane or
`systemctl --user start` the unit bare: a hand relaunch drops the unit's
`--dangerously-skip-permissions` and binary (stalls on unseen approval prompts), and a bare
start can open a fresh conversation. `session-resume` resumes the session's own transcript
by uuid through its own unit, keeps its launch flags, and refuses while anything still holds
the session. Run `--dry-run` first. Steps: header of `scripts/session-resume.sh`, pinned by
`tests/test-session-resume.sh`.

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
- `using-superpowers` and the global skills are wired into every session automatically — don't wait for the user to ask
- One Bash call for the whole recipe — `new-session` is one command; don't split it into manual steps
- The *generated* start scripts and units are local-only (`~/.local/bin/`, `~/.config/systemd/user/`) — never commit them to any repo
- Git-aware run dir: a git workdir starts on the **default branch** (or a fresh worktree off it), never a stale feature branch — see below
- Model default is **per role** via `CLAUDE_SESSION_PROFILE`: `owner`→`sonnet` (full tool set, for long-lived lane owners), `hub`→`sonnet` (full tools plus the Opus consult contract), `builder`→`sonnet`, `copywriter`→`haiku` (bare aliases, auto-track the latest release for their tier); `orchestrator`→`claude-opus-5-5`, **pinned** to an exact id (see `scripts/new-session.sh`'s "Model selection" comment for why). Override per-spawn with `CLAUDE_SESSION_MODEL=<model>`
- `agents/builder.md` caps a builder at 250 turns per invocation (`maxTurns`). The CLI stops it
  mid-step. On an "Agent stopped at its 250-turn limit" result, run `git status` /
  `git diff --stat` in its worktree before deciding anything. Then continue it with SendMessage,
  which keeps its context and its half-done edits; a fresh spawn would orphan them.
- Hub sessions run Sonnet by default and keep both native `advisor` and the Opus one-shot
  consult contract in [`references/hub-opus-consult.md`](references/hub-opus-consult.md).
- The Opus orchestrator has no `advisor` (Sonnet-only). For a second opinion it spawns a
  Fable subagent directly — `subagent_type: "reviewer"` (`agents/reviewer.md`, once
  deployed to `~/.claude/agents/`) or an ad hoc `Agent({description, prompt, model:
  "fable"})` — not a Sonnet builder, which would just be Sonnet checking its own
  reasoning. `model: fable` is a valid agent-frontmatter value on the installed CLI (a probe
  agent with it ran as a Fable model).
- ChatGPT is reached, if at all, through a project-specific relay subagent (not a standalone
  session), defined in that project's own `.claude/agents/` and roles table — don't copy its
  call-out details here. `$CRSS_HOME/local.md` says which projects have one.
- The order of second opinions is overlay-configurable: `$CRSS_HOME/local.md` may name which
  reviewer goes first (for example a cheaper strong model), which gives a different-family
  cross-check, and which expensive reviewer goes last. Whatever the order, a review that gates
  a merge or an operator-facing decision never rests on a single model family; if only one
  family is available, pause and report rather than approving on one family's say-so. An
  orchestrator's own sanity check (the Fable bullet above) is not that review.

## Choosing a tier (right-size the model, save quota)

The launcher knows the task; the script cannot guess it. Pick `--tier` from the signals below and
say why with `--tier-reason "<one line>"` (logged to spawn telemetry so the rubric can be tuned
from outcomes). The resolver (`scripts/new-session.sh`, pinned by `tests/test-new-session-tier.sh`)
applies the floors and ceilings; do not restate its rules here.

| Tier | Pick it when the task is | Resolves to |
|---|---|---|
| `light` | mechanical, doc/copy-only, a bounded edit with a clear check | copywriter profile, haiku, `--effort low` |
| `standard` | ordinary implementation, debugging, review in one repo | builder profile, sonnet |
| `heavy` | ambiguous design, long-lived lane, gating review, destructive/outward-facing steps | owner profile, sonnet (full tools) |

- `--needs-fanout` when the session must call `Workflow`/`Agent`: lifts a trimmed profile to `owner`.
- Opus is never chosen implicitly. `--tier heavy --approve-opus` (or an explicit
  `CLAUDE_SESSION_MODEL`) is the only route; reserve it for decisions Sonnet cannot settle.
- Effort only moves **down** from the CLI baseline (light = low). Raise it with
  `CLAUDE_SESSION_EFFORT=low|medium|high|xhigh|max`; that is an explicit spend decision.
- Explicit `CLAUDE_SESSION_PROFILE` / `_MODEL` / `_EFFORT` always win over the tier, piecewise.
- No `--tier` means today's default (orchestrator on Opus); a bare spawn is the expensive path, so pass a tier.
- A host overlay can route tiers to the Codex backend (no Claude quota) with
  `CRSS_TIER_CODEX_TIERS="light standard"` in `$CRSS_HOME/config.sh`; `--needs-fanout` stays on Claude.

## Writing the kickoff task

A spawned session starts with none of your context and works unattended for a long time;
the shape of the first message decides whether it succeeds, not how hard you tell it to try.
Full contract: [`handoff/references/massaging.md`](handoff/references/massaging.md); fill-in
starting shape: [`handoff/references/kickoff-templates.md`](handoff/references/kickoff-templates.md)
template (a). Before writing, read `$CRSS_HOME/local.md` if it exists — this host's real
escalation channel, project guardrail index, and delegate routing; absent overlay, use the
generic defaults in those two files. What matters most for a fresh spawn:

- **A finish line, not an activity.** "PR merged with `shell-tests` green and the script
  redeployed" — not "look into the compaction bug". Models sustain long multi-step work
  *when they know what done looks like*; an open-ended ask is where they drift.
- **A stop rule that names the channel.** Say when to keep going, when to stop and ask, and
  *through what*: a question left only in the child's own pane is a stall, not an
  escalation. Default wording (via `session-send <parent-session> --file <f>`, numbered list
  with a recommended option): [`handoff/references/massaging.md`](handoff/references/massaging.md).
  A permission denial or a plain-text question in the child's pane does **not** raise an
  `AskUserQuestion` notification, so the operator never sees it. A blocked child therefore
  `session-send`s its launcher the exact command or decision needed. Launchers sweep their
  children's panes read-only for such stalls and alert the operator; they never answer a
  permission denial on the operator's behalf.
- **Concrete anti-patterns, not "be careful".** Name the specific mistakes to avoid in this
  domain ("don't branch from local `main`", "no deploys without explicit human approval in this session").
  A named habit gets avoided; a general caution gets ignored.
- **Builders: Codex first.** For hands-on implementation, spawn Codex builders first
  (`new-session --backend codex`, or `codex exec` for one-shot local work); use Sonnet as
  the fallback when Codex cannot run the task, and record the model that actually ran.
- **Delegate every independent slice, with evidence checks.** Research, per-file edits, and
  verification each go to their own subagent (`subagent_type: builder` or `model: "sonnet"`,
  which keeps `advisor`); brief each completely — only the prompt string crosses over — and
  don't delegate a builder's own verification back to itself. Have subagents write large
  output to files and return a short summary plus the path; check each one's evidence before
  accepting its report. Second opinion on the orchestrator's own work: Fable (see Key Rules).
- **A task file for long runs.** For anything multi-hour or multi-PR: *"keep a TASKS.md
  checklist with the finish line at the top; update it as you go; re-read it after any
  compaction, before acting."* Context gets summarized; the file doesn't.
- **Eval/hillclimb campaigns need a budget gate.** For prompt/model/grader/harness loops,
  use the compact add-on in
  [`handoff/references/kickoff-templates.md`](handoff/references/kickoff-templates.md#e-evalhillclimb-campaign-kickoff-add-on)
  and the canonical protocol in
  [`handoff/references/eval-hillclimb-protocol.md`](handoff/references/eval-hillclimb-protocol.md).
  It covers eval splits, novelty reserve, budget, stop/revert, and
  `scripts/eval-hillclimb-decision.py` decisions.
- **Leave out "think carefully / step by step / ultrathink".** Models decide how much to
  think on their own; those lines add length, not quality. Same for ALL-CAPS or "MUST" — a
  reason attached to a rule holds up better than a rule shouted louder.

While it runs, **add context with `session-send`** rather than killing and respawning — the
session picks up a mid-run message without losing its work. When it reports done, **first
check what it needs from you** (a decision, an approval, a merge, a credential) and unblock
that, then read the rest of its summary.

## Naming

```
tmux session:    <prefix>_<alias>-<MMDD-HHMM>
remote-control:  <prefix>-<alias>-<MMDD-HHMM>
workdir (repo):  $CRSS_WORKSPACE/<foldername>     (default $HOME/workspace)
workdir (util):  $CRSS_SESSIONS_DIR/<foldername>  (default $HOME/.sessions)
```

Name-first, date last; every spawn gets a unique name, so it never collides with a
same-minute session. Use `workspace/` for repo sessions, `.sessions/` for utilities
(managers, monitors, etc.). `<prefix>` defaults to `cs` (`CRSS_SESSION_PREFIX`); a host that
changes prefix can list the old one(s) in `CRSS_LEGACY_PREFIXES` so `session-doctor` keeps
recognising older sessions.

`<alias>` comes from the `session-alias` helper, persisted in `~/.claude/session-aliases`
(`folder<TAB>alias` per line):

- Folder names `<= 18` chars are used as-is; longer ones become an initials acronym
  (`claude-remote-session-skill` → `crss`), saved so later spawns reuse it.
- **`--alias` is per-spawn.** Sessions habitually pass the *task* (`--alias crss-prs`), so it
  no longer rewrites the folder default. Add `--set-default-alias` only when the name
  describes the **folder**, not the task.
- **Protected folders are never aliased**: a folder matching `CRSS_ALIAS_PROTECT_NAMES`
  (see `examples/crss-overlay/config.sh.example`) keeps its full name so `session-doctor`
  can protect it by that token. (Narrower than reap's `CRSS_PROTECT_NAMES`, which also covers
  `claude-remote` bridge sessions; this repo's folder still shortens normally.)
- **Alias values are validated (anti-poisoning)** on read, write, and store upsert, so a
  stored alias that looks like a full session name can't produce
  `<prefix>-<prefix>-…-MMDD-MMDD`. Rules: `scripts/session-alias.sh`, pinned by
  `tests/test-session-alias.sh`.
- `session-alias --audit-store` read-only-reports stored entries that fresh inference now
  disagrees with; it never rewrites. A human decides what to change.

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
live processes.

## Sessions agent scope

Some hosts run a bounded sessions-management agent (session ops only, no project work),
enforced by its own `.claude/CLAUDE.md` (see `$CRSS_HOME/local.md`). If project work lands
there: write a handoff to that project's `memory/`, spawn or connect to the project session
(`handoff` skill), and tell the user which session has it — don't do the work yourself.
