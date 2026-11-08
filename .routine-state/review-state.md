# Nightly review state
last_run: 2026-10-28   last_reviewed_sha: ccda8549bb79b4f9ec278aa1ba84ad6695103c54

## open (found, PR not merged yet)
(none; the one item open at the last run, a claim-matching gap in the retired merge-guard script,
is moot since the crss rewrite removed that script)

## fixed (last 30 days)
(history before the crss rewrite is in git; the scripts it concerned are retired)

## rejected / wont_fix (keep; never retry)
(none)

## next (max 5 lines)
- The 2026-10-28 run reviewed about 60 commits, found nothing else confirmed, and audited the
  highest-risk scripts for injection and logic bugs. Those scripts no longer exist; the next run
  reviews `scripts/crss.sh` and `scripts/crss-compat.sh` from the rewrite commit onward.
