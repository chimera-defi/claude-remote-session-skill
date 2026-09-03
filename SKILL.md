---
name: gstack-session-spawn
slug: gstack-session-spawn
version: "1.8.9"
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
- Pass `-a`/`--alias <x>` to `new-session` for a one-off name (this spawn only);
  add `--set-default-alias` to persist it as the folder default.
- **Protected folders are never aliased.** A folder whose name matches `openclaw|hermes`
  keeps its full name (aliasing would strip the token `session-doctor` needs to protect it;
  `--alias` is ignored for these). This `ALIAS_PROTECT` guard is deliberately narrower than
  `session-doctor`'s reap `PROTECT` (`claude-remote|openclaw|hermes`): the bare
  `claude-remote`/`claude-remote-b` bridge sessions aren't spawned via `new-session`, so a
  folder that merely contains `claude-remote` (like this repo) is a normal dev session that
  shortens and is reapable like any other.
- **Alias values are validated (anti-poisoning).** An alias that itself looks like a full
  session name — an `ah-` prefix, an `MMDD-HHMM` timestamp, a trailing `-MMDD` date, or a
  long numeric run paired with a real date fragment — is rejected and a clean alias
  re-inferred. Enforced on **read** (a poisoned stored value is discarded and self-healed),
  on **write** (`--alias`), and as a `store_upsert` backstop — so a bad entry from an errant
  `--alias`, an external writer, or legacy data can never produce doubled `ah-ah-…-MMDD-MMDD`
  session names. Gating is calendar-validated, so ordinary digit runs (`sprint-2024`,
  `port-8080`, `chain-84532`, `issue-12345`) keep distinct aliases. The detection rules
  themselves live in `scripts/session-alias.sh` and are pinned by 69 assertions in
  `tests/test-session-alias.sh` — read those rather than restating them here.
- **`--alias` is PER-SPAWN and does not change the folder's default.** Sessions habitually
  pass the *task* (`--alias crss-prs`, `trs-fix`, `pssot-indep`) rather than the folder, and
  when that used to persist automatically it was the dominant source of drift — two audits
  found 11-of-37 and 11-of-42 entries drifted, every one this shape, none collisions. Fixed
  2026-09-03: pass `--set-default-alias` to actually rewrite the folder default, and only
  when the name describes the **folder**, not the task.
- `session-alias --audit-store` read-only-scans the whole store and reports entries where
  fresh inference now disagrees with what's stored (e.g. a pre-fix collision) — it never
  rewrites anything; a human decides whether to leave, re-`--alias --set-default-alias`,
  or clear the line.

## Key Rules

