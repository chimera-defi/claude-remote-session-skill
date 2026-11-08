# Kickoff templates

Starting shapes for the seven parts in [`../SKILL.md`](../SKILL.md); adapt, don't fill mechanically.
Read `$CRSS_HOME/local.md` first if it exists.

Slots: `{goal}` the outcome in one sentence; `{why}` one clause of real motivation;
`{finish_line}` the checkable state that means done; `{escalation_channel}` a concrete command, such
as `crss send <launcher> --file F` (a desktop or bus launcher is not reachable that way; name its
channel from `$CRSS_HOME/local.md`); `{project_guardrails}` the project's own `CLAUDE.md` or
`AGENTS.md` rules. For a Claude child whose workdir is inside the repo, name the section (it
auto-loads); for anything else, paste the block or give a readable path.

## (a) Orchestrator child session (`crss spawn`, long-running)

```
You are {role}. {why}
GOAL: {goal}
FINISH LINE: {finish_line}
{project_guardrails}
CONTEXT: {where things live, what's decided. Preferences labelled "preference, not a target".}
ROLES: you orchestrate. Delegate independent slices by references/orchestration-flow.md (Codex
terra low builds, Haiku low repairs a failed check; Claude fallback `subagent_type: builder`).
Brief each subagent fully; nothing else crosses over. Subagents write large output to files and
return a summary plus path. Don't delegate a builder's own verification back to itself.
TASKS.md: keep one untracked at your worktree root with the finish line on top; re-read after any
compaction. If you write your own compaction summary keep: problems and fixes, options dropped and
why, exact decisions, current state, what's open, hard-to-rebuild names and paths.
ESCALATION: operator-owned items go to {escalation_channel} as a numbered list with a recommended
option. Decide ordinary defaults yourself and report them afterwards.
STOP RULE: keep going on steps that need no outside decision, with status in the same message as
your next action. Stop and ask only for a decision that is {escalation_channel}'s, or before
something destructive: deleting what you didn't create, force-pushing, touching another session or
repo. At the finish line send one report: table, evidence, open decisions.
```

## (b) Builder subagent (Agent tool prompt string)

Only this string crosses; `subagent_type: "builder"` supplies the standing rules (`agents/builder.md`).

```
{goal} - {why}
Context: {paths, prior findings, decisions made}. [Research or decisions: no preferred outcome,
answer menu or method.]
FINISH LINE: {finish_line}
Scope: {what not to touch}.
Write large output to files; report outcome against the finish line, files changed, evidence for
every claim. A decision only {escalation_channel} can make goes in the report, not a guess.
```

## (c) Independent reviewer (one-shot on a frozen packet)

Use one gpt-6.1-sol call while Fable is paused; `agents/reviewer.md` is the Fable form. Give the
diff or decision, not your conclusion.

```
Review {diff / decision / transcript} for {the actual question}. Context: {why it matters,
constraints}. Give your own verdict; don't anchor on any framing here, including mine. Lead with
the verdict, then what you'd change and why.
```

## (d) One-shot handoff into an existing session (`crss send NAME --file F`)

```
GOAL: {goal} - {why}
CONTEXT: {where things live, what changed since; no candidate answers}
PREFERENCES (not targets; the evidence decides): {omit if none}
METHOD: yours. [Numbered steps only where order is a real constraint.]
KNOWN STATE (verify, don't assume): {facts, each tagged with how to confirm}
DELIVERABLE: {exact destination}
GUARDRAILS: {project_guardrails, plus any gate this domain's peers enforce}
SCOPE: {concrete anti-patterns}
STOP RULE: keep going unless a decision is {escalation_channel}'s or a step is destructive.
```

For an assessment-only ask ("is this safe"), say the deliverable is the assessment, not a fix.

## Pre-send checklist

- Goal is a checkable finish line; why is a real reason; escalation channel is a concrete command.
- Guardrails delivered the right way for the target; scope names concrete anti-patterns.
- Research or decision brief: no preferred outcome as target, no answer menu, no method steps,
  neutral question, closeout in the finish line.
- Stale-able facts marked "verify"; deliverable has an exact destination; stop rule says both when
  to keep going and when to ask.
- Report, benchmark or new repo: see [`research-deliverables.md`](../../references/research-deliverables.md).
- Long run: TASKS.md instruction. (a) only: delegation instruction.
