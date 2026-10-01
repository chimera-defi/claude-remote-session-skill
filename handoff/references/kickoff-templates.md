# Kickoff templates

Fill-in complements to the contract in [`massaging.md`](massaging.md): one compact template per
prompt type plus a pre-send checklist. These are starting shapes; read the task and apply
massaging.md's domain weighting rather than filling mechanically. First read
`$CRSS_HOME/local.md` if it exists (escalation channel, project index, delegate routing);
otherwise use the generic defaults shown.

**Slots**

- `{goal}`: the outcome in one sentence, not the activity.
- `{why}`: one clause of real motivation. Claude generalizes better from a reason than a bare
  instruction; don't skip it under space pressure.
- `{finish_line}`: the checkable state that means done.
- `{escalation_channel}`: where operator-owned questions go; from `$CRSS_HOME/local.md`, else
  "the session that spawned you, via `session-send`".
- `{project_guardrails}`: how the project's guardrails reach the target. They live in the
  project's own `CLAUDE.md`/`AGENTS.md`, never in the `$CRSS_HOME` overlay.
  - Claude child with workdir inside the repo: the file auto-loads, so don't paste it; name the
    section ("the 'Guardrails' section of the repo's `CLAUDE.md` is binding").
  - Anything else (non-Claude agent such as Codex unless its `AGENTS.md` already points at the
    section, or a Claude child whose workdir is outside the repo): paste the block, or give an
    explicit readable path with the section named.
  A child that never sees a project's execution gate is worse than a long kickoff. Omit the line
  only if the project has no guardrails to carry.
- `{eval_hillclimb_contract}`: for eval/prompt/model/harness campaigns, link
  [`eval-hillclimb-protocol.md`](eval-hillclimb-protocol.md) and fill only budgets, split names,
  noise/min-effect/parity values and the final-holdout owner.

## (a) Opus orchestrator child session (`new-session`, long-running, can compact)

```
You are {role}. {why}

GOAL: {goal}
FINISH LINE: {finish_line}

{project_guardrails} [Omit if this project has none to carry forward.]

ROLES: you orchestrate. Delegate every independent slice (research, per-file edits,
verification) to a subagent (`subagent_type: builder` or `model: "sonnet"`, which keeps
`advisor`). Don't delegate a builder's own verification back to itself, and don't spawn one
for something you can finish in a few tool calls. Brief each subagent completely in the prompt
string: nothing else crosses over. For a second opinion on your own work, spawn a Fable
subagent directly (`model: "fable"`), not a Sonnet builder (Sonnet checking its own reasoning).

CONTEXT HYGIENE: have subagents write large research/logs/diffs to files and return a short
summary plus the path; don't let intermediate output fill your context.

TASKS.md: keep one at your worktree root (untracked) with this finish line at the top and one
line per step. Update as you go; re-read after any compaction, before acting. If you write your
own compaction summary, preserve: (1) problems hit and how resolved; (2) options considered and
why dropped; (3) exact decisions/constraints stated; (4) current state; (5) what's still open;
(6) exact names/numbers/paths hard to reconstruct.

ESCALATION: send anything genuinely operator-owned to {escalation_channel} as a numbered list
with a recommended option. Decide defaults yourself when there's a normal recommended answer
and report them afterwards; a question that only sits in your pane is a stall.

STOP RULE: when a step doesn't need a decision from outside, keep going and put status in the
same message as your next action. Stop and ask only when you can't continue without a decision
that's genuinely {escalation_channel}'s to make, or before something destructive: deleting
branches/data you didn't create, force-pushing, touching another session or repo.

When the finish line is met, send {escalation_channel} one report: table, evidence, open
decisions. [Then stay on as owner / then reap yourself; say which.]
```

## (b) Sonnet builder subagent (Agent tool prompt string)

Only this string crosses to the subagent (no parent history, tool results or system prompt).
`subagent_type: "builder"` already supplies standing instructions (finish line, stop rule,
evidence-based reporting, `agents/builder.md`); this is the task brief. Delegate only
independent, sizeable work; one subagent if one suffices.

```
{goal} — {why}

Context: {file paths, prior findings, decisions already made; everything the builder needs}.

FINISH LINE: {finish_line}

Scope: {what NOT to touch: other repos, other sessions, files another agent owns}.

Write large intermediate output (research, logs, diffs) to files; keep your final report short:
outcome against the finish line, files changed, evidence for every claim.

If you hit a decision only {escalation_channel} can make, note it in your report instead of
guessing.
```

