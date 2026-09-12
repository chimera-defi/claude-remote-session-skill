# Nightly review state

Read this before starting a new nightly review pass so you don't rediscover
or re-litigate something an earlier run already found, fixed, or rejected.

## last_run

- date: 2026-09-12
- status: completed
- gh_mode: mcp (gh binary absent; mcp__github__ tools used for the whole run)
- pr: (opened this run)
- branch: nightly-review-2026-09-12

## PHASE 0 gate note

No open `nightly-review-*` PR existed at the start of this run. `main` was
at a9de42b (#61, merged 2026-09-11) - includes #58, #60 and #61, all
merged and settled since the 2026-09-10 run's state file was written (that
file's own backlog-clear note already covered #54/#55/#58; #60 and #61
were new work this run had not seen before).

## findings_reported

- `scripts/session-handoff.sh` `_input_box_empty`'s border-line detection
  (`nbound`) used an awk regex `/^─+$/` to find the separator line below
  the input box. '─' is multi-byte UTF-8; a quantified regex over it only
  matches under a UTF-8-locale-aware multibyte engine (gawk under a UTF-8
  locale) - mawk (Debian/Ubuntu's default `awk`) is never multibyte-aware,
  in any locale, and GNU grep/awk under a non-UTF-8 locale (LC_ALL=C/
  POSIX) have the same problem. This sandbox runs mawk with
  LC_CTYPE=POSIX, and the regex silently never matched: nbound fell back
  to "whole buffer," which pulled the status/permission-mode lines below
  the box in as if they were draft content, so every genuinely idle pane
  misclassified as `draft-in-input-box` and `_is_safe_to_inject` /
  `ready` never reported safe. This landed in #60 (2026-09-11, the new
  positive inject-safety predicate) and had not yet had a nightly-review
  pass - confirmed via `git log -S` that the buggy line was introduced in
  that PR, not older code.
  Fixed by replacing the awk regex with a plain bash loop using literal
  (non-regex) substring stripping (`${line//─/}`) to detect the
  all-border-char line - a byte-for-byte search with no quantifier or
  char-class involved, so it is correct regardless of locale or awk/grep
  build. No new test file was added: the existing
  `tests/test-session-handoff-ready.sh` already encodes the exact
  scenarios this broke (clean-ready pane, dim-placeholder pane, cursor-
  split placeholder, multiline-whitespace-only draft, the CLI-level
  `ready` subcommand) and is suficient regression coverage going forward,
  since the fix itself removes the locale/awk-implementation dependency
  rather than papering over one symptom.

## findings_rejected

(none this run)

## verified_already_fixed (not re-reported, not re-litigated)

- **session-alias poisoning**: still fully fixed and covered (80
  assertions in tests/test-session-alias.sh; guard fires as expected in
  this run's baseline). Do not re-propose this validation.
- **README.md `--alias` persistence doc-drift**: merged 2026-09-11 as
  0237bbb (#54). Settled.
- **session-preserve.sh `--wip` false SAFE-TO-REAP on a failed commit**:
  merged 2026-09-11 as 890ea3b (#55). Settled.
- **session-handoff.sh `send --file` masking read errors**: merged
  2026-09-11 as 12bf3b5 (#58). Settled.

## attempt_counts

- files read this run: this state file (from the 2026-09-10 run, carried
  onto `main` via #58), SKILL.md, README.md, `references/*.md`, all of
  `scripts/`, focusing on what changed since 2026-09-10 (`session-
  compact.sh` is new; `session-handoff.sh`, `session-doctor.sh`,
  `session-preserve.sh` gained substantial new code in #60/#61).
- test suite: ran all 17 tests/test-*.sh files on `main` before starting.
  16 of 17 files were clean; `test-session-handoff-ready.sh` showed
  49 pass / 16 fail - all 16 failures traced to the single nbound bug
  above. After the fix: all 17 files clean, 65/65 in that file, no
  regressions elsewhere (spot-checked `session-compact.sh` does not call
  into `_input_box_empty`/`_safety_reason`, so this fix is self-contained).
- searched the rest of `scripts/` for the same class of bug (a quantified
  regex bracket/`+`/`*` wrapping a non-ASCII multi-byte literal) - found
  none outside the fixed line; the other non-ASCII regex uses in
  session-handoff.sh (`_is_working`'s spinner-glyph class, `_input_region`'s
  `/❯/` literal, the `[^❯]*` prompt-strip) are either unquantified literal
  matches or already covered green by passing tests, so left as-is.
- PR CI: watched via the PR's check-runs rollup after pushing (never a
  bare blocking `gh pr checks --watch`).

## Notes for future runs

- The reap/recycle "safe to reap" agreement between `session-preserve.sh`
  and `session-registry.sh`, flagged by the 2026-09-10 run as lower-
  scrutiny surface, was not revisited this run - this run's budget went
  to the mawk/locale bug instead, which was a live, currently-broken
  predicate rather than a hypothetical edge case. Worth a look next time
  nothing more urgent turns up.
- `session-compact.sh` (new in #60/#61) and its two test files
  (`test-session-compact.sh`, 114 assertions) were read but not
  line-by-line audited to the same depth as `session-handoff.sh` this
  run. It does not depend on the fixed function, so it is unaffected by
  tonight's bug, but it is a large, fresh piece of code that could use a
  dedicated pass.
- General lesson worth restating: any future regex over one of this
  repo's non-ASCII glyphs (❯, ─, the spinner set, NBSP) needs a `git log
  -S`-style check for whether it is QUANTIFIED (`+`, `*`, or a `{...}`
  count) over the multi-byte literal itself. Unquantified literal
  matches (`/❯/`, `[^❯]*` stopping at a single literal) are fine in any
  locale/awk build; a quantified span over the multi-byte bytes
  themselves (`─+`) is the pattern that silently breaks under mawk or a
  non-UTF-8 locale. This run's fix is the second time this file has
  needed a byte-vs-character care note (see `_input_box_empty`'s NBSP
  comment from an earlier run) - it may be worth eventually enforcing a
  UTF-8 locale explicitly at the top of these scripts instead of relying
  on every regex author to remember this, but that is a bigger,
  cross-cutting change and out of scope for one bounded nightly fix.
