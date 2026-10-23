# Orchestration flow: Opus orchestrates, luna builds, Haiku checks, Opus/Fable attack

Default shape for any non-trivial multi-file or multi-step lane; link it in the kickoff brief.
Host model pins and quota rules live in the host overlay and `~/.claude/CLAUDE.md`.

## Roles

| Job | Model + effort | Backend | Evidence |
|---|---|---|---|
| Orchestrator | Opus (pinned id), effort medium; high at risky forks | Claude | blind check: medium 8.3 vs high 8.0, $0.10 vs $0.17 a plan |
| Builder (default) | gpt-6-luna high, default tier, [trim flags](#codex-flags) (stripped harness for tool-less one-shots); any bounded, well-specified task | Codex `codex exec -m gpt-6-luna -c model_reasoning_effort=high`, or `new-session --backend codex` (`--tier auto --task-type build` sets it) | hard set (routing bench): stripped high 31/35, $0.00105/pass, ~13 s; luna low 21/35 |
| Builder repair (fallback) | Haiku low reads the statement + luna's code and returns corrected code, then re-run the check | Claude `claude -p --model haiku --effort low --tools ""` with a repair prompt (not `haiku-reviewer`, which only reports) | luna low → Haiku repair 35/35, $0.0035/pass, ~27 s |
| Builder escalation | gpt-6.1-sol medium after a failed Haiku repair ([ladder](#escalation-ladder)) | Codex | A: 7/7, 52–71 s, ~$0.044–0.056 proxy |
| Builder fallback | Sonnet 5.5 low, `subagent_type: builder` ([`agents/builder.md`](../agents/builder.md)) | Claude | C: 7/7, 17–29 s, $0.09; when Codex cannot run the task |
| Review | Haiku low, `subagent_type: haiku-reviewer` (read-only; [`agents/haiku-reviewer.md`](../agents/haiku-reviewer.md)) | Claude | ~10 s, ~$0.0013/review; advisory, no real bug found |
| Mechanical | Haiku (`model: "haiku"`) | Claude | greps, inventories, log triage, doc moves |
| Adversarial reviewer | Opus, different context from author | Claude | races, idempotency, partial failure, restart, rollback |
| Second opinion/tiebreak | Fable, `subagent_type: reviewer` ([`agents/reviewer.md`](../agents/reviewer.md)); condensed packet only | Claude | independent read at risky forks or after Opus |

Never:

- Orchestrators hand-implement multi-file changes or do large reads.
- Claude builders inherit Opus.
- Mechanical checks make judgement calls or edit shared state.
- Reviewers review their own work or say "looks fine" without a failing scenario.
- Fable receives transcripts (it shares the Claude spend limit with Opus).

## Bench evidence

Model bench 2026-10-22 ([private report](https://claude.ai/artifact/E9zfBpSipyg7kS1aP9Luhm)) and the follow-up routing bench (private repo `model-routing-bench`); ids and flags as of those benches, a host overlay may override them.

- Small coding tasks: 18 configs, 198 runs, all passed; higher effort changed neither correctness nor speed on these ceiling tasks.
- Tools off: Haiku 5.5 low led at 4.54 s, $0.0003.
- Agentic task: 5-file change + tests, 7 hidden tests, two rounds each; A/B included Haiku review, C ran alone.
- Haiku flagged only spec-undefined inputs: a cheap advisory pass, not a merge gate.
- Harder problems (luna's 7 worst, n=35 each, post hoc): luna low/medium average 0–7 reasoning tokens a call and pass 21/35; prompt nudges and harness trims do not change that. luna high (stripped) 31/35, Haiku low 32/35, luna low → Haiku repair 35/35, Sonnet medium 35/35 at ~10× the cost.
- Measured on one real lane (2026-10-22, website copy + this tool; `scripts/slice-usage.py`, $ from a one-call CLI cost probe per model, so read it as ±30%). Haiku research and two luna high builds cost $0.03 in all; the same tokens on Opus would have cost ~$1.55. But the bill was the Opus orchestrator ($7.45, 10M cache-read tokens over 79 calls) and three Fable reviews ($6.05; Fable is about 3x Opus per token on the probe). Cheap builders are a solved saving. The levers left are fewer orchestrator turns and one Fable gate per change on a tight packet, with interim checks on Haiku.

## Escalation ladder

Default builder: gpt-6-luna high (operator, 2026-10-22, replacing luna low); Codex first spends that subscription first.

luna high → Haiku low repair → gpt-6.1-sol medium → Sonnet builder.

- Hop on a failed check or Haiku review, or when the task needs judgement, ambiguity resolution or architecture.
- Log every hop in the [routing log](#self-improving-routing) so the table self-corrects.
- Don't build with luna low or medium beyond trivial edits: they barely reason and failed 40% of the hard set. Revisit the default if luna high's logged fail rate exceeds ~10%.

### Quota ladder

luna and gpt-6.1-sol share one Codex quota, so hopping between them never escapes a quota-out.

- **Codex out** → Sonnet low builder + Haiku low review.
- **Claude out** → Codex-only: luna builds, gpt-6.1-sol reviews; the PR says "single-family review (Claude quota-out)".
- **Both out** → pause and report the exact error text.
- Claude Code's own `--fallback-model` only covers an overloaded or unavailable model (it retries the primary each turn); it does not see quota-outs across families, so this ladder stays in `new-session`.

`scripts/quota-check.sh` detects it: `classify` reads error text (pipe a hand-run `codex exec` through it), `codex-status` reads the latest Codex rollout `rate_limits`, `claude-status` reads recent transcript API errors. `new-session` runs both at spawn, fails over automatically (`CRSS_QUOTA_FAILOVER=0` disables) and logs the hop. Patterns come from the installed Codex CLI and real Claude transcripts; override them in `quota-patterns.txt` in the crss overlay (`$CRSS_HOME`, else `~/.config/crss`). A quota-out inside an already-running Codex TUI is not detected.

Review gate:

- Never review on one model family alone when a second is available; Haiku alone is advisory and does not count.
- Single-family review only in the Claude-out case above; record `models_ran`.

### Codex flags

- Builder trims: `-c skills.include_instructions=false --disable multi_agent -c project_doc_max_bytes=0` (input ~28k → ~14.5k tokens).
- Tool-less one-shots (stripped harness) may add `-c include_environment_context=false -c model_instructions_file=<file>` and disable the shell features: input ~14.7k → ~6.2k tokens, same accuracy. The host `AGENTS.md` in `$CODEX_HOME` cannot be dropped by any flag (Codex 0.163).
- Priority: keep it out of host config; opt in per call with `-c service_tier=priority`. ~31% faster on gpt-6.1-sol (5.15 s vs 7.43 s), no gain on luna; assumed 1.5x cost.

## Self-improving routing

- Log each delegated task: job type, model, effort, backend, tier, wall s, $, pass/fail, rework, escalation hops. `new-session` appends `--tier auto` picks and quota hops to `$CRSS_ROUTING_LOG` (default `~/.sessions/routing-log.jsonl`); `quota-check log key=value...` adds others.
- Measure, don't estimate: `python3 scripts/slice-usage.py <session.jsonl> --codex <exec.jsonl>` prints each slice's real tokens (main transcript, its subagents, `codex exec --json` logs) and the Claude slices' wall-clock span; Codex logs carry no timestamps or model name; price them with the bench's rates or the CLI's cost readout.
- Codex $ is a list-price proxy; log in the lane's `TASKS.md` or report `models_ran`.
- Revisit routing when a job type's pass rate drops, costs drift >2x, or a new model/CLI lands; rerun the bench first.
- Record routing decisions with the date.

## Steps

1. **Finish line first.** One checkable "done" atop `TASKS.md` (scratchpad or worktree, not committed); re-read after compaction.
2. **Packet** per slice: decided design, exact paths, constraints, tests to add, "open PR from `origin/main`, do not merge", applicable safety rules. Self-contained: the builder has none of your context.
3. **Fan out** independent slices only; ~3 concurrent subagents max. Subagents cannot nest.
4. **Verify claims.** Re-run the cited command or open the cited file:line before relaying "done" or "no issues". No evidence means unverified.
5. **Adversarial review.** Opus reviews each diff on its own packet (diff, claim, how to run it), not your transcript. Findings: file:line, why wrong, how to show it fails. Max 3 rounds; re-review only what changed.
6. **Land.** CI green + second-family review, then merge. Redeploy anything deployed (diff first; copies drift both ways). Restarting live infrastructure needs a runbook and rollback to the launcher first.
7. **Report:** what landed, what was redeployed, what is left, `models_ran`, numbered operator decisions each with a recommended option.

## Rules that keep it cheap and safe

- Drafting counts as building: briefs, dispositions, review packets and records go to a builder with a frozen packet. The orchestrator decides, verifies, posts.
- Fewer, better tests; a few real end-to-end checks; test count is not a metric.
- Ask the operator only for decisions that are theirs (irreversible, outward-facing, conflicting requirements), with a recommendation. Otherwise decide and report.
- Blocked sessions raise nothing on their own: `session-send` the launcher with the exact decision.