- `--dangerously-skip-permissions` always — sessions must never prompt
- Sentinel file `.sessions-init` prevents 0s exit on fresh workdirs triggering 300s backoff
- Auto-wire `using-superpowers` and all global skills into every session — do not wait for user to request it
- One Bash call for the entire recipe — do not split into multiple tool calls
- Scripts are local-only (`~/.local/bin/`, `~/.config/systemd/user/`) — no repo commits
- Git-aware run dir: when the workdir is a git repo, sessions start from the **default branch** — never a stale feature branch — and parallel sessions never collide (see below)
- Model default is **per role** via `CLAUDE_SESSION_PROFILE`: `builder`→`sonnet`, `copywriter`→`haiku` (bare aliases, auto-track the latest release for their tier); `orchestrator`→`claude-opus-5`, **pinned** to an exact id rather than the bare `opus` alias (see `scripts/new-session.sh`'s "Model selection" comment for why). Override per-spawn with `CLAUDE_SESSION_MODEL=<model>`. `new-session` only warns on a moving bare alias when one is passed *explicitly* — never for a role default

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

**Check the workdir is the repo you actually mean — a project's *name* is not always its
folder.** Because non-git workdirs skip `session-git-prep` entirely, spawning against a
same-named stub fails silently: no worktree, no default-branch checkout, no lock. The
non-git branch of `session-git-prep` is a bare `emit "$REPO"` with **no `log` call** — every
other branch logs what it did, this one says nothing — so the only signal is the absence of
one. Worse than landing in an empty directory, the stub can carry its own `CLAUDE.md` and
`AGENTS.md`, which load as project instructions and make the wrong folder read as right.
Verified 2026-08-24: the portfolio project is called `portfolio-ssot` everywhere it is
referenced — its CLAUDE.md says `gbrain sync --source portfolio-ssot`, its `.gbrain-source`
file reads `portfolio-ssot` — but the actual checkout is
`workspace/portfolio-single-source-of-truth`, while `workspace/portfolio-ssot` is a leftover
**non-git** scratch dir holding exactly the six files (`CLAUDE.md`, `AGENTS.md`, a stale
handoff, …) that make it look like the real thing. One command settles it before you spawn:

```bash
git -C /home/agents/workspace/<foldername> rev-parse --show-toplevel
```

A `fatal: not a git repository` on a folder you expected to be a repo means you have the
wrong folder, not a broken repo — resolve the real checkout first, then spawn against that.

## Recipe — use the script (preferred)

A standalone script handles the full recipe. Use it directly:

```bash
new-session <foldername>              # auto-detects workspace/ vs .sessions/
new-session <foldername> workspace    # force workspace/
new-session <foldername> sessions     # force .sessions/
new-session <foldername> --alias x    # explicit short alias (THIS spawn only)
new-session <foldername> --alias x --set-default-alias   # ...and make it the folder default
new-session <foldername> --dry-run    # print resolved names and exit (no session spawned, store untouched)
new-session --help                    # print usage and exit (no session spawned)

new-session <foldername> --task "..."        # spawn AND kick off, in one shot
new-session <foldername> --task-file <path>  # same, task text read from a file
```

**Prefer `--task`/`--task-file` over typing the kickoff by hand.** It polls until claude is
ready in the pane, sends, then verifies the message landed — the manual type/verify/Enter
dance drops the Enter often enough to matter, leaving the session idle with no error. The
two flags are mutually exclusive; an unreadable `--task-file` fails *before* anything spawns.

Relaying into an already-running session, and tearing one down:

```bash
session-send <name> "..."             # relay a follow-up (or --file <path>)
session-doctor reap <name> [--force]  # teardown of a named ALIVE session (tmux + unit)
session-doctor land-check             # report-only: per-worktree real-dirty + unlanded
```

`reap` is the live counterpart to `reap-local` (which only handles already-dead sessions).
It refuses protected names outright, and refuses a session with unlanded/uncommitted work
unless `--force` — rescue first via `session-preserve <name> --rescue --wip`.

Script lives at `~/.local/bin/new-session`. If it's missing, recreate it from
`references/fallback-recipe.md` (or copy `scripts/new-session.sh` directly).

**Deployed copies drift.** The skill dir and `/create-session` symlink into this repo, so
they can't rot; `~/.local/bin/*` are real copies — after landing a fix, redeploy
(`install -m 755 scripts/<x>.sh ~/.local/bin/<x>`) or it stays inert, and **diff before
overwriting** or you silently revert a deployed-only hand-patch (how `advisor` fell out of
`BUILDER_TOOLS`).

## After Creating

Connect from Claude Code app: look for `ah-<alias>-<MMDD-HHMM>` in remote sessions.
Each spawn gets a unique name — never collides with same-minute sessions.
(Scripts are local-only — see Key Rules.)

## Finding stale sessions: session-registry

"Which sessions are older than N days" is a cheap, repeatable query — no manual
tmux/log scan needed:

```bash
session-registry                     # every live ah_/agenthost_ session, oldest first
session-registry --older-than 3d     # filter to sessions older than N days (or Nh)
```

Age is the session's **first-ever spawn**, read from the existing
`~/.sessions/session-starts.log` (every `new-session` invocation already writes
a `starting`/`started`/`already-running` line there — no new instrumentation
needed, this is a read-only query layer, not a second source of truth). A
restart keeps the same tmux session name but must not reset its age, so age is
the *earliest* log line for that name, not the most recent one — tmux's own
`#{session_created}` resets on every systemd restart and would under-report
age for a bounced session, the dangerous direction for a reap decision.
`#{session_created}` is used only as a fallback for a live session with zero
log entries.

## Preserve before reaping (recycling a bloated session)

Long-lived sessions accumulate context until every turn is slow and expensive.
Recycling one — kill it, spawn a fresh session on the same repo — is the fix.
**Never reap before `session-preserve` says it is safe.**

```bash
session-preserve <tmux-session>            # audit only. exit 0 = safe to reap
session-preserve <tmux-session> --rescue   # + copy non-junk untracked files aside
session-preserve <tmux-session> --wip      # + WIP-commit uncommitted tracked changes
session-preserve --all                     # audit the whole fleet
```

Recycle recipe:

```bash
session-preserve <s> --rescue --wip        # must print SAFE-TO-REAP
systemctl --user disable --now <base>.service
tmux kill-session -t <s>
new-session <foldername> workspace --alias <new-alias>
```

**Never use `git log @{u}..` to decide whether work is pushed.** It returns
*nothing* when a branch has no upstream configured, so unpushed work reads as
clean. On 2026-08-17 that mistake reported 10,162 local-only commits as "0
unpushed" and nearly authorised a reap sweep across them. Use
`git log HEAD --not --remotes`, and check `git remote` separately — a repo with
**no remote at all** (e.g. `portfolio-single-source-of-truth`, 155 local
branches, zero remotes) cannot be pushed anywhere, so its branch refs are the
only copy that exists.

What actually makes a reap safe is that **HEAD is reachable from a named local
branch** — then killing the session and removing its worktree cannot orphan the
commits, because they stay in the canonical repo's object store. It follows
that *deleting the branch* is the dangerous operation, not reaping. Any worktree
GC must leave `session/*` and research branches alone.

Respawned sessions start on a fresh worktree cut from the default branch, **not**
on the old session's branch. Say so in the kickoff: name the prior branch, the
prior transcript path, and what the session was mid-way through, or the
replacement re-derives it at full cost.

## Detecting a hook-wedged session (different from bloat)

A session can go silent for a reason that looks identical to the "send didn't
land" failure mode but has a different mechanism and a different fix: a
`UserPromptSubmit` or `PreToolUse` hook in the session's own
`.claude/settings.json` throws (a subprocess spawn error, a missing script, an
unhandled exception) and has **no fail-open guard**. Because
`UserPromptSubmit` fires on *every* prompt, once it starts erroring, every
future prompt — including plain retries like "try again" — is rejected before
Claude ever sees it. No amount of resending fixes this from inside the
session; resending IS the thing that keeps failing.

**Symptom in `tmux capture-pane -p`:** repeated blocks shaped like

```
UserPromptSubmit operation blocked by hook:
  [<command>]: error: Failed to spawn: `<script>`
    Caused by: No such file or directory (os error 2)

  Original prompt: <whatever was sent>
```

with no `✻`/`●` processing indicator after it — the agent process is alive and
idle, but unreachable. This happened on 2026-08-17 to `ah-trs-fix-0816-2008`
(ironically, a session tasked with hardening the very hook scripts that then
wedged it): a `PreToolUse` hook spawn error blocked Bash/Read/Grep/Glob, the
in-session `advisor()` call stalled 16 minutes and errored, and every prompt
sent after that — from the user and from a live diagnostic retry — was
rejected by the same broken `UserPromptSubmit` hook.

**Diagnose:** `cat <rundir>/.claude/settings.json` and look at the failing
hook's command. If it has no fail-open guard (compare to a sibling hook line
in the same file that does, e.g. `[ -x <script> ] && <script> || exit 0`),
a subprocess error there is a hard, permanent block — not a fluke worth
retrying.

