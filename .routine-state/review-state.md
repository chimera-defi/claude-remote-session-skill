# Nightly review state

Read this before starting a new nightly review pass so you don't rediscover
or re-litigate something an earlier run already found, fixed, or rejected.

## last_run

- date: 2026-09-29
- status: completed
- gh_mode: mcp (gh binary absent; mcp__github__ tools used for the whole run)
- pr: PR #110 of this repo
- branch: nightly-review-2026-09-29

## PHASE 0 gate note

No open `nightly-review-*` PR existed at run start. One unrelated open PR
existed (#107, `fix/reap-archive-unit`, author-driven, not a nightly-review
artifact) — no overlap with this run's files, left untouched. Open
`diag: nightly-review YYYY-MM-DD - no changes` issues accumulate as a backlog with no
cleanup mechanism in this routine's scope.

`main` had moved by 9 merged PRs since the last full review-state snapshot
(2026-09-23/PR #77) that hadn't been covered by any prior nightly pass:
#101 (kickoff-templates docs), #102 (host-local CRSS_HOME overlay config),
#103 (move host-ops tooling out), #104 (configurable session-name prefix),
#105 (remove host specifics + CI leak check), #106 (overlay-followups docs),
#107 (open, unrelated), #108 (Codex backend support), #109 (eval hillclimb
budget protocol). All merged 2026-09-28, after that night's own nightly
review (#100, created 01:16 UTC) had already run, so none had been reviewed
by any nightly pass before tonight.

## findings_reported

- **Real, currently-failing regression on `main`** (not merely a
  theoretical risk — 6 of 32 `tests/test-*.sh` files were red before this
  run's fix): PR #108 (Codex backend) added Codex's `›` prompt glyph
  alongside Claude's `❯` in `scripts/session-handoff.sh` by writing
  `[❯›]`/`[^❯›]` **bracket character classes** in `_input_region`,
  `_transcript_region`, `_has_prompt`, and the input-box prefix strip in
  `_input_box_empty`. Under a POSIX/C locale (`LC_ALL=C`, no `LANG` set —
  this sandbox's actual locale, and the exact class of host this file's own
  existing comments already document as a support target, re: the
  `_input_box_empty` border-line `─+` mawk/POSIX-locale bug), grep/awk/sed
  treat a bracket class as a set of raw BYTES rather than atomic
  characters: a multi-byte UTF-8 char inside `[...]` decomposes into its
  individual bytes as separate class members. `❯` (E2 9D AF) and `›`
  (E2 80 BA) share lead byte E2 with nearly every other symbol the
  Claude/Codex TUIs print (`✢✻✽⏵…`), so `[❯›]` false-matched on ANY line
  containing one of those — e.g. the routine `"⏵⏵ bypass permissions on
  (shift+tab to cycle)"` status line under an otherwise-READY pane — which
  collapsed `_input_region` to the buffer's tail and made `_safety_reason`
  misreport every idle Claude pane as `draft-in-input-box` instead of
  `safe`. This broke `session-handoff`'s ready gate and
  `session-compact`'s busy/idle check fleet-wide on any non-UTF-8-locale
  host. Confirmed by direct reproduction
  (`echo '⏵⏵ x' | grep -qE '[❯›]'` matches under `LC_ALL=C`) and by the
  failing test files themselves
  (`test-session-handoff.sh`, `test-session-handoff-ready.sh`,
  `test-session-handoff-pane-guard.sh`, `test-session-handoff-paste-race.sh`,
  `test-session-compact-need-based.sh`, `test-session-compact-sweep.sh`,
  plus partial failures in 2 more compact tests).
  **Fix**: replaced each bracket-class site with alternation (`❯|›`), which
  compares each branch as a whole literal byte string and is
  locale-independent. Added `tests/test-session-handoff-locale-safe-match.sh`
  as a static guard so a future edit can't silently reintroduce a
  multi-glyph bracket class here (verified the guard actually catches the
  bug by reintroducing it in a scratch copy). PR #110, not yet merged as of
  this run's end; CI was still pending (0 statuses) when the PR was opened —
  subscribed to PR activity rather than blocking on `gh pr checks --watch`.

## findings_rejected

(none this run)

## verified_already_fixed (not re-reported, not re-litigated)

- **session-alias poisoning guard**: NOT re-checked this run (budget went
  entirely to the session-handoff regression above, which was higher-
  severity — currently failing on `main`, not a latent risk). Confirmed
  solid on 2026-09-25 through 2026-09-28 (four consecutive nights); no
  reason to suspect regression since `scripts/session-alias.sh` was not
  touched by any of the 9 PRs reviewed tonight. Re-verify fully next run if
  this note is still the most recent confirmation.
- `scripts/fleet-status.sh`, host-ops health scripts, `session-doctor.sh`'s
  worktree-stale/reap paths: confirmed solid as of 2026-09-28 (#100); not
  touched by tonight's 9 PRs except `session-doctor.sh`'s `backend_of`/
  `proc_alive`/`_state_of` additions (PR #108, see "New surface" below —
  spot-checked, not exhaustively re-verified against the pre-existing
  worktree-stale/reap logic since that logic itself wasn't touched).

## New surface this run (reviewed to varying depth — see notes)

- **`scripts/session-handoff.sh`'s Codex pane-classifier additions** (PR
  #108): the bracket-class bug above is fixed and covered by both the
  existing functional fixtures (`tests/test-session-handoff-codex.sh`,
  now-passing `tests/test-session-handoff-ready.sh`) and the new static
  guard. The REST of the Codex classifier logic (`_is_working`,
  `_is_on_menu`, `_is_collapsed_paste_in_input`'s new Codex-menu patterns)
  was read but not adversarially fuzzed beyond the fixtures PR #108 shipped
  — those fixtures are derived from real Codex CLI 0.158.0 captures per
  their own header comment, which is reasonable but unverified independently
  this run.
- **`scripts/new-session.sh` / `scripts/session-doctor.sh`'s Codex backend
  plumbing** (PR #108): `--backend codex`, `CRSS_CODEX_BIN`/`CRSS_CODEX_ARGS`,
  the generated start-script branching (Claude-only sections skipped for
  Codex), `backend_of`/`proc_alive`/`_state_of` backend-awareness in both
  `session-doctor.sh` and `session-handoff.sh`. Read in full; has its own
  dedicated test file (`tests/test-new-session-backend.sh`, 94 lines,
  spawns a stubbed Codex binary and inspects the generated start script).
  `CRSS_CODEX_ARGS` is interpolated unquoted into the generated start
  script by design (mirrors the pre-existing `CRSS_CLAUDE_BIN` pattern, so
  word-splitting happens intentionally — see the file's own comment on why
  per-profile flags are baked as a literal rather than kept as a runtime
  var) and is host-owned config from `$CRSS_HOME/config.sh`, not
  session-spawn-time user input, so this is not a new injection surface.
  No bug found here this run, but this is new enough (one PR old) to be
  worth a second, more adversarial look in a future run rather than being
  marked fully settled.
- **PR #102 (host-local `CRSS_HOME` overlay config)**: read in full via the
  diff; the parse-never-source pattern (`_crss_load_config`) predates this
  PR and was already reviewed in earlier cycles. Not independently
  re-audited line-by-line this run.
- **PR #109 (eval hillclimb budget protocol)**: NOT reviewed this run
  (budget went to the higher-severity regression above). Worth a first pass
  next run.
- **PR #104 (configurable `CRSS_SESSION_PREFIX`/`CRSS_LEGACY_PREFIXES`)**:
  the resulting `_crss_prefix_re` construction was read as part of
  `scripts/session-alias.sh` (see that file's own extensive inline
  rationale) while investigating the alias-poisoning guard's current state;
  looked correct (validates each token against `^[a-z][a-z0-9]{0,15}$`,
  fails closed to `cs` / drops the whole legacy list on any invalid
  element). Not independently re-audited beyond that read.
- **PR #103 (move host-ops tooling out), #105 (remove host specifics + CI
  leak check), #106 (overlay-followups docs), #101 (kickoff-templates
  docs)**: not reviewed this run — lower risk (chore/docs), and budget went
  to the regression above. Worth inclusion in a future doc-drift pass.

## attempt_counts

- Full suite: ran all 32 `tests/test-*.sh` files on `main` (5d46635) before
  making any change — 6 files failed (see findings_reported for the list
  and failure counts). After the fix: 32/32 green, plus the new guard test
  (33rd file) also green.
- `shellcheck -S warning -e SC2010 scripts/*.sh tests/*.sh` (installed
  fresh this run via apt-get; not present in the sandbox by default):
  clean before and after (shellcheck itself doesn't flag the bracket-class
  locale bug — this is a correctness issue, not a shellcheck-detectable
  pattern).
- Files read this run: `.routine-state/review-state.md` (this file, prior
  version), commit history/PR list since 2026-09-23, PRs #102/#108's full
  diffs, `scripts/session-alias.sh` (full, re-confirming the poisoning
  guard's current shape), `scripts/session-handoff.sh` (full, both before
  and after the fix), `scripts/new-session.sh` (Codex backend sections),
  `scripts/session-doctor.sh` (backend-awareness additions only, grepped),
  all `tests/test-*.sh` file names + the 3 new Codex-related test files in
  full.
- PR CI: checked `get_status` once right after opening PR #110 (0 statuses
  yet, `state: pending`) rather than a bare blocking watch; subscribed to
  the PR's activity so CI/review events arrive as they land instead of
  being polled for.

## Notes for future runs

- The 18 open `diag: nightly-review YYYY-MM-DD - no changes` issues
  (#52-#100) are still an accumulating backlog with no cleanup mechanism in
  this routine's scope — carried over from the 2026-09-23 note, still not
  acted on.
- PR #109 (eval hillclimb budget protocol) and PR #103/#105/#106/#101
  (host-ops move, leak-check CI, docs) are this cycle's least-scrutinized
  surfaces — good starting points for the next run's dedicated read
  budget, alongside a second, more adversarial pass at PR #108's Codex
  backend plumbing (new-session.sh generated-script branching,
  session-doctor.sh backend-awareness) now that the handoff-side
  regression is fixed.
- Re-verify the session-alias poisoning guard fully next run — it was only
  confirmed-by-inference this run (untouched by tonight's PRs), not
  re-read line-by-line.
