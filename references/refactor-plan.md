# crss refactor plan

Measured 2026-11-07 on `origin/main` 11adcaf. Re-measure before each PR; numbers drift.

## Where the lines are

25 files in `scripts/` (24 scripts and `session-aliases.example`), 10,176 lines. 2,980 (29%)
are comment lines.

| Script | Lines | Comment lines | Embedded Python lines |
|---|---|---|---|
| `session-doctor.sh` | 2,740 | 834 | ~409 (10 blocks) |
| `new-session.sh` | 1,489 | 371 | ~28 |
| `session-compact.sh` | 1,314 | 504 | ~123 |
| `session-handoff.sh` | 845 | 422 | ~10 |
| `session-resume.sh` | 472 | 94 | ~60 |
| `session-preserve.sh` | 363 | 149 | |
| `session-alias.sh` | 337 | 151 | |
| `telemetry-report.sh` | 322 | 30 | ~238 |
| `codex-send.py` | 316 | 5 | (all Python) |
| everything else (16 files) | 1,978 | 420 | ~450 |

The rest of the size comes from four places:

- **Copied blocks.** The config loader (22 lines) is in 11 scripts and the prefix block
  (28 lines) is in 7. `_crss_admit` is in 4, `tmux_to_base` in 3, and `_encode_cwd` and
  `_find_helper` in 2. All copies are byte-identical today, and
  `tests/test-crss-overlay-config.sh` keeps the first two that way. Together that is about
  480 lines, plus the 5-line explanation repeated above each loader copy.
- **Embedded Python.** About 1,320 lines sit in heredocs and `python3 -c` strings across 11
  scripts. Some of it parses JSON that `jq` handles in one line; some of it is real logic.
- **Inline dispatch arms.** In `session-doctor.sh`, the `case "$MODE"` body runs from line
  1970 to the end of the file, about 770 lines. `idle-report` alone is about 250.
- **Tests.** 8,722 lines in 49 files. `session-doctor` has 12 test files and `new-session`
  has 5.

## Rules for every PR

- **No behavior change** unless the PR title says so. Each PR states which proof it uses:
  1. **Comment-only.** `shfmt -mn` output matches `origin/main` for every changed `.sh`
     (`shfmt -mn` strips comments and keeps heredoc bodies), `ast.dump` matches for every
     `.py`, and the help text of the scripts that print their header comment matches. A
     checker that does all three goes in `tests/` with PR 1 (see PR order).
  2. **Code move**, such as the shared lib or turning a dispatch arm into a function. Run the
     full suite. Then run the read-only live commands from the `origin/main` copy and the
     branch copy back to back and diff them: `session-doctor report`, `fleet-status --all`,
     `session-registry`, `session-handoff targets`, `new-session --help`.
  3. **Behavior change**, such as dropping a flag or subcommand. An e2e case shows the new
     behavior, and the dead-code evidence below is re-run on the PR's base.
- Branch from `origin/main`, one concern per PR. These PRs touch the same files, so they
  conflict: land them in the order below and rebase the next one on the new `origin/main`
  each time.
- The done list in `CLAUDE.md` still applies: the suite, shellcheck, both leak checks, green
  `shell-tests`, a second-family review, and a redeploy with a diff first.

## 1. Line budget

"After trim" is the comment-only PRs, measured on their branches: 8,362 lines in total
(−18%), with comment lines down from 2,980 to 1,166. "Target" is after the lib, the
heredoc and arg-table PRs, and the proven dead-code removals. Each target is the sum of
that script's copied blocks and the replaceable Python, rounded to the nearest 10.

| Script | Now | After trim | Target | Main lever after the trim |
|---|---|---|---|---|
| `session-doctor.sh` | 2,740 | 2,243 | 1,900 | lib (loader, prefix, `_is_protected`, `tmux_to_base`, `_encode_cwd`, `_find_helper`); `jq` for registry JSON; PR 9 then splits it into two files of about 950 lines each |
| `new-session.sh` | 1,489 | 1,300 | 1,100 | lib (loader, prefix, `_crss_admit`); one table for the codex lane/builder arg pairs; flag parsing |
| `session-compact.sh` | 1,314 | 888 | 750 | lib (`_crss_admit`, `_find_helper`, `_encode_cwd`); its `python3 -c` JSONL scans → `jq` |
| `session-handoff.sh` | 845 | 530 | 450 | lib (loader, prefix, `_crss_admit`, `tmux_to_base`) |
| `session-resume.sh` | 472 | 434 | 340 | lib; admission arg-scan folded into the main parser |
| `session-preserve.sh` | 363 | 277 | 220 | lib; help moves from line-numbered header to `usage()` |
| `session-alias.sh` | 337 | 240 | 190 | lib |
| `telemetry-report.sh` | 322 | 313 | 290 | lib; heredoc stays (real logic) |
| `codex-send.py` | 316 | 316 | 316 | none needed |
| others (16) | 1,978 | 1,821 | 1,700 | lib (6 more loader copies) |
| `crss-lib.sh` (new) | — | — | +130 | |
| **total** | **10,176** | **8,362** | **about 7,400** | |

