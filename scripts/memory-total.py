#!/usr/bin/env python3
"""Read-only memory inventory; token estimates are bytes / 4, rounded half up.

Config lookup: --config, HOST_TOOLS_CONFIG, then
${CRSS_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/crss}/host-tools.json.
Only the "memory-total" object is used. Keys: extra_start_files (path list),
memory_root (path), workspace_dirs (workspace parent path list; default
~/workspace), kb_sources (list of {name, path}), kb_status_cmd (argv list).
Paths expand ~ using --home; relative config paths resolve against --home.
Sections overlap intentionally; totals deduplicate realpaths within each section.
"""

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import shlex
import socket
import stat
import subprocess
import sys


def redact(s):
    """Scrub credentials from every output string, including keys and notes."""
    s = re.sub(r"://[^/\s:@]+:[^/\s@]+@", "://[REDACTED]@", str(s))
    patterns = (
        r"sk-[A-Za-z0-9_-]{16,}", r"gh[pousr]_[A-Za-z0-9]{20,}",
        r"github_pat_[A-Za-z0-9_]{20,}", r"xox[abprs]-[A-Za-z0-9-]{10,}",
        r"AKIA[0-9A-Z]{16}",
        r"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}",
        r"\b[0-9a-fA-F]{40,}\b", r"[A-Za-z0-9+/=_-]{48,}",
    )
    for pattern in patterns:
        s = re.sub(pattern, "[REDACTED]", s)
    s = re.sub(r"((?:key|token|secret|password|passwd|apikey|api_key|auth)"
               r"\s*[=:]\s*)[^\s\"']+", r"\1[REDACTED]", s, flags=re.I)
    # Status commands can accidentally include unit configuration.
    return re.sub(r"Environment\s*=.*", "[REDACTED]", s)


def scrub(value):
    if isinstance(value, str):
        return redact(value)
    if isinstance(value, list):
        return [scrub(v) for v in value]
    if isinstance(value, dict):
        return {redact(k): scrub(v) for k, v in value.items()}
    return value


def tokens(size):
    return (size + 2) // 4


def timestamp(epoch):
    return dt.datetime.fromtimestamp(epoch, dt.timezone.utc).isoformat() if epoch else ""


def canonical(p):
    return Path(os.path.realpath(p))


