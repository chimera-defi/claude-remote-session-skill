# Nightly review state

Read this before starting a new nightly review pass so you don't rediscover
or re-litigate something an earlier run already found, fixed, or rejected.

## last_run

- date: 2026-09-06
- status: completed
- gh_mode: mcp (gh binary absent; mcp__github__ tools used for the whole run)
- pr: https://github.com/chimera-defi/claude-remote-session-skill/pull/54
- branch: nightly-review-2026-09-06

## findings_reported

- README.md "Use the script directly" section claimed `--alias` is
  "(persisted)". Stale since the 2026-09-03 fix (commit 5eb4138 / PR #50)
  made persistence an explicit opt-in via `--set-default-alias`; a bare
  `--alias` is per-spawn only. SKILL.md and the scripts already documented
  the corrected behavior — only README.md had drifted. Fixed in PR #54.

## findings_rejected

(none this run — the one issue class explicitly called out in this run's
brief, session-alias poisoning, was already fully handled; see below.)

## verified_already_fixed (not re-reported, not re-litigated)

- **session-alias poisoning** (an `ah-`-prefixed or MMDD-dated value saved
  as an alias, doubling into `ah-ah-...-MMDD-MMDD` on future spawns):
  `scripts/session-alias.sh`'s `store_upsert` refuses to persist a
  poisoned value (write-path guard), the stored-alias lookup path
  self-heals a poisoned entry on read, and an explicit `--alias`/
  `--set-default` value is validated the same way before it can be saved.
  Covered by 80 assertions in `tests/test-session-alias.sh`, all passing.
  Do not re-propose adding this validation — it is already there and
  heavily regression-tested; if a *new* poisoning shape is found, add a
  fixture to test-session-alias.sh and extend `looks_like_session_name`,
  don't assume the mechanism is missing.

## attempt_counts

- files read this run: SKILL.md, README.md, references/fallback-recipe.md,
  references/session-lifecycle.md, docs/context-footprint.md,
  docs/idle-report.md, docs/openclaw-token-rotation.md,
  handoff/SKILL.md, .claude/commands/create-session.md, all scripts/*.sh,
  tests/test-session-alias.sh (spot-checked others by running them).
- test suite: ran all 13 tests/test-*.sh files twice (before and after the
  change) — 346 assertions total, all passing both times.
- PR CI (shell-tests check) was still in_progress when this run ended;
  not watched to completion (avoided a blocking `--watch`). Verify it went
  green before merging; if it's red, that's the next run's job (or fix it
  now if you're a human reading this before the next nightly fires).

## Notes for future runs

- This repo has been through many prior review passes (see the density of
  "found in review" / "caught by Codex review" comments already in the
  scripts and their tests) — most low-hanging correctness bugs in the
  scripts themselves are already fixed and pinned by tests. The
  highest-value thing a future run can still do is (a) re-verify anything
  listed under `verified_already_fixed` is *still* fixed after any new
  commits, (b) hunt for *documentation* drift between README.md/SKILL.md
  and actual script behavior after a behavior-changing commit lands (this
  run's finding was exactly that shape), and (c) look for genuinely new
  edge cases, not re-litigate settled ones.
- `.claude/review-state.md` (the pre-`.routine-state/` location) was not
  found in this repo at review time — nothing to leave in place there.
