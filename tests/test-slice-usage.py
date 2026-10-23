#!/usr/bin/env python3
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "scripts" / "slice-usage.py"


def write_jsonl(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")


def claude_message(message_id, model="claude-opus-5-5", usage=None, timestamp="2026-10-22T15:32:22.860Z"):
    return {
        "type": "assistant",
        "timestamp": timestamp,
        "message": {
            "id": message_id,
            "model": model,
            "usage": usage or {
                "input_tokens": 3,
                "cache_creation_input_tokens": 100,
                "cache_read_input_tokens": 5000,
                "output_tokens": 40,
            },
        },
    }


class SliceUsageTest(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.session = self.root / "session.jsonl"

    def tearDown(self):
        self.tempdir.cleanup()

    def run_tool(self, *args):
        return subprocess.run(
            [sys.executable, str(TOOL), str(self.session), *map(str, args)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
            text=True,
        )

    def json_rows(self, *args):
        return json.loads(self.run_tool(*args, "--json").stdout)

    def test_duplicate_message_ids_count_once(self):
        usage = {"input_tokens": 8, "cache_creation_input_tokens": 2, "cache_read_input_tokens": 4, "output_tokens": 1}
        write_jsonl(self.session, [claude_message("same", usage=usage), claude_message("same", usage=usage)])
        rows = self.json_rows()
        main = next(row for row in rows if row["slice"] == "orchestrator")
        self.assertEqual(main["calls"], 1)
        self.assertEqual(main["out"], 1)

    def test_subagent_files_are_reported_as_separate_slices(self):
        write_jsonl(self.session, [])
        agent = self.session.with_suffix("") / "subagents" / "agent-abc123.jsonl"
        write_jsonl(agent, [claude_message("agent-call")])
        rows = self.json_rows()
        self.assertIn("agent-abc123", {row["slice"] for row in rows})

    def test_models_in_one_slice_get_separate_rows(self):
        write_jsonl(self.session, [claude_message("one"), claude_message("two", model="claude-sonnet-5")])
        rows = [row for row in self.json_rows() if row["slice"] == "orchestrator"]
        self.assertEqual({row["model"] for row in rows}, {"claude-opus-5-5", "claude-sonnet-5"})

    def test_codex_turns_sum_with_cached_tokens_removed_from_uncached(self):
        codex = self.root / "exec.jsonl"
        write_jsonl(codex, [
            {"type": "turn.started", "payload": {"model": "gpt-test"}},
            {"type": "turn.completed", "usage": {"input_tokens": 100, "cached_input_tokens": 70, "output_tokens": 5}},
            {"type": "turn.completed", "usage": {"input_tokens": 40, "cached_input_tokens": 10, "output_tokens": 7}},
        ])
        row = next(row for row in self.json_rows("--codex", codex) if row["slice"] == "codex:exec")
        self.assertEqual((row["model"], row["calls"], row["uncached_in"], row["cache_read"], row["out"]),
                         ("gpt-test", 2, 60, 80, 12))

    def test_malformed_line_is_skipped(self):
        self.session.write_text("{bad json\n" + json.dumps(claude_message("ok")) + "\n", encoding="utf-8")
        row = next(row for row in self.json_rows() if row["slice"] == "orchestrator")
        self.assertEqual(row["calls"], 1)

    def test_json_output_totals_match_slice_rows(self):
        write_jsonl(self.session, [claude_message("one"), claude_message("two")])
        rows = self.json_rows()
        main = next(row for row in rows if row["slice"] == "orchestrator")
        total = next(row for row in rows if row["slice"] == "TOTAL")
        self.assertEqual(total["calls"], main["calls"])
        self.assertEqual(total["uncached_in"], main["uncached_in"])
        self.assertEqual(total["out"], main["out"])


if __name__ == "__main__":
    unittest.main()
