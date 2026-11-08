# claude-remote-session-skill — agent instructions

This repo is the session tool `crss` (`scripts/crss.sh`; the old names `new-session`,
`session-send`, `session-handoff`, `session-doctor` and `session-preserve` are symlinks to
`scripts/crss-compat.sh`). **Every live session on this host runs it from `~/.local/bin`**, so a bad
change breaks the whole fleet. Skill docs: `SKILL.md`, `handoff/`, `references/`, `agents/`.

## What "done" means for a change here

All of these, not before:

1. The full suite passes locally (same as CI's `shell-tests`):
   ```bash
   for t in tests/test-*.sh; do bash "$t" || echo "FAILED: $t"; done
   shellcheck -S warning scripts/*.sh tests/*.sh
   ```
   `tests/test-no-host-leaks.sh` is in that loop. This is a public repo, so it fails the build on an
   absolute home path, a real email, or a github.com URL naming another owner. On a host with an
   overlay also run it with your private denylist (never checked in):
   ```bash
   CRSS_LEAK_DENYLIST="${CRSS_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/crss}/leak-denylist.txt" bash tests/test-no-host-leaks.sh
   ```
2. It is on a branch cut from **`origin/main`** (not local `main`), in a PR with `shell-tests`
   green, reviewed by a non-Claude family (gpt-6.1-sol; name the model in the PR body), and merged
   with `gh pr merge --merge`, keeping the branch. No squash: branches should merge in. Never push to
   `main`. Grok never reviews (operator 2026-11-01); Fable reads are paused (2026-10-28) and Fable
   alone doesn't count. With Codex out the PR waits, review marked UNVERIFIED.
3. Every changed deployable is redeployed and verified (see "Deploying"). Merged but not redeployed
   is inert for the fleet.
4. You've told the operator what landed, what was redeployed, and what is left undone.

A smaller task (an audit, a report) is defined by its own brief; if it has none, write the finish
line down first.

## Keep going vs. stop and ask

Keep going when a step doesn't need the operator; put status in the same message as the next
action, and act on the recommended answer. Stop and ask only when a decision is genuinely the
operator's, or the next step is destructive or outward-facing: deleting branches or files you didn't
create, force-pushing, resetting a shared checkout, or changing anything outside this repo except the
documented redeploy targets. Reaps go through `crss reap` and need no asking. A test failing for a
reason you can explain is not a reason to stop; one you can't explain is.

## Anti-patterns this repo has already paid for

- **Branching from or committing to local `main`** in the canonical checkout (the target of the
  `~/.claude/skills/<skill>` symlink; its path is in `$CRSS_HOME/local.md`). Other agents leave
  work there. Cut from `origin/main`, and check `gh pr list` and `git branch -r` for collisions.
- **`cp`/`install` over `~/.local/bin/<x>` without diffing first.** Deployed copies drift both ways;
  a blind overwrite once reverted a deployed-only patch (`advisor` fell out of `BUILDER_TOOLS`).
- **`git log @{u}..` to decide whether work is pushed.** No upstream prints nothing. Use
  `git log HEAD --not --remotes` and check `git remote`.
- **`git cherry` / patch-id to decide a branch is landed.** Squash merges (old history is squashed)
  change patch-ids. Verify by content diff against `origin/main` or the PR's merge record.
- **Deleting a `session/*` or research branch.** The ref keeps a reaped session's commits reachable.
- **Accepting a tool's "safe" or "nothing to preserve" verdict.** Enumerate on-disk state yourself
  (`git status`, untracked files, worktree list) before any reap.
- **Treating green fixture tests as proof a sensor or actuator tool works.** Run tools that read or
  act on live sessions against a live session before automating them.
- **Writing config keys or CLI flags from memory or another agent's summary, or trusting an
  unverified "that's fabricated".** Check the installed CLI (`--help`, settings schema) in both
  directions before documenting a knob.
- **Restating a script's rules in prose.** It drifts. Point at the script and the test that pins it.
- **Trusting `status=clean` before removing a worktree.** A clean worktree can hold gitignored
  results, and `git worktree remove` deletes them. `crss reap` archives them first.
- **Bare `git stash`.** The stack is shared across all worktrees and sessions. Use a WIP commit.
- **Removing a session's worktree without retiring the session.** `crss-up.timer` restarts it into
  the missing directory. Use `crss reap`.

## Large audits and migrations

Give each independent slice its own delegate: implementation to Codex gpt-6.1-terra low first
(`references/orchestration-flow.md`), read-only slices to Haiku, a Claude builder as
`subagent_type: builder` or `model: "sonnet"` (an Opus-inheriting one costs more).
`usage-audit --opus-subagents [--days N]` counts Opus subagent transcripts.

**Check each subagent's evidence before accepting its report.** "Fixed" is a claim: re-run the
command it cites, open the file:line, or diff the change. Consolidate verified results in one table.

**Second opinions:** an Opus orchestrator uses its native `advisor` for routine forks
(`references/spawn-guide.md`). The independent read at risky forks and before declaring done is one
gpt-6.1-sol call on a frozen packet, never a Sonnet builder and never Grok; otherwise mark it
UNVERIFIED. This is not the second-family merge review in "done".

## Long runs

Work that will outlive one context window needs a `TASKS.md` in your scratchpad or worktree (not
committed unless asked): finish line on top, one line per step. Re-read it after a compaction.

## Before asking for review

Review your own diff (`git diff origin/main...`) and list only merge-blocking problems: file and
line, why it's wrong, how to show it fails. Fix them before the PR; put anything left unfixed in the
PR body.

## Deploying

After merge, for each changed deployable:

| Repo source | Deployed to | How |
|---|---|---|
| `scripts/crss.sh` | `~/.local/bin/crss` | `diff` first, then `install -m 755` |
| `scripts/crss-compat.sh` | `~/.local/bin/crss-compat`, plus symlinks `new-session`, `session-send`, `session-handoff`, `session-doctor`, `session-preserve` → `crss-compat` | `diff` first, then `install -m 755` |
| `systemd/crss-up.{service,timer}` | `~/.config/systemd/user/` | `diff` first, `install -m 644`, `systemctl --user daemon-reload` |
| `agents/<name>.md` | `~/.claude/agents/<name>.md` | `diff` first, then `install -m 644` |
| `SKILL.md`, `handoff/`, `references/`, `.claude/commands/create-session.md` | symlinked from the canonical checkout | canonical checkout must be on `origin/main` |

Five old helpers stay deployed in `~/.local/bin` though no longer in this repo: `session-git-prep`,
`session-trust-seed`, `crss-tmux-scope`, `codex-resume-pin` and `crss-lib.sh`. The protected
sessions' start scripts call them; git history has their source. Don't remove them until those
sessions run on `crss`.

If a diff shows the deployed copy has changes the repo lacks, stop and land that patch in the repo
first. The skill docs are live only once the canonical checkout reflects `origin/main`; if it has
diverged or carries someone else's uncommitted work, don't reset it, report it.

## Usage habits

Start a fresh session or hand off at a task boundary; don't carry one past about 2h. Keep the
always-on prefix small (deny or name-only unused MCP tools and skills). Bulk reads, sweeps and builds
go to Haiku or Codex. `usage-audit --days 7` re-runs the audit.