Most of the code left after this plan is real logic: argument grammars, safety gates and
report builders. Going much below about 7,400 means dropping features. That is the
operator's call, and section 4 lists the candidates that have no scripted caller.

`tests/` target: about 5,000 lines (see section 5).

## 2. Shared lib: `scripts/crss-lib.sh`

**Contents.** These are the blocks copied today, moved verbatim as functions:
- `_crss_load_config`
- `_crss_prefix_init`: the CRSS-PREFIX-RE block wrapped in a function
- `_crss_admit`
- `_is_protected` (in `session-doctor` today; PR #231's `session-restart` adds a second copy)
- `tmux_to_base`
- `_encode_cwd`
- `_find_helper`

Sourcing the lib only defines functions. Each script keeps calling `_crss_load_config` and
then `_crss_prefix_init` at the point where its copied block sits today, so the order of side
effects stays the same. For example, `session-resume` runs its admission gate before loading
config. Scripts that do not have the prefix block today (`fleet-status`,
`telemetry-report`, `record-spawn-telemetry`, `session-spawn-server`) do not call
`_crss_prefix_init`, so they don't start printing its warnings.

**How a script finds it.** It looks next to its own resolved path and never uses `PATH`.
Timer and systemd runs have no usable `PATH`, so a `command -v` lookup would fail there:
```bash
_crss_lib="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/crss-lib.sh"
# shellcheck source=crss-lib.sh
. "$_crss_lib" || { echo "${0##*/}: missing $_crss_lib; install crss-lib.sh next to this script" >&2; exit 2; }
```
- **In the repo:** `scripts/x.sh` finds `scripts/crss-lib.sh`.
- **Deployed:** `~/.local/bin/x` finds `~/.local/bin/crss-lib.sh`.
- **Symlinked into a fake bin by a test:** `readlink -f` resolves back to `scripts/`.

A missing lib exits 2 with that message. There is deliberately no fallback copy: a silent
fallback would let a stale copy run unnoticed.

A caller that runs a script with no file path (`bash -s`, `bash -c "$(cat …)"`, process
substitution) has no `BASH_SOURCE` path either, so that script would exit 2. On 2026-11-07
a grep of `scripts/`, the host overlay and `~/.local/bin` for those forms found none; re-run
it before PR 3.

**Deploy.** The lib is installed before any script that sources it. An old script ignores
the lib, and a new script without it fails at once. The lib PR changes the deploy table in
`CLAUDE.md` to:

| Repo source | Deployed to | How |
|---|---|---|
| `scripts/crss-lib.sh` | `~/.local/bin/crss-lib.sh` | `diff` first, then `install -m 644`, **before** any script that sources it |
| `scripts/<x>.sh`, `scripts/<x>.py` | `~/.local/bin/<x>` | `diff` first, then `install -m 755`; a script that sources `crss-lib.sh` exits 2 if it is missing |

**Rollback.** Reinstall the previous script copies. The lib can stay in place, because
nothing old reads it.

**Tests.**
- **Overlay-config test.** The byte-identity check in `tests/test-crss-overlay-config.sh`
  is replaced by two checks: no script carries its own copy of a lib function, and every
  sourcing script has the lookup line. The behavior cases (an env var wins over the file,
  quote stripping, invalid-prefix fallback, legacy list) run once, against the lib.
- **Tests that copy a script.** These must copy `crss-lib.sh` too:
  - `test-reap-merged`
  - `test-new-session-rtk`
  - `test-new-session-kickoff`
  - `test-session-send` (both layouts)
  - `test-new-session-tier`

  Tests that symlink a script need no change.
- **Deploy-layout test.** Add one e2e case: a flat bin dir holding the script but no lib
  must exit 2 with the message above.

**Not chosen:**
- *Concatenating the lib into each script at install time.* The deployed file would then
  differ from the repo file, which breaks the diff-before-install check the deploy table
  relies on.
- *Keeping the copies with a sync test (today's model).* It costs about 480 lines, and every
  new script has to remember to join the test's file lists.

**Open PR #231** (`session-restart`) carries its own loader and prefix copies and adds itself
to the overlay test's lists. Whichever of #231 and the lib PR lands second converts
`session-restart` to source the lib.

## 3. Splits

**Decision: no per-subcommand files for now.** Every new deployable is another
`~/.local/bin` copy that can drift, and both tests and `reap-merged` call the script as one
file. For example, `reap-merged` re-runs `bash "${BASH_SOURCE[0]}" reap` on itself. The
size problem is comments, copies and inline code, not the number of files.

- **`session-doctor.sh`.** First move each dispatch arm longer than about 15 lines into a
  `_cmd_<sub>` function, which is a code move with no behavior change. The dispatch `case`
  then fits on one screen. If the file is still over 1,500 lines after the lib, heredoc and
  dead-code PRs, split it by domain, not by subcommand:
  - `session-doctor` keeps the dispatcher plus `report`, `history`, `overlay`, `auth-*` and
    `opus-subagents`;
  - a sourced `session-doctor-reap.sh` takes `reap`, `reap-local`, `reap-merged`,
    `archive-ignored`, `land-check`, `worktree-stale` and `registry-*`.

  It deploys next to the script the same way the lib does, and the `session-doctor <sub>`
  command line is unchanged.
- **`new-session.sh`.** Keep it as one file. It is one linear spawn flow. Splitting it moves
  code without removing any. The size levers are the lib, collapsing the codex lane/builder
  argument helpers into one table, and the flag parser.

## 4. Dead code

**Method.**
- Every function in `scripts/*.sh` was checked for a call site other than its own
  definition and comments.
- Every subcommand and flag was grepped in the repo, `$CRSS_HOME` (including
  `host-tools.json`), `~/.claude`, `~/.local/bin`, the systemd user units, and the lines that
  name the tool in other workspace repos.
- A literal grep misses names built at run time. For example, `new-session` calls
  `"$QUOTA_CHECK" "$BACKEND-status"`. Every removal below was also checked for callers that
  build the name.

**Removed in the dead-code PR:**
- **The pre-checksum lock key in `session-git-prep`**, and its mirror in `session-resume`.
  It was a rollout shim for the lock-key change of 2026-09-02, and new claims never write
  the old format. All 12 old-format files under `~/.claude/session-locks/` name dead tmux
  sessions; the newest is from 2026-08-17. The test that pinned the shim now pins the new
  behavior, and it fails against the old script.

**Remove after the `session-handoff` trim lands** (it conflicts with that PR's comment edits):
- **`_is_safe_to_inject`.** It is a one-line wrapper over `_safety_reason` with no caller.
  `docs/session-compaction.md` uses its name three times for what `ready` checks; point
  those lines at `_safety_reason`.

**No dead subcommands or flags.** Each one has a live caller:
- the systemd units: `registry-stale`, `reap-local --force`, `auth-heal --apply`, and
  `reap-merged --apply` from a drop-in;
- `fleet-status`: `report` and `worktree-stale`;
- `env-refresh`: `opus-subagents`;
- `session-compact`: `idle-report --minutes --tsv`;
- the bus-router idle reaper: `land-check`;
- the `host-tools.json` spawn commands: `--launcher`, `--task-file`, `--task-type`,
  `--tier`, `--tier-reason` and `--alias`;
- `new-session`: `quota-check log` and `<backend>-status`.

**Operator-only: no scripted caller, documented for manual use.** Keep these; dropping any
is a feature cut and the operator's call:
- `session-doctor`: `overlay`, `auth-scan`, `suggest-feeders`, `registry-prune`,
  `archive-ignored` (the subcommand form; `reap` runs the function), `history`,
  `--idle-min`, `--allow-young`, `--keep-registry`, `--keep-worktree`, `--outcome` and
  `--outcome-note`;
- `new-session`: `--set-default-alias`, `--escalate-from`, `--task` and `--backend`;
- `crss-module`: `list` and `path`;
- `crss-tmux-scope`: `status` (the default) and `adopt`.

**Test gaps found on the way:** `--outcome-note` has no test anywhere. `--tier-reason` is live
in `host-tools.json` but has no test of its own.

**Python heredocs, input for PR 6:**
- *`jq` candidates:*
  - `record-spawn-telemetry` builds one JSON event (`jq -n`);
  - `session-compact`'s two `python3 -c` JSONL scans;
  - `session-doctor`'s registry-JSON blocks, assessed block by block in that PR.
- *Stay Python, because they hold real logic:*
  - `session-trust-seed` (`fcntl` lock and atomic rename);
  - `codex-resume-pin` (its argv grammar);
  - `telemetry-report` (the report builder);
  - `quota-check` (window logic);
  - `merge-guard` (banner rules);
  - `session-resume` (patches the launch line in place).

## 5. Tests

The operator rule is fewer tests and more e2e. The test count is not a metric. The target is
a few end-to-end cases per tool, each one driving the real script on a fake `HOME` with fake
`tmux`/`claude`/`systemctl` (`tests/lib.sh`, `tests/fake-claude-tui.py`), and asserting on
outcomes (files, units, exit codes, output lines), not on internal function return values.

| Tool | Today | Proposed |
|---|---|---|
| `session-doctor` | 12 files, ~2,200 lines | 3 files: `report`/`history` read-only; reap lifecycle (spawn fixture → reap → archive → registry prune); worktree safety (dirty, ignored, landed) |
| `new-session` | 5 files, ~1,375 lines | 2 files: spawn e2e (name, tier, backend, kickoff) and codex lanes |
| `session-compact` | 2 files, ~590 lines | 1 file |
| `session-handoff` | 2 files, ~390 lines | 1 file, driven by `fake-claude-tui.py` |
| `codex-resume-pin` | 1 file, 496 lines | 1 file, about half the size: one table of argv cases |

**Merge order.** Each merge keeps every distinct behavior that an assertion checks today.
- List the behaviors as one line each in the new file's header.
- Delete only assertions that duplicate one another.
- Run the old and new files on the same commit, then break the script by hand once for each
  behavior and check that the new file catches it.
- Do test merges after the code PRs for that tool, not before, so each code PR still runs
  against the old, wider net.

## 6. Comments

- Keep a one-line "why" for a hazard, a constraint or an outside behavior the code depends
  on. Example: "tmux drops keys sent while a menu is open, so check first."
- Drop comments that restate the code. Drop history (dates, PR numbers, "used to"); it
  belongs in `git log`.
- A file header is the purpose plus one line per subcommand.
- Scripts that print their header as help (`sed -n '2,Np' "$0"`) move to a `usage()` with a
  heredoc, so a comment edit can never change `--help`. Affected: `crss-tmux-scope`,
  `session-preserve`, `session-registry`, `session-spawn-server`, `session-resume` and
  `codex-resume-pin`. This is a separate PR, and it changes only how the help text is
  stored, not the text itself.
- Docs that point at a comment, such as `handoff/SKILL.md` → `_state_of`'s state list or
  `references/session-lifecycle.md` → the `session-doctor` header, must keep that comment
  or move the fact into the doc in the same PR.

## 7. PR order

| # | PR | Risk | Live check after deploy |
|---|---|---|---|
| 1 | Comment trims, already open (one PR per file group), plus the comment-only checker in `tests/` | Low: proof 1 shows identical code | `--help` diff; `session-doctor report` |
| 2 | Proven dead code out (section 4) | Medium: removes paths | Re-run the section 4 greps on the PR base; `session-doctor report` and one dry-run `reap` |
| 3 | `crss-lib.sh` plus the `CLAUDE.md` deploy-table change | **High**: one missing file breaks every script, and so does a caller that runs a script from stdin | Install the lib, then one script (`session-registry`), run it, then the rest. Run `fleet-status --all`, `session-handoff targets`, a `new-session` spawn of a throwaway session, and one timer-driven run (`systemd-run --user` with no `PATH`) |
| 4 | Help text to `usage()` heredocs | Low | `--help` diff per script |
| 5 | `session-doctor` dispatch arms → `_cmd_*` functions | Medium: a big move | Proof 2 snapshot diff |
| 6 | JSON-only Python → `jq`, one script per PR, `session-doctor` first | Medium: parsing edge cases | Proof 2, plus one malformed-input case per replaced block |
| 7 | `new-session` arg-helper table and flag parser | Medium | Spawn one session per `--backend` and `--tier` in a throwaway workspace and diff the generated start scripts |
| 8 | Test consolidation, one tool per PR (section 5) | Low for the fleet, medium for coverage | Break-it-by-hand check per behavior |
| 9 | Re-measure; split `session-doctor` by domain only if it is still over 1,500 lines | Medium | Same as PR 3: new deployable, install order |

Every PR ends with `diff` and then `install` for each changed deployable, and the live check
in its row. A merged PR that has not been redeployed does nothing for the fleet.
