# Delegating work: pick the smallest thing that works

Link this from non-trivial multi-file kickoff briefs. Which model fills each role is host policy.

## Pick the smallest thing that works

Start with what Claude Code does natively. Reach for `crss` only when the work must outlive one session.

| Need | Use |
|---|---|
| A worker inside this session, with its own context, that returns a summary | **Subagents.** Parallel for independent work, chained when each step needs the last |
| One script that fans out many subagents (fan-out then verify, iterate until passing, review then merge) | **Dynamic workflows** |
| Independent tasks you check on later | **Agent view / background sessions** (`claude --bg`, research preview) |
| A lead plus teammates sharing a task list and a mailbox | **Agent teams** (experimental). Teammates get no worktree isolation, so partition the files |
| Sessions on one machine talking to each other | **Cross-session messaging** (ListAgents / SendMessage) |
| Long-lived, named sessions that restart themselves, survive a reboot (timer), and are reachable from the phone | **crss sessions.** `crss send` reports delivered or queued; `crss reap` keeps unpushed work |

## Patterns

Multi-agent runs use roughly 15x the tokens of a chat (Anthropic's multi-agent research post). Use them
when the work is parallel and valuable enough to pay for that.

Each pattern: when to use it, its shape, what it costs.

- **Orchestrator and workers.** *When:* a task splits into bounded pieces. *Shape:* one planner briefs,
  verifies and decides; cheaper workers build. The planner does not hand-implement multi-file changes or
  do large reads. *Cost:* one planner context plus a context per worker; the planner's attention is the
  bottleneck.
- **Pipeline.** *When:* each step needs the previous one's output. *Shape:* chained steps, each with its
  own check, so a bad step stops the chain. *Cost:* no parallelism; latency adds up.
- **Fan-out and verify (swarm).** *When:* many independent slices (audits, migrations, research).
  *Shape:* parallel workers, one per slice, writing to files; then an independent verifier per result.
  Never trust a worker's "done". About 3 concurrent subagents is a sane start; subagents can't nest.
  *Cost:* the multi-agent token multiplier above, plus the verifiers.
- **Hub with lane owners (coordinator, fleet).** *When:* several lanes of work run for hours or days.
  *Shape:* a launcher session spawns long-lived owner sessions with `crss spawn`; each owns a lane and
  reports back with `crss send`. Owners decide and land; the hub relays only real decisions. *Cost:*
  every owner is a resident session, so reap finished ones.
- **Review gate.** *When:* before anything merges or a person acts on it. *Shape:* the builder is never
  the sole reviewer; an independent reviewer reads a frozen diff, not the transcript (rule:
  [spawn-guide](spawn-guide.md#second-opinions)). *Cost:* one extra read per change; a cheap first pass
  is advisory only.

## Roles

| Role | Job |
|---|---|
| Planner / verifier | Strongest model. Plans, briefs, verifies claims, decides. Short, hard, bounded work |
| Builder | Cheap model. Runs the task's own check (real tests, not just the examples in the spec) before reporting. On a failed check raise effort before changing model |
| Read-only scanner | Smallest model. Searches, reads logs, summarizes; no edits (`agents/haiku-scanner.md`) |
| Independent reviewer | A different model family when you have one. Gets a frozen packet, not the transcript |

Mechanical checks (greps, inventories, log triage) report; they make no judgement calls and edit no
shared state. Which model fills each role is host policy: `$CRSS_HOME/staffing.md`.

## Brief template

A worker has no other context, so the brief carries it. Four parts:

1. **Objective.** One sentence naming a checkable finish line, and what check to run.
2. **Output format.** What to return and where (paths, PR base, "large output to files, summary back").
3. **Tools and sources.** Which files, commands and sources to use.
4. **Boundaries.** What not to touch, as concrete anti-patterns ("open the PR from `origin/main`, do not merge").

Also restate any rule the brief depends on; a worker will not infer it. Shapes for each case:
[kickoff-templates](../handoff/references/kickoff-templates.md).

## Steps

1. **Finish line first.** One checkable "done" atop `TASKS.md` (scratchpad or worktree, untracked);
   re-read it after compaction.
2. **Packet:** decided design, exact paths, constraints, tests, safety rules.
3. **Fan out** independent slices only. Give each its own delegate; write results to files.
4. **Verify:** a subagent report is a claim. Call a tool "out" (quota, blocked) only on its exact error
   text, and quote it. Re-run the command it cites or open the file:line before
   relaying "done"; otherwise label it unverified. Consolidate verified results in one table.
5. **Adversarial review:** the reviewer gets the diff, the claim and run instructions, not the
   transcript. Findings are file:line, why it is wrong, a failing scenario. Max 3 rounds; re-review
   changes only.
6. **Land:** CI green plus independent review, merge, then diff and redeploy deployed copies. Before
   restarting live infrastructure, send the launcher a runbook and a rollback.
7. **Report:** what landed, what was redeployed, what is left, which models ran, and numbered decisions
   each with a recommended option.

When to stop and ask: [kickoff-templates](../handoff/references/kickoff-templates.md). Revisit your
routing when a job type's pass rate drops, costs drift, or a new model lands.
