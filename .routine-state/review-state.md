# Nightly review state

Read this before starting a new nightly review pass so you don't rediscover
or re-litigate something an earlier run already found, fixed, or rejected.

This file does not exist on `main` yet - PRs #54 (2026-09-06) and #55
(2026-09-07) each carried their own copy on their own branch, and neither
has merged yet. This run (2026-09-10) folds both of those runs' findings in
below, plus this run's own, since none of them are on `main`. Once #54, #55
and this run's PR all merge, later runs will see one consolidated file.

## last_run

- date: 2026-09-10
- status: completed
- gh_mode: mcp (gh binary absent; mcp__github__ tools used for the whole run)
- pr: (opened this run)
- branch: nightly-review-2026-09-10

## PHASE 0 gate note

Two open nightly-review PRs were found: #54 (nightly-review-2026-09-06,
README `--alias` persistence doc-drift) and #55 (nightly-review-2026-09-07,
session-preserve --wip dirty-flag fix). Both are green (`shell-tests`
check: success) and `mergeable_state: clean`, just unmerged - `main` has
not moved since #55 was opened (still at c74cb61). Per the gate rule for a
green-and-unmerged PR, neither's findings were re-reported. This run read
both diffs and the state file carried on #55's branch, then looked for
something genuinely new per that file's own "Notes for future runs"
(focus on the less-scrutinized scripts), rather than re-auditing settled
ground.

## findings_reported

- `scripts/session-handoff.sh` `send --file <path>` mode: read the file via
  `cat` (ignoring its exit status) BEFORE checking that the tmux session
  existed. A missing/unreadable path silently left `MSG` empty, which fell
  through to the unrelated "message is empty or whitespace-only" refusal -
  hiding the real cause. This also contradicted the design already
  documented in `tests/test-session-send.sh`'s own comments ("the
  has-session check runs before any file is read"), which the code didn't
  actually match. Fixed by moving the has-session check first and checking
  `cat`'s exit status, reporting "could not read --file path: <path>" on
  failure. Added a regression test (`unreadable-file-*` in
  tests/test-session-send.sh) against a live, ready tmux session; reverting
  the fix turns it red (2 assertions) as expected.

## findings_rejected

(none this run)

## verified_already_fixed (not re-reported, not re-litigated)

- **session-alias poisoning** (an `ah-`-prefixed or MMDD-dated value saved
  as an alias): still fully fixed and covered by 80 assertions in
  tests/test-session-alias.sh as of this run (baseline run showed the
  "looks like a session name; re-inferring" guard firing as expected). Do
  not re-propose adding this validation - it is already there.
- **README.md `--alias` persistence doc-drift**: fixed on branch
  nightly-review-2026-09-06 / PR #54. Unmerged as of this run; **merged
  2026-09-11 as 0237bbb**. Settled.
- **session-preserve.sh `--wip` false SAFE-TO-REAP on a failed commit**:
  fixed on branch nightly-review-2026-09-07 / PR #55. Unmerged as of this
  run; **merged 2026-09-11 as 890ea3b**. Settled.

## attempt_counts

- files read this run: `.routine-state` (absent on main), both open PRs'
  bodies/diffs/state files, `scripts/session-handoff.sh`,
  `scripts/session-send.sh`, `scripts/telemetry-report.sh` and their tests
  in depth (the three scripts PR #55's state file flagged as having had
  lighter scrutiny).
- test suite: ran all 13 tests/test-*.sh files on `main` before starting
  (346 assertions, unchanged from #54/#55's baseline since neither has
  merged) and again after this run's fix + new test (349 assertions). All
  passing both times.
- PR CI: watched via the PR's check-runs rollup after pushing (never a
  bare blocking watch).

## Notes for future runs

- Two open, green, mergeable nightly-review PRs (#54, #55) plus this run's
  new one are now stacked, unmerged, on `main` as of 2026-09-10. Merging
  is a human's call, not this routine's, but a future run should keep
  checking the PHASE 0 gate and should flag (via the heartbeat issue, not
  by merging) if the backlog keeps growing without any of them landing.
  **Resolved 2026-09-11:** the operator directed a backlog clear and all
  three landed — #54 (0237bbb), #55 (890ea3b), #58 (this run). Nothing
  from those runs is pending; don't re-report their findings.
- **Lesson from that backlog clear, worth acting on:** the gate rule
  ("don't re-report, open a separate PR from `main`") is correct, but it
  guarantees a `review-state.md` conflict for every run opened while a
  previous run's PR is still open — because every run rewrites this same
  file. Three stacked PRs meant each one conflicted the moment any other
  merged. The *script* fixes never collided once; only this file did.
  Two practical consequences: (a) resolve such a conflict by taking the
  **newer** run wholesale — this file is current state, not append-only
  history — rather than hand-merging sections; (b) that conflict cost is
  a real argument for merging each run's PR promptly instead of letting
  them stack, which is exactly what the backlog-growth flag above is for.
- `telemetry-report.sh` was read this run and found to have no correctness
  issues worth reporting (pure read/summarize of a JSONL file, tolerant of
  malformed lines, has a documented hardcoded-fallback-path rationale).
  `session-send.sh` itself is a thin passthrough and was already covered
  by good passthrough tests; the actual bug was in the shared
  `session-handoff.sh send` logic it delegates to.
- Remaining lower-scrutiny surface for a future run: `session-registry.sh`
  and `session-doctor.sh` have decent test coverage already (15 and 50
  assertions) but weren't read line-by-line this run; the reap/recycle
  interaction between `session-preserve.sh` and `session-registry.sh` (do
  they agree on what "safe to reap" means end-to-end?) is worth a look
  once #55 merges.
