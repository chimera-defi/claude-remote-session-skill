# Nightly review state
last_run: 2026-10-15   last_reviewed_sha: a44059b2a85c1e9837d4a5471d97614e3d0c6e2c

## open (found, PR not merged yet)
- merge-guard: rename/move claim breaks on "Y from X" phrasing (branch nightly-review-2026-10-15)

## fixed (last 30 days)
- merge-guard: rename/move body claim false-positives on "X to Y" phrasing - #159
- test-session-resume.sh leaked background processes across standalone runs - #122
- tests/test-*.py never ran in CI or the local loop; wired in - #137
- session-resume admission subject used a leading flag not the session name - #143

## rejected / wont_fix (keep; never retry)
(none)

## next (max 5 lines)
- Reviewed #159 (merge-guard to/into fix, merged), #160 (session-doctor
  auth-scan), #161 (docs), #162 (SKILL.md slim + harness-claim corrections;
  advisor/effort/model-id changes verified against new-session.sh + tests).
  Found the "Y from X" rename-phrasing gap in #159 itself; fixed here.
- session-alias poisoning guard: re-verified green (48/48), 9th night running.
