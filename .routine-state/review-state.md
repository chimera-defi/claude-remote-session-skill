# Nightly review state

Read this before starting a new nightly review pass so you don't rediscover
or re-litigate something an earlier run already found, fixed, or rejected.

## last_run

- date: 2026-10-01
- status: completed
- gh_mode: mcp (gh binary absent; mcp__github__ tools used for the whole run)
- pr: PR #122 of this repo
- branch: nightly-review-2026-10-01

## PHASE 0 gate note

No open `nightly-review-*` PR existed at run start (the prior one, #110, was
merged). `main` had moved by 8 merged PRs since the last full review-state
snapshot (2026-09-29/PR #110, itself merged after that snapshot was written):
#111 (Codex backend review findings), #112 (new `session-resume.sh` feature),
#115 (docs genericization), #116 (genericize host-specific script names +
locale fix), #117/#118 (test fixture genericization, host-leak scan
tightening), #120/#121 (small docs/comment fixes). Two throwaway PRs (#114,
#119, titled "tmp: ... (do not merge)") were opened and closed unmerged by a
prior run or the operator — not reviewed, not relevant.

## findings_reported

- **Reproducible test-hygiene bug, not a production-code bug**:
  `tests/test-session-resume.sh` leaks background processes. Every real
  (non-dry-run) `session-resume.sh` invocation in this test backgrounds a
  stubbed systemd unit's supervisor loop via
  `setsid timeout N bash -c "$payload" &`, then cleans up between test cases
  with `pkill -f <pattern>`. `pkill -f` only signals the one PID whose own
  argv matches — it does not reach a child the loop has ALREADY forked (the
  fake-claude stub's `sleep`, or the loop's own `sleep 300` exit backoff) if
  that child is running at the moment of the kill. That child is immediately
  orphaned and keeps running to completion (up to 5 minutes), untouched by
  anything else in the test.
  **Reproduced directly** (not inferred): running this one test file
  standalone (not inside the aggregate `for t in tests/test-*.sh` loop, which
  masks the bug by redirecting each test's output to a FILE rather than a
  pipe — the for-loop doesn't wait on an orphan holding a file descriptor
  open) hung past a 100s `timeout` with its own pass/fail summary never
  printed, and left live `sleep 20`/`sleep 300` processes system-wide,
  confirmed via `ps aux` (`bash -c "...while true...sleep 300...done"` still
  running, its own `sleep 300` child still running, both well after the test
  invocation that spawned them should have finished).
  **Fix**: every `setsid` launch site (4 of them in this one file) now
  records its session leader's pid — the SAME pid survives through setsid's
  own `exec`, by construction, so `$!` captured right after backgrounding is
  reliable — to `$STUB_STATE/all.sids` (appended, never overwritten: several
  fixtures reuse the same unit name across test cases). The test's `EXIT`
  trap now also signals each recorded session with `pkill -s <sid>`, which
  reaches the loop AND every descendant it forked regardless of which one
  happens to be currently running, instead of only the one PID a pattern
  happens to match.
  **Second issue surfaced by fixing the first**: this sandbox's pid 1 does
  not reap orphaned zombies, so a just-killed fake-claude stub can sit as a
  zombie (`ps` showed `Z ... <defunct>`, reparented to pid 1) that STILL
  answers `kill -0` as alive (POSIX: signal 0 to a zombie succeeds). Once the
  first fix made the test reach this point reliably every run (previously it
  rarely got this far without hanging first), `session-resume.sh`'s own
  liveness check — correct behavior for real production use — read the
  zombie's still-existing pid as "this transcript is still open" and refused
  a later resume of the same fixture (`FAIL: repeat-run-exit0 — got '1' want
  '0'`, reproduced identically across 2 separate runs before the second fix).
  Confirmed root cause directly: added temporary debug output, captured
  `ps -p $jpid` for the refusing pid, saw `Z [bash] <defunct>`. Fix: the test
  now drops its own stale PID-keyed registry entry
  (`rm -f "$CRSS_CLAUDE_HOME"/sessions/*.json`) at each of the 4 points it
  already kills a resumed session, so the next real run in the same file
  never trips over a zombie pid from an earlier one. This is a test-only
  workaround for a sandbox quirk (no reaping init), not a change to
  `session-resume.sh`'s own (correct) liveness-check logic.
  **Verified**: 3 consecutive standalone runs, pass=87 fail=0 each, ~17s
  wall-clock each (vs. hanging indefinitely / past a 100s timeout before any
  fix). Full `tests/test-*.sh` suite green both before and after. shellcheck
  clean both before and after. `ps aux` checked clean (no leftover
  sleep/supervisor processes) after every run of the fixed test, including 3
  back-to-back. PR #122, CI was still pending (0 statuses) when the PR was
  opened; subscribed to PR activity rather than blocking on
  `gh pr checks --watch`.

## findings_rejected

(none this run)

## verified_already_fixed (not re-reported, not re-litigated)

- **session-alias poisoning guard** (`scripts/session-alias.sh`): re-read in
  full this run (the prior 3 runs' notes flagged it as only
  confirmed-by-inference, not re-read line-by-line, since #104/#121 touched
  only comments/the prefix mechanism, not the guard logic itself). Read
  `looks_like_session_name`, `has_mmdd_group`, `desessionify`, `infer`,
  `store_upsert`'s write-path refusal, and the read-path self-heal (rule 2 in
  the resolution order) end to end. Still solid: write path refuses to
  persist a session-name-shaped alias (store_upsert), read path discards and
  re-infers a poisoned stored value. Ran its own test file directly:
  `tests/test-session-alias.sh` — 81/81 assertions pass. No changes needed;
  this guard has now been independently re-verified 5 nights running.

