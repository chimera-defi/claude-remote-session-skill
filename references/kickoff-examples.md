# Kickoff examples: before / after

Two **synthetic** kickoffs in a neutral domain (a web-service refactor and a long-running
worker), graded against `handoff/references/massaging.md` and rewritten with
`handoff/references/kickoff-templates.md` template (a). Every name, path, and number below
is invented for illustration; none is taken from a real project. Replace the `<...>`
placeholders with your own values.

---

## Example 1: bounded lane-owner kickoff (service refactor)

### Before

```
You own the billing-service refactor. Do it carefully. GUARDRAILS (non-negotiable): never
touch the payments module, never push to main, don't delete branches, use builders, keep
the test suite green, post status when you can, ask if unsure, read the docs first, stay
inside the billing directory, don't change public API shapes, don't rename things, and make
sure nothing regresses. Report when done.
```

Problems: no WHY behind the hard rule, nine directives in one caps-heavy paragraph, no
finish line, no escalation channel, no mention of what survives a compaction.

### After (template (a))

```
GOAL: extract the invoice-rendering code from `billing/` into `billing/render/` with no
behavior change. Finish line: full test suite green, one PR open against the default
branch, PR body lists anything left undone.

WHY THE HARD RULES EXIST: the payments module is owned by another team and is deployed on
a separate schedule; an accidental edit there ships to production unreviewed.

HARD RULES
1. Do not edit anything under `payments/`. Write a guard test that fails if the diff
   touches that path, and make it your first deliverable.
2. Never push to the default branch; work on a branch and open a PR.
3. Do not delete branches you did not create.

WORKING NOTES
- Keep a `TASKS.md` (finish line at the top, one line per step). Re-read it after any
  compaction, before acting.
- Delegate multi-file work to builder subagents. Brief them completely: only the prompt
  string crosses the parent-to-subagent boundary. Have them write large output to files
  and return short summaries; check their evidence before accepting a report.

STOP RULE: when a step doesn't need a decision from outside, keep going and put status in
the same message as your next action. Stop and ask only when you can't continue without a
decision that's genuinely a human's to make, or before something destructive: deleting
branches/data you didn't create, force-pushing, touching another session or repo.

ESCALATION: anything only a human can decide goes on a numbered list (short description
plus a recommended option), sent as you find it, not at the end:
`session-send <launcher> --file <decisions-file>`
```

### What changed, and why

- Put the reason for the hard rule ahead of the mechanics, so the receiver can generalize
  from it instead of following it mechanically.
- Split one unbroken guardrail paragraph into a short numbered hard-rules list plus
  ordinary working notes; dialed back shouting caps to plain sentences.
- Added a stated finish line, so "done" is checkable.
- Added the `TASKS.md` re-read-after-compaction clause, and an explicit delegation
  instruction (brief completely, large output to files).
- Made escalation a real command the receiver can run, sent as items are found.

---

## Example 2: standing long-running worker kickoff

### Before

```
You are the queue-worker follow-up session. The last session did most of it; continue.
Latest message id is 4812. Check the dashboard, clean up stale jobs, fix what you can, and
keep going until it looks healthy. Don't break anything. Report at the end.
```

Problems: a flat-fact "latest id" on a fast-moving queue, no stop condition, no statement
of what to verify, nowhere to send a question, no note on what to do after compaction.

### After (template (a))

```
GOAL: take over the stale-job cleanup started by the previous session and keep the worker
queue healthy until the stop condition below.

CONTEXT TO VERIFY, NOT ASSUME: the previous session's report and the "latest message id"
it cites are a snapshot. Re-read the queue's current state before building on either.

TASKS
1. Read the previous session's report at `<report-path>`; list what it says is done.
2. Confirm each "done" item against the queue itself, then continue with the remainder.
3. If a pane shows dim prompt text, treat it as autosuggest ghost text, not a queued ask;
   check the transcript and on-disk state before deciding keep or reap.
4. Keep `TASKS.md` current and re-read it after any compaction, before acting.

STOP CONDITIONS (numeric): stop after 3 consecutive health checks with zero stale jobs,
or after 6 hours with no new work, and send a final report.

BOUNDARIES, each with its reason
- Do not delete the worker's working directory: its service unit runs from there.
- Do not use a bare `git stash`: the stash stack is shared across every worktree.
- Do not restart sessions you did not start: someone else may be mid-task in them.

STOP RULE: when a step doesn't need a decision from outside, keep going and put status in
the same message as your next action. Stop and ask only when you can't continue without a
decision that's genuinely a human's to make, or before something destructive: deleting
branches/data you didn't create, force-pushing, touching another session or repo.

ESCALATION: decisions only a human can make go to
`session-send <launcher> --file <decisions-file>` as you find them, each with a
recommended option.
```

### What changed, and why

- Escalation moved from end-of-run to as-you-find-it, with the real command named.
- Tagged the quoted message id and the predecessor's report as "verify, don't assume".
- Added the `TASKS.md` re-read clause; a standing role is exactly the kind of session most
  likely to compact.
- Turned a dense caps guardrail paragraph into individually reasoned bullets; every
  "don't" now carries the reason it exists.
- Kept what was already good: the ghost-text disambiguation (a specific, hard-won lesson
  encoded as "your call") and numeric stop conditions rather than "until healthy".
