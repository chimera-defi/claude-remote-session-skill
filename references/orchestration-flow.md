# Orchestration flow: Opus orchestrates, gpt-6.1-sol builds, Haiku checks, Opus/Fable attack

Default shape for any non-trivial multi-file or multi-step lane; link it in the kickoff brief.
Host model pins and quota rules live in the host overlay and `~/.claude/CLAUDE.md`.

## Roles

| Job | Model + effort | Backend | Evidence |
|---|---|---|---|
| Orchestrator | Opus (pinned id), effort medium; high at risky forks | Claude | blind check: medium 8.3 vs high 8.0, $0.10 vs $0.17 a plan |
| Builder (default) | gpt-6.1-sol high, fast mode (priority tier), [trim flags](#codex-flags); any bounded, well-specified task | Codex `codex exec -m gpt-6.1-sol -c model_reasoning_effort=high -c service_tier=priority`, or `new-session --backend codex` (`--tier auto --task-type build` sets it) | routing bench 2026-10-23: 60/60 functions, 15/15 L7, 35/35 hard set, 12/12 agentic; $0.0186/pass list price, 27 s median (agentic ~110 s). luna high 31/35 on the hard set |
| Builder repair (fallback) | The light check: run the task's tests (or the statement's examples) first; only if they fail, Haiku low reads the statement + the builder's code and returns corrected code, then re-run the check. Not a Haiku review of every answer | Claude `claude -p --model haiku --effort low --tools ""` with a repair prompt (not `haiku-reviewer`, which only reports) | hard set: sol61-high and astra-medium with this gate both 35/35 with 0 repairs (so $0 Claude); a weaker builder leans on it (luna high → Haiku low 32/35, the examples gate missed 3 bad answers) |
| Builder escalation | gpt-6-astra medium after a failed Haiku repair, or first when latency matters ([ladder](#escalation-ladder)) | Codex `codex exec -m gpt-6-astra -c model_reasoning_effort=medium` | routing bench: perfect on every set like sol61-high, ~25% faster (21 s function median, agentic ~85 s), ~4× the list price ($0.075/pass; quota use assumed to track list price, unverified) |
| Builder fallback | Sonnet 5.5 low, `subagent_type: builder` ([`agents/builder.md`](../agents/builder.md)) | Claude | C: 7/7, 17–29 s, $0.09; when Codex cannot run the task |
| Review | Haiku low, `subagent_type: haiku-reviewer` (read-only; [`agents/haiku-reviewer.md`](../agents/haiku-reviewer.md)) | Claude | ~10 s, ~$0.0013/review; advisory, no real bug found |
| Research / workers | gpt-6.1-sol low (medium for large or ambiguous), via the host relay or `codex exec`; read-only, written findings back to the orchestrator | Codex / ChatGPT | host staffing ruling, not benched here; Claude fallback `subagent_type: builder` when Codex is out; `new-session --tier auto --task-type research` is a Sonnet lane owner, not this row |
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
- Harder problems (luna's 7 worst, n=35 each, post hoc): luna low/medium average 0–7 reasoning tokens a call and pass 21/35; prompt nudges and harness trims do not change that. luna high (stripped) 31/35, Haiku low 32/35, Haiku medium 35/35 ($0.00192/pass, ~15 s), Sonnet medium 35/35 at ~10× the cost; luna high with gated Haiku low repair 32/35 at $0.00135.
- Corrected headline ([private report](https://claude.ai/artifact/8SHR12aRZ3aWqaZ1ixcFho)): on these tools-off function problems haiku-medium alone is the pick (59/60 overall, 0 misses on the hard set), matching the best luna → Haiku pipeline (review every answer, 35/35) at about half its cost and beating the gated one (32/35) on accuracy. A Codex builder stays the default because Codex $ is a list-price proxy for a separate subscription quota (moving builds to Haiku spends the Claude quota Opus and Fable share); the next bullet replaces luna high with sol61-high. When Codex is out, Haiku builds per the [quota ladder](#quota-ladder): low first, Haiku medium (`claude -p --model haiku --effort medium --tools ""`) on a failed check or a costly miss.
- Effort above high does not help (2026-10-23, hard set): sol61-xhigh 35/35 like high, but 1.5x the output tokens, 44 s median and ~1.5x the $, with the same lint, complexity and runtime as high. Code quality (passing solutions; bench report Appendix C): sol61-high is level with the other Codex flagships on lint (0.03 warnings per solution) and complexity, its solutions run ~28% faster than the reference and never grow worse than it, and a blind Fable read of 20 solutions scored it 7.25/10 with no blocks (all 3 blocks were sonnet-medium). No sign it writes bad code at high or xhigh.
- Trusted Codex builders (2026-10-23, same report): gpt-6.1-sol high and gpt-6-astra medium never failed on any set (function 60/60, L7 15/15, hard 35/35, agentic 12/12). sol61-high is the default: about a quarter of astra's list price, at the cost of time. Claude $ per pass is $0 for any Codex config (billed to the Codex subscription); the old $0.0179 next to sol61-medium was a Codex list-price figure in the wrong column. sol61-medium missed 2/60, so medium is not a trusted builder.
- Measured on one real lane (2026-10-22, website copy + this tool; `scripts/slice-usage.py`, $ from a one-call CLI cost probe per model, so read it as ±30%). Haiku research and two luna high builds cost $0.03 in all; the same tokens on Opus would have cost ~$1.55. But the bill was the Opus orchestrator ($7.45, 10M cache-read tokens over 79 calls) and three Fable reviews ($6.05; Fable is about 3x Opus per token on the probe). Cheap builders are a solved saving. The levers left are fewer orchestrator turns and one Fable gate per change on a tight packet, with interim checks on Haiku.

## Escalation ladder

Default builder: gpt-6.1-sol high (2026-10-23, replacing luna high; the operator proposed astra medium, and sol61-high was picked for the same pass rate at about a quarter of the list price; `CRSS_CODEX_BUILDER_MODEL=gpt-6-astra CRSS_CODEX_BUILDER_EFFORT=medium` switches). Codex first spends that subscription first; only a trusted builder saves money, because every repair or review spends Claude quota.

sol61-high → light check (tests/examples) → Haiku low repair on failure → astra-medium → Sonnet builder.

- Hop on a failed check or Haiku review, or when the task needs judgement, ambiguity resolution or architecture.
- Log every hop in the [routing log](#self-improving-routing) so the table self-corrects.
- Don't build with luna (any effort) or sol61 medium: luna low/medium barely reason and failed 40% of the hard set; luna high and sol61 medium miss without a gate. Revisit the default if sol61-high's logged fail rate exceeds ~5%.

### Quota ladder

luna and gpt-6.1-sol share one Codex quota (one `limit_id: "codex"`); astra is assumed to share it too (no astra rollout checked), so hopping between Codex models never escapes a quota-out.

- **Codex out** (only on the exact quota error text) → one-shot builds go to Haiku low (`claude -p --model haiku --effort low --tools ""`), same light check; a failed check, or a task where a miss is costly, goes to Haiku medium. A whole lane (`new-session` failover) becomes a Sonnet low builder. Return to sol61-high when Codex resets.
- **Claude out** → Codex-only: sol61-high builds, gpt-6.1-sol reviews; the PR says "single-family review (Claude quota-out)".
- **Both out** → pause and report the exact error text.
- Claude Code's own `--fallback-model` only covers an overloaded or unavailable model (it retries the primary each turn); it does not see quota-outs across families, so this ladder stays in `new-session`.

`scripts/quota-check.sh` detects it: `classify` reads error text (pipe a hand-run `codex exec` through it), `codex-status` reads the latest Codex rollout `rate_limits`, `claude-status` reads recent transcript API errors. `new-session` runs both at spawn, fails over automatically (`CRSS_QUOTA_FAILOVER=0` disables) and logs the hop. Patterns come from the installed Codex CLI and real Claude transcripts; override them in `quota-patterns.txt` in the crss overlay (`$CRSS_HOME`, else `~/.config/crss`). A quota-out inside an already-running Codex TUI is not detected.

Review gate:

- Never review on one model family alone when a second is available; Haiku alone is advisory and does not count.
- Single-family review only in the Claude-out case above; record `models_ran`.

### Codex flags

- Builder trims: `-c skills.include_instructions=false --disable multi_agent -c project_doc_max_bytes=0` (input ~28k → ~14.5k tokens).
- Tool-less one-shots (stripped harness) may add `-c include_environment_context=false -c model_instructions_file=<file>` and disable the shell features: input ~14.7k → ~6.2k tokens, same accuracy. The host `AGENTS.md` in `$CODEX_HOME` cannot be dropped by any flag (Codex 0.163).
- Priority (fast mode): on by default for builders and fan-outs since 2026-10-23 (operator: affordable), via `-c service_tier=priority` in the recipe and `CRSS_CODEX_BUILDER_TIER` (default `priority`) for `--task-type build` lanes; still out of `~/.codex/config.toml`, so interactive Codex keeps the default tier. Hard set, run side by side: sol61-high fast 35/35 at 18.9 s median vs 30.1 s default (37% faster), same output size and code quality; about 2x the list price (published multiplier). No gain on luna.

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