## New surface this run (reviewed to varying depth — see notes)

- **`scripts/session-resume.sh`** (PR #112, new, 438 lines, not reviewed by
  any prior nightly pass): read in full. Brings a dead session back on its
  OWN systemd unit, resuming its OWN transcript by explicit uuid — a
  deliberately conservative tool (refuses rather than guesses whenever
  anything is ambiguous: multiple transcripts with no `--uuid`, a dirty
  canonical worktree with no own worktree, an unrecognised start-script
  shape, a non-claude backend). Validates `--uuid`/`--model`/the target name
  before using them; uses `python3 -c 'shlex.split(...)'` to read start-script
  fields rather than fragile sed/regex extraction (same pattern PR #111 added
  elsewhere); the python patch step that rewrites a pre-pin script's
  supervisor loop validates its own output with `bash -n` before replacing
  the original, and keeps a timestamped backup. No production-code
  correctness bug found. Well covered by `tests/test-session-resume.sh`
  (87 assertions after this run's fix) — see findings_reported above for the
  test-hygiene bug found IN that test file, not in the script itself.
- **PR #111 (Codex backend review findings)**: read the full diff. Fixes a
  real shell-injection-shaped issue the previous nightly pass had explicitly
  (and, in hindsight, too charitably) waved off as "host-owned config, not a
  new injection surface" — `CRSS_CODEX_ARGS` is now split and `%q`-escaped
  into a proper bash array (`_shell_words_literal`, `_shell_quote`) instead
  of being interpolated unquoted into the generated start script. Also adds
  `_is_codex_selection_widget` (a rate-limit/model-switch TUI menu
  classifier) and a `start_script_field`/`_start_script_field` helper
  (shlex-based field extraction) duplicated into both
  `scripts/session-doctor.sh` and `scripts/session-handoff.sh` — same
  pattern as `session-resume.sh`'s own `field()`, not yet factored into one
  shared location, but each copy is correct and independently tested
  (`tests/test-new-session-backend.sh` includes a malicious-argv injection
  test that asserts no command substitution executes; `bash -n` on the
  generated script; grouped-quoting-preserved test). No bug found.
- **PR #108's Codex backend plumbing**: NOT given a second adversarial pass
  this run (the prior run's note asked for one) — budget went to the
  test-hygiene bug above, which was reproducible and in-scope as "regression
  coverage for bugs found." PR #111 already closes the one issue the first
  pass had flagged as worth a second look (the unquoted `CRSS_CODEX_ARGS`
  interpolation), so this is lower-priority now than when it was first
  flagged.
- **#115/#116/#117/#118 (genericization + host-leak-scan tightening)**: not
  independently re-audited line-by-line this run; their own purpose (removing
  host-specific identifiers, tightening the leak scanner) is exactly what
  `tests/test-no-host-leaks.sh` pins, and that test passes generically (0
  hits) as of this run.
- **#120/#121 (small docs/comment fixes)**: not reviewed — trivial,
  self-evidently low-risk from their titles/diff size.

## attempt_counts

- Full suite: ran all 32 `tests/test-*.sh` files on `main` (03421bc) before
  making any change — all green (the test-hygiene bug does not make
  `tests/test-session-resume.sh` FAIL; it only hangs/leaks when run in
  isolation outside the aggregate loop, which is exactly why it had escaped
  notice). After the fix: still 32/32 green, plus verified the fixed file
  standalone 3x in a row (pass=87 fail=0 each time, no hang, no leftover
  processes).
- `shellcheck -S warning -e SC2010 scripts/*.sh tests/*.sh`: clean before and
  after this run's change.
- `tests/test-no-host-leaks.sh` (generic mode, no `CRSS_LEAK_DENYLIST` set on
  this host): PASS, 0 hits, matches CI.
- Files read in full this run: this file (prior version), `git log`/PR list
  since 2026-09-29, PR #111's full diff, `scripts/session-alias.sh` (full,
  re-confirming the poisoning guard), `scripts/session-resume.sh` (full, 438
  lines), `tests/test-session-resume.sh` (full, both before and after the
  fix, plus iterative debug instrumentation to confirm both root causes
  directly rather than by inference).
- PR CI: checked `get_status` once right after opening PR #122 (0 statuses
  yet, `state: pending`) rather than a blocking watch; subscribed to the
  PR's activity so CI/review events arrive as they land instead of being
  polled for.

## Notes for future runs

- PR #109 (eval hillclimb budget protocol) is now the longest-standing
  unreviewed item — flagged 2 nights running, still not reviewed, each time
  because a higher-severity, reproducible issue took the run's budget
  instead. Worth deliberately prioritizing next time nothing more urgent
  turns up first.
- #103/#105/#106/#101 (host-ops move, leak-check CI, docs) remain the
  least-scrutinized chore/docs surface — still fine to leave for a dedicated
  doc-drift pass rather than nightly budget.
- The `shared setsid-session-leak` pattern this run found and fixed in
  `tests/test-session-resume.sh` (backgrounding a supervisor loop, cleaning
  up by `pkill -f <pattern>` instead of by session/group) is specific to that
  one file in this repo as of this run — no other test file backgrounds a
  long-running stub this way (checked: `grep -rn 'setsid' tests/` matched
  only this file). Worth a quick grep-check in a future run if a new test
  adds a similar stubbed-supervisor-loop pattern, to catch the same mistake
  before it ships rather than after.
- The open `diag: nightly-review YYYY-MM-DD - no changes` issues (#52-#100,
  18 of them as of the 2026-09-29 note) are still an accumulating backlog
  with no cleanup mechanism in this routine's scope — carried over,
  still not acted on. Not relevant this run since a PR was opened (no
  heartbeat issue needed).
