# Nightly review state
last_run: 2026-10-13   last_reviewed_sha: 8a2ad2ff754879abd077d45935b5211aa4498bfa

## open (found, PR not merged yet)
- merge-guard: rename/move body claim false-positives (branch nightly-review-2026-10-13)

## fixed (last 30 days)
- test-session-resume.sh leaked background processes across standalone runs - #122
- tests/test-*.py never ran in CI or the local loop; wired in - #137
- session-resume admission subject used a leading flag not the session name - #143

## rejected / wont_fix (keep; never retry)
(none)

## next (max 5 lines)
- Reviewed #138,#140,#141,#142,#144-#158 (tier routing, reap-merged, 24h min-age
  gate, reap-local archive, telemetry-report deployed-path fallback, kids scan,
  merge-guard). Only merge-guard's rename/move false-positive (this PR) was a
  real defect; rest spot-checked clean against shellcheck + full suite.
- session-alias poisoning guard: re-verified green (48/48), 8th night running.
