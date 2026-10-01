# Eval and hillclimb protocol

For model, prompt, harness or agent-loop improvement campaigns: keep creative discovery while
making repeated eval/model/poll loops prove they are worth their cost.

## Campaign preflight

- Define the Pareto objective before the first candidate: quality, token/call cost, and
  latency. Quality wins must exceed measured noise and a declared minimum effect; cost
  campaigns must keep quality inside a declared parity tolerance.
- Build evals from production-derived cases. Prefer deterministic/programmatic graders.
  Grade outcomes and required invariants rather than one prescribed tool path unless the
  path itself is a requirement; valid creative solutions should still pass. Use an LLM
  judge only for open-ended outputs; keep it separate from the model under test, blinded,
  and backed by checkable claims.
- Prove grader plumbing before hillclimbing: repeatability, run-to-run noise, headroom,
  and stronger-model/effort monotonicity where applicable. For stochastic runs, replicate
  per case and aggregate within the case before campaign-level comparisons; do not treat
  repeated samples of one case as independent evidence.
- If the baseline is already saturated, about 95% or higher, refuse a quality hillclimb.
  Pivot to cost/latency-at-quality-parity instead.
- Set explicit campaign and per-round token/call budgets. Reserve a configurable minority
  for novelty rounds; default to 20%.

## Splits and leakage

- Keep three splits. `SEARCH`/`TRAIN` failures may be inspected. `GATE`/`VALIDATION`
  exposes aggregate scores only for candidate decisions. `FINAL HOLDOUT` stays untouched
  until the campaign ends.
- Never paste failure examples, hidden answers, or holdout details into prompts,
  harnesses, retros, or candidate diffs. Root-cause labels are allowed; examples are not.
- Cache and dedupe stable context. Candidate prompts should be diff-only whenever possible.
  Put large traces in files and cite paths, not inline dumps.

## Round shape

1. Run cheap static/programmatic checks.
2. Run a small train smoke. Novelty candidates are allowed to reach this smoke before
   normal gates reject them.
3. Run full train only if the smoke is plausible.
4. Run validation only for promising candidates.
5. Re-run or replicate borderline results near the measured noise threshold.
6. Touch final holdout only once, at campaign end.

Normal rounds make one attributable local change. Revert validation regressions, train-only
gains, and gains below noise/min-effect. After two to three stalls, stop editing and bucket
remaining failures, evaluator bugs, ambiguity, or data gaps before spending another round.

Novelty rounds may propose non-local changes, but they obey the same leakage, budget, and
final-holdout rules. Do not let normal gates consume the novelty reserve.

## Model and polling discipline

- Scarce reviewers and high-cost models are sampled/final-gate resources, not every-round
  defaults. Let deterministic grading and cheaper builders carry the loop.
- Do not repeatedly poll, nudge, or re-evaluate when no state changed. On 429 or quota
  responses, use bounded exponential backoff, then stand down.

## Machine gate

Use `scripts/eval-hillclimb-decision.py` as the stdlib decision gate for candidate
accept/revert/reflect/stop/pivot decisions. It reads JSON from stdin or a file and emits:
`KEEP`, `REVERT`, `REFLECT`, `STOP_BUDGET`, or `COST_PIVOT`.

Minimal shape:

```json
{
  "mode": "quality",
  "round_type": "normal",
  "baseline": {"quality": 0.80, "cost": 100, "latency": 10},
  "candidate": {"train_quality": 0.84, "validation_quality": 0.835, "cost": 105, "latency": 10.5},
  "noise": {"quality": 0.01},
  "min_effect": {"quality": 0.02, "cost_fraction": 0.05, "latency_fraction": 0.05},
  "parity_tolerance": {"quality": 0.005},
  "stalls": 0,
  "budget": {
    "campaign_calls_used": 20,
    "campaign_call_limit": 100,
    "round_calls_used": 1,
    "round_call_limit": 10,
    "novelty_fraction": 0.20,
    "novelty_calls_used": 3,
    "campaign_tokens_used": 20000,
    "campaign_token_limit": 100000,
    "round_tokens_used": 1000,
    "round_token_limit": 10000,
    "novelty_tokens_used": 3000
  }
}
```

Generic by design: it does not grade outputs, inspect examples, call models, or know any
domain evaluator. Pinned by `tests/test-eval-hillclimb-decision.py`.

## Grounding

Adapts the 2026-09-28 Claude.dev guidance on automated eval design and hillclimbing and
Anthropic's agent-eval guidance (outcome-based grading, tracking tokens/latency), adding a
separate aggregate-only validation gate, untouched final holdout, novelty reserve and explicit
token/call budgets for long multi-agent campaigns.
