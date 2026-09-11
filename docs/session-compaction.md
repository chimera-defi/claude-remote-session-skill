# `session-compact` — compacting idle sessions without corrupting them

`session-compact.sh` finds sessions whose context is worth reclaiming and issues
`/compact` into them. It exists because "compact a stale session before you relay
into it" was informal orchestrator practice that only happened when someone
remembered; this makes it a checkable, testable operation.

```
session-compact.sh report                      # who is eligible, and why/why not — mutates nothing
session-compact.sh sweep --dry-run             # what an idle-window sweep WOULD compact
session-compact.sh sweep --apply               # actually compact the idle window
session-compact.sh before-relay <sess> <msg>   # compact IF stale, verify, then relay the message
session-compact.sh install-timer               # write the systemd units (does NOT enable them)
```

## The report/act boundary is preserved — `session-doctor` never mutates

`session-doctor.sh` stays the **sensor** and stays report-only, per
[`idle-report.md`](idle-report.md) ("the report/act separation is the safety
property"). It gained `idle-report --minutes N --tsv` — minute granularity and a
machine-readable format — and nothing else. **All mutation lives in
`session-compact.sh`**, which shells out to the sensor and parses its TSV.

That split is also why the actuator is testable: tests feed it synthetic TSV and
assert on decisions with no tmux and no live session anywhere.

## What actually justifies compacting (the original cache rationale does not)

This feature was scoped around a cache argument: *the prompt cache boundary is
~1h, so a session idle 30–60min is past the point of caring and compacting is
free.* **The 1h premise is correct. The conclusion drawn from it is backwards.**

Verified by inspecting the Claude Code v2.1.206 binary (`strings` + tracing the
call graph to where the `ttl` reaching `cache_control` is decided, not just
where `"1h"` appears). Claude Code **does** opt into the 1-hour TTL — it is not
the API's bare 5-minute default — behind four gates: no `FORCE_PROMPT_CACHING_5M`,
an OAuth-scope eligibility check, not on overage billing, and a remotely
configurable `querySource` allowlist that **defaults to including
`repl_main_thread*`**, i.e. ordinary interactive sessions. It also pushes the
`extended-cache-ttl-2025-04-11` beta header when it does.

The TTL is a **sliding window refreshed on every cache read**, so "idle N minutes"
and "N minutes since last refresh" are the same thing. Therefore:

> At 30–60min idle the cache is **still alive**. Compacting there destroys a cache
> a resumer would have hit at ~0.1× cost. The window isn't the cheapest moment to
> compact — of the two readings it is the **most expensive** one.

The waste shrinks as you approach 60min and only reaches zero past it. (Under the
counterfactual 5-minute default the window is no better justified — merely
arbitrary, since everything past 5min is equally "expired".)

Two further corrections to the premise's mental model:

- **Compaction is not a total cache miss.** Caching is tiered — `tools → system →
  messages`. Compaction rewrites the *messages* tier only; the large, byte-stable
  system-prompt and tool-definition tiers keep hitting cache. So the cost is one
  tier missing, not the whole prefix.
- **The real trade is timing-independent.** A compact costs one summarization call
  plus a single messages-tier miss on the next turn, and pays back smaller context
  on *every* future turn. Cache timing only adds a second-order, one-turn
  correction, dwarfed by the recurring benefit for any session with more than a
  couple of turns left.

So the only question worth asking is *"will this session have future turns?"* —
which is why the lazy path below is the primary one, and why no idle window is a
good proxy for the answer.

> Two caveats on the above, stated rather than smoothed over: this host's
> `ANTHROPIC_BASE_URL` points at a local proxy, so the described behaviour is
> Claude Code's *intent* and may not be the literal wire bytes; and no distinct
> `querySource` for `--remote-control` exists in the binary — it appears to share
> the ordinary interactive value, which is strongly inferred, not confirmed.

## Measured, not asserted

Harness: spawned a disposable session (`ah_compact-probe-0911-0556`), gave it real
work until its context was non-trivial, drove `/context` and `/compact` through
`session-handoff.sh send`, captured the pane and diffed the transcript.
Claude Code **v2.1.206**.

| Measurement | Before | After |
|---|---:|---:|
| `compactMetadata` preTokens → postTokens | 91,726 | **18,542** |
| `/context` Messages | 62.6k (6.5%) | **34.9k (3.6%)** |
| `/context` total window | 86.8k / 967k (9%) | **59.1k / 967k (6%)** |
| Wall-clock cost of the compact | — | ~101s |

The two token pairs measure different things (the engine's own pre/post accounting
vs `/context`'s whole-window breakdown including system prompt/tools/skills) and
are not meant to agree; both independently show a real reduction.

> **Transcript bytes are not tokens — do not quote them as a saving.** Measured on
> a real 30MB transcript: the bytes/extracted-char ratio is **15×**, **39%** of the
> file is a duplicate `toolUseResult` field mirroring content already present, and
> `thinking` blocks store an empty string plus an opaque signature (real bytes,
> zero readable text). The transcript holds all history; the live context holds
> only a suffix. **The only ground truth for context occupancy is a live
> `/context` reading.**

## How it works (verified empirically — don't re-derive)

1. **`/compact` delivery works through the normal `send` path.** `session-handoff.sh
   send <s> "/compact"` returns `landed`, exit 0. The `/`-pops-an-autocomplete-menu
   hazard **does not apply**: bracketed paste (`load-buffer` + `paste-buffer -p -d`)
   delivers the whole string atomically before per-keystroke autocomplete reacts.
   Confirmed across 4 slash-command sends; no menu ever appeared.
2. **Sent into a busy session it queues, it does not corrupt.** It appears under
   `Press up to edit queued messages` and auto-runs when the in-flight turn ends.
   We still skip busy sessions — not for safety, but because a queued compact fires
   at an unpredictable point mid-workflow.
3. **A completed compaction is detectable in the transcript.** It writes a
   `type:"system"` entry with `"subtype":"compact_boundary"` plus a `compactMetadata`
   object, and the next `type:"user"` entry carries `"isCompactSummary": true`.
   Idempotency keys off this, so it is **self-healing** — no marker file to go stale
   when a session is destroyed and recreated under the same name.
4. **That detection is version-gated.** These fields exist on v2.1.206; transcripts
   from older builds don't have them. When absent, fall back to the marker file at
   `~/.sessions/compact-markers/<session>.json` rather than assuming "never compacted".
5. **`/compact` itself writes a `type:user` entry**, so a naive idle calculation sees
   a just-compacted session as freshly active, and ~30min later it re-enters the idle
   window and gets compacted again, forever. Idle is therefore computed from the last
   **genuine** user turn — entries with `isCompactSummary:true` are excluded.
6. **`type:user` includes tool-result turns** (inherited from `idle-report`), so an
   autonomously-looping agent counts as active and is never compacted out from under
   itself. Intentional.

## The injection hazard — why a positive readiness check exists

`_is_working` detects *busy*. It does **not** mean "safe to type into". If someone
left an **unsubmitted draft** in the input box, the pane shows no spinner, so a
naive caller pastes onto the end of their draft and presses Enter — submitting
corrupted merged text and destroying the draft.

This is not hypothetical. During the probe run, **un-typed ghost text appeared in
the input box that neither `Ctrl+U` nor `Escape` would clear.**

So `session-handoff.sh` gained a *positive* predicate, `_is_safe_to_inject` (plus a
`ready <session>` CLI mode), requiring: not working, at a real `❯` prompt, **input
box free of a real draft**, and not on an interactive menu (the `↑/↓ to navigate`
widget from SKILL.md). It reports a named reason (`busy` / `draft-in-input-box` /
`menu` / `no-prompt`) so a caller can tell "retry later" from "needs a human".

### Not every line in the input box is a draft — check dimness, not emptiness

The first cut of that predicate required the input box to be **empty**, and reported
**0 of 29** live sessions safe. That was a false positive, and the reason matters:

**Claude Code renders an auto-generated "suggested next action" as placeholder text
inside the input box.** All 29 panes had contextually-different text at the same
screen row ("delete the backup ref", "set a recurring mark cadence for the momentum
book", …) while an actively-working session's box was empty. This is the same ghost
text described above.

`tmux capture-pane -p` strips ANSI, which makes a suggestion indistinguishable from a
typed draft. `capture-pane -p -e` preserves it, and the suggestion is **dim** — SGR 2:

```
^[[39m❯ ^[[2mdelete the backup ref^[[0m
```

So the rule is **dim ⇒ placeholder ⇒ safe to overwrite** (the probe confirmed a paste
over one landed cleanly and `/compact` then ran normally); **non-dim ⇒ real
unsubmitted draft ⇒ never overwrite**. Requiring an empty box instead is what turns a
useful predicate into one that refuses every session forever.

Measured across the live host, before and after that fix:

| `session-handoff ready` census | SAFE | `draft-in-input-box` | `busy` |
|---|---:|---:|---:|
| empty-box rule | 0 | 29 | 0 |
| dim-aware rule | **28** | 0 | 1 |

Note the matcher keys on an actual SGR escape, not the substring `[2m`, so colored
draft text (`ESC[38;5;12m…`) is not mistaken for dim. Run the census yourself with
`for s in $(tmux ls -F '#{session_name}'); do session-handoff ready "$s"; done` — it
only captures panes and is safe against live sessions.

## Eligibility — all must hold

| Check | Why |
|---|---|
| ≥1 genuine `type:user` turn | a never-touched session has nothing to compact |
| idle within the configured window | see the timing discussion above |
| `_is_safe_to_inject` | never paste onto someone's draft or into a menu |
| not already compacted this idle window | `compact_boundary` after the last genuine turn |
| not (`landed=yes` **and** git-clean) | finished + delivered: nothing will resume it |
| not protected (`claude-remote\|openclaw\|hermes`) | conservative default |

Note the protection list guards against *deletion* and is a poor fit for injection
risk — it is reused here only as a conservative default, not as the real guard.
`_is_safe_to_inject` is the real guard.

## Two tiers, and why only one of them is automatic

**Lazy (`before-relay`) — the primary path.** Compact only when someone is about to
message a stale session. Zero speculative spend: you pay exactly when you know the
session has a future turn. This is the path that reaches the real mass — measured on
this host, **95% of reclaimable idle transcript bytes sit in sessions idle >24h**
(21 sessions, 101.5MB), which a 30–60min window cannot touch by construction.

**Eager (`sweep`) — shipped, but not automatic.** At the time of measurement the
30–60min bucket held **0 sessions**, while >24h held 21. A point-in-time snapshot
*cannot* prove a timer would rarely fire — every one of those 21 transited the window
earlier — so this is not evidence the timer is useless. It *is* evidence the timer
can only ever be **forward hygiene** (stopping backlog accumulating), never a fix for
the existing backlog.

Given that, plus an inverted cache premise and a real injection hazard, an unattended
timer that types into ~30 live panes is not something this PR turns on.

### The default window is 60min+, not 30–60min

`--min-idle` defaults to **60**, not 30, and `--max-idle` defaults to **0**
(unbounded). This is a deliberate departure from the window this feature was
originally scoped with, and it follows directly from the cache finding above: below
60 minutes the 1h cache is still live, so 30–60min is the one window we now have
evidence *against*. Waiting until past the TTL makes the incremental cache cost of
compacting exactly zero.

The original 30–60min window is still one flag away
(`--min-idle 30 --max-idle 60`) if the operator disagrees with that reading.

## Activation (opt-in, and report-only by default)

Units are not committed — per SKILL.md's Key Rules, scripts and units are local-only.
`install-timer` writes them, modeled on the existing `session-doctor-weekly` pair:

```
session-compact.sh install-timer        # writes the .service/.timer; enables NOTHING
systemctl --user enable --now session-compact-report.timer    # explicit opt-in
```

**The shipped unit runs `report` mode.** Enabling it is safe: it logs who *would* be
compacted to `~/.local/state/session-compact/report.log` and mutates nothing. That
gives real data on how often the window is actually populated — the thing the
snapshot above could not measure. Promoting it to `sweep --apply` is a deliberate,
separate edit, and should not happen until the report log shows the window is worth
sweeping and the cache question is settled.

## Deliberately not shipped

- An enabled timer that sends `/compact` unattended (reasons above).
- An any-age backlog sweep for the 21 stale sessions holding 95% of the reclaimable
  bytes. That is the higher-value follow-up, but it is a different feature with a
  different risk profile, and `before-relay` already covers the case where one of
  those sessions actually gets used again.

Cadence / where this fits: see [`references/session-lifecycle.md`](../references/session-lifecycle.md).
