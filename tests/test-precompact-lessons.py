#!/usr/bin/env python3
"""precompact-lessons: validation table, flows against a stubbed reviewer, hook never fails compaction."""
import importlib.util
import json
import os
import shutil
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

    def last_log_in(self, state):
        return json.loads((state / "precompact-lessons.jsonl").read_text().splitlines()[-1])

    def test_validate_table(self):
        ok, why = mod.validate(dict(GOOD))
        self.assertEqual((ok["slug"], why), ("feedback-verify-before-relay", ""))
        bad = [
            ("date-in-rule", {"rule": "Since 2026-10-25 always rerun checks."}),
            ("date-in-rule", {"rule": "Since October 25, 2026 rerun checks."}),
            ("ref-number-in-rule", {"rule": "Rerun checks, see PR #201 for the incident."}),
            ("ref-number-in-rule", {"rule": "Rerun checks; see pr 7 for the incident."}),
            ("ref-number-in-why", {"why": "Broke in commit 1b92d62abc last time."}),
            ("ref-number-in-why", {"why": "Broke after commit deadbeef landed."}),
            ("negative-claim-in-rule", {"rule": "Skip the browser tool because it does not work."}),
            ("negative-claim-in-rule", {"rule": "Bash cannot execute commands in builders."}),
            ("secret-in-why", {"why": "Auth token: abcd1234efgh5678 was rejected."}),
            ("secret-in-why", {"why": "gh" + "p_" + "a1" * 15 + " leaked."}),
            ("secret-in-rule", {"rule": "Use API key: abcdefghijklmnop for authentication."}),
            ("secret-in-rule", {"rule": "Use glpat-abcdefghijklmnopqrst for GitLab access."}),
            ("bad-type", {"type": "random"}),
            ("bad-update-target", {"update": "../escape.md"}),
            ("bad-slug", {"slug": "Not A Slug!"}),
            ("bad-slug", {"slug": "sk-abcdefghijklmnopqrst"}),
        ]
        for reason, patch in bad:
            got, why = mod.validate({**GOOD, **patch})
            self.assertIsNone(got, patch)
            self.assertEqual(why, reason, patch)
        for fine in ("Decide 2 owners per lane.", "Market 10 lanes at most.", "Never work directly on shared main.",
                     "Do not work around failing checks.", "Rotate the API key owner field monthly."):
            self.assertIsNotNone(mod.validate({**GOOD, "rule": fine})[0], fine)
        for slug in ("task-reports-lead-with-finish-line", "verify-2-independent-sources-before-reporting"):
            got, why = mod.validate({**GOOD, "slug": slug})
            self.assertEqual((got["slug"], why), (f"feedback-{slug}", ""), slug)

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
        self.reply.write_text(json.dumps({**GOOD, "slug": "fresh-rule", "rule": "Stage runs small.", "why": "Quota."}))
        self.run_hook("--sync", extra_env={"CRSS_LESSONS_MAX_FILE_BYTES": "50"})
        self.assertEqual(self.last_log()["outcome"], "rejected:file-cap", "create must honour the size cap too")
        self.assertFalse((self.mem / "feedback-fresh-rule.md").exists())
        self.reply.write_text(json.dumps({**GOOD, "slug": "short-dup", "rule": "Keep briefs short.", "why": "Brevity."}))
        self.run_hook("--sync")
        self.assertEqual(self.last_log()["outcome"], "rejected:duplicate", "short lessons are deduplicated too")

    def test_redirected_memory_dir_is_refused(self):
        self.write_transcript(self.wren_rows())
        self.reply.write_text(json.dumps(GOOD))
        self.run_hook("--sync", extra_env={"CRSS_LESSONS_STATE": str(self.mem / "state")})
        self.assertEqual(self.last_log_in(self.mem / "state")["outcome"], "skip:memory-dir-redirected")

        other = self.home / "elsewhere"
        other.mkdir()
        shutil.rmtree(self.mem / "state")
        for f in list(self.mem.iterdir()):
            f.rename(other / f.name)
        self.mem.rmdir()
        self.mem.symlink_to(other)
        self.run_hook("--sync")
        self.assertEqual(self.last_log()["outcome"], "skip:memory-dir-redirected")
        self.assertFalse((other / "feedback-verify-before-relay.md").exists())

    def test_worktree_session_writes_to_main_checkout_memory(self):
        work = self.home / "work"
        work.mkdir()
        subprocess.run(["git", "init", "-q", "main"], cwd=work, check=True)
        subprocess.run(["git", "worktree", "add", "-q", "--orphan", "-b", "wtb", "../wt"], cwd=work / "main", check=True)
        key = lambda p: "".join(c if c.isalnum() else "-" for c in str(p))
        projects = self.home / ".claude" / "projects"
        wt_proj = projects / key(work / "wt")
        (wt_proj / "memory").mkdir(parents=True)  # a stale folder here must not attract the lesson
        self.transcript = wt_proj / "sess-1.jsonl"
        self.write_transcript([{**r, "cwd": str(work / "wt")} for r in self.wren_rows()])
        self.reply.write_text(json.dumps(GOOD))
        # the payload cwd follows the Bash tool's `cd`: here it points at an unrelated directory
        payload = json.dumps({"session_id": "sess-1", "transcript_path": str(self.transcript),
                              "trigger": "manual", "cwd": str(self.home)})
        subprocess.run([sys.executable, str(TOOL), "--sync"], input=payload, text=True, capture_output=True,
                       env=self.env, timeout=30, check=True)
        main_mem = projects / key(work / "main") / "memory"
        self.assertEqual(self.last_log()["outcome"], "saved:create")
        self.assertTrue((main_mem / "feedback-verify-before-relay.md").exists(), "memory goes where the CLI reads it")
        self.assertEqual(list((wt_proj / "memory").iterdir()), [])

    def test_window_stops_at_last_compaction_and_skips_summary(self):
        rows = self.wren_rows()
        rows[1] = row("user", "EARLIER-CORRECTION " * 20)
        boundary = {"type": "system", "subtype": "compact_boundary"}
        summary = row("user", "SUMMARY-TEXT " * 30, isCompactSummary=True)
        after = [row("user", "MID-CORRECTION keep one writer per file. " * 4),
                 row("assistant", [{"type": "text", "text": 'grep shows {"subtype": "compact_boundary"} twice. ' * 4}]),
                 row("user", "LATER-CORRECTION never push to main without review. " * 4),
                 row("assistant", [{"type": "text", "text": "ok " * 120}])]
        self.write_transcript(rows + [boundary, summary] + after)
        self.run_hook("--sync")
        prompt = self.prompt.read_text()
        self.assertIn("LATER-CORRECTION", prompt)
        self.assertIn("MID-CORRECTION", prompt, "text that mentions compact_boundary is not a boundary")
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
