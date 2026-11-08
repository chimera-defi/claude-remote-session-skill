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

## Decision gate

Decide each candidate round with these rules, applied in order. They are deterministic, so
apply them to the numbers rather than to a feeling about the result. (A stdlib script,
`scripts/eval-hillclimb-decision.py`, and its test implemented them until the 2026 crss rewrite
removed them from this repo; they remain in git history before that commit.) The outcomes are
`KEEP`, `REVERT`, `REFLECT`, `STOP_BUDGET` and `COST_PIVOT`.

Inputs: `mode` (`quality` or `cost`), `round_type` (`normal` or `novelty`), baseline and candidate
`quality` (candidate `train_quality` and `validation_quality`), `cost`, `latency`; `noise.quality`;
`min_effect` (`quality`, `cost_fraction` and `latency_fraction`, both default 0.05);
`parity_tolerance.quality`; `stalls`; and the budget: campaign and round call and token limits
with the amounts used, `novelty_fraction` (default 0.20) and novelty calls and tokens used.

1. **STOP_BUDGET** if any campaign or round call or token limit is reached (a limit of 0 means
   unset).
2. **COST_PIVOT** if `mode` is `quality` and baseline quality is at or above the saturation
   threshold (default 0.95): refuse the quality hillclimb and optimise cost or latency at parity.
3. **REFLECT** on a novelty-budget breach. A novelty round with no novelty reserve left is
   refused; a normal round that would eat into the novelty reserve (remaining total budget is no
   more than the remaining reserve) is refused too.
4. In `cost` mode: **KEEP** if validation quality loss is within the parity tolerance and cost or
   latency improved by at least its minimum fraction; **REVERT** if the loss exceeds the
   tolerance; otherwise **REFLECT** after 2 stalls, else **REVERT** (flat).
5. In `quality` mode, with `threshold = max(noise, min_effect)` on quality: **REVERT** if the
   validation delta is below `-threshold`; if the train delta reaches the threshold but the
   validation delta does not, **REFLECT** after 2 stalls, else **REVERT** (train-only gain);
   **KEEP** if the validation delta reaches the threshold; otherwise **REFLECT** after 2 stalls,
   else **REVERT** (below noise).

The gate does not grade outputs, inspect examples, call models, or know any domain evaluator.

## Grounding

Adapts the 2026-09-28 Claude.dev guidance on automated eval design and hillclimbing and
Anthropic's agent-eval guidance (outcome-based grading, tracking tokens/latency), adding a
separate aggregate-only validation gate, untouched final holdout, novelty reserve and explicit
token/call budgets for long multi-agent campaigns.
