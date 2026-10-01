# `session-compact`: compacting idle sessions without corrupting them

`session-compact.sh` finds sessions whose context is worth reclaiming and issues `/compact`
into them, making "compact a stale session before you relay into it" a checkable, testable
operation.

```
session-compact.sh report                      # who is eligible, and why/why not; mutates nothing
session-compact.sh sweep --dry-run             # what the idle/high-context sweep WOULD compact
session-compact.sh sweep --apply               # compact eligible idle/high-context sessions
session-compact.sh before-relay <sess> <msg>   # compact IF stale, verify, then relay the message
session-compact.sh install-timer               # write the systemd units (does NOT enable them)
```

## Report/act boundary

`session-doctor.sh` stays the report-only **sensor** ([`idle-report.md`](idle-report.md));
it only gained `idle-report --minutes N --tsv`. All mutation lives in `session-compact.sh`,
which shells out to the sensor and parses its TSV. That is also why the actuator is
testable: tests feed it synthetic TSV and assert on decisions with no tmux or live session.

## Why compact: not the cache argument

The feature was scoped on "the prompt cache lasts ~1h, so a session idle 30-60min is past
caring and compacting is free". The 1h premise is right; the conclusion is backwards.

Verified in the Claude Code v2.1.206 binary (`strings`, plus tracing where the `ttl` reaching
`cache_control` is decided): Claude Code opts into the 1-hour TTL (not the API's 5-minute
default) behind four gates: no `FORCE_PROMPT_CACHING_5M`, an OAuth-scope eligibility check,
not on overage billing, and a remotely configurable `querySource` allowlist that defaults to
including `repl_main_thread*` (ordinary interactive sessions). It sends the
`extended-cache-ttl-2025-04-11` beta header. The TTL is a sliding window refreshed on every
cache read, so "idle N minutes" = "N minutes since last refresh".

- At 30-60min idle the cache is still alive; compacting then destroys a cache a resumer
  would hit at ~0.1x cost. It is the most expensive moment; waste reaches zero only past 60min.
- Compaction is not a total miss. Caching is tiered (`tools -> system -> messages`) and
  compaction rewrites only the messages tier; the byte-stable system and tool tiers still hit.
- The real trade is timing-independent: one summarization call plus one messages-tier miss,
  repaid by smaller context on every future turn. The only question is "will this session
  have future turns?", which is why the lazy path is primary.
- Caveats: a host whose `ANTHROPIC_BASE_URL` points at a local proxy may not see the literal
  wire bytes; no distinct `querySource` for `--remote-control` exists in the binary (shares
  the interactive value; inferred, not confirmed).

## Measured (CLI v2.1.206, disposable probe session, via `session-handoff.sh send`)

| Measurement | Before | After |
|---|---:|---:|
| `compactMetadata` preTokens -> postTokens | 91,726 | **18,542** |
| `/context` Messages | 62.6k (6.5%) | **34.9k (3.6%)** |
| `/context` total window | 86.8k / 967k (9%) | **59.1k / 967k (6%)** |
| Wall-clock cost of the compact | - | ~101s |

The two pairs measure different things (engine pre/post accounting vs whole-window
breakdown) and need not agree. **Transcript bytes are not tokens; never quote them as a
saving.** On a real 30MB transcript the bytes/extracted-char ratio was 15x, 39% of the file
was a duplicate `toolUseResult` field, and `thinking` blocks store an empty string plus an
opaque signature; the transcript holds all history while live context holds only a suffix.
The only ground truth for context occupancy is a live `/context` reading.

## How it works (verified; don't re-derive)

1. **`/compact` goes through the normal `send` path.** `session-handoff.sh send <s> "/compact"`
   returns `landed`. The `/`-pops-an-autocomplete-menu hazard does not apply: bracketed
   paste (`load-buffer` + `paste-buffer -p -d`) delivers the string atomically (4 slash-command
   sends, no menu).
2. **Sent into a busy session it queues** (shown under `Press up to edit queued messages`)
   and runs when the turn ends. Busy sessions are still skipped, because a queued compact
   fires at an unpredictable point mid-workflow.
3. **A completed compaction is visible in the transcript**: a `type:"system"` entry with
   `"subtype":"compact_boundary"` plus a `compactMetadata` object, then a `type:"user"`
   entry with `"isCompactSummary": true`. Idempotency keys off this (self-healing, no
   marker to go stale when a session is recreated under the same name).
4. **Version-gated**: those fields exist on v2.1.206; older builds lack them. When absent,
   fall back to the marker file `~/.sessions/compact-markers/<session>.json` rather than
   assuming "never compacted".
5. **One `/compact` writes five `type:user` artifacts**; a naive idle calculation sees a
   just-compacted session as fresh and re-compacts it ~30min later, forever. All five are
   excluded so idle is measured from the last genuine turn. The list and scoping live only in
   [`idle-report.md`](idle-report.md) (item 5), so the docs can't drift.
6. **`type:user` includes tool-result turns**, so an autonomously looping agent counts as
   active and is never compacted out from under itself.
7. **`session-compact.sh` polls the transcript** (item 3's marker with a timestamp newer than
   a pre-send baseline) for completion after sending, not pane text. Pane-state
   (busy-then-ready) is a fallback only: relying on it alone gave a false "timeout" on two
   successful compacts, because the pane never matched `_is_working`'s busy patterns and the
   busy-before-ready guard never released.

## Injection hazard: why a positive readiness check exists

