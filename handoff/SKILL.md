---
name: handoff
description: "Use when a launcher/session-launcher session has a raw or terse human task that belongs in some OTHER Claude session rather than done here, or when the operator types /handoff. Triggers: \"hand this to <session>\", \"relay this task to X\", \"new <repo> session\" followed by a paragraph of intent, routing a request to a live or freshly-spawned target session."
triggers:
  - "hand this to"
  - "relay this task to"
  - "/handoff"
---

# handoff

Turn a terse human task into a target session actually working on a well-formed version of
it. Mechanics are scripted (`session-handoff`); **which** session and **how to phrase** the
task are your judgment.

**Core principle: relay the *massaged* task, not the raw one, and *confirm it landed*; never
assume the keys were received.**

Use when a launcher receives a raw/terse task (often "new `<repo>` session" + a paragraph of
intent) or must route work to a live or freshly spawned session. **Not** for doing the
target's project work yourself: the launcher stays bounded (route / relay / monitor).

## Workflow

1. **Target.** `session-handoff targets` lists live sessions with state + model. Route to an
   existing one, or spawn via `new-session <folder> [workspace|sessions]` (handles alias
   anti-poisoning + the model-pin warning). The default `orchestrator` profile gives Opus; pass
   `CLAUDE_SESSION_MODEL=<model>` or `CLAUDE_SESSION_PROFILE=owner|hub|builder|copywriter`
   only for a different tier. `CLAUDE_SESSION_PROFILE=hub` is the Sonnet owner-class profile
   with the Opus one-shot consult contract; `owner` is Sonnet owner-class without that extra
   contract. Name trial lanes, and track their outcomes (commits landed, review pass rate,
   `models_ran`) before you widen them. Other new owners keep their host's default (see
   `$CRSS_HOME/local.md`). Give
   every long-lived owner a `CAMPAIGN_CHECKPOINT.md` from
   [`references/campaign-checkpoint.md`](references/campaign-checkpoint.md).
   - **Check size and staleness before routing to an existing session, not just topic match.**
     `tmux capture-pane -p -t <session>`: look for a `/clear to save NNNk tokens` hint (six
     figures = bloated) and idle time. Neither `session-handoff` nor `session-preserve`
     measures this. A small, recently-active session is the cheaper target. A bloated, stale
     one is the trap: stale cache means the next message pays full price to reload the prefix,
     and size means every later turn wades through irrelevant history, for one turn's value.
     Then don't send into it: extract the load-bearing facts, follow "Preserve before
     reaping" in [`../references/troubleshooting.md`](../references/troubleshooting.md)
     (`session-preserve --rescue --wip`, stop the unit, respawn fresh) and hand the compact
     version to the new session.
2. **Verify healthy.** `session-handoff check <tmux-session>`; exit 0 = ready at the prompt.
   Don't send to a `starting`/`dead`/`menu` target (`menu` covers interactive widgets and the
   first-launch folder-trust dialog; `send` refuses these, it does not queue). `busy` queues
   behind current work. State list: `_state_of`'s comment in `scripts/session-handoff.sh`.
3. **Massage.** **REQUIRED SUB-REFERENCE: follow the contract in `references/massaging.md`**:
   goal (checkable finish line) -> numbered steps -> known state to verify, not assume ->
   deliverable -> carried-forward guardrails -> scope (concrete anti-patterns) -> stop rule
   (naming the real channel, e.g. `session-send <parent> --file <f>`). The parts are fixed;
   weighting and phrasing are judgment. Long runs get a TASKS.md instruction (re-read after any
   compaction); audits/migrations get subagents that write to files plus evidence checks.
   Fill-in shape: `references/kickoff-templates.md` (d). First read `$CRSS_HOME/local.md` if it
   exists (this host's escalation channel and project index); otherwise use the generic defaults.
4. **Relay + confirm.** Write the prompt to a file, then
   `session-handoff send <tmux-session> --file <path>`. It pastes (multi-line safe), presses
   Enter, retries if buffered, and prints `landed` or `unverified`. On `unverified`, re-`check`
   / capture the pane and confirm the session started working **before** claiming success.
5. **Report.** Tell the human which session, one line on what you handed it, and **which
   guardrails you preserved** (e.g. "kept the `EXECUTION_APPROVED_HUMAN` gate; flag if you want
   it dropped").
6. **Follow up, don't restart.** Relay mid-run news with `session-send` (or
   `session-handoff send`); respawning throws the work away.
7. **When the target reports back**, first check what it needs from you (a decision, approval,
   merge, credential) and unblock that. Then verify its claims against evidence (PR, file,
   command output) before telling the human "done".

## Quick reference

| Need | Command |
|------|---------|
| list live targets + model | `session-handoff targets` |
| health of one target | `session-handoff check <tmux-session>` |
| relay a prompt + verify it landed | `session-handoff send <tmux-session> --file <path>` |
| spawn a target (Opus by default; pass `--tier light\|standard\|heavy` to right-size, rubric in the root `SKILL.md`) | `new-session <folder> [sessions\|workspace] [--tier <t>]` |

`session-handoff` with no args prints usage. See also `gstack-session-spawn` (the
`new-session`/`session-doctor`/`session-alias` family).

## Common mistakes

- Relaying the raw task verbatim: drops the structure a context-less target needs.
- Silently dropping a domain guardrail the target's peers enforce (e.g. the WATCH-only /
  `EXECUTION_APPROVED_HUMAN` gate). Carry it forward, then flag it to the human.
- Stating possibly-stale known state as fact: mark it "verify, don't assume".
- Reporting success on `unverified`.
- A goal with no finish line ("look into X"): the target stops early or never stops.
- No stop rule: it stalls asking permission for routine steps, or pushes through a destructive
  one. Include part 7 of the massaging contract.
- Padding with "think carefully / step by step": models size their own thinking; spend the
  words on the finish line and anti-patterns.
- Routing a one-shot task into a bloated, stale session instead of recycling (see step 1).