## (c) Fable reviewer/advisor (second opinion via `model: "fable"`)

Spawn via `subagent_type: "reviewer"` (`agents/reviewer.md`, once deployed to
`~/.claude/agents/`) or ad hoc `Agent({description, prompt, model: "fable"})`. Give it what it
needs for an independent view (the diff, transcript or decision itself), not your conclusion.
Ask for its own read, not agreement; Fable's prose runs dense, so ask for a short verdict first
if you need brevity.

```
Review {what: a diff / a decision / a transcript} for {the actual question, e.g. "is this safe
to merge" or "which of these two approaches is better"}.

Context: {why this matters, what's been tried, constraints that apply}.

Give your own independent verdict; don't anchor on any framing above, including mine. State
what you'd change, if anything, and why. Lead with the verdict; supporting detail after.
```

If the review surfaces something operator-owned, say so in the verdict rather than deciding it
silently.

## (d) One-shot handoff into an existing session (`session-handoff send`)

Compact version of the seven parts in [`massaging.md`](massaging.md).

```
GOAL: {goal} — {why}

STEPS: {the concrete path, numbered; enough not to reverse-engineer intent, not so detailed
you're doing its thinking}

KNOWN STATE (verify, don't assume): {facts you hold, each tagged with how to confirm it}

DELIVERABLE: {exact destination: file path, PR against which branch, report back}

GUARDRAILS: {project_guardrails} [Omit if none, or add any execution/safety gate this domain's
peers already enforce.]

SCOPE: {what NOT to touch (other sessions, other repos) as concrete anti-patterns, not "be
careful"}

STOP RULE: keep going when a step doesn't need you to check in. Stop and ask only for a
decision only {escalation_channel} can make, or before anything destructive.
```

For an assessment-only ask ("what do you think of X", "is this safe"), say so explicitly: the
deliverable is the assessment, not a fix applied unasked.

## (e) Eval/hillclimb campaign kickoff add-on

Append to (a), (b) or (d) when the task improves a model, prompt, harness, grader or agent loop.
Detailed rules live in [`eval-hillclimb-protocol.md`](eval-hillclimb-protocol.md); fill only
campaign-specific numbers.

```
EVAL/HILLCLIMB: follow handoff/references/eval-hillclimb-protocol.md.
Objective: {quality/cost/latency Pareto objective, including parity tolerance if cost-focused}.
Splits: SEARCH/TRAIN={name}; GATE/VALIDATION={name, aggregate scores only}; FINAL HOLDOUT={name, owner, untouched until end}.
Budgets: campaign={tokens/calls}; per round={tokens/calls}; novelty reserve={default 20% unless changed}.
Preflight: prove grader stability, plumbing, noise, headroom; if baseline quality is saturated (~95%+), pivot to cost/latency-at-parity.
Round rule: one attributable normal change; novelty rounds may be non-local but still get only cheap smoke before larger spend.
Decision gate: run scripts/eval-hillclimb-decision.py on explicit metrics/budgets; KEEP/REVERT/REFLECT/STOP_BUDGET/COST_PIVOT is binding unless you report why the inputs are invalid.
Leakage: inspect TRAIN failures only; never paste validation/holdout examples or answers into prompts, harnesses, or reports.
Quota: on 429/quota, bounded exponential backoff, then stand down; do not repeatedly poll or nudge without state change.
```

## Pre-send checklist

- [ ] `{goal}` is a checkable finish line, not an activity.
- [ ] `{why}` is a real reason, not provenance ("X asked for this").
- [ ] `{escalation_channel}` is a concrete command the operator sees (e.g.
      `session-send <parent> --file <f>`), not "the operator".
- [ ] `{project_guardrails}` is set the right way for the target (name the section for a Claude
      child inside the repo; paste or give a path otherwise), or its absence is a deliberate call.
- [ ] Every possibly-stale relayed fact is marked "verify, don't assume".
- [ ] Deliverable names an exact destination.
- [ ] Scope names concrete anti-patterns, not "be careful".
- [ ] Stop rule states both when to keep going and when to stop and ask.
- [ ] Eval/hillclimb? Add (e) with budgets/splits/noise/parity; point at the protocol, don't copy it.
- [ ] Long-running (a)/(b)? TASKS.md instruction included ("re-read after any compaction, before acting").
- [ ] (a) only: delegation instruction present (delegate independent slices, not a builder's own
      verification; brief completely).
- [ ] No "think carefully / step by step / ultrathink"; no ALL-CAPS or "MUST" without a reason.
