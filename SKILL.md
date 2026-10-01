---
name: gstack-session-spawn
slug: gstack-session-spawn
version: "1.9.1"
tagline: "Create a persistent Claude remote session via tmux + systemd"
description: "Use when asked to create a remote session, schedule a persistent agent, spin up a Claude session for a project, or start a background Claude process. Creates a tmux+systemd session with --dangerously-skip-permissions, --continue auto-resume, and smart backoff."
allowed-tools:
  - Bash
---

# gstack-session-spawn

Use when asked to: "create a session for X", "create a remote session in X", "spin up an agent for X", or "start a background Claude process for X".

**Done** for a spawn means: `new-session` printed a `REMOTE_NAME`, the unit is active
(`systemctl --user is-active <REMOTE_NAME>.service`), and — if you gave it a task —
`--task` printed `Task sent … and verified landed.` The kickoff settles first (several
consecutive ready polls) and refuses rather than pasting blind:
`trust dialog open (or another menu/dialog widget)` means answer it by hand first
(`tmux send-keys -t <session> 1 Enter`); `claude not running in pane` means it isn't up
yet — wait and resend. On plain `UNVERIFIED` (common on first send), check the pane and
resend with `session-send` ([`references/troubleshooting.md`](references/troubleshooting.md)).
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
session-doctor reap <name> [--force] [--keep-registry] [--keep-worktree]
                                       # teardown (tmux + unit) + registry entry + worktree
session-doctor land-check             # report-only: per-worktree real-dirty + unlanded
session-resume <name> [--dry-run] [--uuid <id>] [--model <m>]
                                       # bring a DEAD session back on its own unit + transcript
