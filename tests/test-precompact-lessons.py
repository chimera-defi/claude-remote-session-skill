#!/usr/bin/env python3
"""precompact-lessons: validation table, flows against a stubbed reviewer, hook never fails compaction."""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "scripts" / "precompact-lessons.py"
SIGNAL_PATH = "agents/claude/public/wren/START.md"

spec = importlib.util.spec_from_file_location("precompact_lessons", TOOL)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

GOOD = {"save": True, "type": "feedback", "slug": "verify-before-relay", "description": "Verify child output first",
        "rule": "Rerun a child's cited command before relaying done.",
        "why": "Child summaries claim success without evidence.", "update": None}


def row(kind, content, **extra):
    return {"type": kind, "message": {"role": kind, "content": content}, "isSidechain": False, **extra}


class LessonsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = Path(self.tmp.name)
        self.home, self.state = t / "home", t / "state"
        self.proj = self.home / ".claude" / "projects" / "-work-proj"
        self.mem = self.proj / "memory"
        self.mem.mkdir(parents=True)
        (self.mem / "MEMORY.md").write_text("# Memory Index\n\n- [Old](feedback-old.md) — old rule\n")
        (self.mem / "feedback-old.md").write_text(
            "---\nname: feedback-old\ndescription: old rule\nmetadata:\n  type: feedback\n---\n\nKeep briefs short.\n")
        self.transcript = self.proj / "sess-1.jsonl"
        self.prompt, self.reply = t / "prompt.txt", t / "reply.json"
        self.stub = t / "claude-stub"
        self.stub.write_text('#!/bin/bash\ncat > "$STUB_PROMPT"\n'
                             '[ -n "$STUB_FAIL" ] && { echo boom >&2; exit 3; }\ncat "$STUB_REPLY"\n')
        self.stub.chmod(0o755)
        self.reply.write_text(json.dumps({"save": False}))
        self.env = dict(os.environ, HOME=str(self.home), CRSS_LESSONS_STATE=str(self.state),
                        CRSS_LESSONS_CLAUDE=str(self.stub), STUB_PROMPT=str(self.prompt), STUB_REPLY=str(self.reply))
        for k in ("CRSS_LESSONS", "CRSS_LESSONS_CHILD", "CRSS_LESSONS_MEMORY_DIR", "STUB_FAIL"):
            self.env.pop(k, None)

    def tearDown(self):
        self.tmp.cleanup()

    def write_transcript(self, rows):
        self.transcript.write_text("".join(json.dumps(r) + "\n" for r in rows))

    def wren_rows(self):
        return [row("assistant", [{"type": "tool_use", "name": "Read", "input": {"file_path": f"/x/{SIGNAL_PATH}"}}]),
                row("user", "Do not ask me to merge; just merge and report afterwards. " * 4),
                row("assistant", [{"type": "text", "text": "Understood, merging without asking. " * 4}])]

    def run_hook(self, *args, extra_env=None):
        payload = json.dumps({"session_id": "sess-1", "transcript_path": str(self.transcript), "trigger": "manual"})
        return subprocess.run([sys.executable, str(TOOL), *args], input=payload, text=True, capture_output=True,
                              env={**self.env, **(extra_env or {})}, timeout=30)

    def last_log(self):
        return json.loads((self.state / "precompact-lessons.jsonl").read_text().splitlines()[-1])

    def test_validate_table(self):
        ok, why = mod.validate(dict(GOOD))
        self.assertEqual((ok["slug"], why), ("feedback-verify-before-relay", ""))
        bad = {
            "date-in-rule": {"rule": "Since 2026-10-25 always rerun checks."},
            "ref-number-in-rule": {"rule": "Rerun checks, see PR #201 for the incident."},
            "ref-number-in-why": {"why": "Broke in commit 1b92d62abc last time."},
            "negative-claim-in-rule": {"rule": "Skip the browser tool because it does not work."},
            "secret-in-why": {"why": "Auth token: abcd1234efgh5678 was rejected."},
            "bad-type": {"type": "random"},
            "bad-update-target": {"update": "../escape.md"},
            "bad-slug": {"slug": "Not A Slug!"},
        }
        for reason, patch in bad.items():
            got, why = mod.validate({**GOOD, **patch})
            self.assertIsNone(got, reason)
            self.assertEqual(why, reason, reason)

    def test_flows_against_stub_reviewer(self):
        self.write_transcript([row("user", "hello")])
        out = self.run_hook("--sync")
        self.assertEqual(out.returncode, 0)
        self.assertEqual(self.last_log()["outcome"], "skip:no-wren-signal")
        self.assertFalse(self.prompt.exists(), "reviewer must not run without a Wren signal")

        self.write_transcript(self.wren_rows())
        self.run_hook("--sync")
        self.assertEqual(self.last_log()["outcome"], "nothing-to-save")

        self.reply.write_text(json.dumps(GOOD))
        self.run_hook("--sync", "--dry-run")
        self.assertEqual(self.last_log()["outcome"], "dry-run:create")
        self.assertFalse((self.mem / "feedback-verify-before-relay.md").exists())
        self.run_hook("--sync")
        self.assertEqual(self.last_log()["outcome"], "saved:create")
        new = (self.mem / "feedback-verify-before-relay.md").read_text()
        self.assertIn("originSessionId: sess-1", new)
        self.assertIn("**Why:**", new)
        self.assertIn("(feedback-verify-before-relay.md)", (self.mem / "MEMORY.md").read_text())

        self.run_hook("--sync")
        self.assertEqual(self.last_log()["outcome"], "rejected:duplicate")

        self.reply.write_text(json.dumps({**GOOD, "update": "feedback-old.md",
                                          "rule": "Open the cited file line before relaying a verdict.",
                                          "why": "Unchecked verdicts propagate silently."}))
        index_before = (self.mem / "MEMORY.md").read_text()
        self.run_hook("--sync")
        self.assertEqual(self.last_log()["outcome"], "saved:update")
        self.assertTrue((self.mem / "feedback-old.md").read_text().rstrip().endswith("propagate silently."))
        self.assertEqual((self.mem / "MEMORY.md").read_text(), index_before)

        self.reply.write_text(json.dumps({**GOOD, "update": "feedback-old.md", "rule": "Prefer small staged benchmark runs.",
                                          "why": "A written stop rule saves quota."}))
        self.run_hook("--sync", extra_env={"CRSS_LESSONS_MAX_FILE_BYTES": "50"})
        self.assertEqual(self.last_log()["outcome"], "rejected:file-cap")

    def test_window_stops_at_last_compaction_and_skips_summary(self):
        rows = self.wren_rows()
        rows[1] = row("user", "EARLIER-CORRECTION " * 20)
        boundary = {"type": "system", "subtype": "compact_boundary"}
        summary = row("user", "SUMMARY-TEXT " * 30, isCompactSummary=True)
        after = [row("user", "LATER-CORRECTION never push to main without review. " * 4),
                 row("assistant", [{"type": "text", "text": "ok " * 120}])]
        self.write_transcript(rows + [boundary, summary] + after)
        self.run_hook("--sync")
        prompt = self.prompt.read_text()
        self.assertIn("LATER-CORRECTION", prompt)
        self.assertNotIn("EARLIER-CORRECTION", prompt)
        self.assertNotIn("SUMMARY-TEXT", prompt)
        self.assertIn("Old", prompt, "memory index must be shown to the reviewer")

    def test_hook_never_fails_or_prints(self):
        self.write_transcript(self.wren_rows())
        self.reply.write_text("not json at all")
        self.run_hook("--sync")
        self.assertEqual(self.last_log()["outcome"], "error:unparseable-reply")
        for stub_env in ({"STUB_FAIL": "1"}, {"CRSS_LESSONS_CLAUDE": "/nonexistent/claude"}):
            out = self.run_hook("--sync", extra_env=stub_env)
            self.assertEqual(out.returncode, 0)
            self.assertTrue(self.last_log()["outcome"].startswith("error:"))
        bad = subprocess.run([sys.executable, str(TOOL)], input="{ not json", text=True, capture_output=True,
                             env=self.env, timeout=30)
        self.assertEqual((bad.returncode, bad.stdout), (0, ""))

        before = len((self.state / "precompact-lessons.jsonl").read_text().splitlines())
        self.reply.write_text(json.dumps(GOOD))
        started = time.monotonic()
        out = self.run_hook()
        self.assertEqual((out.returncode, out.stdout), (0, ""))
        self.assertLess(time.monotonic() - started, 5)
        for _ in range(100):
            if len((self.state / "precompact-lessons.jsonl").read_text().splitlines()) > before:
                break
            time.sleep(0.1)
        self.assertEqual(self.last_log()["outcome"], "saved:create")

        self.write_transcript(self.wren_rows())
        before = len((self.state / "precompact-lessons.jsonl").read_text().splitlines())
        for guard in ({"CRSS_LESSONS_CHILD": "1"}, {"CRSS_LESSONS": "0"}):
            self.run_hook(extra_env=guard)
        time.sleep(0.5)
        self.assertEqual(len((self.state / "precompact-lessons.jsonl").read_text().splitlines()), before)


if __name__ == "__main__":
    unittest.main()
