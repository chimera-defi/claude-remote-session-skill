---
name: handoff
description: Use when a launcher/session-launcher session has a raw or terse human task that belongs in some OTHER Claude session rather than done here, or when the operator types /handoff. Triggers: "hand this to <session>", "relay this task to X", "new <repo> session" followed by a paragraph of intent, routing a request to a live or freshly-spawned target session.
---

# handoff

## Overview

Turn a terse human task into a target session actually working on a well-formed version of it. The mechanics are scripted (`session-handoff`); the two judgment calls — **which** session and **how to phrase** the task — stay yours, guided here.

**Core principle: relay the *massaged* task, not the raw one, and *confirm it landed* — never assume the keys were received.**

## When to use

- A launcher session receives a raw/terse task (often "new `<repo>` session" + a paragraph of intent).
- You must route work to an existing live session, or spawn a fresh one and brief it.
- **Not** for doing the target's project work yourself — the launcher stays bounded: route / relay / monitor.

## Workflow

1. **Target.** `session-handoff targets` lists live sessions with state + model. Decide: route to an existing one, or spawn.
   - Spawn via `new-session <folder> [workspace|sessions]` (it already handles alias anti-poisoning + the model-pin warning). The default `orchestrator` profile already gives **Opus**, so a plain `new-session` is right for launcher work; only pass `CLAUDE_SESSION_MODEL=<model>` (or `CLAUDE_SESSION_PROFILE=builder|copywriter`) when the task wants a different tier.
   - **Before routing to an existing session, check its size and staleness — not just topic match.** `tmux capture-pane -p -t <session>` and look for a `/clear to save NNNk tokens` hint (six figures = bloated) and how long it's been idle. Neither `session-handoff` nor `session-preserve` currently measures this automatically — you have to look. A *small, recently-active* session is usually the cheaper and better routing target (it avoids re-paying rediscovery costs). A *bloated and stale* session is the trap: prompt-cache staleness means the next message pays full price to reload the whole prefix, size means every later turn keeps paying to wade through mostly-irrelevant history — for a one-shot handoff you pay both costs for a single turn's value. In that case, don't send into it: pull out just the load-bearing facts the target needs, then follow the "Preserve before reaping" recipe in [`../references/troubleshooting.md`](../references/troubleshooting.md) (`session-preserve --rescue --wip`, stop the unit, respawn fresh) and hand the compact version to the new session instead.
2. **Verify healthy.** `session-handoff check <tmux-session>` — exit 0 means ready at the prompt. Don't send to a `starting`/`dead` target; `busy` will queue behind current work.
3. **Massage.** Shape the raw request into a self-contained prompt. **REQUIRED SUB-REFERENCE: follow the contract in `references/massaging.md`** — a good handoff prompt *is*: goal (a checkable finish line) → numbered steps → known-state-to-verify-not-assume → deliverable → carried-forward guardrails → scope (with concrete anti-patterns) → stop rule. The parts are fixed; how you weight and phrase them is judgment for the task's domain. Long runs also get a TASKS.md instruction; audits/migrations get subagents-plus-evidence-checks.
4. **Relay + confirm.** Write the massaged prompt to a file, then `session-handoff send <tmux-session> --file <path>`. It pastes (multi-line safe), presses Enter, retries if buffered, and prints `landed` or `unverified`. On `unverified`, re-`check` / capture the pane and confirm the session actually started working **before** you claim success — the human asked for *landed*, not "keys sent".
5. **Report.** Tell the human: which session, one line on what you handed it, and **which guardrails you preserved** — e.g. "kept the `EXECUTION_APPROVED_HUMAN` gate; flag if you want it dropped."
6. **Follow up, don't restart.** If you learn something the target needs mid-run, relay it with `session-send` (or `session-handoff send`) — it picks up a mid-run message without losing its work. Respawning throws that work away.
7. **When the target reports back, check what it needs from you first** — a decision, an approval, a merge, a credential — and unblock that before reading the rest of its summary. Then verify its claims against evidence (the PR, the file, the command output) before relaying "done" to the human.

## Quick reference

| Need | Command |
|------|---------|
| list live targets + model | `session-handoff targets` |
| health of one target | `session-handoff check <tmux-session>` |
| relay a prompt + verify it landed | `session-handoff send <tmux-session> --file <path>` |
| spawn a target (Opus by default via `orchestrator` profile) | `new-session <folder> [sessions\|workspace]` |

Run `session-handoff` with no args for usage. See also: `gstack-session-spawn` (the `new-session`/`session-doctor`/`session-alias` family this builds on).

## Common mistakes

- **Relaying the raw task verbatim** — drops the structure the context-less target needs.
- **Silently dropping a domain guardrail** the target's peers enforce (e.g. the WATCH-only / `EXECUTION_APPROVED_HUMAN` execution gate). Carry it forward, then flag it to the human.
- **Stating known-state as fact** when it may be stale — mark it "verify, don't assume".
- **Reporting success on `unverified`** — confirm the session started working first.
- **A goal with no finish line** ("look into X", "improve Y") — the target either stops early or never stops. Name the checkable end state.
- **No stop rule** — the target stalls asking permission for routine steps, or pushes through a destructive one. Include part 7 (stop rule) from the massaging contract.
- **Padding the prompt with "think carefully / step by step"** — current models size their own thinking; spend the words on the finish line and anti-patterns.
- **Routing a one-shot task into a bloated, stale session instead of recycling it** — burns a full cache-reload on irrelevant history for a single turn's value. Check size/idle time before routing (see step 1); prefer recycle-and-respawn with a compact handoff when both are true.