class Inventory:
    columns = ["store", "kind", "path", "files", "bytes", "est_tokens",
               "loads_at_start", "last-modified"]
    skip = {"node_modules", ".git"}

    def __init__(self, home):
        self.home = home.absolute()
        self.sections = []
        self.notes = []

    def path(self, value):
        value = str(value)
        if value == "~" or value.startswith("~/"):
            return self.home / value[2:] if value != "~" else self.home
        p = Path(value)
        return p if p.is_absolute() else self.home / p

    def display(self, p):
        try:
            return "~/" + str(p.absolute().relative_to(self.home))
        except ValueError:
            return str(p)

    @staticmethod
    def secret(p):
        return "secrets" in p.parts or "secrets" in canonical(p).parts

    def is_type(self, p, section, directory=False):
        try:
            mode = p.stat().st_mode
            return stat.S_ISDIR(mode) if directory else stat.S_ISREG(mode)
        except FileNotFoundError:
            return False
        except OSError as exc:
            section["notes"].append(f"{self.display(p)}: {exc.strerror}")
            return False

    def children(self, p, section):
        try:
            return sorted(p.iterdir())
        except OSError as exc:
            section["notes"].append(f"{self.display(p)}: {exc.strerror}")
            return []

    def section(self, title, extra=()):
        section = {"title": title, "columns": self.columns + list(extra),
                   "rows": [], "notes": []}
        self.sections.append(section)
        return section, set()

    def measure(self, p, seen, section):
        """Follow links, stat regular files only, and never open any file."""
        try:
            real = canonical(p)
            if real in seen:
                section["notes"].append(f"{self.display(p)} → {self.display(real)} (counted once)")
                return 0, 0, 0
            seen.add(real)
            info = p.stat()
            if stat.S_ISREG(info.st_mode):
                return 1, info.st_size, info.st_mtime
            if not stat.S_ISDIR(info.st_mode):
                return 0, 0, 0
            count, size, modified = 0, 0, 0
            for child in self.children(p, section):
                if section["title"] == "Instruction files" and (child.name in self.skip or (child.name == "worktrees" and p.name == ".claude")):
                    continue
                n, b, t = self.measure(child, seen, section)
                count, size, modified = count + n, size + b, max(modified, t)
            return count, size, modified
        except (OSError, RuntimeError) as exc:
            section["notes"].append(f"{self.display(p)}: {exc}")
            return 0, 0, 0

    def row(self, section, seen, store, kind, p, loads="no", extra=(), measured=None):
        n, size, modified = measured if measured is not None else self.measure(p, seen, section)
        path = self.display(p)
        if canonical(p) != p.absolute():
            path += " → " + self.display(canonical(p))
        if self.secret(p):
            kind += " (not read)"
        section["rows"].append([store, kind, path, n, size, tokens(size), loads,
                                timestamp(modified)] + list(extra))

    def total(self, section, row=False):
        files = sum(r[3] for r in section["rows"])
        size = sum(r[4] for r in section["rows"])
        estimate = sum(r[5] for r in section["rows"])
        section["notes"].append(f"Total: {files} files; {size} bytes; {estimate} est_tokens.")
        if row:
            section["rows"].append(["TOTAL", "total", "", files, size, estimate, "yes", ""])

    def memory_lines(self, p, section, limit=None):
        if self.secret(p):
            return 0, 0, False
        count, size, longer = 0, 0, False
        try:
            with p.open("rb") as stream:
                for line in stream:
                    if limit is not None and count == limit:
                        longer = True
                        break
                    count += 1
                    size += len(line)
        except OSError as exc:
            section["notes"].append(f"{self.display(p)}: {exc.strerror}")
        return count, size, longer

    def instructions(self, p, section, seen, depth=0, active=None):
        if not self.is_type(p, section):
            return
        active = set() if active is None else active
        real = canonical(p)
        if real in active or real in seen:
            section["notes"].append(f"{self.display(p)} → {self.display(real)} (already included; cycle-safe)")
            return
        self.row(section, seen, p.name, "instruction", p, "yes")
        if self.secret(p):
            return
        if depth == 5:
            section["notes"].append(f"{self.display(p)}: import depth limit 5")
            return
        try:
            with p.open(encoding="utf-8", errors="replace") as stream:
                for line in stream:
                    if not line.startswith("@"):
                        continue
                    try:
                        parts = shlex.split(line[1:], comments=True)
                    except ValueError:
                        continue
                    if not parts:
                        continue
                    target = self.path(parts[0]) if parts[0].startswith("~") else p.parent / parts[0]
                    self.instructions(target, section, seen, depth + 1, active | {real})
        except OSError as exc:
            section["notes"].append(f"{self.display(p)}: {exc.strerror}")

    def session(self, config, project):
        section, seen = self.section("Session-start context")
        base = self.home / ".claude"
        paths = [base / "CLAUDE.md"] + sorted((base / "rules").glob("*.md"))
        paths += [self.home / "AGENTS.md"] + [self.path(p) for p in config.get("extra_start_files", [])]
        paths += [project / "CLAUDE.md", project / ".claude/CLAUDE.md", project / "AGENTS.md"]
        for p in paths:
            self.instructions(p, section, seen)
        slug = str(project.absolute()).replace("/", "-")
        p = base / "projects" / slug / "memory/MEMORY.md"
        if self.is_type(p, section):
            _, size, longer = self.memory_lines(p, section, 200)
            measured = self.measure(p, seen, section)
            self.row(section, seen, "MEMORY.md", "auto-memory (first 200 lines)", p,
                     "partial" if longer else "yes", measured=(measured[0], size if measured[0] else 0, measured[2]))
        self.total(section, row=True)

    def auto(self):
        section, seen = self.section("Claude auto-memory", ["MEMORY.md lines"])
        projects = self.home / ".claude/projects"
        if self.is_type(projects, section, True):
            for project in self.children(projects, section):
                memory = project / "memory"
                if self.is_type(memory, section, True):
                    lines, _, _ = self.memory_lines(memory / "MEMORY.md", section) if self.is_type(memory / "MEMORY.md", section) else (0, 0, False)
                    self.row(section, seen, project.name, "auto-memory", memory, "partial", [lines])
            transcripts = []
            walked = set()

            def visit(p):
                real = canonical(p)
                if real in walked:
                    return
                walked.add(real)
                if self.is_type(p, section):
                    if p.suffix == ".jsonl":
                        transcripts.append(self.measure(p, seen, section))
                elif self.is_type(p, section, True):
                    for child in self.children(p, section):
                        visit(child)

            visit(projects)
            measured = (sum(t[0] for t in transcripts), sum(t[1] for t in transcripts), max((t[2] for t in transcripts), default=0))
            self.row(section, seen, "transcripts", "transcripts", projects, extra=[""], measured=measured)
            section["rows"][-1][5] = ""
        # Transcripts have no token estimate: only file counts and sizes.
        for_total = [r[5] for r in section["rows"] if isinstance(r[5], int)]
        section["notes"].append(f"Total: {sum(r[3] for r in section['rows'])} files; {sum(r[4] for r in section['rows'])} bytes; {sum(for_total)} est_tokens (memory only).")

    def agents(self, config):
        section, seen = self.section("Agent memory")
        if not config.get("memory_root"):
            section["notes"].append("No memory_root configured.")
        else:
            root = self.path(config["memory_root"])
            walked = set()

            def secrets(p):
                real = canonical(p)
                if real in walked or not self.is_type(p, section, True):
                    return
                walked.add(real)
                if self.secret(p):
                    self.row(section, seen, "secrets", "secrets", p)
                    return
                for child in self.children(p, section):
                    secrets(child)

            if self.is_type(root, section, True):
                secrets(root)
            parents = [root / "shared"]
            if self.is_type(root / "agents", section, True):
                parents += [p for p in self.children(root / "agents", section) if self.is_type(p, section, True)]
            for parent in parents:
                if not self.is_type(parent, section, True):
                    continue
                for ns in self.children(parent, section):
                    if self.is_type(ns, section, True):
                        self.row(section, seen, f"{parent.name}/{ns.name}", "memory namespace", ns)
        self.total(section)

    def knowledge(self, config):
        section, seen = self.section("Knowledge-base sources")
        for source in config.get("kb_sources", []):
            self.row(section, seen, source["name"], "knowledge source", self.path(source["path"]))
        if not config.get("kb_sources"):
            section["notes"].append("No kb_sources configured.")
        command = config.get("kb_status_cmd")
        if command:
            if not isinstance(command, list) or not all(isinstance(arg, str) for arg in command):
                section["notes"].append("kb_status_cmd must be an argv list.")
            elif self.secret(self.path(command[0])):
                section["notes"].append("kb_status_cmd under secrets skipped.")
            else:
                try:
                    result = subprocess.run(command, capture_output=True, text=True, errors="replace", timeout=5, check=False)
                    section["notes"] += result.stdout.splitlines()[:20]
                    if result.returncode:
                        section["notes"].append(f"kb_status_cmd exit status {result.returncode}")
                except subprocess.TimeoutExpired:
                    section["notes"].append("kb_status_cmd: timeout")
                    section["rows"].append(["kb_status_cmd", "status", "timeout", 0, 0, 0, "no", ""])
                except OSError:
                    section["notes"].append("kb_status_cmd: missing or unavailable command")
        self.total(section)

    def workspace(self, config):
        section, seen = self.section("Instruction files")
        walked = set()

        def visit(p, repo):
            real = canonical(p)
            if real in walked or self.secret(p):
                return
            walked.add(real)
            for child in self.children(p, section):
                if child.name in self.skip or (p.name == ".claude" and child.name == "worktrees"):
                    continue
                if self.is_type(child, section, True):
                    if child.name in {"docs", "references"}:
                        self.row(section, seen, repo.name, "documentation", child)
                        # Nested instruction files still appear with zero duplicate bytes.
                    visit(child, repo)
                elif self.is_type(child, section) and (child.name in {"CLAUDE.md", "AGENTS.md"} or (p.name == "rules" and p.parent.name == ".claude" and child.suffix == ".md")):
                    self.row(section, seen, repo.name, "instruction", child, "yes")

        for value in config.get("workspace_dirs", ["~/workspace"]):
            parent = self.path(value)
            if self.is_type(parent, section, True):
                for repo in self.children(parent, section):
                    if self.is_type(repo, section, True) and repo.name not in self.skip and not self.secret(repo):
                        visit(repo, repo)
        section["notes"].append("Instruction loads_at_start assumes a session in that repo; documentation is not loaded.")
        self.total(section)

    def skills(self):
        section, seen = self.section("Skills & agents", ["start_description_tokens"])
        base = self.home / ".claude"
        skills = base / "skills"
        descriptions = set()
        if self.is_type(skills, section, True):
            for skill in self.children(skills, section):
                if not self.is_type(skill, section, True):
                    continue
                description = 0
                p = skill / "SKILL.md"
                if self.is_type(p, section) and not self.secret(p) and canonical(p) not in descriptions:
                    descriptions.add(canonical(p))
                    try:
                        with p.open("rb") as stream:
                            first = stream.readline(1024)
                            remaining = 1024 - len(first)
                            if first.strip() == b"---":
                                while remaining > 0:
                                    line = stream.readline(remaining)
                                    remaining -= len(line)
                                    if not line or line.strip() == b"---":
                                        break
                                    if line.startswith(b"description:"):
                                        description += tokens(len(line.rstrip(b"\r\n")))
                    except OSError as exc:
                        section["notes"].append(f"{self.display(p)}: {exc.strerror}")
                self.row(section, seen, skill.name, "skill", skill, "partial", [description])
        agents = base / "agents"
        if self.is_type(agents, section, True):
            for p in sorted(agents.glob("*.md")):
                self.row(section, seen, p.stem, "agent", p, "no", [0])
        plugins = base / "plugins"
        if self.is_type(plugins, section, True):
            self.row(section, seen, "plugins", "plugins", plugins, "partial", [0])
        section["notes"].append("Only skill frontmatter descriptions load at start; estimated from description: lines in the first 1 KB of each SKILL.md. Agent bodies and plugin contents are stat-only.")
        self.total(section)


