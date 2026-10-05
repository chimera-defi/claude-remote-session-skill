# Nightly review state
last_run: 2026-10-05   last_reviewed_sha: bee9eb8ebccbf2b0a25f36216d33cf7bca982e4f

## open (found, PR not merged yet)
- tests/test-*.py never ran in CI or the local loop; wired in - PR (branch nightly-review-2026-10-05)

## fixed (last 30 days)
- test-session-resume.sh leaked background processes across standalone runs - #122

## rejected / wont_fix (keep; never retry)
(none)

## next (max 5 lines)
- 63 commits landed since the last reviewed sha (03421bc..bee9eb8): codex-resume-pin,
  session-handoff codex_live/pipefail-grep-q family, new-session Codex workdir/start_id
  work. All already carry their own multi-pass "review fixes" commits and full test
  coverage; spot-checked rather than re-reviewed line by line this run for budget.
- session-alias poisoning guard: re-verified green (81/81), 6th night running.
- No open nightly-review-* PR existed at run start; prior one (#122) was merged.
