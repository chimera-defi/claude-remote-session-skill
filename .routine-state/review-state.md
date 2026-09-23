# Nightly review state

Read this before starting a new nightly review pass so you don't rediscover
or re-litigate something an earlier run already found, fixed, or rejected.

## last_run

- date: 2026-09-23
- status: completed
- gh_mode: mcp (gh binary absent; mcp__github__ tools used for the whole run)
- pr: https://github.com/chimera-defi/claude-remote-session-skill/pull/77
- branch: nightly-review-2026-09-23

## PHASE 0 gate note

No open `nightly-review-*` PR existed at the start of this run. `main` had
moved by 4 merged PRs since the 2026-09-21 review-state snapshot (all
merged directly by the operator on 2026-09-22, outside a nightly run):
#66 (idle-report doc fix), #72 (session-git-prep worktree-reuse fix, this
routine's own 2026-09-21 output), #74 (fleet-status composite view), #75
(session-compact managed/Fable-context-hygiene feature, `session-compact.sh`
664 -> 1222 lines), #76 (cruft-reduction pass).

## findings_reported

- `scripts/session-preserve.sh`'s `JUNK_RE` didn't exclude the spawner's own
  untracked `.sessions-init-<remote>` sentinel (touched by `new-session.sh`'s
  kickoff loop at the worktree root, present for the life of every restarted
  session), even though `session-git-prep.sh` and `session-doctor.sh`'s
  `_wt_dirty` already special-case it. Result: `session-preserve <session>`
  (no `--rescue`) reported `NOT-SAFE-TO-REAP` / `untracked-files` on that
  sentinel alone for essentially every real session, regardless of whether
  any actual work was uncommitted — defeating the audit for the common case
  (though safely: it only ever over-refused, never a false SAFE-TO-REAP).
  This was explicitly flagged by PR #76's author as "for the nightly review
  / a human" rather than fixed inline in that cleanup PR.
  Fixed by adding `\.sessions-init-[^/]*` to `JUNK_RE`. +2 test cases in
  tests/test-session-preserve.sh (61 -> 67 assertions): the sentinel alone
  now audits SAFE-TO-REAP; a sentinel alongside genuine untracked work still
  correctly blocks reap. Full 22-file suite green before and after;
  `shellcheck -S warning -e SC2010 scripts/*.sh tests/*.sh` (CI's exact
  invocation) clean. PR #77, not yet merged as of this run's end.

## findings_rejected

(none this run)

## verified_already_fixed (not re-reported, not re-litigated)

- **session-alias poisoning guard**: not re-checked line-by-line this run
  (budget went to the PR #76-flagged item and a safety spot-check of the
  new `session-compact.sh` Fable/managed-threshold code); no reason to
  suspect regression since #72's snapshot. Re-verify fully next run if this
  note is still the most recent confirmation.
- **session-git-prep.sh worktree-reuse-across-restarts fix (PR #72)**: now
  merged to main (a726a00). Its own regression coverage (+5 assertions
  total across two follow-on Codex-review fixes) is in place and green.
- **`--days`/`--minutes` mutual exclusivity, README/SKILL.md doc-drift,
  session-preserve `--wip` false-safe, session-handoff `--file`/mawk fixes,
  session-preserve fail-open on dead proc**: all previously merged and
  settled (see 2026-09-21 state file entry for details); not re-litigated.

## New surface this run (not fully audited — see notes)

- `scripts/session-compact.sh`'s new managed-threshold / context-floor /
  Fable-model-window / phase-boundary (`in_progress` task) logic added by
  PR #75 (664 -> 1222 lines, +1680/-65 across the PR). This is operator-
  authored (not a nightly-review artifact) and ships with its own 231
  focused assertions across 4 dedicated test files (all green), plus the
  PR description states a live Fable mainline was successfully compacted
  with it and that "Agent Host main now pins this branch/commit as an
  external reviewed dependency." Given that existing scrutiny, this run
  did a safety spot-check only (no `eval`, `set -uo pipefail` present,
  shellcheck clean, no obviously-unquoted expansions in the new code
  regions) rather than a full line-by-line correctness read. **Flagging
  for a future run**: this file has nearly doubled in size and gained a
  new state-machine (managed allowlist, task-ledger binding, dual context
  triggers) since the last full line-by-line audit (2026-09-14, when it
  was 664 lines) — worth a dedicated deep pass once it's had a few nights
  to settle, the way `session-git-prep.sh` got one this cycle.
- `scripts/fleet-status.sh` (PR #74, composite fleet/server health view) —
  not reviewed this run at all; no prior review-state coverage either.
  Worth a first pass next run.

## attempt_counts

- files read this run: this state file, git log/PR history back to the
  2026-09-21 snapshot, PRs #74/#75/#76's diffs and descriptions (for
  overlap/follow-up), `scripts/session-preserve.sh` (full),
  `scripts/session-git-prep.sh` and `scripts/session-doctor.sh` (grepped
  for the `.sessions-init` handling being compared against),
  `scripts/new-session.sh` (sentinel-creation section), `tests/test-
  session-preserve.sh` (full, to match its existing style for the new
  cases), `scripts/session-compact.sh` (grepped/spot-checked, not fully
  read end to end — see "New surface" above).
- test suite: ran all 22 `tests/test-*.sh` files on `main` (a08c782)
  before starting — all green. After the fix: 22 files, session-preserve.sh
  61 -> 67 assertions, still green.
- `shellcheck -S warning -e SC2010 scripts/*.sh tests/*.sh` (installed
  fresh this run via apt-get; not present in the sandbox by default): clean
  before and after.
- PR CI: checked `get_status` once right after opening PR #77 (0 statuses
  yet, `state: pending`) rather than a bare blocking watch; subscribed to
  the PR's activity so CI/review events arrive as they land instead of
  being polled for.

## Notes for future runs

- The 13 open `diag: nightly-review YYYY-MM-DD - no changes` issues
  (#52-#73, spanning 2026-09-04 through 2026-09-22) are an accumulating
  backlog with no cleanup mechanism in this routine's scope (it only ever
  creates them, never closes them). Not something to act on unilaterally,
  but worth a human triage pass (e.g. close them once superseded, or add a
  step that closes the previous night's diagnostic issue when a new one
  supersedes it with nothing further to add).
- `scripts/session-compact.sh` and `scripts/fleet-status.sh` are this
  cycle's two least-scrutinized surfaces (see "New surface" above) — good
  starting points for the next run's dedicated deep-read budget.
