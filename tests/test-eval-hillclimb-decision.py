#!/usr/bin/env python3
import importlib.util
import json
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "scripts" / "eval-hillclimb-decision.py"


def load_tool():
    spec = importlib.util.spec_from_file_location("eval_hillclimb_decision", TOOL)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def case(**overrides):
    data = {
        "mode": "quality",
        "round_type": "normal",
        "baseline": {"quality": 0.80, "train_quality": 0.80, "cost": 100.0, "latency": 10.0},
        "candidate": {
            "train_quality": 0.84,
            "validation_quality": 0.835,
            "cost": 105.0,
            "latency": 10.5,
        },
        "noise": {"quality": 0.01},
        "min_effect": {"quality": 0.02, "cost_fraction": 0.05, "latency_fraction": 0.05},
        "parity_tolerance": {"quality": 0.005},
        "stalls": 0,
        "saturation_threshold": 0.95,
        "budget": {
            "campaign_calls_used": 20,
            "campaign_call_limit": 100,
            "round_calls_used": 1,
            "round_call_limit": 10,
            "novelty_fraction": 0.20,
            "novelty_calls_used": 3,
            "campaign_tokens_used": 20_000,
            "campaign_token_limit": 100_000,
            "round_tokens_used": 1_000,
            "round_token_limit": 10_000,
            "novelty_tokens_used": 3_000,
        },
    }
    for key, value in overrides.items():
        if isinstance(value, dict) and isinstance(data.get(key), dict):
            data[key] = {**data[key], **value}
        else:
            data[key] = value
    return data


class EvalHillclimbDecisionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tool = load_tool()

    def decide(self, payload):
        return self.tool.decide(payload)

    def assert_action(self, payload, action, reason):
        out = self.decide(payload)
        self.assertEqual(out["action"], action)
        self.assertIn(reason, out["reasons"])
        return out

    def test_keeps_validation_quality_improvement_above_noise_and_min_effect(self):
        self.assert_action(case(), "KEEP", "validation_quality_improved")

    def test_reverts_train_only_gain_when_validation_is_flat(self):
        payload = case(
            candidate={"train_quality": 0.87, "validation_quality": 0.805}
        )
        self.assert_action(payload, "REVERT", "train_only_gain")

    def test_reverts_validation_regression(self):
        payload = case(candidate={"validation_quality": 0.78})
        self.assert_action(payload, "REVERT", "validation_regressed")

    def test_reverts_improvement_below_noise_or_min_effect(self):
        payload = case(candidate={"train_quality": 0.82, "validation_quality": 0.812})
        self.assert_action(payload, "REVERT", "below_noise_or_min_effect")

    def test_reflects_after_repeated_stalls_before_spending_more_rounds(self):
        payload = case(candidate={"train_quality": 0.81, "validation_quality": 0.805}, stalls=2)
        self.assert_action(payload, "REFLECT", "stall_limit_reached")

    def test_quality_campaign_pivots_when_baseline_is_saturated(self):
        payload = case(baseline={"quality": 0.965})
        self.assert_action(payload, "COST_PIVOT", "quality_saturated")

    def test_cost_campaign_keeps_cost_drop_at_quality_parity(self):
        payload = case(
            mode="cost",
            candidate={"validation_quality": 0.797, "cost": 90.0, "latency": 9.9},
        )
        self.assert_action(payload, "KEEP", "cost_improved_at_quality_parity")

    def test_protects_configured_novelty_reserve_from_normal_rounds(self):
        payload = case(
            budget={"campaign_calls_used": 80, "campaign_call_limit": 100, "novelty_calls_used": 0}
        )
        self.assert_action(payload, "REFLECT", "novelty_calls_reserve_protected")

    def test_reflects_when_novelty_reserve_is_exhausted(self):
        payload = case(
            round_type="novelty",
            budget={"campaign_calls_used": 60, "campaign_call_limit": 100, "novelty_calls_used": 20},
        )
        self.assert_action(payload, "REFLECT", "novelty_calls_reserve_exhausted")

    def test_stops_on_exhausted_campaign_or_round_budget(self):
        self.assert_action(case(budget={"campaign_calls_used": 100}), "STOP_BUDGET", "campaign_budget_exhausted")
        self.assert_action(case(budget={"round_calls_used": 10}), "STOP_BUDGET", "round_budget_exhausted")
        self.assert_action(case(budget={"campaign_tokens_used": 100_000}), "STOP_BUDGET", "campaign_token_budget_exhausted")
        self.assert_action(case(budget={"round_tokens_used": 10_000}), "STOP_BUDGET", "round_token_budget_exhausted")

    def test_protects_token_novelty_reserve_too(self):
        payload = case(
            budget={
                "campaign_calls_used": 20,
                "novelty_calls_used": 20,
                "campaign_tokens_used": 80_000,
                "campaign_token_limit": 100_000,
                "novelty_tokens_used": 0,
            }
        )
        self.assert_action(payload, "REFLECT", "novelty_tokens_reserve_protected")

    def test_cli_accepts_json_and_prints_deterministic_action(self):
        proc = subprocess.run(
            [sys.executable, str(TOOL)],
            input=json.dumps(case()).encode(),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        self.assertEqual(json.loads(proc.stdout)["action"], "KEEP")


if __name__ == "__main__":
    unittest.main()