```

**A dead session comes back with `session-resume`, never by hand.** Every agent, Codex
included: do not type `claude --resume <uuid> …` into a new tmux pane and do not
`systemctl --user start` the unit bare. A hand relaunch drops the unit's
`--dangerously-skip-permissions` and binary, so the session stalls on approval prompts
nobody sees; a bare unit start can open a fresh conversation instead of the old one.
`session-resume` resumes the session's own transcript by uuid through its own unit, keeps
the unit's launch flags, and refuses while anything still holds the session. Run
`--dry-run` first. Steps: header comment of `scripts/session-resume.sh`, pinned by
`tests/test-session-resume.sh`.

`reap` refuses protected names outright, and refuses a session with unlanded/uncommitted
work unless `--force` — rescue first via `session-preserve <name> --rescue --wip`. It also
removes that session's own `~/.claude/worktrees/<name>` git worktree by default (branch
kept; `--keep-worktree` opts out); guards: `references/session-lifecycle.md`.

### Codex Backend

`new-session --backend codex` uses the same session envelope as Claude (tmux session,
systemd user unit, start script, alias/name parsing, telemetry, `--task`/`--task-file`
kickoff, `session-send`/`session-handoff` landing verification, `session-doctor reap`
cleanup). The backend switch and Codex command are in `scripts/new-session.sh`; pane-state
detection is in `scripts/session-handoff.sh`.

Host defaults live in `$CRSS_HOME/config.sh`: `CRSS_SESSION_BACKEND=codex` changes the
default (generic default: Claude), `CRSS_CODEX_BIN` selects the binary, `CRSS_CODEX_ARGS`
supplies model, sandbox, and approval flags. Check the installed `codex --help` before
setting those args.

Claude-only features do not apply to Codex sessions: model/profile pinning,
`BUILDER_TOOLS`, `advisor`, `--settings`, remote-control registration, and the global
`.claude/skills` symlink/bootstrap are skipped. `session-doctor` tmux/systemd/worktree/reap
handling covers Codex sessions; Claude registry and transcript history stay Claude-specific.

Script lives at `~/.local/bin/new-session`. If it's missing, recreate it from
`references/fallback-recipe.md` (or copy `scripts/new-session.sh` directly).

**Deployed copies drift.** The skill dir and `/create-session` symlink into this repo's
canonical checkout; `~/.local/bin/*` are real copies — redeploy after landing a fix
(`install -m 755 scripts/<x>.sh ~/.local/bin/<x>`) or it stays inert, and **diff before
overwriting** or you silently revert a deployed-only hand-patch (how `advisor` fell out of
`BUILDER_TOOLS`). Full procedure: `CLAUDE.md` "Deploying".

## Key Rules

- `--dangerously-skip-permissions` always — sessions must never prompt
- Sentinel file `.sessions-init-<remote_name>` (touched before the first launch) makes every later restart `--continue`; a one-shot resume pin from `session-resume` overrides it with `--resume <uuid>`
- `using-superpowers` and the global skills are wired into every session automatically — don't wait for the user to ask
- One Bash call for the whole recipe — `new-session` is one command; don't split it into manual steps
- The *generated* start scripts and units are local-only (`~/.local/bin/`, `~/.config/systemd/user/`) — never commit them to any repo
- Git-aware run dir: a git workdir starts on the **default branch** (or a fresh worktree off it), never a stale feature branch — see below
- Model default is **per role** via `CLAUDE_SESSION_PROFILE`: `builder`→`sonnet`, `copywriter`→`haiku` (bare aliases, auto-track the latest release for their tier); `orchestrator`→`claude-opus-5-5`, **pinned** to an exact id (see `scripts/new-session.sh`'s "Model selection" comment for why). Override per-spawn with `CLAUDE_SESSION_MODEL=<model>`
- The Opus orchestrator has no `advisor` (Sonnet-only). For a second opinion it spawns a
  Fable subagent directly — `subagent_type: "reviewer"` (`agents/reviewer.md`, once
  deployed to `~/.claude/agents/`) or an ad hoc `Agent({description, prompt, model:
  "fable"})` — not a Sonnet builder, which would just be Sonnet checking its own
  reasoning. `model: fable` is a valid agent-frontmatter value on the installed CLI (a probe
  agent with it ran as a Fable model).
- ChatGPT is reached, if at all, through a project-specific relay subagent (not a standalone
  session), defined in that project's own `.claude/agents/` and roles table — don't copy its
  call-out details here. `$CRSS_HOME/local.md` says which projects have one.

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
  escalation. Default wording: *"When a step doesn't need me, keep going and put status in
  the same message as your next action. Stop and ask only if you can't continue without a
  decision from me, or before anything destructive (deleting data, force-pushing, touching
  anything outside this repo). Anything genuinely my call goes to me via `session-send
  <parent-session> --file <f>` — a numbered list with your recommended option. Decide
  defaults yourself when there's a normal recommended answer; report them afterwards."*
- **Concrete anti-patterns, not "be careful".** Name the specific mistakes to avoid in this
  domain ("don't branch from local `main`", "no deploys without explicit human approval in this session").
  A named habit gets avoided; a general caution gets ignored.
- **Delegate every independent slice.** Research, per-file edits, and verification each go
  to their own subagent (`subagent_type: builder` or `model: "sonnet"`, which keeps
  `advisor`); don't delegate a builder's own verification back to itself, and brief each one
  completely — only the prompt string crosses over. Second opinion on the orchestrator's own
  work: Fable (see Key Rules).
- **Context hygiene.** Have subagents write large research, logs, or diffs to files and
  return a short summary plus the file path, instead of dumping it inline.
- **A task file for long runs.** For anything multi-hour or multi-PR: *"keep a TASKS.md
  checklist with the finish line at the top; update it as you go; re-read it after any
  compaction, before acting."* Context gets summarized; the file doesn't.
- **Subagents with evidence checks for large audits/migrations.** *"Give each slice its own
  subagent (`subagent_type: builder`), have it write large output to files, and return a
  short summary; check each one's evidence before accepting its report."*
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
- **Protected folders are never aliased**: a folder matching your host's
  `CRSS_ALIAS_PROTECT_NAMES` (e.g. `my-other-bridge` — see
  `examples/crss-overlay/config.sh.example`) keeps its full name so `session-doctor` can
  protect it by that token. (Narrower than reap's own `CRSS_PROTECT_NAMES`, which also
  covers `claude-remote` bridge sessions — this repo's folder merely contains that string
  and still shortens normally.)
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
| Is the fleet/server healthy? | `fleet-status` (`--sessions`, `--host`) | composes `session-doctor report`, `worktree-stale`, a host health snapshot (prints its age), and a token-savings tool's summary, where the host has them. On demand only. |
| Which sessions are older than N? | `session-registry --older-than 3d` | age = *first-ever* spawn from `~/.sessions/session-starts.log`, so a restart doesn't reset it |
| What ran in this folder before / now? | `session-doctor history <folder-or-substring>` | NOW (live, idle mins) + PAST (from transcripts, which outlive worktrees) + branch/landed/dirty |
| Relay into an idle/stale session | `session-compact before-relay <name> "task"` | compacts, verifies, then relays; fails closed. Don't compact under ~60 min idle — the 1h cache is still live |
| Recycle a bloated session | `session-preserve <s> --rescue --wip` → must print `SAFE-TO-REAP` | then stop the unit and respawn; **never reap before this** |
| Session went silent | `tmux capture-pane -p -t <s>` | bloat vs. hook wedge vs. stuck menu — see runbooks |
| Clean up stale registry entries | `session-doctor registry-prune [--days N] [--apply]` | dry-run by default; `reap <name>` also prunes that session's own entry unless `--keep-registry` — see `references/session-lifecycle.md` |
| Clean up a reaped session's leftover worktree | `session-doctor worktree-stale` | for one NOT already handled — `reap <name>` removes its own worktree automatically (`--keep-worktree` to skip); see `references/session-lifecycle.md` |

Host-specific ops tooling lives outside this repo.

Runbooks for compaction, recycling, hook-wedged sessions, and stuck-menu sessions:
[`references/troubleshooting.md`](references/troubleshooting.md). Session layers, reaping and
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

| File | Holds | Read by |
|---|---|---|
| `config.sh` | `CRSS_*=value` settings (parsed, never sourced) | the scripts that load it (`new-session`, `session-doctor`, `session-handoff`, `session-preserve`, `session-registry`, `session-alias`, `session-resume`, `fleet-status`, telemetry scripts); not `session-compact`, `session-git-prep`, `session-send` |
| `local.md` | host prose: operator handle, escalation channel, project index, routing | agents, via a tiny user rules file that `@`-imports it |
| `leak-denylist.txt` | host-private terms that must never reach this repo | `tests/test-no-host-leaks.sh`, only when `CRSS_LEAK_DENYLIST` is set |

To add a host fact: machine-readable knob goes in `config.sh` (see
`examples/crss-overlay/config.sh.example`), human/agent prose goes in `local.md`; do not edit
`SKILL.md` or any file in this repo. Step-by-step setup, the denylist term syntax, and how to
run the stricter local leak check are in
[`examples/crss-overlay/README.md`](examples/crss-overlay/README.md). `session-doctor overlay`
reports whether the overlay is healthy.

## Cross-session knowledge: agent-memory, not a new bus

For durable facts other sessions should inherit, most hosts wire up a shared memory
convention (a memory-store repo, a knowledge tool) through the user-level
`~/.claude/CLAUDE.md` every session already loads; its details (root, namespace, sync
command, citation format) are there or in `$CRSS_HOME/local.md`, not here.

"Who else is working here right now" is a different question — use
`session-doctor history`, which derives presence from live processes.

## Sessions agent scope

Some hosts run a bounded sessions-management agent (session ops only, no project work),
enforced by its own `.claude/CLAUDE.md`. If yours does — see your host's
`$CRSS_HOME/local.md` — and project work lands there anyway: write a handoff to that
project's `memory/`, spawn or connect to the project session (use the `handoff` skill),
and tell the user which session has it — don't do the work yourself.
