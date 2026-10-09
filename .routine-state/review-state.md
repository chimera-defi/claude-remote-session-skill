# Nightly review state
last_run: 2026-10-06   last_reviewed_sha: b18212247b179f0834b3b0af807c1e55809ed90d

## open (found, PR not merged yet)
- session-resume admission subject used a leading flag not the session name - PR (branch nightly-review-2026-10-06)

## fixed (last 30 days)
- test-session-resume.sh leaked background processes across standalone runs - #122
- tests/test-*.py never ran in CI or the local loop; wired in - #137

## rejected / wont_fix (keep; never retry)
(none)

## next (max 5 lines)
- Reviewed #138 (tier routing), #140 (reap telemetry), #141 (escalate-from) diffs
  in depth; only the session-resume admission-subject bug (this PR) was a real
  defect. Rest spot-checked clean: shellcheck, full shell+python suites, and
  session-alias regression (81/81) all green.
- session-alias poisoning guard: re-verified green (81/81), 7th night running.
