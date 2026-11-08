# Orchestration flow: Opus orchestrates, Codex builds, Haiku checks

Link this from non-trivial multi-file kickoff briefs. Host pins and quota policy live in the host
overlay and the operator's global instructions.

## Roles

| Job | Model | How |
|---|---|---|
| Orchestrator | Opus 5.5, effort medium (high only at risky forks) | `crss spawn NAME DIR --model claude-opus-5-5 -- --effort medium` |
| Builder (default) | gpt-6.1-terra low, priority tier | `codex exec -m gpt-6.1-terra -c model_reasoning_effort=low -c service_tier=priority ... </dev/null` |
| Repair | Haiku low, after a failed check only | `claude -p --model haiku --effort low --tools ""` |
| Escalation | gpt-6-astra medium after a failed repair, or first when latency matters | `codex exec -m gpt-6-astra -c model_reasoning_effort=medium` |
| Claude builder | Sonnet low, when Codex can't run the task | `subagent_type: builder` ([`agents/builder.md`](../agents/builder.md)) |
| First-pass review | Haiku low, read-only, advisory | `subagent_type: haiku-reviewer` |
| Research and workers | gpt-6.1-sol low (medium for large or ambiguous work) | `codex exec` or the host relay |
| Mechanical | Haiku | greps, inventories, log triage, doc moves |
| Independent read | gpt-6.1-sol on a frozen packet (Fable reads are paused) | one call, packet not transcript |

Never:

- Orchestrators hand-implement multi-file changes or do large reads.
- Claude builders inherit Opus (use `subagent_type: builder` or `model: "sonnet"`).
- Mechanical checks make judgement calls or edit shared state.
- Reviewers review their own work, or say "looks fine" without a failing scenario.
- Build with luna (any effort) or sol61 medium: luna low and medium barely reason and failed 40% of
  the hard set; sol61 medium missed 2 of 60.

## Evidence behind the defaults

Private `dispatchbench` runs, 2026-10-22 to 2026-11-02. IDs and flags are bench-time; the host
overlay may override.

- terra61-low fast matched sol61-high's pass rate at about a third of the cost and 2.5 to 3x faster
  (commit f77c040). L7 hard problems p13 to p15 were not run on terra, so sol61-high stays the pick
  for work the bench did not cover. Revisit if terra61-low's logged fail rate passes about 5%.
- sol61-high and astra-medium never failed on any set (function 60/60, L7 15/15, hard 35/35,
  agentic 12/12). sol61-xhigh equalled high at 1.5x the output tokens.
- Tools-off Haiku: medium missed 1 of 60 and 2 of 15 L7; high passed every set, about 4x cheaper
  than Sonnet medium. That is why Codex-out failed checks go to Haiku high.
- A light check using only statement examples missed 3 of 35 bad answers; use real tests.
- Haiku reviews flagged only spec-undefined inputs: advisory, not a merge gate. Review quality is
  unmeasured.
- Orchestrator effort: medium scored 8.3 vs high 8.0 on a blind check at about 60% of the cost.

## Escalation ladder

terra61-low, then a light check (tests or examples), then Haiku low repair on failure, then
astra-medium, then a Sonnet builder. Hop on a failed check, or when the task needs judgement or
architecture. Log each hop in the lane's `TASKS.md` or report (`models_ran`).

To change the default builder, change `-m` and `model_reasoning_effort` in the `codex exec` line
you give builders.

### Quota ladder

luna, sol and astra share one Codex quota, so hopping between Codex models never escapes a quota-out.
Call a tool "out" only on the exact quota error text (a failed `codex exec`, or an API error in the
Claude transcript) and quote it in the report. Nothing in crss detects this; the orchestrator walks it.

- **Codex out:** one-shot builds go to Haiku low with the same check; a failed check or costly miss
  goes to Haiku high. A whole lane becomes `crss spawn NAME DIR --model sonnet -- --effort low`.
  Return to terra61-low when Codex resets.
- **Claude out:** Codex only; terra61-low builds, gpt-6.1-sol reviews; the PR says "single-family
  review (Claude quota-out)".
- **Both out:** pause and report the exact error text.

Review wants a second model family when available; Haiku alone is advisory.

### Codex flags

- Builder trims: `-c skills.include_instructions=false --disable multi_agent -c project_doc_max_bytes=0`
  (input about 28k to 14.5k tokens). The host `AGENTS.md` in `$CODEX_HOME` can't be dropped by any flag.
- Commits from a sandboxed builder in a linked worktree fail with `index.lock': Read-only file
  system`, because `workspace-write` makes `.git` read-only. Add the gitdir and the common `objects`,
  `refs` and `logs` directories from `git rev-parse --path-format=absolute --git-dir --git-common-dir`
  as `--add-dir <DIR>`, one each, on `codex exec -s workspace-write -C "$dir"`. Adding `.git` itself
  does not work.
- Priority tier: default since 2026-10-30 in `~/.codex/config.toml` (`service_tier = "priority"`),
  and passed as `-c service_tier=priority` so benches and other hosts keep it. It cut sol61-high's
  median from 30 s to 19 s at about 2x list price. Claude fast mode stays off unless the operator
  asks for a deadline push.

## Steps

1. **Finish line first.** One checkable "done" atop `TASKS.md` (scratchpad or worktree, untracked);
   re-read it after compaction.
2. **Packet:** decided design, exact paths, constraints, tests, "open PR from `origin/main`, do not
   merge", safety rules. A builder has no other context.
3. **Fan out** independent slices only, about 3 concurrent subagents. Subagents can't nest.
4. **Verify:** re-run cited commands or open file:line before relaying "done"; otherwise unverified.
5. **Adversarial review:** Opus gets the diff, the claim and run instructions, not the transcript.
   Findings are file:line, why wrong, a failing scenario. Max 3 rounds; re-review changes only.
6. **Land:** CI green plus second-family review, merge, diff and redeploy deployed copies. Before
   live infrastructure restarts, send the launcher a runbook and rollback.
7. **Report:** what landed, what was redeployed, what is left, `models_ran`, numbered operator
   decisions each with a recommended option.

Builders draft briefs, dispositions and review packets from frozen packets; the orchestrator decides,
verifies and posts. Ask the operator (with a recommendation) only for irreversible, outward-facing or
conflicting-requirement decisions; otherwise decide and report. Measure a session with the host's
`usage-audit` if it has one. Revisit routing when a job type's pass rate drops, costs drift over 2x,
or a new model lands, and rerun the bench first.
