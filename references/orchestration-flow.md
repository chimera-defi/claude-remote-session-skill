# Orchestration flow: Opus orchestrates, gpt-6.1-terra builds, Haiku checks, Opus/Fable attack

Link this flow in non-trivial multi-file/multi-step kickoff briefs. Host pins/quota policy:
host overlay and `~/.claude/CLAUDE.md`.

## Roles

| Job | Model + effort | Backend | Evidence |
|---|---|---|---|
| Orchestrator | Opus (pinned id, `crss spawn --model claude-opus-5-5 -- --effort medium`), effort medium; high at risky forks | Claude | blind check: medium 8.3 vs high 8.0, $0.10 vs $0.17 a plan |
| Builder (default) | gpt-6.1-terra low, fast mode (priority tier, default 2026-11-02), [trim flags](#codex-flags); any bounded, well-specified task | Codex `codex exec -m gpt-6.1-terra -c model_reasoning_effort=low -c service_tier=priority`, stdin closed | sol61-high routing bench 2026-10-23: 60/60 functions, 15/15 L7, 35/35 hard set, 12/12 agentic; $0.0186/pass list price, 27 s median (agentic ~110 s). luna high 31/35 on the hard set |
| Builder repair (fallback) | Light check: task tests (or statement examples); on failure, Haiku low reads statement + code, returns corrected code; re-run check | Claude `claude -p --model haiku --effort low --tools ""` with repair prompt; `haiku-reviewer` only reports | hard set: sol61-high/astra-medium 35/35, 0 repairs, $0 Claude; their repair quality UNMEASURED. luna high → Haiku low 32/35: examples missed 3/35 bad answers (REPORT:444). Use real tests. |
| Builder escalation | gpt-6-astra medium after a failed Haiku repair, or first when latency matters ([ladder](#escalation-ladder)) | Codex `codex exec -m gpt-6-astra -c model_reasoning_effort=medium` | routing bench: perfect on every set like sol61-high, ~25% faster (21 s function median, agentic ~85 s), ~4× the list price ($0.075/pass; quota use assumed to track list price, unverified) |
| Builder fallback | Sonnet 5.5 low, `subagent_type: builder` ([`agents/builder.md`](../agents/builder.md)) | Claude | C: 7/7, 17–29 s, $0.09; when Codex cannot run the task |
| Review | Haiku low, `subagent_type: haiku-reviewer` (read-only; [`agents/haiku-reviewer.md`](../agents/haiku-reviewer.md)) | Claude | ~10 s, ~$0.0013/review; 10-22 artifact only: advisory, no real bug found; review quality UNMEASURED in dispatchbench. |
| Research / workers | gpt-6.1-sol low (medium: large/ambiguous), host relay or `codex exec`; read-only findings to orchestrator | Codex / ChatGPT | host staffing policy; UNMEASURED (dispatchbench lacks scans/reviews). Codex-out fallback: `subagent_type: builder`. |
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

Model bench 2026-10-22 ([private report](https://claude.ai/artifact/E9zfBpSipyg7kS1aP9Luhm)); follow-up:
private `dispatchbench` (formerly `model-routing-bench`). IDs/flags are bench-time; host overlay may override.

- Small coding tasks: 18 configs, 198 runs, all passed; higher effort changed neither correctness nor speed on these ceiling tasks.
- Tools off: Haiku 5.5 low led at 4.54 s, $0.0003.
- Agentic task: 5-file change + tests, 7 hidden tests, two rounds each; A/B included Haiku review, C ran alone.
- Haiku flagged only spec-undefined inputs: a cheap advisory pass, not a merge gate.
- Harder problems (luna's 7 worst, n=35 each, post hoc): luna low/medium average 0–7 reasoning tokens a call and pass 21/35; prompt nudges and harness trims do not change that. luna high (stripped) 31/35, Haiku low 32/35, Haiku medium 35/35 ($0.00192/pass, ~15 s), Sonnet medium 35/35 at ~10× the cost; luna high with gated Haiku low repair 32/35 at $0.00135.
- Tools-off headline ([private report](https://claude.ai/artifact/8SHR12aRZ3aWqaZ1ixcFho)): haiku-medium alone
  59/60 overall, 0 hard-set misses; matches luna → Haiku review-every-answer (35/35) at ~half
  cost, beats gated repair (32/35). Codex remains default: its list-price $ proxies a separate
  subscription; Haiku spends Claude quota shared with Opus/Fable. Codex-out:
  [quota ladder](#quota-ladder), low first then `claude -p --model haiku --effort high --tools ""`
  on failed checks/costly misses.
- Above-high effort (2026-10-23, hard set): sol61-xhigh = high at 35/35 and lint/complexity/runtime;
  xhigh uses 1.5x output tokens, 44 s median, ~1.5x $. Passing-code quality (Appendix C):
  sol61-high matches Codex flagships on lint (0.03 warnings/solution) and complexity;
  ~28% faster than reference, never worse growth. Blind Fable read: 20 solutions, 7.25/10,
  no blocks (all 3 blocks were sonnet-medium); no high/xhigh code-quality deficit observed.
- Trusted Codex builders (2026-10-23, same report): gpt-6.1-sol high and gpt-6-astra medium never failed on any set (function 60/60, L7 15/15, hard 35/35, agentic 12/12). sol61-high was the default until 2026-11-02 (now terra61-low, escalation sol61-high): about a quarter of astra's list price, at the cost of time.
- Claude parity (2026-10-24, same report; exploratory after main results): haiku-high
  function 60/60, L7 15/15, hard 35/35, agentic 12/12; L1–L6 $0.0028/pass, ~4x cheaper
  than sonnet-medium. Median 14.7 s vs sonnet-medium 10.1 s; long tail p90 38 s.
  haiku-medium missed 1/60 and 2/15 L7: Codex-out failed-check/costly-miss fallback is high.
  Codex configs spend $0 Claude/pass; $0.0179 for sol61-medium was Codex list price
  misfiled as Claude spend. sol61-medium missed 2/60; untrusted for builds.
- One lane (2026-10-22, website copy + this tool; host-module `slice-usage`, one CLI cost
  probe/model, ±30%): Haiku research + two luna high builds $0.03 vs ~$1.55 for those
  tokens on Opus. Opus orchestrator: $7.45, 10M cache-read tokens, 79 calls; three Fable
  reviews: $6.05, ~3x Opus/token. Remaining savings: fewer orchestrator turns, one tight
  Fable packet/change, interim Haiku checks. Host tools: `$CRSS_HOME/local.md`.

## Escalation ladder

Default: gpt-6.1-terra low.
2026-11-02: dispatchbench f77c040 found terra61-low fast had equal pass rate, ~3x lower cost and 2.5–3x faster; sol61-high remains the escalation for uncovered work, including L7 hard problems p13–p15, which terra was not run on.
To switch the default, change the `-m` and `model_reasoning_effort` flags in the `codex exec` line
you give builders (for example `-m gpt-6-astra -c model_reasoning_effort=medium`).
Codex-first preserves Claude quota; repairs/reviews spend it.

terra61-low → light check (tests/examples) → Haiku low repair on failure → astra-medium → Sonnet builder.

- Hop on a failed check or Haiku review, or when the task needs judgement, ambiguity resolution or architecture.
- Log every hop (see [Self-improving routing](#self-improving-routing)) so the table self-corrects.
- Don't build with luna (any effort) or sol61 medium: luna low/medium barely reason and failed 40% of the hard set; luna high and sol61 medium miss without a gate. Revisit the default if terra61-low's logged fail rate exceeds ~5% (then fall back to sol61-high).

### Quota ladder

luna and gpt-6.1-sol share one Codex quota (one `limit_id: "codex"`); astra is assumed to share it too (no astra rollout checked), so hopping between Codex models never escapes a quota-out.

- **Codex out** (only on the exact quota error text) → one-shot builds go to Haiku low (`claude -p --model haiku --effort low --tools ""`), same light check; a failed check, or a task where a miss is costly, goes to Haiku high. A whole lane becomes a Sonnet low builder (`crss spawn NAME DIR --model sonnet -- --effort low`). Return to terra61-low when Codex resets.
- **Claude out** → Codex-only: terra61-low builds, gpt-6.1-sol reviews; the PR says "single-family review (Claude quota-out)".
- **Both out** → pause and report the exact error text.
- `--fallback-model` cannot detect cross-family quota-outs, and nothing in crss does: the
  orchestrator walks this ladder by hand. Call a tool "out" only on the exact quota error text
  (a failed `codex exec`, or an API error in the Claude transcript), and quote it in the report.
  A Codex TUI session that quota-outs is not detected by anything.
  Availability and retry semantics: [spawn guide](spawn-guide.md#choosing-the-model).

Review: require a second model family when available; Haiku alone is advisory.
Claude-out permits single-family review with `models_ran`.

### Codex flags

- Builder trims: `-c skills.include_instructions=false --disable multi_agent -c project_doc_max_bytes=0` (input ~28k → ~14.5k tokens).
- Tool-less one-shots (stripped harness) may add `-c include_environment_context=false -c model_instructions_file=<file>` and disable the shell features: input ~14.7k → ~6.2k tokens, same accuracy. The host `AGENTS.md` in `$CODEX_HOME` cannot be dropped by any flag (Codex 0.163).
- Commits from a sandboxed builder in a linked worktree: `workspace-write` makes `.git` read-only, so `git commit` fails with `index.lock': Read-only file system` (PR 218 case study, 2026-10-28; reproduced on codex-cli 0.164). Add the worktree's gitdir plus the common `objects`, `refs` and `logs` directories (from `git rev-parse --path-format=absolute --git-dir --git-common-dir`) as writable roots of `codex exec -s workspace-write -C "$dir"`, one `--add-dir <DIR>` each (codex-cli `exec --help`). Adding the `.git` dir itself does not work. Agent Host MCP workers keep the common dir read-only on purpose (the server commits), so they need no flag.
- Priority (fast mode): on by default since 2026-10-30 (operator: benchmarks showed the standard tier was too slow; it was on 10-23 to 10-28, then off 10-28 to 10-30). Set in `~/.codex/config.toml` (`service_tier = "priority"`, so interactive Codex gets it too) and passed explicitly as `-c service_tier=priority` in builder commands, so builds keep it on hosts or benches without that config. Claude fast mode stays off except a deadline push the operator asks for. Hard set, run side by side: sol61-high fast 35/35 at 18.9 s median vs 30.1 s default (37% faster), same output size and code quality; about 2x the list price (published multiplier). No gain on luna.

## Self-improving routing

- Log each delegated task: job type, model, effort, backend, wall s, $, pass/fail, rework, escalation hops. Nothing logs this automatically any more; keep it in the lane's `TASKS.md` or report (`models_ran`).
- Measure with the host's `slice-usage <session.jsonl> --codex <exec.jsonl>` if the host has it
  (`$CRSS_HOME/local.md`): main/subagent/`codex exec --json` tokens and Claude wall-clock span.
  Codex logs lack timestamps/model; price with bench rates or CLI cost readout.
- Codex $ is a list-price proxy; report it with `models_ran`.
- Revisit routing when a job type's pass rate drops, costs drift >2x, or a new model/CLI lands; rerun the bench first.
- Record routing decisions with the date.

## Steps

1. **Finish line first.** One checkable "done" atop `TASKS.md` (scratchpad or worktree, not committed); re-read after compaction.
2. **Packet:** decided design, exact paths, constraints, tests, "open PR from `origin/main`, do not merge", safety rules; self-contained (builder has no context).
3. **Fan out** independent slices only; ~3 concurrent subagents max. Subagents cannot nest.
4. **Verify:** re-run cited commands or open file:line before relaying "done"/"no issues"; otherwise unverified.
5. **Adversarial review:** Opus gets diff/claim/run instructions, not transcript. Findings: file:line, why wrong, failing scenario. Max 3 rounds; re-review changes only.
6. **Land:** CI green + second-family review, merge, diff/redeploy deployed copies (drift both ways). Before live infrastructure restarts, send launcher runbook/rollback.
7. **Report:** what landed, what was redeployed, what is left, `models_ran`, numbered operator decisions each with a recommended option.

## Rules that keep it cheap and safe

- Builders draft briefs/dispositions/review packets/records from frozen packets; orchestrator decides/verifies/posts.
- Prefer a few real end-to-end checks; test count is no metric.
- Ask with a recommendation only for operator decisions (irreversible, outward-facing, conflicting requirements); otherwise decide/report.
- Blocked-session channel: [spawn guide](spawn-guide.md#writing-the-kickoff), `crss send <launcher> --file F` with the exact decision (or the host's channel when the launcher is not a crss session).
