---
name: handoff
description: "Use when a launcher/session-launcher session has a raw or terse human task that belongs in some OTHER Claude session rather than done here, or when the operator types /handoff. Triggers: \"hand this to <session>\", \"relay this task to X\", \"new <repo> session\" followed by a paragraph of intent, routing a request to a live or freshly-spawned target session."
triggers:
  - "hand this to"
  - "relay this task to"
  - "/handoff"
---

# handoff

Turn a terse human task into a target session working on a well-formed version of it. The
mechanics are `crss` (root `SKILL.md`); **which** session and **how to phrase** the task are your
judgment. Relay the massaged task, not the raw one, and confirm it landed. The launcher stays
bounded: route, relay, monitor; never do the target's project work.

## Workflow

1. **Target.** `crss ls`. Route to the existing owner of the area, or `crss spawn` a new one (model
   choice: `references/spawn-guide.md`). Check size and staleness, not just topic: a `/clear to save
   NNNk tokens` hint in `tmux capture-pane -p -t =ah_NAME:` with six figures means bloated. Don't
   send a one-shot into a bloated, stale session (the next message pays full price to reload the
   prefix); extract the facts, `crss reap` it, and hand the compact version to a fresh spawn.
2. **Can it take a message?** `idle` yes. `busy` or `shell`: it queues. `waiting`: a dialog is open
   and `crss send` refuses; look at the pane. `down` or `?`: refused.
3. **Massage** into the seven parts below. The parts are fixed; weighting and phrasing are
   judgment. Shapes: `references/kickoff-templates.md`. Read `$CRSS_HOME/local.md` first if it
   exists (this host's escalation channel and project index).
4. **Relay and confirm.** Write the prompt to a file; `crss send NAME --file F` (or `crss spawn NAME
   DIR --brief F`). `delivered` or `queued` (exit 0) landed. `UNVERIFIED` (1): capture the pane and
   confirm it started working before claiming success. Refused (2): see step 2.
5. **Report** to the human: which session, one line on what you handed it, and which guardrails
   you preserved.
6. **Follow up, don't restart.** Relay news mid-run with `crss send`; respawning throws work away.
7. **When the target reports back:** unblock what it needs (a decision, approval, merge,
   credential), then verify its claims against evidence (PR, file, command output) before telling the
   human "done".

## The seven parts

1. **Goal:** one sentence naming a checkable finish line, the outcome not the activity ("a ranked
   shortlist in `memory/survey.md`", not "survey the candidates").
2. **Why and method:** one clause of why; the method is the target's. Give steps only where order
   is a real constraint.
3. **Known state, to verify:** each item tagged with how current it is and how to confirm it.
4. **Deliverable:** what to produce and exactly where (path, PR base branch, report to whom).
5. **Carried-forward guardrails:** what governance the target's peers enforce in this domain
   (read-only, execution gates). A relay never silently drops one; if unsure, include and flag it.
   For execution-capable work put this first.
6. **Scope:** what not to touch, as concrete anti-patterns ("don't branch from local `main`").
7. **Stop rule and channel:** keep going on steps that don't need a decision; stop and ask only
   for an operator-owned decision or before something destructive; name a real command
   (`crss send <parent> --file F`), or the host's channel when the parent isn't a crss session.

## Rules

- **Don't steer research or decision answers.** No preferred outcome as target (label preferences
  "not a target; the evidence decides"), no menu of candidate answers, no method steps; ask
  neutrally ("what does the evidence say about X?"). Re-asking a settled question is not new
  evidence; reopen one only if a pre-agreed trigger fired or the facts changed, and say which.
- **Research and decision briefs need a closeout** in the finish line: every recommendation marked
  adopted, declined, superseded or needs-ruling, with an owner; each rule's checker and date; the
  operative part as a short separate proposal; the findings ledger updated in place.
- **Build work:** name the branch, PR or direct commit, and required tests; ask for a self-review of
  the diff (merge-blocking problems only, file:line and a failing case).
- **Audits and migrations:** one subagent per slice writing to files, plus evidence checks.
- **Long runs** (hours, several PRs): "Keep a TASKS.md (untracked) with the finish line on top and
  one line per step; re-read it after any compaction." A long-lived owner also keeps a short
  checkpoint file with finish line, state and `next_action`, so a fresh owner can resume.
- **Eval or hillclimb campaigns:** declare the objective, splits (never paste hidden failures),
  budgets, noise, minimum effect and a decision rule up front; touch the final holdout once.
- No "think carefully" or "step by step" filler.

## Common mistakes

Relaying the raw task; dropping a peer guardrail; stating stale state as fact; reporting success on
`UNVERIFIED`; a goal with no finish line; no stop rule; routing a one-shot into a bloated session.