**Recover:** same mechanics as the bloat recycle recipe above — a hook wedge
is not a special case for reaping:

```bash
session-preserve <s> --rescue --wip        # runs from OUTSIDE the wedged session — unaffected by its hook
systemctl --user disable --now <base>.service
new-session <foldername> workspace --alias <same-alias>
```

Then hand off the wedged session's actual state in the kickoff (branch, task
list, what was in progress) since its own transcript may be unrecoverable —
`tmux capture-pane -S` is capped by the pane's history-limit and may not reach
back to the original kickoff.

**Prevention (tell whoever fixes the hook):** any script wired to
`UserPromptSubmit` or `PreToolUse` must fail open — catch spawn/subprocess
errors and `exit 0` rather than propagate — because a failure there doesn't
just fail one tool call, it can permanently wedge the whole session.

## Detecting a stuck-on-a-menu session (different from both wedge types above)

A session can look wedged for a third reason that has nothing wrong with it
at all: it's mid an interactive multi-choice widget (an `AskUserQuestion`-style
prompt — numbered options with `[ ]`/`[✔]` checkboxes, a
`←  ☐ Next direction  ✔ Submit  →` bar, "Enter to select · ↑/↓ to navigate ·
Esc to cancel") and whoever replied sent ordinary free text instead of
navigating it. The widget only understands arrow keys + Enter (and a
dedicated "Type something" option for free text); a plain sentence sent into
it is not a valid input, so it just sits there inert — the session looks
unresponsive to normal chat, but the agent process is perfectly healthy the
whole time. Confirmed on 2026-08-21 (`ah-frontend-refactor-0821-0657`): a
plain-text reply ("all good?") to a "where should I point the next
iterations" menu never registered; the widget was still waiting for a
selection.

**Symptom in `tmux capture-pane -p`:** a numbered option list with checkboxes
and the `↑/↓ to navigate` hint still on screen, with a plain-text line sitting
below it that was clearly meant as an answer but isn't reflected in any
checkbox state.

**Recover (no reap needed — this is not a broken session):**
1. `tmux send-keys -t <s> Down` (or `Up`) and re-capture to confirm the `❯`
   marker actually moves — this proves the widget is live and just
   mis-navigated, not stuck for some other reason.
2. Navigate to the option that best matches what the original sender meant
   (`Enter` toggles a `[ ]`→`[✔]` checkbox on the highlighted option — it does
   **not** submit).
3. `Right` arrow to move from the options page to "Submit", then `Enter` again
   on the review screen ("1. Submit answers") to actually confirm. Re-capture
   after each step — the same "type, act, verify" discipline as any other
   kickoff, just with arrow keys instead of literal text.

Check `session-preserve` / `git log HEAD --not --remotes` before doing
anything if there's any doubt — but a stuck-menu session usually has nothing
to lose: it was mid a *review* pause, not mid an edit.

## Sessions Agent Scope

A sessions management agent (workdir `/home/agents/.sessions/agenthost-sessions`) has a **bounded scope**:

- **Allowed**: create sessions, write handoffs to `memory/` in target repos, relay context, monitor session status
- **NOT allowed**: run scripts, execute optimizers, make code changes, or do project work for another repo

If project-specific work arrives in a sessions agent's context (e.g. a handoff describing optimizer runs):
1. Write a handoff to that repo's `memory/` folder with the pending work
2. Spawn or connect to the appropriate project session
3. Tell the user what session to use — do NOT execute the work yourself

The sessions agent's `CLAUDE.md` at `/home/agents/.sessions/agenthost-sessions/.claude/CLAUDE.md` enforces these rules.
