# claude-remote-session-skill — agent instructions

This repo is the session tooling (`new-session`, `session-send`, `session-handoff`,
`session-doctor`, `session-preserve`, `session-compact`, …) that **every live session on
this host runs from `~/.local/bin`**. A bad change here breaks the whole fleet, not just
this repo. Skill docs: `SKILL.md` (spawn/operate sessions), `handoff/` (route work to
another session), `references/` (runbooks), `agents/` (subagent definitions).

## What "done" means for a change here

A change is done when **all** of these are true — not before:

1. Full suite passes locally (same as CI's `shell-tests`):
   ```bash
   for t in tests/test-*.sh; do bash "$t" || echo "FAILED: $t"; done
   shellcheck -S warning -e SC2010 scripts/*.sh tests/*.sh
   ```
2. It's on a branch cut from **`origin/main`** (not local `main` — see anti-patterns), in a
   PR, `shell-tests` is green, and it's merged. Never push to `main`; never self-approve.
3. Every changed deployable is redeployed and verified (see "Deploying" below). A fix that
   is merged but not redeployed is inert for the fleet.
4. You've told the operator what landed, what was redeployed, and anything left undone.

If the task is smaller than a code change (an audit, a report), its own brief defines done;
if it doesn't, write the finish line down yourself before starting.

## When to keep going vs. stop and ask

Keep going when a step doesn't need the operator. Put status notes in the same message as
your next action instead of pausing for acknowledgement.

Stop and ask **only** when:
- you can't continue without a decision that is genuinely the operator's (conflicting
  requirements, a trade-off the brief doesn't settle), or
- the next step is destructive or outward-facing: deleting branches/worktrees/files you
  didn't create, force-pushing, reaping or restarting a session you don't own, resetting a
  shared checkout, deleting registry entries, or changing anything outside this repo other
  than the documented redeploy targets.

A test failing for a reason you can explain is not a reason to stop — fix it. A test failing
for a reason you *can't* explain is.

## Anti-patterns this repo has already paid for

Each of these has happened here. Don't repeat them.

- **Branching from or committing to local `main`** in the canonical checkout
  (`/home/agents/workspace/claude-remote-session-skill`). Other agents leave in-flight work
  there; it has diverged from `origin/main` before. Cut branches from `origin/main`, and
  check `gh pr list` + `git branch -r` for active work you'd collide with.
- **`cp`/`install` over `~/.local/bin/<x>` without diffing first.** Deployed copies drift in
  *both* directions; a blind overwrite silently reverted a deployed-only hand-patch (that's
  how `advisor` fell out of `BUILDER_TOOLS`).
- **`git log @{u}..` to decide whether work is pushed.** With no upstream it prints nothing,
  so unpushed work reads as clean (once reported 10,162 local-only commits as "0 unpushed").
  Use `git log HEAD --not --remotes` and check `git remote` separately.
- **`git cherry` / patch-id to decide a branch is landed.** Squash merges change patch-ids.
  Verify by content diff against `origin/main` or by the PR's merge record before deleting.
- **Deleting a `session/*` or research branch** to "clean up". The branch ref is what keeps
  a reaped session's commits reachable; deleting it is the dangerous step, not the reap.
- **Accepting a tool's "safe"/"nothing to preserve" verdict without looking.**
  `session-preserve` once called an orphan worktree holding 320 unsaved lines safe. Before
  any reap, enumerate on-disk state yourself (`git status`, untracked files, worktree list).
- **Treating green fixture tests as proof a sensor/actuator tool works.** 619 passing
  assertions once hid a self-observation feedback loop. Run tools that read or act on live
  sessions against a live session before automating them.
- **Writing config keys or CLI flags from memory or from another agent's summary.**
  `autoCompactEnabled`/`autoCompactWindow` were fabricated by a guide agent and don't exist.
  Check the installed CLI (`claude --help`, its schema) before documenting a knob.
- **Restating a script's rules in prose.** Docs that restate detection logic drift from it.
  Point at the script and the test that pins it (as `SKILL.md` does for alias validation).
- **Trusting `status=clean` / SAFE-TO-REAP before removing a worktree.** A clean worktree
  can hold gitignored results, and `git worktree remove` deletes them (2026-08-29
  exp-lab loss: a research campaign's `artifacts/`). `reap` now archives them first
  (`_wt_archive_ignored`); a hand-run `git worktree remove` does not.
- **Bare `git stash` / `git stash pop`.** The stash stack is shared across every worktree
  and session. Use a WIP commit instead.
- **`git worktree remove` without disabling the session's systemd unit** — leaves an orphan
  unit restarting into a missing directory.

## Large audits and migrations: subagents, then verify

For work that spans many files or many sessions (a doc audit, a fleet-wide check, a
multi-script migration), give each independent slice to its own subagent. Spawn them with
`subagent_type: builder` or `model: "sonnet"` — a subagent that inherits an Opus 5.x model
silently loses the `advisor` tool.

**Check each subagent's evidence before accepting its report.** A summary saying "fixed" or
"no issues" is a claim, not a result: re-run the command it cites, open the file:line it
names, or diff the change yourself. If it gave no evidence, treat the item as unverified.
Consolidate the verified results in one table at the end.

**The Opus orchestrator's own second opinion is Fable, not a Sonnet builder.** (Operator
directive, 2026-09-26.) Opus 5.x has no `advisor` tool; spawning a Sonnet builder for a
second opinion is Sonnet re-checking its own reasoning, not an independent perspective.
Spawn Fable directly instead — `Agent({description, prompt, model: "fable"})` — at the
forks `advisor` would otherwise cover: before a risky or destructive action, before
committing to a design under real ambiguity, before declaring a multi-step task done. A
Sonnet orchestrator keeps using `advisor` natively; this is specifically the Opus path.

## Long runs: keep a task file

If the work will outlive one context window (multi-PR, multi-hour, anything likely to be
compacted), keep a checklist file — `TASKS.md` in your scratchpad or worktree, not committed
unless the operator asks — with the finish line at the top and one line per step. Update it
as you go. After a compaction, re-read it before acting; the summary alone loses detail.

## Before asking for review

Review your own diff first (`git diff origin/main...`) and list only merge-blocking problems:
for each, the file and line, why it's wrong, and how to show it fails. Fix those before
opening the PR; put anything you deliberately left unfixed in the PR body.

## Deploying

After merge, for each changed deployable:

| Repo source | Deployed to | How |
|---|---|---|
| `scripts/<x>.sh` | `~/.local/bin/<x>` | `diff` first, then `install -m 755` |
| `agents/<name>.md` | `~/.claude/agents/<name>.md` | `diff` first, then `install -m 644` |
| `SKILL.md`, `handoff/`, `references/`, `.claude/commands/create-session.md` | symlinked from the canonical checkout | canonical checkout must be on `origin/main` |

If a diff shows the deployed copy has changes the repo lacks, stop — that's a deployed-only
patch that must be landed in the repo first, not overwritten.

The skill docs are only live once the **canonical checkout** reflects `origin/main`. If that
checkout has diverged or carries someone else's uncommitted work, don't reset it — report it
to the operator (see "stop and ask").
