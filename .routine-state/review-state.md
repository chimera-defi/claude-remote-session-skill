# Nightly review state
last_run: 2026-10-28   last_reviewed_sha: ccda8549bb79b4f9ec278aa1ba84ad6695103c54

## open (found, PR not merged yet)
- merge-guard: plural noun-form claims (Deletions/Additions/Removals of) bypass the
  body-vs-diff check (branch nightly-review-2026-10-28)

## fixed (last 30 days)
- merge-guard: rename/move claim breaks on "Y from X" phrasing - #164
- merge-guard: noun-form claims (Addition/Creation/Deletion of) bypass check - #176

## rejected / wont_fix (keep; never retry)
(none)

## next (max 5 lines)
- Reviewed ~60 commits merged since 2026-10-15 (new-session escaping fixes #205-209,
  session-spawn-server #185, quota-check #181-182, codex-send, jev-delegate, etc).
  Full suite (46 files) green, shellcheck -S warning clean, session-alias 48/48.
  Audited the highest-risk new/changed scripts (session-spawn-server escaping,
  new-session CLAUDE_SESSION_MODEL quoting, merge-guard) for injection/logic bugs;
  found the plural noun-form claim regex gap above. No other defect confirmed.
