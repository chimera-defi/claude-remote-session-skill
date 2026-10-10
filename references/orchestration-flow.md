# Orchestration flow: Opus orchestrates, Sonnet builds, Opus attacks

The default shape for any non-trivial multi-file or multi-step lane. Put this file's path in the
kickoff brief instead of retyping it. Host model pins and quota rules live in the host overlay and
`~/.claude/CLAUDE.md`; this file is only the flow.

## Roles

| Role | Model | Does | Never |
|---|---|---|---|
| Orchestrator | Opus (the `orchestrator` profile's pinned id, see `SKILL.md` key rules) | reads, diagnoses, decides, writes frozen packets, verifies, reports | hand-implements multi-file changes; large reads that a builder can summarise |
| Builder | Sonnet (`subagent_type: builder` or `model: "sonnet"`) | implements one independent slice in its own worktree off `origin/main`, opens a PR, does not merge | inherits the Opus model (it silently loses `advisor`) |
| Mechanical | Haiku (`model: "haiku"`) | greps, inventories, log triage, doc moves | judgement calls, anything that edits shared state |
| Adversarial reviewer | Opus (`model: "opus"`), a different context from the author | tries to break the diff: races, idempotency, partial failure, restart, rollback | reviewing its own work; "looks fine" without a failing scenario |
| Second opinion / tiebreak | Fable (`subagent_type: reviewer`, `agents/reviewer.md`) | an independent read of a diff or decision after the Opus pass, at a real fork, or before a risky action; condensed packet only | pasting transcripts (it shares the Claude spend limit with Opus) |

Codex is the preferred builder/reviewer when the host overlay says it has quota (model and flags live there); when it is
out, say "Codex quota-out, operator-approved Claude-only review" in the PR and record `models_ran`.
Never review on one model family alone when a second is available.

## Steps

1. **Finish line first.** One checkable "done" at the top of `TASKS.md` (scratchpad or worktree, not
   committed). Re-read it after any compaction.
2. **Packet.** For each slice: decided design, exact paths, constraints, tests to add, "open PR from
   `origin/main`, do not merge", and the safety rules that apply. A packet is self-contained; the
   builder has none of your context.
3. **Fan out.** Keep concurrent subagents few (3 is a good ceiling here); subagents cannot nest. Independent slices only.
4. **Verify claims.** A report is a claim. Re-run the cited command or open the cited file:line
   before relaying "done" or "no issues". No evidence means unverified.
5. **Adversarial review.** Opus reviews each diff on its own packet (the diff, the claim, how to run
   it), not your transcript. Findings are file:line, why wrong, how to show it fails. Max 3 rounds;
   fix, re-run gates, re-review only what changed.
6. **Land.** CI green + second-family review, then merge. Redeploy anything deployed (diff first;
   deployed copies drift both ways). Anything that restarts live infrastructure: runbook and rollback
   to the launcher first.
7. **Report.** What landed, what was redeployed, what is left, `models_ran`, and numbered operator
   decisions each with a recommended option.

## Rules that keep it cheap and safe

- Drafting counts as building: briefs, dispositions, review packets and records go to a builder with a
  frozen packet; the orchestrator decides, verifies, posts.
- Fewer, better tests; a few real end-to-end checks; test count is not a metric.
- Ask the operator only for a decision that is theirs (irreversible, outward-facing, conflicting
  requirements), with a recommendation; everything else, decide and report.
- Blocked sessions raise nothing on their own: `session-send` the launcher with the exact decision.
