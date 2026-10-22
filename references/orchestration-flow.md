# Orchestration flow: Opus orchestrates, Codex builds, Haiku checks, Opus/Fable attack

The default shape for any non-trivial multi-file or multi-step lane. Put this file's path in the
kickoff brief instead of retyping it. Host model pins and quota rules live in the host overlay and
`~/.claude/CLAUDE.md`; this file is only the flow.

## Roles

| Job | Model + effort | Backend | Evidence |
|---|---|---|---|
| Orchestrator | Opus (pinned id; no tier effort) | Claude | orchestration and escalation |
| Implementation/builder | gpt-6.1-sol low, default tier, trim flags below | Codex `codex exec` or `new-session --backend codex` | 2026-10-22 routing decision: spend Codex subscription limits first; A: 7/7, 52–71 s, ~$0.044–0.056 proxy |
| Cheap/fast implementation | gpt-6-luna low | Codex | B: 7/7, 20–21 s, ~$0.004 proxy; small tasks with tools: 4.45 s median, ~$0.0009 proxy |
| Builder fallback | Sonnet 5.5 low, `subagent_type: builder` | Claude | C: 7/7, 17–29 s, $0.09; when Codex cannot run the task |
| Review and mechanical checks | Haiku 5.5 low, `subagent_type: haiku-reviewer` | Claude | ~10 s, ~$0.0013/review; advisory, no real bug found |
| Adversarial reviewer | Opus, different context from author | Claude | races, idempotency, partial failure, restart, rollback |
| Second opinion/tiebreak | Fable, `subagent_type: reviewer`; condensed packet only | Claude | independent read after Opus or at a real fork |

Never: orchestrators hand-implement multi-file changes or do large reads a builder can summarise;
Claude builders inherit Opus; mechanical checks make judgement calls or edit shared state;
reviewers review their own work or say "looks fine" without a failing scenario;
Fable receives transcripts (it shares the Claude spend limit with Opus).

Evidence: model bench 2026-10-22 (https://claude.ai/artifact/E9zfBpSipyg7kS1aP9Luhm).
Small coding tasks: 18 configs, 198 runs, all passed; higher effort changed neither correctness
nor speed on these ceiling tasks. Tools off: Haiku 5.5 low led at 4.54 s, $0.0003.
Agentic task: 5-file change + tests, 7 hidden tests, two rounds each; A/B included Haiku review,
C ran alone. Haiku flagged only spec-undefined inputs: a cheap advisory pass, not a merge gate.

Codex is the default builder on subscription limits; use gpt-6-luna low when cost/latency matters
more than strength. When it is out, say "Codex quota-out, operator-approved Claude-only review"
in the PR and record `models_ran`. Never review on one model family alone when a second is
available. Haiku review alone does not satisfy the second-family gate: it is advisory.

Builder trim flags: `-c skills.include_instructions=false --disable multi_agent -c project_doc_max_bytes=0`
(input ~28k → ~14.5k tokens). Tool-less one-shots may also use
`-c include_environment_context=false -c model_instructions_file=<file>`.
Keep priority out of host config. Opt in per call with `-c service_tier=priority`:
~31% faster on gpt-6.1-sol (5.15 s vs 7.43 s), no gain on luna; assumed 1.5x cost.

## Self-improving routing

- Log each delegated task: job type, model, effort, backend, tier, wall s, $, pass/fail, rework.
- Codex $ is a list-price proxy; log in the lane's `TASKS.md` or report `models_ran`.
- Revisit routing when a job type's pass rate drops, costs drift >2x, or a new model/CLI lands.
- Rerun the bench before changing defaults.
- Record routing decisions with the date.

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
