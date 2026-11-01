#!/usr/bin/env python3
"""Check model releases, report host health, and optionally start a refresh.

Config lookup: --config, HOST_TOOLS_CONFIG, then
${CRSS_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/crss}/host-tools.json.
Only the "env-refresh" object is used. All keys are optional: claude_bin
(path; default realpath of claude on PATH), codex_models_cache (path;
default ~/.codex/models_cache.json), memory_root (default ~/agent-memory),
usage_audit_cmd (argv; default ["usage-audit", "--days", "7"]),
opus_subagents_cmd (argv; default ["session-doctor", "opus-subagents",
"--days", "7"]), lessons_log (default
~/.local/state/crss/precompact-lessons.jsonl), backup_marker (path; mtime
of last successful off-box backup), spawn_cmd (argv; brief path appended),
extra_repos (paths of further local git repos to report, e.g. ~/.config/crss).
Paths expand ~ using --home; relative config paths resolve against --home.
The brief is read beside the repository's scripts/ directory, or from the
installed ~/.claude/skills/gstack-session-spawn/references/ directory.
Only ack updates fingerprint.json. Dry runs never write or spawn.
"""

import argparse
from collections import Counter
import datetime as dt
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import time


def redact(s):
    """Scrub credentials from every output string, including keys and notes."""
    s = re.sub(r"://[^/\s:@]+:[^/\s@]+@", "://[REDACTED]@", str(s))
    patterns = (
        r"sk-[A-Za-z0-9_-]{16,}", r"gh[pousr]_[A-Za-z0-9]{20,}",
        r"github_pat_[A-Za-z0-9_]{20,}", r"xox[abprs]-[A-Za-z0-9-]{10,}",
        r"AKIA[0-9A-Z]{16}",
        r"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}",
        r"\b[0-9a-fA-F]{40,}\b", r"[A-Za-z0-9+=_-]{48,}",
    )
    for pattern in patterns:
        s = re.sub(pattern, "[REDACTED]", s)
    s = re.sub(r"((?:key|token|secret|password|passwd|apikey|api_key|auth)"
               r"\s*[=:]\s*[\"']?)[^\s\"']+", r"\1[REDACTED]", s, flags=re.I)
    s = re.sub(r"\bBearer\s+\S+", "Bearer [REDACTED]", s, flags=re.I)
    return re.sub(r"Environment\s*=.*", "[REDACTED]", s)


def scrub(value):
    if isinstance(value, str):
        return redact(value)
    if isinstance(value, list):
        return [scrub(v) for v in value]
    if isinstance(value, dict):
        return {redact(k): scrub(v) for k, v in value.items()}
    return value


class Parser(argparse.ArgumentParser):
    def _print_message(self, message, file=None):
        if message:
            super()._print_message(redact(message), file)


class MetricTimeout(Exception):
    """A whole-metric deadline, distinct from recoverable per-file errors."""


def one_line(value):
    return " ".join(str(value).splitlines())


def epoch(value):
    if isinstance(value, (float, int)):
        return float(value)
    parsed = dt.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    return parsed.replace(tzinfo=parsed.tzinfo or dt.timezone.utc).timestamp()