def markdown(report):
    def cell(value):
        return str(value).replace("|", "\\|").replace("\r", " ").replace("\n", "<br>")
    lines = [f"# {report['tool']}", "", f"Generated: {report['generated']} · Host: {report['host']}"]
    for section in report["sections"]:
        lines += ["", f"## {section['title']}", "", "| " + " | ".join(map(cell, section["columns"])) + " |",
                  "| " + " | ".join("---" for _ in section["columns"]) + " |"]
        lines += ["| " + " | ".join(map(cell, row)) + " |" for row in section["rows"]]
        lines += ["", *[f"- {note}" for note in section["notes"]]]
    lines += ["", *[f"- {note}" for note in report["notes"]]]
    return "\n".join(lines)


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(errors="backslashreplace")
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--json", action="store_true")
    mode.add_argument("--md", action="store_true")
    parser.add_argument("--config", metavar="FILE")
    parser.add_argument("--home", default=os.environ.get("HOME", str(Path.home())), metavar="DIR")
    parser.add_argument("--project", default=os.getcwd(), metavar="DIR", help="project whose session-start context to estimate (default: cwd)")
    args = parser.parse_args()
    inv = Inventory(Path(args.home))
    overlay = os.environ.get("CRSS_HOME") or str(Path(os.environ.get("XDG_CONFIG_HOME", str(inv.home / ".config"))) / "crss")
    filename = args.config or os.environ.get("HOST_TOOLS_CONFIG") or str(Path(overlay) / "host-tools.json")
    config = {}
    p = inv.path(filename)
    if inv.secret(p):
        inv.notes.append("Config under secrets skipped.")
    else:
        try:
            with p.open(encoding="utf-8") as stream:
                document = json.load(stream)
            if not isinstance(document, dict):
                raise ValueError("config must be an object")
            config = document.get("memory-total", {})
            if not isinstance(config, dict):
                raise ValueError("memory-total config must be an object")
        except FileNotFoundError:
            pass
        except (OSError, ValueError) as exc:
            inv.notes.append(f"Config unavailable: {exc}")
            config = {}
    inv.session(config, Path(args.project).absolute())
    inv.auto()
    inv.agents(config)
    inv.knowledge(config)
    inv.workspace(config)
    inv.skills()
    inv.notes += ["est_tokens = bytes / 4, rounded half up per row; totals sum row estimates.",
                  "Totals are deduplicated by realpath within each section; sections overlap and must not be added together. File sizes are logical bytes, not allocated disk usage."]
    report = scrub({"tool": "memory-total", "generated": dt.datetime.now(dt.timezone.utc).isoformat(),
                    "host": socket.gethostname(), "sections": inv.sections, "notes": inv.notes})
    print(json.dumps(report, ensure_ascii=False) if args.json else markdown(report))


if __name__ == "__main__":
    main()
