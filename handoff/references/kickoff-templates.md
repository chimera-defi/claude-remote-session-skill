# Kickoff templates

Fill-in complements to the judgment-based contract in
[`massaging.md`](massaging.md): one compact template per prompt type, plus a pre-send
checklist. Start from the template, then apply massaging.md's judgment for what to weight
per domain — these are starting shapes, not something to fill in mechanically without
reading the task.

**Slots**, used across templates:

- `{goal}` — the outcome in one sentence, not the activity.
- `{why}` — one clause of real motivation. Claude generalizes better from a reason than
  from a bare instruction, so don't skip this even under space pressure.
- `{finish_line}` — the checkable state that means done.
- `{escalation_channel}` — where operator-owned questions go. Fill from
  `$CRSS_HOME/local.md` if it exists; otherwise the generic default is "the session that
  spawned you, via `session-send`".
- `{project_rules_path}` — path to this project's guardrail file (e.g.
  `$CRSS_HOME/projects/<name>.md`), referenced so the kickoff can say "read this; it's
  binding" instead of pasting the guardrail block. Omit the line if none exists.

Before filling any of these in, read `$CRSS_HOME/local.md` if it exists — it holds this
host's actual escalation channel, project index, and delegate routing. Absent overlay:
use the generic defaults shown here.

## (a) Opus orchestrator child session (`new-session`, long-running, can compact)

```
You are {role}. {why}

GOAL: {goal}
FINISH LINE: {finish_line}

Read {project_rules_path} first; it is binding. [Omit if no project rules file exists.]

ROLES: you orchestrate. Delegate every independent slice — research, per-file edits,
verification — to a subagent (`subagent_type: builder` or `model: "sonnet"`, which keeps
`advisor`). Don't delegate a builder's own verification back to itself, and don't spawn
one for something you can finish yourself in a few tool calls. Brief each subagent
completely in the prompt string: nothing else crosses over. For a second opinion on your
own work, spawn a Fable subagent directly (`model: "fable"`) rather than a Sonnet
builder, which would just be Sonnet checking its own reasoning.

CONTEXT HYGIENE: have subagents write large research/logs/diffs to files and return a
short summary plus the file path — don't let intermediate output fill your own context.

TASKS.md: keep one at your worktree root (untracked) with this finish line at the top
and one line per step. Update it as you go, and re-read it after any compaction, before
acting — a summary drops detail a file doesn't. If you write your own compaction
summary, preserve: (1) problems hit and how they were resolved; (2) options considered
and why dropped; (3) exact decisions/constraints stated; (4) current state; (5) what's
still open; (6) exact names/numbers/paths that would be hard to reconstruct.

ESCALATION: send anything genuinely operator-owned to {escalation_channel} as a numbered
list with a recommended option. Decide defaults yourself when there's a normal
recommended answer, and report them afterwards — a question that only sits in your own
pane is a stall, not an escalation.

STOP RULE: when a step doesn't need a decision from outside, keep going and put status
in the same message as your next action. Stop and ask only when you can't continue
without a decision that's genuinely {escalation_channel}'s to make, or before something
destructive: deleting branches/data you didn't create, force-pushing, touching another
session or repo.

When the finish line is met, send {escalation_channel} one report: table, evidence,
open decisions. [Then stay on as owner / then reap yourself — say which.]
```

## (b) Sonnet builder subagent (Agent tool prompt string)

Only this string crosses to the subagent — no parent history, tool results, or system
prompt. `subagent_type: "builder"` already supplies standing instructions (finish line,
stop rule, evidence-based reporting per `agents/builder.md`); this prompt is the task
brief, not a restatement of those. Delegate only genuinely independent, sizeable work; use
one subagent if one suffices.

```
{goal} — {why}

Context: {file paths, prior findings, decisions already made — everything the builder
needs, since nothing else crosses over}.

FINISH LINE: {finish_line}

Scope: {what NOT to touch — other repos, other sessions, files another agent owns}.

Write large intermediate output (research, logs, diffs) to files; keep your final report
short — outcome against the finish line, files changed, evidence for every claim.

If you hit a decision only {escalation_channel} can make, note it in your report instead
of guessing.
```

## (c) Fable reviewer/advisor (second opinion via `model: "fable"`)

Spawn via `subagent_type: "reviewer"` (`agents/reviewer.md`, once deployed to
`~/.claude/agents/`) or an ad hoc `Agent({description, prompt, model: "fable"})` call.
Give it what it needs to form an independent view — the diff, transcript, or decision
itself — not your own conclusion about it. Ask explicitly for its own read, not agreement
with yours; Fable's default prose runs denser than Sonnet's, so ask for a short verdict
first if you need brevity.

```
Review {what: a diff / a decision / a transcript} for {the actual question, e.g. "is
this safe to merge" or "which of these two approaches is better"}.

Context: {why this matters, what's already been tried, constraints that apply}.

Give your own independent verdict — don't anchor on any framing above, including mine.
State what you'd change, if anything, and why. Lead with the verdict; put supporting
detail after it.
```

If the review surfaces something genuinely operator-owned, say so in the verdict rather
than deciding it silently.

## (d) One-shot handoff into an existing session (`session-handoff send`)

Full contract: [`massaging.md`](massaging.md). This is the compact fill-in version of its
seven parts.

```
GOAL: {goal} — {why}

STEPS: {the concrete path, numbered — enough to not reverse-engineer intent, not so
detailed you're doing its thinking for it}

KNOWN STATE (verify, don't assume): {facts you hold, each tagged with how to confirm it}

DELIVERABLE: {exact destination — file path, PR against which branch, report back}

GUARDRAILS: read {project_rules_path} first; it is binding. [Omit if none exists, or add
any execution/safety gate this domain's peers already enforce.]

SCOPE: {what NOT to touch — other sessions, other repos — as concrete anti-patterns, not
"be careful"}

STOP RULE: keep going when a step doesn't need you to check in. Stop and ask only for a
decision only {escalation_channel} can make, or before anything destructive.
```

If this is an assessment-only ask ("what do you think of X", "is this safe") rather than
a go-do-it task, say so explicitly — the deliverable is the assessment, not a fix applied
without being asked.

## Pre-send checklist

- [ ] `{goal}` is a finish line you can check, not an activity.
- [ ] `{why}` is a real reason, not just provenance ("X asked for this").
- [ ] `{escalation_channel}` is a concrete command the operator actually sees (e.g.
      `session-send <parent> --file <f>`), not just "the operator".
- [ ] `{project_rules_path}` is referenced (or its absence is a deliberate call), not
      silently dropped.
- [ ] Every relayed fact that could be stale is marked "verify, don't assume".
- [ ] Scope names concrete anti-patterns for this domain, not "be careful".
- [ ] Stop rule states both when to keep going and when to stop and ask.
- [ ] Long-running (a)/(b)? TASKS.md instruction included, with "re-read after any
      compaction, before acting".
- [ ] (a) only: delegation instruction present — delegate independent slices, don't
      delegate a builder's own verification to itself, brief completely.
- [ ] No "think carefully / step by step / ultrathink"; no ALL-CAPS or "MUST" shouting
      without a reason attached to it.
