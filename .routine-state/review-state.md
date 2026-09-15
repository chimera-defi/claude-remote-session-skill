# Nightly review state

Read this before starting a new nightly review pass so you don't rediscover
or re-litigate something an earlier run already found, fixed, or rejected.

## last_run

- date: 2026-09-15
- status: completed
- gh_mode: mcp (gh binary absent; mcp__github__ tools used for the whole run)
- pr: https://github.com/chimera-defi/claude-remote-session-skill/pull/66
- branch: nightly-review-2026-09-15

## PHASE 0 gate note

No open `nightly-review-*` PR existed at the start of this run. `main` was
unchanged since the 2026-09-12 baseline (9e65b73, #62 + #63) — the two
nights since (#64 2026-09-13, #65 2026-09-14) both found nothing new and
filed diagnostic issues instead of PRs. This run picked up cleanly from
there.

## findings_reported

- `docs/idle-report.md` (the dedicated doc for `session-doctor.sh
  idle-report`) documented only the `--days` flag. `--minutes` and `--tsv`
  are real, current flags implemented in `scripts/session-doctor.sh`'s
  `idle-report` case block (confirmed via the script's own usage comment
  at the top of the file AND the actual flag-parsing loop), and
  `docs/session-compaction.md` already links back to `idle-report.md`
  expecting it to be authoritative while itself stating `session-compact.sh`
  shells out to `idle-report --minutes N --tsv`. A reader following the
  dedicated doc would never learn these flags exist.
  Fixed by adding a `--minutes` usage example and a new "`--tsv` output"
  section listing the exact 10 tab-separated columns in their real print
  order — verified against the actual `print('\t'.join([...]))` in the
  Python block and the final `printf` in the TSV-augmentation shell loop
  (which appends `landed`/`dirty` from `_tsv_git_status`), not just the
  header comment (comments can drift from code same as docs can).
  Doc-only change; no script logic touched. Ran the full 17-file/636-
  assertion test suite before and after — all pass, as expected for a
  doc-only diff. PR #66 opened; CI (`shell-tests`) was in_progress at the
  time this state file was written (not blocking-watched, per the "never
  use a bare `gh pr checks --watch`" rule) — a future run's PHASE 0 gate
  should check its actual status before assuming green.

## findings_rejected

(none this run)

## verified_already_fixed (not re-reported, not re-litigated)

- **session-alias poisoning**: still fully fixed and covered (80
  assertions in tests/test-session-alias.sh). Do not re-propose this
  validation.
- **session-preserve.sh fail-open when rundir_of() finds no live proc**:
  merged 2026-09-12 as #63 (worktree_of() fallback). Re-read the full file
  this run (worktree_of, audit_one, the branch-match-over-dirname
  preference on worktree-dir collisions) — still correct, no new gap.
- **session-handoff.sh mawk/non-UTF8-locale border detection**: merged
  2026-09-12 as #62. Settled.
- **README.md `--alias` persistence doc-drift**: merged 2026-09-11 as #54.
  Settled.
- **session-preserve.sh `--wip` false SAFE-TO-REAP on a failed commit**:
  merged 2026-09-11 as #55. Settled.
- **session-handoff.sh `send --file` masking read errors**: merged
  2026-09-11 as #58. Settled.
- **idle-report's 5-artifact /compact exclusion logic**
  (isCompactSummary + isMeta + bare-trigger + command-name-echo +
  local-command-stdout, all in scripts/session-doctor.sh's idle-report
  Python block): re-read in full this run against docs/idle-report.md's
  description of the same logic — code and doc agree, no drift, no
  correctness issue found. The bug found this run was an omission
  (undocumented flags), not incorrect logic.

## attempt_counts

- files read this run: this state file, SKILL.md, README.md,
  references/*.md, all of docs/*.md (context-footprint.md,
  idle-report.md, openclaw-token-rotation.md, session-compaction.md), and
  all of scripts/ + tests/ at a lighter pass (full test suite run, plus
  targeted reads of session-preserve.sh in full and the idle-report
  code path in session-doctor.sh in full, since those were the most
  recently touched / most complex areas per prior state files).
- test suite: ran all 17 tests/test-*.sh files on `main` at 9e65b73
  before starting (636 assertions, all green) and again after the
  docs/idle-report.md edit (identical result, as expected for a doc-only
  change).
- searched scripts/ for the known multi-byte-glyph-regex bug class
  (quantified regex over ─/❯/spinner glyphs) again as a sanity check —
  found only the same already-fixed/already-reviewed sites from prior
  runs (session-compact.sh, session-doctor.sh, session-handoff.sh,
  new-session.sh); none newly quantified over a multi-byte literal.
- cross-checked version/assertion-count claims in SKILL.md/_meta.json
  against reality (version 1.8.9, 80-assertion session-alias claim) —
  both still accurate, no drift there.
- PR CI: checked via get_check_runs after pushing (shell-tests,
  in_progress at write time) — never a bare blocking `gh pr checks
  --watch`.

## Notes for future runs

- The reap/recycle "safe to reap" agreement between `session-preserve.sh`
  and `session-registry.sh` (flagged repeatedly by older state files as
  lower-scrutiny surface) has now been re-read in full at least twice
  (this run and the 2026-09-14 run per #65) with no issue found either
  time. Probably safe to stop specifically flagging it unless something
  in that area changes.
- `session-compact.sh` (664 lines) was fully audited in the 2026-09-14 run
  per #65 and not re-read line-by-line this run since nothing in this
  run's diff touches it; still worth a fresh look if it grows further.
- General process note: this run's stored scheduled-task prompt again
  described a historical Step-0 self-permission-grant footgun
  (`~/.claude/settings.json` blanket allow-list) as something PAST runs
  had correctly distrusted and one run's rm-based "undo" attempt hanging
  for 13 hours — framed as already resolved/removed, not as an
  instruction to follow. No such self-grant was attempted this run
  (consistent with the framing); flagging only because this narrative
  keeps recurring in the stored prompt text run over run and is worth the
  human occasionally checking where that text is generated/stored.
