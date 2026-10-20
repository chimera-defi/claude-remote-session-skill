# Nightly review state
last_run: 2026-10-20   last_reviewed_sha: 7f36759599cc399b84fc40e0cc2fe5e69d8fc6909b

## open (found, PR not merged yet)
- merge-guard: noun-form claims (Addition/Creation/Deletion of) bypass body-vs-diff check (branch nightly-review-2026-10-20)

## fixed (last 30 days)
- merge-guard: rename/move claim breaks on "Y from X" phrasing - #164
- merge-guard: rename/move body claim false-positives on "X to Y" phrasing - #159
- test-session-resume.sh leaked background processes across standalone runs - #122
- tests/test-*.py never ran in CI or the local loop; wired in - #137
- session-resume admission subject used a leading flag not the session name - #143

## rejected / wont_fix (keep; never retry)
(none)

## next (max 5 lines)
- Reviewed #165-#175 (auth-heal, opus-subagents scan, land-check squash/PR-landed
  fallbacks, compact-window default, prompt-suggestion off switch, telemetry
  quarantine): full suite + shellcheck clean, logic traced against own tests,
  no defect found beyond the merge-guard regex gap fixed here.
- session-alias poisoning guard: re-verified green, 10th night running.