`_is_working` detects *busy*, not "safe to type into". With an unsubmitted draft in the
input box the pane shows no spinner, so a naive caller pastes onto the draft and submits
corrupted text. During the probe, ghost text appeared that neither `Ctrl+U` nor `Escape`
cleared.

`session-handoff.sh` therefore has a positive predicate, `_is_safe_to_inject` (CLI:
`ready <session>`), requiring: not working, at a real `❯` prompt, input box free of a real
draft, not on an interactive menu (the `↑/↓ to navigate` widget). It reports a named reason
(`busy` / `draft-in-input-box` / `menu` / `no-prompt`) so a caller can tell "retry later"
from "needs a human".

**Check dimness, not emptiness.** The first cut required an empty box and reported 0 of 29
live sessions safe. Claude Code renders an auto-generated "suggested next action" as
placeholder text in the input box; `capture-pane -p` strips ANSI so it looks like a draft.
`capture-pane -p -e` preserves it, and the suggestion is dim (SGR 2):

```
^[[39m❯ ^[[2mdelete the backup ref^[[0m
```

Rule: dim = placeholder = safe to overwrite (a paste over one landed and `/compact` ran);
non-dim = real draft = never overwrite. The matcher keys on an actual SGR escape, not the
substring `[2m`, so coloured draft text (`ESC[38;5;12m...`) is not mistaken for dim.

| `session-handoff ready` census (live fleet) | SAFE | `draft-in-input-box` | `busy` |
|---|---:|---:|---:|
| empty-box rule | 0 | 29 | 0 |
| dim-aware rule | **28** | 0 | 1 |

Census (only captures panes; safe on live sessions):
`for s in $(tmux ls -F '#{session_name}'); do session-handoff ready "$s"; done`

## Eligibility: all must hold

| Check | Why |
|---|---|
| >=1 genuine `type:user` turn | a never-touched session has nothing to compact |
| idle within the configured window | see the cache section |
| `_is_safe_to_inject` | never paste onto a draft or into a menu |
| not already compacted this idle window | `compact_boundary` after the last genuine turn |
| not (`landed=yes` **and** clean worktree) | finished + delivered: nothing will resume it |
| not protected (`claude-remote` built-in, plus `CRSS_PROTECT_NAMES`) | conservative default |

The protection list guards against deletion and fits injection risk poorly; it is a
conservative default only. `_is_safe_to_inject` is the real guard.

## Two tiers

**Lazy (`before-relay`), primary.** Compact only when someone is about to message a stale
session: zero speculative spend. It reaches the real mass: most reclaimable idle transcript
bytes sit in sessions idle >24h, which a 30-60min window cannot touch.

**Eager (`sweep`), shipped but not automatic.** At measurement time the 30-60min bucket held
0 sessions and >24h held most. A snapshot can't prove a timer would rarely fire (every
session transited the window earlier), but it shows the timer can only be forward hygiene,
never a fix for the backlog. With the inverted cache premise and the injection hazard, no
unattended timer types into ~30 live panes by default.

**Default window is 60min+.** `--min-idle` defaults to **60** and `--max-idle` to **0**
(unbounded): below 60min the 1h cache is live, so 30-60min is the one window with evidence
against it. The old window is `--min-idle 30 --max-idle 60`. `--timeout` defaults to 240s.

## Activation (opt-in, report-only by default)

Units are not committed (SKILL.md Key Rules: scripts and units are local-only).
`install-timer` writes them, modeled on the `session-doctor-weekly` pair:

```
session-compact.sh install-timer        # writes the .service/.timer; enables NOTHING
systemctl --user enable --now session-compact-report.timer    # explicit opt-in
```

The generated unit runs `report` mode only. Check with
`systemctl --user is-enabled session-compact-report.timer`. Enabled, it logs who *would* be
compacted to `~/.local/state/session-compact/report.log` and mutates nothing, giving real
data on how often the window is populated. Promoting it to `sweep --apply` is a separate,
deliberate edit, not before the log shows the window is worth sweeping.

## Deliberately not shipped (fleet-wide)

- An enabled timer sending `/compact` unattended to the whole fleet. A host may run its own
  hand-deployed timer for `sweep --apply --managed-only`, scoped to an allowlist of managed
  orchestrators under the two policies below; that is host state, not documented here.
- An any-age backlog sweep over long-stale sessions: a different feature with a different
  risk profile; `before-relay` already covers one of them being used again.

Cadence: [`references/session-lifecycle.md`](../references/session-lifecycle.md).

## Managed-orchestrator high-context policy

Fleet-wide, the high-context sweep trigger is **80% of the model context window plus 5
minutes idle**. For allowlisted managed orchestrators under `--managed-only` it is lower:
**50% plus 5 minutes idle**. The idle-window path still needs its separate 40% context
floor. The 5-minute floor keeps compaction out of active turns; the lower threshold makes
persistent orchestrators compact well before pressure is acute. Long-running orchestrators
should also checkpoint durably and compact at major phase boundaries and at least once per
active 24-hour period. Code: `_SWEEP_CONTEXT_TRIGGER_PCT`, `_SWEEP_IDLE_CONTEXT_FLOOR_PCT`
in `scripts/session-compact.sh`.

## Managed campaign-phase guard

Managed-only compaction also reads the active Claude session task ledger. Any task with
status `in_progress` skips compaction even if the pane looks idle and the threshold is
exceeded; an unreadable task-state binding also skips (fail-closed). Checkpoint and finish
the phase, compact, then re-orient before opening the next phase.