class Check:
    def __init__(self, args):
        self.home = Path(args.home).absolute()
        self.warnings = []
        self.now = time.time()
        overlay = os.environ.get("CRSS_HOME") or str(
            Path(os.environ.get("XDG_CONFIG_HOME") or self.home / ".config") / "crss")
        filename = args.config or os.environ.get("HOST_TOOLS_CONFIG") or str(Path(overlay) / "host-tools.json")
        document = self.read_json(self.path(filename), {})
        config = document.get("env-refresh", {}) if isinstance(document, dict) else None
        if not isinstance(config, dict):
            self.warnings.append("env-refresh config must be an object; using defaults")
            config = {}
        self.config = config
        state = args.state_dir or str(Path(os.environ.get("XDG_STATE_HOME") or self.home / ".local/state") / "crss/env-refresh")
        self.state = self.path(state)

    def path(self, value):
        value = str(value)
        if value == "~" or value.startswith("~/"):
            return self.home / value[2:] if value != "~" else self.home
        p = Path(value)
        return p if p.is_absolute() else self.home / p

    def read_json(self, path, default):
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return default
        except (OSError, ValueError) as exc:
            self.warnings.append(f"{path.name}: {exc}")
            return default

    def command(self, argv, timeout=120):
        if not isinstance(argv, list) or not argv or not all(isinstance(a, str) and a for a in argv):
            raise ValueError("command must be a nonempty argv list")
        argv = list(argv)
        if argv[0].startswith("~"):
            argv[0] = str(self.path(argv[0]))
        result = subprocess.run(argv, capture_output=True, text=True, errors="replace",
                                timeout=timeout, check=False,
                                env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"})
        if result.returncode:
            raise ValueError(f"{argv[0]}: exit {result.returncode}: {one_line(result.stderr)[:300]}")
        return result.stdout

    def fingerprint(self):
        fp = {"claude_cli_version": "", "claude_models": [],
              "codex_cli_version": "", "codex_models": []}
        binary = self.config.get("claude_bin") or shutil.which("claude")
        if binary:
            try:
                binary = self.path(binary).resolve()
            except (OSError, RuntimeError) as exc:
                self.warnings.append(f"claude_bin unavailable: {exc}")
                binary = None
        for key, argv in (("claude_cli_version", [str(binary), "--version"] if binary else []),
                          ("codex_cli_version", ["codex", "--version"])):
            try:
                lines = self.command(argv, timeout=20).splitlines()
                if not lines:
                    raise ValueError("empty version output")
                fp[key] = lines[0]
            except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
                self.warnings.append(f"{key} unavailable: {exc}")
        try:
            if not binary:
                raise FileNotFoundError("claude not found on PATH")
            models, carry = set(), b""
            pattern = re.compile(rb"claude-(?:opus|sonnet|haiku|fable)-\d+(?:-\d+)?")
            with binary.open("rb") as stream:
                while True:
                    chunk = stream.read(1024 * 1024)
                    if not chunk:
                        models.update(m.decode("ascii") for m in pattern.findall(carry))
                        break
                    data = carry + chunk
                    # Defer starts in the final 64 bytes, so a boundary cannot
                    # turn a partial model ID into an extra spurious model.
                    cutoff = max(0, len(data) - 64)
                    models.update(m.group().decode("ascii") for m in pattern.finditer(data)
                                  if m.start() < cutoff)
                    carry = data[-64:]
            fp["claude_models"] = sorted(models)
        except (OSError, ValueError) as exc:
            self.warnings.append(f"claude_models unavailable: {exc}")
        try:
            cache = self.path(self.config.get("codex_models_cache", "~/.codex/models_cache.json"))
            document = json.loads(cache.read_text(encoding="utf-8"))
            models = document["models"]
            if not isinstance(models, list):
                raise ValueError("models must be a list")
            slugs = [m.get("slug") or m.get("id") for m in models if isinstance(m, dict)]
            fp["codex_models"] = sorted({s for s in slugs if isinstance(s, str) and s})
        except (OSError, ValueError, KeyError, TypeError) as exc:
            self.warnings.append(f"codex_models unavailable: {exc}")
        return scrub(fp)

    def lessons(self):
        counts = Counter()
        invalid = 0
        path = self.path(self.config.get("lessons_log", "~/.local/state/crss/precompact-lessons.jsonl"))
        with path.open(encoding="utf-8", errors="replace") as stream:
            for line in stream:
                try:
                    entry = json.loads(line)
                    if self.now - 7 * 86400 <= epoch(entry["ts"]) <= self.now:
                        counts[str(entry["outcome"])] += 1
                except (ValueError, TypeError, KeyError, OverflowError):
                    invalid += 1
        saved = sum(n for k, n in counts.items() if k.startswith("saved:"))
        skipped = sum(n for k, n in counts.items() if k.startswith("skip:"))
        return [f"saved = {saved}; skipped = {skipped}; malformed = {invalid}",
                "By outcome: " + json.dumps(dict(sorted(counts.items())), ensure_ascii=False)]

    def memory(self):
        root = self.path(self.config.get("memory_root", "~/agent-memory"))
        if not root.is_dir():
            raise FileNotFoundError("memory_root unavailable")
        rows = []

        def label(directory):
            try:
                return str(directory.relative_to(root))
            except ValueError:
                return str(directory)

        def visit(directory, depth):
            if (directory / ".git").exists():
                prefix = ["git", "-C", str(directory)]
                try:
                    dirty = len(self.command(prefix + ["status", "--porcelain", "--untracked-files=all"]).splitlines())
                    remote = bool(self.command(prefix + ["remote"]).strip())
                    try:
                        committed = int(self.command(prefix + ["log", "-1", "--format=%ct"]).strip())
                        age = f"{max(0, (self.now - committed) / 86400):.1f} days"
                    except ValueError:
                        age = "no commits"
                    rows.append(f"{label(directory)}: dirty={dirty}; last commit={age}; remote={'yes' if remote else 'none'}")
                except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
                    rows.append(f"{directory.relative_to(root)}: unavailable: {exc}")
            if depth < 5:
                for child in sorted(directory.iterdir()):
                    if child.name != ".git" and not child.is_symlink() and child.is_dir():
                        visit(child, depth + 1)

        visit(root, 0)
        for extra in self.config.get("extra_repos", []):
            if isinstance(extra, str) and self.path(extra).is_dir():
                visit(self.path(extra), 5)
        return rows or ["No git repositories found (depth <= 5)."]

    def backup(self):
        marker = self.config.get("backup_marker")
        if not marker or not self.path(marker).exists():
            return ["none configured (backup_marker unset or missing)"]
        return [f"{max(0, (self.now - self.path(marker).stat().st_mtime) / 86400):.1f} days"]

    def transcripts(self):
        def size(path, seen):
            info = path.stat()  # Follow symlinks, including ~/.claude/projects.
            identity = (info.st_dev, info.st_ino)
            if identity in seen:
                return 0
            seen.add(identity)
            if stat.S_ISREG(info.st_mode):
                return info.st_size
            if stat.S_ISDIR(info.st_mode):
                return sum(size(p, seen) for p in path.iterdir())
            return 0

        rows = []
        for value in ("~/.claude/projects", "~/.codex/sessions"):
            try:
                rows.append(f"{value}: {size(self.path(value), set())} bytes")
            except (OSError, RuntimeError) as exc:
                rows.append(f"{value}: unavailable: {exc}")
        return rows

    def metrics(self):
        def usage():
            return self.command(self.config.get("usage_audit_cmd", ["usage-audit", "--days", "7"])).splitlines()[-40:]

        def opus():
            lines = self.command(self.config.get("opus_subagents_cmd", ["session-doctor", "opus-subagents", "--days", "7"])).splitlines()
            return [f"{len(lines)} lines", *lines[:10]]

        def timeout_handler(_signum, _frame):
            raise MetricTimeout("metric exceeded 120s")

        sections = []
        for title, collect in (("Usage audit (7 days)", usage), ("Opus subagents (7 days)", opus),
                               ("Lessons (7 days)", self.lessons), ("Memory health", self.memory),
                               ("Off-box backup", self.backup), ("Transcripts", self.transcripts)):
            previous = signal.signal(signal.SIGALRM, timeout_handler)
            signal.setitimer(signal.ITIMER_REAL, 120)
            try:
                lines = collect() or ["No output."]
            except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired, MetricTimeout) as exc:
                lines = [f"Unavailable/skipped: {exc}"]
            finally:
                signal.setitimer(signal.ITIMER_REAL, 0)
                signal.signal(signal.SIGALRM, previous)
            sections.append((title, [one_line(line) for line in lines]))
        return sections

    def recent_spawn(self, fingerprint):
        try:
            with (self.state / "history.jsonl").open(encoding="utf-8") as stream:
                for line in stream:
                    try:
                        row = json.loads(line)
                        if (row.get("spawned") and row.get("fingerprint") == fingerprint
                                and self.now - 3 * 86400 <= epoch(row["generated"]) <= self.now):
                            return True
                    except (ValueError, TypeError, KeyError, AttributeError, OverflowError):
                        continue
        except FileNotFoundError:
            pass
        return False


