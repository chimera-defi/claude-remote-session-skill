# Nightly review state
last_run: 2026-10-26   last_reviewed_sha: 6c6cd20c86d0c54a5e6e5230a94aca71ea707ac7

## open (found, PR not merged yet)
- merge-guard: noun-form claims (Addition/Creation/Deletion of) bypass check - PR #176 (clean, CI green)
- new-session: CLAUDE_SESSION_MODEL quote-breakout executes in the pane launch line - this PR

## fixed (last 30 days)
- merge-guard: rename/move claim breaks on "Y from X" phrasing - #164
- review follow-ups for #151-#169 (auth-scan rc, merge-guard verbs, stale comments) - #170
- merge-guard: rename/move body claim false-positives on "X to Y" phrasing - #159

## rejected / wont_fix (keep; never retry)
(none)

## next (max 5 lines)
- #163-175 already reviewed in PR #176's own body (session-doctor auth-heal/opus-subagents,
  land-check landed-fallbacks, compact-window default, --launcher liveness warning): no action.
- Tonight covered #177-#207 (escaping/admission/quota/delegation-prompt/session-spawn-server/
  slice-usage.py); full suite+shellcheck clean on main. Found the model-injection above.
- session-alias poisoning guard: re-verified green (48/48), 11th night running.
