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
   - Spawn via `new-session <folder> [workspace|sessions]` (it already handles alias anti-poisoning + the model-pin warning). Launcher default is **Opus** unless the task names a model: `CLAUDE_SESSION_MODEL=opus new-session <folder> sessions`.
   - **Before routing to an existing session, check its size and staleness — not just topic match.** `tmux capture-pane -p -t <session>` and look for a `/clear to save NNNk tokens` hint (six figures = bloated) and how long it's been idle. Neither `session-handoff` nor `session-preserve` currently measures this automatically — you have to look. A *small, recently-active* session is usually the cheaper and better routing target (it avoids re-paying rediscovery costs). A *bloated and stale* session is the trap: prompt-cache staleness means the next message pays full price to reload the whole prefix, size means every later turn keeps paying to wade through mostly-irrelevant history — for a one-shot handoff you pay both costs for a single turn's value. In that case, don't send into it: pull out just the load-bearing facts the target needs, then follow `gstack-session-spawn`'s "Preserve before reaping" recipe (`session-preserve --rescue --wip`, stop the unit, respawn fresh) and hand the compact version to the new session instead.
2. **Verify healthy.** `session-handoff check <tmux-session>` — exit 0 means ready at the prompt. Don't send to a `starting`/`dead` target; `busy` will queue behind current work.
3. **Massage.** Shape the raw request into a self-contained prompt. **REQUIRED SUB-REFERENCE: follow the contract in `references/massaging.md`** — a good handoff prompt *is*: goal → numbered steps → known-state-to-verify-not-assume → deliverable → carried-forward guardrails → scope. The parts are fixed; how you weight and phrase them is judgment for the task's domain.
4. **Relay + confirm.** Write the massaged prompt to a file, then `session-handoff send <tmux-session> --file <path>`. It pastes (multi-line safe), presses Enter, retries if buffered, and prints `landed` or `unverified`. On `unverified`, re-`check` / capture the pane and confirm the session actually started working **before** you claim success — the human asked for *landed*, not "keys sent".
5. **Report.** Tell the human: which session, one line on what you handed it, and **which guardrails you preserved** — e.g. "kept the `EXECUTION_APPROVED_HUMAN` gate; flag if you want it dropped."

## Quick reference

| Need | Command |
|------|---------|
| list live targets + model | `session-handoff targets` |
| health of one target | `session-handoff check <tmux-session>` |
| relay a prompt + verify it landed | `session-handoff send <tmux-session> --file <path>` |
| spawn a target (Opus default for launcher work) | `CLAUDE_SESSION_MODEL=opus new-session <folder> [sessions\|workspace]` |

Run `session-handoff` with no args for usage. See also: `gstack-session-spawn` (the `new-session`/`session-doctor`/`session-alias` family this builds on).

## Common mistakes

- **Relaying the raw task verbatim** — drops the structure the context-less target needs.
- **Silently dropping a domain guardrail** the target's peers enforce (e.g. the WATCH-only / `EXECUTION_APPROVED_HUMAN` execution gate). Carry it forward, then flag it to the human.
- **Stating known-state as fact** when it may be stale — mark it "verify, don't assume".
- **Reporting success on `unverified`** — confirm the session started working first.
- **Routing a one-shot task into a bloated, stale session instead of recycling it** — burns a full cache-reload on irrelevant history for a single turn's value. Check size/idle time before routing (see step 1); prefer recycle-and-respawn with a compact handoff when both are true.