def markdown(summary, sections, warnings):
    lines = ["# Environment refresh", f"Generated: {summary['generated']}", "",
             f"{summary['status']}: {'; '.join(summary['reasons'])}", "", "## Fingerprint"]
    lines += [f"- {key}: {one_line(json.dumps(value, ensure_ascii=False))}"
              for key, value in summary["fingerprint"].items()]
    lines += ["New models: " + one_line(json.dumps(summary["new_models"], ensure_ascii=False)),
              "Warnings: " + one_line("; ".join(warnings) or "none")]
    # Preserve every repo's measurements, folding long inventories onto one line.
    for title, rows in sections:
        if title == "Memory health" and len(rows) > 20:
            rows = rows[:19] + [" ; ".join(rows[19:])]
        lines += ["", f"## {title}", *rows]
    return redact("\n".join(lines) + "\n")


def write_json(path, value):
    # Atomic replacement prevents an interrupted ack from erasing its baseline.
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(scrub(value), ensure_ascii=False) + "\n", encoding="utf-8")
    temporary.replace(path)


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(errors="backslashreplace")
    parser = Parser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", nargs="?", choices=["ack"])
    parser.add_argument("--home", default=os.environ.get("HOME", str(Path.home())), metavar="PATH")
    parser.add_argument("--state-dir", metavar="PATH")
    parser.add_argument("--config", metavar="PATH")
    parser.add_argument("--max-age-days", type=int, default=30)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--spawn", action="store_true")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    if args.max_age_days < 0:
        parser.error("--max-age-days must be nonnegative")
    check = Check(args)
    fingerprint = check.fingerprint()
    generated = dt.datetime.fromtimestamp(check.now, dt.timezone.utc).isoformat()
    if args.action == "ack":
        ack = {"acked_at": generated, "fingerprint": fingerprint}
        if not args.dry_run:
            check.state.mkdir(parents=True, exist_ok=True)
            write_json(check.state / "fingerprint.json", ack)
        print(json.dumps(scrub(ack), ensure_ascii=False))
        return 0
    ack = check.read_json(check.state / "fingerprint.json", {})
    reasons = []
    try:
        baseline = ack["fingerprint"]
        if not isinstance(baseline, dict) or not all(isinstance(baseline.get(k), list)
                                                   for k in ("claude_models", "codex_models")):
            raise ValueError("invalid fingerprint")
        ack_time = epoch(ack["acked_at"])
    except (KeyError, ValueError, TypeError, OverflowError):
        baseline = {}
        ack_time = None
        reasons.append("no ack yet (or unreadable ack)")
    new_models = {key: sorted(set(fingerprint[key]) - {v for v in baseline.get(key, []) if isinstance(v, str)})
                  for key in ("claude_models", "codex_models")}
    if any(new_models.values()):
        reasons.append("new models detected")
    if ack_time is not None and check.now - ack_time > args.max_age_days * 86400:
        reasons.append(f"last ack older than {args.max_age_days} days")
    if args.force:
        reasons.append("forced")
    due = bool(reasons)
    stamp = dt.datetime.fromtimestamp(check.now, dt.timezone.utc).strftime("%Y%m%dT%H%MZ")
    report_path = check.state / "reports" / (stamp + ".md")
    summary = {"generated": generated, "status": "DUE" if due else "OK",
               "reasons": reasons or ["acked models unchanged; refresh age within limit"],
               "fingerprint": fingerprint, "new_models": new_models,
               "report_path": str(report_path), "spawned": False}
    report = markdown(summary, check.metrics(), check.warnings)
    if args.dry_run:
        print(redact(report), end="")
        return 10 if due else 0
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(redact(report), encoding="utf-8")
    command = check.config.get("spawn_cmd")
    if due and args.spawn and command:
        try:
            if not args.force and check.recent_spawn(fingerprint):
                summary["spawn_note"] = "same fingerprint spawned within last 3 days"
            elif not isinstance(command, list) or not all(isinstance(a, str) and a for a in command):
                summary["spawn_note"] = "spawn_cmd must be an argv list"
            else:
                template = Path(__file__).resolve().parent.parent / "references/env-refresh-brief.md"
                if not template.is_file():
                    template = check.home / ".claude/skills/gstack-session-spawn/references/env-refresh-brief.md"
                brief = template.read_text(encoding="utf-8")
                for key, value in (("new_models", json.dumps(new_models, ensure_ascii=False)),
                                   ("reasons", "; ".join(summary["reasons"])), ("report_path", str(report_path))):
                    brief = brief.replace("{" + key + "}", value)
                brief_path = check.state / ("brief-" + stamp + ".md")
                brief_path.write_text(redact(brief), encoding="utf-8")
                # Let the launcher finish creating its session before the
                # oneshot unit exits and systemd cleans up its child processes.
                check.command(command + [str(brief_path)])
                summary.update(spawned=True, brief_path=str(brief_path))
        except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
            summary["spawn_note"] = f"spawn unavailable: {exc}"
    with (check.state / "history.jsonl").open("a", encoding="utf-8") as stream:
        # Scrub strings before encoding, so escaped JSON quotes stay intact.
        stream.write(json.dumps(scrub(summary), ensure_ascii=False) + "\n")
    print(json.dumps(scrub(summary), ensure_ascii=False) if args.json else redact(report_path))
    return 10 if due else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError) as error:
        print(redact(f"env-refresh: {error}"), file=sys.stderr)
        sys.exit(2)
