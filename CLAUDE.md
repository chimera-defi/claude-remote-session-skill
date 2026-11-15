# claude-remote-session-skill — agent instructions

This repo is the session tool `crss` (`scripts/crss.sh`; the old names `new-session`,
`session-send`, `session-handoff`, `session-doctor` and `session-preserve` are symlinks to
`scripts/crss-compat.sh`). A deployed copy (for example in `~/.local/bin`) may be what every live
session runs, so a bad change can break the whole fleet. Skill docs: `SKILL.md`, `handoff/`, `references/`, `agents/`.

## What "done" means for a change here

All of these, not before:

1. The full suite passes locally (same as CI's `shell-tests`):
   ```bash
   for t in tests/test-*.sh; do bash "$t" || echo "FAILED: $t"; done
   shellcheck -S warning scripts/*.sh tests/*.sh
   ```
   `tests/test-no-host-leaks.sh` is in that loop. This is a public repo, so it fails the build on an
   absolute home path, a real email, a github.com URL naming another owner, or a dated ruling
   reference. On a host with an overlay also run it with your private denylist (never checked in;
   `CRSS_HOME` is defined in [`examples/crss-overlay/README.md`](examples/crss-overlay/README.md)):
   ```bash
   CRSS_LEAK_DENYLIST="${CRSS_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/crss}/leak-denylist.txt" bash tests/test-no-host-leaks.sh
   ```
2. It is on a branch cut from **`origin/main`** (not local `main`), in a PR with `shell-tests`
   green, reviewed by an independent reviewer, preferably a different model family, named in the PR
   body ([rule](references/spawn-guide.md#second-opinions)), and merged with `gh pr merge --merge`,
   keeping the branch. No squash: branches should merge in. Never push to `main`. Host-specific
   reviewer policy lives in the overlay (`$CRSS_HOME/staffing.md`).
3. Every changed deployable is redeployed and verified (see "Deploying"). Merged but not redeployed
   is inert for the fleet.
4. You've told the user what landed, what was redeployed, and what is left undone.

A smaller task (an audit, a report) is defined by its own brief; if it has none, write the finish
line down first.

## Keep going vs. stop and ask

Keep going when a step doesn't need the user; put status in the same message as the next
action, and act on the recommended answer. Stop and ask only when a decision is genuinely the
user's, or the next step is destructive or outward-facing: deleting branches or files you didn't
create, force-pushing, resetting a shared checkout, or changing anything outside this repo except the
documented redeploy targets. Reaps go through `crss reap` and need no asking. A test failing for a
reason you can explain is not a reason to stop; one you can't explain is.

## Anti-patterns this repo has already paid for

- **Branching from or committing to local `main`** in the canonical checkout (the target of the
  `~/.claude/skills/<skill>` symlink; its path is in your overlay's `local.md`, if you keep one). Other agents leave
  work there. Cut from `origin/main`, and check `gh pr list` and `git branch -r` for collisions.
- **`cp`/`install` over `~/.local/bin/<x>` without diffing first.** Deployed copies drift both ways.
- **`git log @{u}..` to decide whether work is pushed, or deleting `session/*` branches, or removing
  a session worktree by hand.** See [troubleshooting](references/troubleshooting.md#compact-or-recycle).
- **`git cherry` / patch-id to decide a branch is landed.** Squash merges
  change patch-ids. Verify by content diff against `origin/main` or the PR's merge record.
- **Accepting a tool's "safe" or "nothing to preserve" verdict.** Enumerate on-disk state yourself
  (`git status`, untracked files, worktree list) before any reap.
- **Treating green fixture tests as proof a sensor or actuator tool works.** Run tools that read or
  act on live sessions against a live session before automating them.
- **Writing config keys or CLI flags from memory or another agent's summary, or trusting an
  unverified "that's fabricated".** Check the installed CLI (`--help`, settings schema) in both
  directions before documenting a knob.
- **Restating a script's rules in prose.** It drifts. Point at the script and the test that pins it.
- **Bare `git stash`.** The stack is shared across all worktrees and sessions. Use a WIP commit.

## Large audits and migrations

Give each independent slice its own delegate: builders for implementation, a read-only scanner for
search and logs, an independent reviewer for the diff. Roles, patterns and the brief template:
[`references/orchestration-flow.md`](references/orchestration-flow.md); second opinions:
[`references/spawn-guide.md`](references/spawn-guide.md#second-opinions). Your host's routing is in
`$CRSS_HOME/staffing.md` if it has one. Pin a Claude builder with `subagent_type: builder` or
`model: "sonnet"`, since an inheriting one runs on the planner's model.

**Check each subagent's evidence before accepting its report.** "Fixed" is a claim: re-run the
command it cites, open the file:line, or diff the change. Consolidate verified results in one table.

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

If a diff shows the deployed copy has changes the repo lacks, stop and land that patch in the repo
first. The skill docs are live only once the canonical checkout reflects `origin/main`; if it has
diverged or carries someone else's uncommitted work, don't reset it, report it.

## Usage habits

Start a fresh session or hand off at a task boundary; don't carry one past about 2h. Keep the
always-on prefix small (deny or name-only unused MCP tools and skills; see "Lean loadouts" in
[`references/spawn-guide.md`](references/spawn-guide.md#lean-loadouts)). Send bulk reads, sweeps and
builds to a cheaper model.
