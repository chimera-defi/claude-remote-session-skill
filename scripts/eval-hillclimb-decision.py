#!/usr/bin/env python3
"""Deterministic budget gate for generic eval/hillclimb campaigns.

Input is JSON on stdin or as a file argument. Output is JSON:
{"action": "KEEP|REVERT|REFLECT|STOP_BUDGET|COST_PIVOT", "reasons": [...]}.

This is intentionally not an evaluator. It only decides whether a candidate
round should advance, revert, pause for root-cause reflection, stop for budget,
or pivot from saturated quality search to cost/latency-at-parity.
"""

from __future__ import annotations

import argparse
import json
import sys
from typing import Any


Action = dict[str, Any]


def _num(data: dict[str, Any], key: str, default: float = 0.0) -> float:
    value = data.get(key, default)
    if value is None:
        return default
    return float(value)


def _budget_exhausted(budget: dict[str, Any]) -> list[str]:
    reasons: list[str] = []
    campaign_limit = _num(budget, "campaign_call_limit")
    campaign_used = _num(budget, "campaign_calls_used")
    round_limit = _num(budget, "round_call_limit")
    round_used = _num(budget, "round_calls_used")
    campaign_token_limit = _num(budget, "campaign_token_limit")
    campaign_tokens_used = _num(budget, "campaign_tokens_used")
    round_token_limit = _num(budget, "round_token_limit")
    round_tokens_used = _num(budget, "round_tokens_used")
    if campaign_limit > 0 and campaign_used >= campaign_limit:
        reasons.append("campaign_budget_exhausted")
    if round_limit > 0 and round_used >= round_limit:
        reasons.append("round_budget_exhausted")
    if campaign_token_limit > 0 and campaign_tokens_used >= campaign_token_limit:
        reasons.append("campaign_token_budget_exhausted")
    if round_token_limit > 0 and round_tokens_used >= round_token_limit:
        reasons.append("round_token_budget_exhausted")
    return reasons


def _novelty_guard(payload: dict[str, Any], budget: dict[str, Any]) -> str | None:
    fraction = _num(budget, "novelty_fraction", 0.20)
    round_type = payload.get("round_type", "normal")
    dimensions = (
        ("calls", "campaign_call_limit", "campaign_calls_used", "novelty_calls_used"),
        ("tokens", "campaign_token_limit", "campaign_tokens_used", "novelty_tokens_used"),
    )
    for label, limit_key, used_key, novelty_used_key in dimensions:
        limit = _num(budget, limit_key)
        if limit <= 0:
            continue
        reserve = max(0.0, limit * fraction)
        novelty_used = _num(budget, novelty_used_key)
        campaign_used = _num(budget, used_key)
        remaining_total = max(0.0, limit - campaign_used)
        remaining_novelty = max(0.0, reserve - novelty_used)
        if round_type == "novelty":
            if remaining_novelty <= 0:
                return f"novelty_{label}_reserve_exhausted"
            continue
        if remaining_novelty > 0 and remaining_total <= remaining_novelty:
            return f"novelty_{label}_reserve_protected"
    return None

def _improved_fraction(baseline: float, candidate: float) -> float:
    if baseline <= 0:
        return 0.0
    return (baseline - candidate) / baseline


def decide(payload: dict[str, Any]) -> Action:
    mode = payload.get("mode", "quality")
    baseline = payload.get("baseline", {})
    candidate = payload.get("candidate", {})
    noise = payload.get("noise", {})
    min_effect = payload.get("min_effect", {})
    parity = payload.get("parity_tolerance", {})
    budget = payload.get("budget", {})

    budget_reasons = _budget_exhausted(budget)
    if budget_reasons:
        return {"action": "STOP_BUDGET", "reasons": budget_reasons}

    baseline_quality = _num(baseline, "quality")
    validation_quality = _num(candidate, "validation_quality")
    baseline_train_quality = _num(baseline, "train_quality", baseline_quality)
    train_quality = _num(candidate, "train_quality", validation_quality)
    quality_delta = validation_quality - baseline_quality
    train_delta = train_quality - baseline_train_quality
    quality_threshold = max(_num(noise, "quality"), _num(min_effect, "quality"))
    parity_tolerance = _num(parity, "quality")
    stalls = int(payload.get("stalls", 0) or 0)

    if (
        mode == "quality"
        and baseline_quality >= _num(payload, "saturation_threshold", 0.95)
    ):
        return {"action": "COST_PIVOT", "reasons": ["quality_saturated"]}

    novelty_reason = _novelty_guard(payload, budget)
    if novelty_reason:
        return {"action": "REFLECT", "reasons": [novelty_reason]}

    if mode == "cost":
        quality_loss = baseline_quality - validation_quality
        cost_gain = _improved_fraction(_num(baseline, "cost"), _num(candidate, "cost"))
        latency_gain = _improved_fraction(
            _num(baseline, "latency"), _num(candidate, "latency")
        )
        cost_threshold = _num(min_effect, "cost_fraction", 0.05)
        latency_threshold = _num(min_effect, "latency_fraction", 0.05)
        if quality_loss <= parity_tolerance and (
            cost_gain >= cost_threshold or latency_gain >= latency_threshold
        ):
            return {"action": "KEEP", "reasons": ["cost_improved_at_quality_parity"]}
        if quality_loss > parity_tolerance:
            return {"action": "REVERT", "reasons": ["quality_parity_broken"]}
        if stalls >= 2:
            return {"action": "REFLECT", "reasons": ["stall_limit_reached"]}
        return {"action": "REVERT", "reasons": ["cost_latency_flat"]}

    if quality_delta < -quality_threshold:
        return {"action": "REVERT", "reasons": ["validation_regressed"]}
    if train_delta >= quality_threshold and quality_delta < quality_threshold:
        if stalls >= 2:
            return {"action": "REFLECT", "reasons": ["stall_limit_reached"]}
        return {"action": "REVERT", "reasons": ["train_only_gain"]}
    if quality_delta >= quality_threshold:
        return {"action": "KEEP", "reasons": ["validation_quality_improved"]}
    if stalls >= 2:
        return {"action": "REFLECT", "reasons": ["stall_limit_reached"]}
    return {"action": "REVERT", "reasons": ["below_noise_or_min_effect"]}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("json_file", nargs="?", help="JSON payload file; stdin if omitted")
    args = parser.parse_args(argv)

    if args.json_file:
        with open(args.json_file, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    else:
        payload = json.load(sys.stdin)

    print(json.dumps(decide(payload), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
