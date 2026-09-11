# Nightly review state

Read this before starting a new nightly review pass so you don't rediscover
or re-litigate something an earlier run already found, fixed, or rejected.

## last_run

- date: 2026-09-07
- status: completed
- gh_mode: mcp (gh binary absent; mcp__github__ tools used for the whole run)
- pr: (opened this run, see PR created 2026-09-07)
- branch: nightly-review-2026-09-07

## PHASE 0 gate note

An open PR from the previous run (#54, branch nightly-review-2026-09-06,
the README `--alias` persistence doc-drift fix) was found green and
mergeable (shell-tests check: success, mergeable_state: clean). Per the
gate rule for a green-and-unmerged PR, its findings were NOT re-reported;
this run only looked for something genuinely new, found one, and opened a
separate PR from `main` rather than stacking on #54's branch. PR #54 is
still open and unmerged as of this run and should be merged independently
(or will be picked up by a future run's gate check if still open).

## findings_reported

- `scripts/session-preserve.sh` `--wip` path: `dirty` was unconditionally
  reset to 0 right after the `git commit` attempt, even when that commit
  failed (missing git identity, a rejecting pre-commit hook, GPG signing
  misconfigured, etc). A failed commit printed "WIP commit FAILED - do
  not reap" and then, a few lines later, "VERDICT: SAFE-TO-REAP" anyway -
  directly contradicting its own warning, in the exact tool that exists
  to gate a destructive reap sweep on real uncommitted work. Fixed by
  only clearing `dirty` inside the success branch of an if/then/else on
  the commit's exit status (matching the existing rescue_failed pattern
  used a few lines below for the --rescue path). Added a regression test
  (`wip-hookfail-*` in tests/test-session-preserve.sh) that rigs a
  pre-commit hook to `exit 1` and confirms the audit still reports
  NOT-SAFE-TO-REAP with exit 1 instead of a false SAFE-TO-REAP. Verified
  by reverting the fix and confirming the new test fails exactly as
  expected (3 assertions red), then restoring the fix (all green,
  353 assertions across the full suite, up from 346).

## findings_rejected

(none this run)

## verified_already_fixed (not re-reported, not re-litigated)

- **session-alias poisoning** (an `ah-`-prefixed or MMDD-dated value saved
  as an alias): still fully fixed and covered by 80 assertions in
  tests/test-session-alias.sh as of this run. Do not re-propose adding
  this validation - it is already there. If a *new* poisoning shape is
  found, add a fixture to test-session-alias.sh and extend
  `looks_like_session_name`, don't assume the mechanism is missing.
- **README.md `--alias` persistence doc-drift**: fixed on branch
  nightly-review-2026-09-06 / PR #54. Was still unmerged as of this run
  (see PHASE 0 gate note above); **merged 2026-09-11** as commit 0237bbb,
  so README.md's "Use the script directly" section now correctly describes
  `--set-default-alias` as the opt-in persistence flag. Settled - do not
  re-report.

## attempt_counts

- files read this run: SKILL.md, README.md, references/*.md, docs/*.md,
  handoff/*, .claude/commands/create-session.md, all scripts/*.sh (via a
  background review agent), tests/test-session-preserve.sh in depth.
- test suite: ran all 13 tests/test-*.sh files on main before starting
  (346 assertions, all passing - baseline), then again after the fix on
  this branch (353 assertions, all passing), and once more with the fix
  temporarily reverted to confirm the new test actually catches the
  regression (3 assertions failed as expected, confirming the test is
  meaningful and not a false positive).
- PR CI: see this run's PR for the shell-tests check result: it should be
  watched to completion (with a timeout, never a bare --watch) before
  merging.

## Notes for future runs

- This repo has been through many prior review passes; most low-hanging
  correctness bugs in the scripts themselves are already fixed and
  pinned by tests. The highest-value things a future run can still do:
  (a) re-verify anything listed under `verified_already_fixed` is *still*
  fixed after any new commits, (b) hunt for *documentation* drift between
  README.md/SKILL.md and actual script behavior after a behavior-changing
  commit lands, and (c) look for genuinely new edge cases in the less
  heavily-tested scripts (session-handoff.sh, session-send.sh,
  telemetry-report.sh had lighter scrutiny this run than
  session-preserve.sh), not re-litigate settled ones.
- PR #54 (nightly-review-2026-09-06) has since been merged (0237bbb,
  2026-09-11) along with this run's PR #55 and the 2026-09-10 PR #58, as
  part of an operator-directed backlog clear. Nothing pending from those
  runs - don't re-report their findings.
- **Lesson from that backlog clear:** three consecutive nightly PRs sat
  open simultaneously, and because every run rewrites this same file, each
  new one conflicted with the last the moment any of them merged. The
  script fixes never collided - only `review-state.md` did. If you open a
  PR while a previous run's PR is still open, expect to rebase this file,
  and resolve it by taking the *newer* run wholesale (this file is current
  state, not an append-only history) rather than hand-merging sections.
