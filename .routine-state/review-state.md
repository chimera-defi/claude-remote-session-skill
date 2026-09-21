# Nightly review state

Read this before starting a new nightly review pass so you don't rediscover
or re-litigate something an earlier run already found, fixed, or rejected.

## last_run

- date: 2026-09-21
- status: completed
- gh_mode: mcp (gh binary absent; mcp__github__ tools used for the whole run)
- pr: https://github.com/chimera-defi/claude-remote-session-skill/pull/72
- branch: nightly-review-2026-09-21

## PHASE 0 gate note

Open PR #66 (`nightly-review-2026-09-15`, docs: idle-report `--minutes`/
`--tsv` flags) was still open at the start of this run - green (Codex review
completed, no findings) and cleanly mergeable, just unmerged (waiting on a
human; 5 straight nightly runs since, #67-#71, all filed "no changes"
diagnostic issues rather than stacking a second PR on it). Per the phase-0
gate this run did not touch or re-review PR #66's own diff; it read the
diff to confirm nothing in tonight's finding overlapped it, then looked for
something genuinely new. `main` itself is unchanged since 9e65b73
(2026-09-15, also PR #66's base).

## findings_reported

- `scripts/session-git-prep.sh`'s worktree-collision path: `REMOTE_NAME` is
  stable across systemd restarts of the SAME session (it's baked into that
  session's generated `<remote>-start.sh`, not regenerated per spawn - see
  `new-session.sh` lines ~293/358/396). So when a session's canonical repo
  was dirty/busy at spawn time (put into an isolated worktree), EVERY
  restart of that same session re-invokes `session-git-prep.sh` with the
  identical `REMOTE`. The collision-handling code unconditionally suffixed
  `$WT` with `-$$` the instant a path already existed there (the
  "belt-and-suspenders" line), BEFORE ever checking whether that existing
  path was already the session's own registered worktree from its prior
  run. The subsequent "if $WT is already a valid worktree, reuse it" check
  then only ever inspected the already-suffixed (and thus brand-new,
  not-yet-existing) path, so it could never actually fire.
  Reproduced directly (see repro in the PR): first invocation creates
  worktree W1 on branch `session/<remote>`; write a WIP file into W1;
  second invocation with the identical REMOTE against the still-dirty
  canonical repo creates a NEW worktree W2 on a distinct `-$$`-suffixed
  branch, emits W2 (not W1), and W1 (plus the WIP file inside it) is left
  orphaned - registered in git but no longer referenced by anything, never
  cleaned up automatically (`worktree-stale` only removes worktrees whose
  OWNING session is dead, and this one's session is very much alive).
  Fixed by moving the "already a registered worktree of this repo? reuse
  it" check to before the suffix decision, so a stable-REMOTE restart finds
  and reuses its own prior worktree immediately. Verified the pre-existing
  belt-and-suspenders suffix path still fires correctly for the genuine
  case it defends against (a stray non-worktree path occupying `$WT`).
  +3 assertions in tests/test-session-git-prep.sh (25 -> 28): same worktree
  path returned across two invocations with the same REMOTE, a WIP file
  written into it survives, and `git worktree list` shows exactly 2 entries
  (canonical + the one reused worktree), not 3. Full 17-file/639-assertion
  suite green before and after.

- **Two follow-on bugs in the fix above, both caught by Codex's PR review
  (chatgpt-codex-connector) on PR #72 itself, both verified and fixed same
  night:**
  1. The reuse check's `grep -qF "worktree $WT"` was a fixed-string
     SUBSTRING search, not an exact match. An unsuffixed `$WT` that is a
     literal path prefix of a real, unrelated, already-registered
     `-<pid>`-suffixed worktree (e.g. `.../remote-y` vs a genuinely
     registered `.../remote-y-393`) matched anyway, so the script emitted
     the unrelated directory as the run dir even though it wasn't a git
     worktree at all (`rev-parse --is-inside-work-tree` failed on it once
     emitted) - reproduced directly. Fixed with `grep -qxF` (exact
     whole-line match). +2 assertions in tests/test-session-git-prep.sh
     (28 -> 30).
  2. `new-session.sh`'s same-minute collision-avoidance only checks LIVE
     tmux sessions, not retained worktrees. `reap-local` never removes
     worktree files, so a reaped session's worktree can outlive it;
     respawning the same folder+alias within the same clock-minute (ID is
     minute-granularity) could reissue that reaped session's exact
     REMOTE_NAME, and the (intentional) same-REMOTE reuse logic from
     finding #1 above would then silently hand the brand-new session the
     reaped session's leftover, possibly-dirty worktree. Fixed by adding
     `name_taken()` to new-session.sh, checked in both the --dry-run and
     real (mkdir-lock) collision loops: a candidate is taken if EITHER a
     live tmux session exists under it OR
     `~/.claude/worktrees/<remote_name>` still exists on disk. +1
     assertion in tests/test-new-session-names.sh (41 -> 42).
  Both threads replied to and resolved on PR #72. Full suite after both
  fixes: 17 files, 643 assertions, green.

## findings_rejected

(none this run)

## verified_already_fixed (not re-reported, not re-litigated)

- **session-alias poisoning**: still fully fixed and covered (80 assertions
  in tests/test-session-alias.sh; guard fires as expected in this run's
  baseline, including the case-folded `AH-`/`Ah-` prefix check and the
  every-`[0-9]{4}-[0-9]{4}`-pair-checked date logic). Do not re-propose this
  validation.
- **session-git-prep.sh worktree-dir-suffixed/branch-unsuffixed quirk on a
  GENUINE collision** (two different sessions/REMOTEs racing for the same
  path): this is intentional, documented, and already correctly
  special-cased by `session-doctor.sh` `worktree-stale` (prefers a branch
  match over a dirname match) and `session-preserve.sh` `worktree_of()`
  (same ordering, with an explicit regression test for it). Not a bug -
  confirmed via a targeted repro this run that a stray non-worktree path at
  `$WT` still correctly falls through to the `-$$` retry. Only the
  SAME-REMOTE-restart case above was broken.
- **`--days`/`--minutes` mutual exclusivity in `session-doctor.sh
  idle-report`** (claimed in PR #66's still-open doc update): re-verified
  against the actual flag-parsing block (`DAYS_SET`/`MINUTES_SET` check,
  lines ~76-78) - correctly enforced, doc claim is accurate.
- **README.md `--alias` persistence doc-drift**: merged 2026-09-11 as
  0237bbb (#54). Settled.
- **session-preserve.sh `--wip` false SAFE-TO-REAP on a failed commit**:
  merged 2026-09-11 as 890ea3b (#55). Settled.
- **session-handoff.sh `send --file` masking read errors**: merged
  2026-09-11 as 12bf3b5 (#58). Settled.
- **session-handoff.sh mawk/non-UTF8-locale border detection**: merged
  2026-09-12 as 5601fc0 (#62). Settled.
- **session-preserve.sh fail-open when rundir_of() finds no live proc**:
  merged 2026-09-12 as 9e65b73 (#63). Settled.
- **reap-local doesn't gate on session-preserve**: confirmed (again) that
  `do_reap()` only touches the systemd unit, start script and tmux session
  - never worktree files/dirs - so no live-data-destruction path exists
  through it. Consistent with the 2026-09-14 through 2026-09-20 runs'
  conclusion; not re-flagging further absent a change in that area.

## attempt_counts

- files read this run: this state file, SKILL.md, README.md,
  `references/*.md`, all of `scripts/` (with a full line-by-line read of
  `session-git-prep.sh` specifically, since it had gone the longest without
  a dedicated deep pass per prior state files' notes), `tests/test-session-
  git-prep.sh`.
- test suite: ran all 17 `tests/test-*.sh` files on `main` (9e65b73) before
  starting - all green, 636 assertions. After the fix: 17 files, 639
  assertions, still green (net +3 from the new regression coverage).
- reproduced the bug live in a scratch repo (two `session-git-prep.sh`
  invocations with the same REPO/SESS/REMOTE against a dirty canonical
  tree) before writing any fix, and re-ran the same repro after the fix to
  confirm the worktree is now reused and the WIP file survives.
- PR CI: will be checked via the PR's check-runs/status rollup after
  pushing (never a bare blocking `gh pr checks --watch`).

## Notes for future runs

- PR #66 has now been open and green for 6+ nights awaiting human merge.
  Nothing to do about that from here (never self-approve/merge), but if it
  keeps sitting, it may be worth a human noticing `docs/idle-report.md`'s
  fix is still unmerged.
- `session-compact.sh` (664 lines, audited in full per the 2026-09-14 run's
  #65) has not been re-read line-by-line since; still nothing prompting a
  fresh pass.
- The general lesson from tonight: a script that's "correct" in the common
  case (fresh spawn) can still hide a stale-cached-decision bug in its
  RESTART/re-invocation path, especially when a value the script treats as
  disposable/unique (here, assuming `REMOTE` looks timestamped-and-thus-
  fresh, per the very comment this run removed) is actually stable at a
  higher layer (systemd unit / generated start script) that the script
  itself never sees. Worth asking, for any script keyed by an
  externally-supplied "session identity" value, whether that value is
  really fresh-per-invocation or persistent-per-session before writing
  collision-avoidance logic that assumes the former.
