# Nightly review state
last_run: 2026-10-23   last_reviewed_sha: 748b23d43dfd05ef399fb17380b2b3fbb01e3e70

## open (found, PR not merged yet)
- merge-guard: noun-form claims (Addition/Creation/Deletion of) bypass body-vs-diff check (PR #176, branch nightly-review-2026-10-20)

## fixed (last 30 days)
- merge-guard: rename/move claim breaks on "Y from X" phrasing - #164
- merge-guard: rename/move body claim false-positives on "X to Y" phrasing - #159
- test-session-resume.sh leaked background processes across standalone runs - #122
- tests/test-*.py never ran in CI or the local loop; wired in - #137
- session-resume admission subject used a leading flag not the session name - #143

## rejected / wont_fix (keep; never retry)
(none)

## next (max 5 lines)
- PR #176 sat 3 nights with zero CI checks ever reported (gh get_status:
  total_count 0). Merged current main in, full suite green locally, pushed
  to resync; CI run started on push. No new defect; leave for merge once green.
- session-alias poisoning guard: re-verified green, 11th night running.
