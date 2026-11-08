---
name: handoff
description: "Use when a launcher/session-launcher session has a raw or terse human task that belongs in some OTHER Claude session rather than done here, or when the operator types /handoff. Triggers: \"hand this to <session>\", \"relay this task to X\", \"new <repo> session\" followed by a paragraph of intent, routing a request to a live or freshly-spawned target session."
triggers:
  - "hand this to"
  - "relay this task to"
  - "/handoff"
---

# handoff

Turn a terse human task into a target session actually working on a well-formed version of it.
The mechanics are `crss` (root `SKILL.md`). **Which** session and **how to phrase** the task are
your judgment.

**Core principle: relay the *massaged* task, not the raw one, and *confirm it landed*; never
assume the keys were received.**

Use this when a launcher receives a raw or terse task (often "new `<repo>` session" plus a
paragraph of intent), or must route work to a live or freshly spawned session. It is **not** for
doing the target's project work yourself: the launcher stays bounded (route, relay, monitor).

## Workflow

1. **Target.**
   - `crss ls` lists the sessions with their status. Route to an existing owner of the area, or
     `crss spawn` a new one (model choice: root `SKILL.md`).
   - Give every long-lived owner a `CAMPAIGN_CHECKPOINT.md` from
     [`references/campaign-checkpoint.md`](references/campaign-checkpoint.md).
   - **Before routing to an existing session, check its size and staleness, not just the topic
     match.** Look at `tmux capture-pane -p -t =ah_NAME:` for a `/clear to save NNNk tokens` hint
     (six figures means bloated) and for how long it has been idle.
     - A small, recently active session is the cheaper target.
     - A bloated, stale one is the trap. The stale cache means the next message pays full price
       to reload the prefix, and the size means every later turn wades through old history.
     - For a bloated target, don't send into it. Extract the facts that matter, `crss reap` it
       (reap keeps any worktree with uncommitted or unpushed work), and hand the compact version
       to a fresh `crss spawn`.
2. **Check it can take a message.** `crss ls` status:
   - `idle`: ready.
   - `busy`, or `shell` (a shell command is running): the message queues behind the current work.
   - `waiting`: a dialog is open. `crss send` refuses, because Enter would answer the dialog.
     Look at the pane first.
   - `down` or `?`: not running, or claude is still starting. `crss send` refuses.
3. **Massage.**
   - **REQUIRED SUB-REFERENCE: follow the contract in `references/massaging.md`.** Its parts, in
     order:
     - the goal, as a checkable finish line;
     - why, the context and the method (the method is the agent's; give steps only when order
       is a real constraint);
     - known state, to verify rather than assume;
     - the deliverable;
     - carried-forward guardrails;
     - scope (concrete anti-patterns);
     - a stop rule that names the real channel (e.g. `crss send <parent> --file <f>`).
   - The parts are fixed. Weighting and phrasing are judgment. Don't steer research or decision
     answers: no target outcome, no answer menu, no method steps.
   - Long runs get a TASKS.md instruction (re-read it after any compaction).
   - Audits and migrations get subagents that write to files, plus evidence checks.
   - Fill-in shape: `references/kickoff-templates.md` (d). Read `$CRSS_HOME/local.md` first if it
     exists (this host's escalation channel and project index); otherwise use the generic
     defaults.
4. **Relay and confirm.** Write the prompt to a file, then run `crss send NAME --file <path>`
   (`crss spawn NAME DIR --brief <path>` for a new session). It pastes the file as one message
   and presses Enter. The result:
   - `delivered` or `queued` (exit 0): it landed.
   - `UNVERIFIED` (exit 1): capture the pane and confirm the session started working **before**
     you claim success.
   - Refused (exit 2): see step 2.
5. **Report.** Tell the human which session, one line on what you handed it, and **which
   guardrails you preserved** (e.g. "kept the `EXECUTION_APPROVED_HUMAN` gate; flag if you want
   it dropped").
6. **Follow up, don't restart.** Relay news mid-run with `crss send`; respawning throws the work
   away.
7. **When the target reports back:**
   1. First check what it needs from you (a decision, an approval, a merge, a credential) and
      unblock that.
   2. Then verify its claims against evidence (PR, file, command output) before telling the human
      "done".

## Common mistakes

- Relaying the raw task verbatim. That drops the structure a context-less target needs.
- Silently dropping a domain guardrail that the target's peers enforce (e.g. the WATCH-only or
  `EXECUTION_APPROVED_HUMAN` gate). Carry it forward, then flag it to the human.
- Stating possibly stale known state as fact. Mark it "verify, don't assume".
- Reporting success on `UNVERIFIED`.
- A goal with no finish line ("look into X"). The target stops early or never stops.
- No stop rule. The target stalls asking permission for routine steps, or pushes through a
  destructive one. Include part 7 of the massaging contract.
- Padding with "think carefully" or "step by step". Models size their own thinking; spend the
  words on the finish line and the anti-patterns.
- Routing a one-shot task into a bloated, stale session instead of recycling it (see step 1).
