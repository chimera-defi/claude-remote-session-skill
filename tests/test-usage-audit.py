#!/usr/bin/env python3
"""Exercise the audit with synthetic data only; never read live transcripts."""
import copy
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path


TOOL = Path(__file__).resolve().parents[1] / "scripts" / "usage-audit.py"
PRIVATE = "PRIVATE_FIXTURE_MARKER"


class UsageAuditTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.root = self.home / "projects" / PRIVATE
        self.now = datetime.now(timezone.utc)
        self.env = os.environ.copy()
        self.env.update(HOME=str(self.home), CLAUDE_CONFIG_DIR=str(self.home / "config"))
        for name in ("AUDIT_ONLY_SESSION", "AUDIT_EXCLUDE_SESSION", "CLAUDE_SESSION_ID"):
            self.env.pop(name, None)
        main = self.assistant("main-call", "main", "claude-opus-5-5", 10, 100, 20, 10, 4)
        main["message"]["content"] = [
            {"type": "tool_use", "id": "bash-id", "name": "Bash", "input": {"command": PRIVATE}},
            {"type": "tool_use", "id": "read-id", "name": "Read", "input": {"file_path": PRIVATE}},
        ]
        partial = copy.deepcopy(main)
        partial["message"]["usage"]["output_tokens"] = 1
        second = self.assistant("second", "main", "claude-fable-5", 20, 80, 8, 0, 2)
        second["message"]["usage"].pop("cache_creation")  # Legacy writes use 5m weight.
        self.write("main.jsonl", [
            self.user("main", PRIVATE), partial, main,
            self.user("main", [{"type": "tool_result", "tool_use_id": "bash-id", "content": "x" * 400}]),
            self.user("main", [{"type": "tool_result", "tool_use_id": "bash-id", "content": "x" * 400}]),
            self.user("main", [{"type": "tool_result", "tool_use_id": "read-id", "content": "x" * 200}]),
            second,
            self.assistant("fake", "main", "<synthetic>", 999999, 0, 0, 0, 0),
        ])
        self.write("main/subagents/agent-fixture.jsonl", [
            self.assistant("sub-call", "main", "claude-sonnet-5-5", 5, 200, 0, 10, 3),
        ])

    def assistant(self, mid, sid, model, inp, read, w5, w1, out, age=1):
        return {"type": "assistant", "sessionId": sid, "cwd": str(self.root),
                "entrypoint": PRIVATE, "timestamp": (self.now - timedelta(days=age)).isoformat(),
                "message": {"id": mid, "model": model, "content": [{"type": "text", "text": PRIVATE}],
                            "usage": {"input_tokens": inp, "cache_read_input_tokens": read,
                                      "cache_creation_input_tokens": w5 + w1, "output_tokens": out,
                                      "cache_creation": {"ephemeral_5m_input_tokens": w5,
                                                         "ephemeral_1h_input_tokens": w1}}}}

    def user(self, sid, content):
        return {"type": "user", "sessionId": sid,
                "timestamp": (self.now - timedelta(days=1, seconds=10)).isoformat(),
                "message": {"content": content}}

    def write(self, name, rows, compact=False):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        separators = (",", ":") if compact else None
        path.write_text("".join(json.dumps(row, separators=separators) + "\n" for row in rows), encoding="utf-8")
        return path

    def run_audit(self, *args, env=None, roots=None):
        result = subprocess.run([sys.executable, str(TOOL), *map(str, roots or [self.root]), *args],
                                env=env or self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, "audit failed (details suppressed for privacy)")
        self.assertEqual(result.stderr, "")
        return result.stdout

    def totals(self, text):
        return tuple(map(int, re.search(r"SESSIONS=(\d+) TOTAL_WEIGHTED=(\d+)", text).groups()))

    def test_partial_dedup_weights_subagent_and_synthetic(self):
        text = self.run_audit("--days", "7")
        # Opus: 10+5+25+20+20=80; Fable: 20+2+10+10=42; subagent: 5+10+20+15=50.
        self.assertEqual(self.totals(text), (1, 172))
        self.assertIn("counted calls 3", text)
        self.assertIn("Subagent share: 50", text)
        self.assertRegex(text, r"Independent total .*172 vs 172 diff 0")
        self.assertNotIn("sum check", text)

    def test_repeated_results_once_per_tool_id(self):
        text = self.run_audit()
        top = text.split("Top 5 biggest tool results", 1)[1].split("Window:", 1)[0]
        self.assertEqual(top.count("Bash: 100"), 1)
        self.assertEqual(top.count("Read: 50"), 1)
        # A separate invocation with identical output must still count.
        self.write("extra.jsonl", [
            self.assistant("extra-call", "extra", "other", 1, 0, 0, 0, 0),
            self.user("extra", [{"type": "tool_result", "tool_use_id": "other-id", "content": "x" * 400}]),
        ])
        top = self.run_audit().split("Top 5 biggest tool results", 1)[1].split("Window:", 1)[0]
        self.assertEqual(len(re.findall(r": 100\b", top)), 2)

    def test_session_and_explicit_or_environment_exclusion(self):
        self.write("other.jsonl", [self.assistant("other-call", "other", "other", 1, 0, 0, 0, 1)])
        self.assertEqual(self.totals(self.run_audit("--exclude-session", "main")), (1, 6))
        env = dict(self.env, AUDIT_EXCLUDE_SESSION="main")
        self.assertEqual(self.totals(self.run_audit(env=env)), (1, 6))
        self.assertEqual(self.totals(self.run_audit("--session", "main", env=env)), (1, 172))
        self.assertEqual(self.totals(self.run_audit("--session", "other", env=env)), (1, 6))
        self.assertEqual(self.totals(self.run_audit(env=dict(self.env, AUDIT_ONLY_SESSION="main"))), (1, 172))

    def test_first_prompt_exclusion_and_explicit_session_override(self):
        self.write("audit.jsonl", [self.user("audit", "Audit my Claude Code usage"),
                                  self.assistant("audit-call", "audit", "other", 1, 0, 0, 0, 1)])
        self.assertEqual(self.totals(self.run_audit()), (1, 172))
        self.assertEqual(self.totals(self.run_audit("--session", "audit")), (1, 6))
        self.write("later.jsonl", [self.user("later", PRIVATE), self.user("later", "Audit my Claude Code usage"),
                                  self.assistant("later-call", "later", "other", 1, 0, 0, 0, 1)])
        self.assertEqual(self.totals(self.run_audit()), (2, 178))

    def test_days_filters_timestamps_mtime_and_top_results(self):
        self.write("old-call.jsonl", [self.assistant("old", "old", "other", 100, 0, 0, 0, 0, age=8)])
        old_file = self.write("old-file.jsonl", [self.assistant("old-file", "old-file", "other", 200, 0, 0, 0, 0)])
        old = (self.now - timedelta(days=8)).timestamp()
        os.utime(old_file, (old, old))
        self.assertEqual(self.totals(self.run_audit("--days", "7")), (1, 172))
        self.assertEqual(self.totals(self.run_audit("--days", "9")), (3, 472))
        text = self.run_audit("--days", "0.5")
        self.assertEqual(self.totals(text), (0, 0))
        self.assertNotIn("Bash: 100", text)

    def test_aggregate_output_and_no_summary_file(self):
        self.write("private.jsonl", [self.assistant("private-call", "private", str(self.root), 1, 0, 0, 0, 0)])
        text = self.run_audit()
        for forbidden in (PRIVATE, str(self.home), "bash-id", "main-call", "x" * 20):
            self.assertNotIn(forbidden, text)
        self.assertFalse((self.home / "claude-usage-audit" / "summary.txt").exists())

    def test_timezone_offsets_and_compact_json(self):
        outside = self.assistant("outside", "outside", "other", 5, 0, 0, 0, 0)
        inside = self.assistant("inside", "inside", "other", 6, 0, 0, 0, 0)
        outside["timestamp"] = (self.now - timedelta(days=7, hours=1)).astimezone(
            timezone(timedelta(hours=14))).isoformat()
        inside["timestamp"] = (self.now - timedelta(days=7) + timedelta(hours=1)).astimezone(
            timezone(timedelta(hours=-12))).isoformat()
        self.write("offsets.jsonl", [outside, inside], compact=True)
        self.assertEqual(self.totals(self.run_audit("--days", "7")), (2, 178))

    def test_preview_sizes_and_private_tool_labels(self):
        call = self.assistant("preview", "preview", "other", 1, 0, 0, 0, 0)
        call["message"]["content"] = [{"type": "tool_use", "id": "private-tool", "name": str(self.root)}]
        self.write("preview.jsonl", [call, self.user("preview", [
            {"type": "tool_result", "tool_use_id": "private-tool",
             "content": [{"type": "text", "text": "Output too large: 4 KB " + PRIVATE}]},
        ])])
        text = self.run_audit()
        self.assertIn("other: 1,024", text)
        self.assertNotIn(PRIVATE, text)

    def test_default_read_weight_and_ids_do_not_merge_sessions(self):
        self.write("one.jsonl", [self.assistant("shared-id", "one", "other", 1, 100, 0, 0, 1)])
        self.write("two.jsonl", [self.assistant("shared-id", "two", "other", 1, 100, 0, 0, 1)])
        self.assertEqual(self.totals(self.run_audit()), (3, 204))

    def test_empty_missing_and_malformed_inputs(self):
        self.write("bad.jsonl", [None, [], {"type": "assistant", "message": None}])
        with (self.root / "bad.jsonl").open("a") as stream:
            stream.write("{bad json\n")
        self.assertEqual(self.totals(self.run_audit()), (1, 172))
        self.assertEqual(self.totals(self.run_audit(roots=[self.home / "missing"])), (0, 0))

    def test_invalid_window_does_not_echo_input(self):
        for value in ("0", "-1", "nan", "inf", PRIVATE):
            result = subprocess.run([sys.executable, str(TOOL), "--days", value],
                                    env=self.env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 2)
            self.assertNotIn(PRIVATE, result.stderr)
            self.assertNotIn(str(self.home), result.stderr)

    def test_invalid_record_error_never_includes_traceback_or_paths(self):
        row = self.assistant("invalid", "invalid", "other", 1, 0, 0, 0, 0)
        row["entrypoint"] = {PRIVATE: str(self.root)}
        self.write("invalid.jsonl", [row])
        result = subprocess.run([sys.executable, str(TOOL), str(self.root)],
                                env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertNotIn(PRIVATE, result.stderr)
        self.assertNotIn(str(self.home), result.stderr)
        self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
