#!/usr/bin/env python3
"""Read-only annotated HOME inventory (Python standard library only).

Config: --config, then HOST_TOOLS_CONFIG, then
${CRSS_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/crss}/host-tools.json.
Only the "host-map" object is used. Keys: workspace_dirs (list of paths,
default ["workspace"]), sessions_dir (path, default ".sessions"), memory_root
(path, default none). Relative paths resolve against --home; ~/ uses --home.
Missing config uses defaults. No file contents beneath secrets are read.
"""

import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import socket
import subprocess
import sys
from threading import Lock
import time
from urllib.parse import urlsplit


REDACTIONS = [
    r"sk-[A-Za-z0-9_-]{16,}", r"gh[pousr]_[A-Za-z0-9]{20,}",
    r"github_pat_[A-Za-z0-9_]{20,}", r"xox[abprs]-[A-Za-z0-9-]{10,}",
    r"AKIA[0-9A-Z]{16}",
    r"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}",
    r"\b[0-9a-fA-F]{40,}\b", r"[A-Za-z0-9+/=_-]{48,}",
]


def redact(s):
    s = re.sub(r"://[^/@\s]+:[^/@\s]*@", "://[REDACTED]@", str(s))
    s = re.sub(r"(?i)(key|token|secret|password|passwd|apikey|api_key|auth)"
               r"(\s*[=:]\s*[\"']?)[^\s\"']+", r"\1\2[REDACTED]", s)
    for pattern in REDACTIONS:
        s = re.sub(pattern, "[REDACTED]", s)
    return s


def clean(value):
    if isinstance(value, str):
        return redact(value)
    if isinstance(value, list):
        return [clean(v) for v in value]
    if isinstance(value, dict):
        return {redact(k): clean(v) for k, v in value.items()}
    return value


def realpath(path):
    # os.path.realpath also tolerates dangling and cyclic links.
    return Path(os.path.realpath(path))


def protected(path):
    return "secrets" in path.parts or "secrets" in realpath(path).parts


def children(path):
    if protected(path):
        return []
    try:
        return sorted(path.iterdir(), key=lambda p: p.name)
    except OSError:
        return []


def read_text(path):
    if protected(path):
        return ""
    try:
        # Bound reads of user-controlled files, and never open special files.
        if not path.is_file():
            return ""
        with path.open(encoding="utf-8", errors="replace") as handle:
            return handle.read(131072)
    except OSError:
        return ""


def date(path):
    try:
        return datetime.fromtimestamp(path.lstat().st_mtime, timezone.utc).strftime("%Y-%m-%d")
    except OSError:
        return "missing"


def human(size):
    value = float(size)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB", "PiB"):
        if value < 1024 or unit == "PiB":
            return f"{value:.1f} {unit}"
        value /= 1024


def origin(url):
    url = url.strip()
    if not url:
        return ""
    if "://" not in url:
        match = re.match(r"(?:[^/@:]+@)?([^/:]+):(.+)", url)
        if match:
            url = "ssh://" + match[1] + "/" + match[2]
        else:
            return "local"
    try:
        parsed = urlsplit(url)
        parts = [p for p in parsed.path.split("/") if p]
        return (parsed.hostname or "local").lower() + "/" + "/".join(parts[:2]).removesuffix(".git")
    except ValueError:
        return "invalid origin"


def base_name(name):
    return re.sub(r"(?i)(?:\.(?:bak|backup|orig)(?:[-._].*)?|-bak-.*|[-_.]v?\d+(?:\.\d+)*)$", "", name)


class Inventory:
    def __init__(self, home):
        self.home = home
        self.sections = []
        self.notes = []
        self.flags = Counter()
        self.commands = {}
        self.sizes = {}
        self.note_lock = Lock()

    def path(self, value):
        if value == "~":
            return self.home
        if value.startswith("~/"):
            return self.home / value[2:]
        path = Path(value)
        return path if path.is_absolute() else self.home / path

    def show(self, path):
        try:
            return "~/" + str(path.relative_to(self.home))
        except ValueError:
            return str(path)

    def note(self, message):
        with self.note_lock:
            if message not in self.notes:
                self.notes.append(message)

    def available(self, command):
        if command not in self.commands:
            self.commands[command] = shutil.which(command) is not None
        if not self.commands[command]:
            self.note(f"{command}: command unavailable")
        return self.commands[command]

    def run(self, args, timeout=5):
        if not self.available(args[0]):
            return "", "unavailable"
        env = dict(os.environ, GIT_OPTIONAL_LOCKS="0", LC_ALL="C")
        try:
            result = subprocess.run(args, capture_output=True, text=True, errors="replace",
                                    timeout=timeout, env=env, cwd=self.home)
        except subprocess.TimeoutExpired:
            self.note(f"{args[0]}: timeout")
            return "", "timeout"
        except OSError:
            self.note(f"{args[0]}: command unavailable")
            return "", "unavailable"
        if result.returncode == 127:
            self.note(f"{args[0]}: command unavailable")
            return "", "unavailable"
        if result.returncode:
            # Do not expose stderr, which can contain credentials or argv.
            self.note(f"{args[0]}: command failed ({result.returncode})")
            return "", "error"
        return result.stdout, ""

    def git(self, path, *args):
        if protected(path) or protected(path / ".git"):
            return "", "secrets (not read)"
        return self.run(["git", "-C", str(path), *args])

    def size(self, path, seen=None):
        target = realpath(path)
        if path.is_symlink() or (seen is not None and target in seen):
            return "→ " + self.show(target), -1
        if seen is not None:
            seen.add(target)
        if target in self.sizes:
            return self.sizes[target]
        out, error = self.run(["du", "-sk", "--", str(path)], timeout=20)
        if error:
            result = error, -1
        else:
            try:
                size = int(out.split()[0]) * 1024
                result = human(size), size
            except (ValueError, IndexError):
                result = "unknown", -1
        self.sizes[target] = result
        return result

    def measure(self, paths):
        # Keep large inventories bounded even when several paths time out.
        unique = {realpath(p): p for p in paths if not p.is_symlink()}
        with ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(self.size, unique.values()))

    def add(self, title, columns, rows, notes=None):
        self.sections.append(dict(title=title, columns=columns, rows=rows, notes=notes or []))

    def flag(self, flags):
        self.flags.update(flags)
        return ", ".join(flags)

    def top(self):
        entries = children(self.home)
        self.measure(entries)
        bases = Counter(base_name(p.name) for p in entries)
        rows = []
        seen = set()
        for p in entries:
            flags = []
            if re.search(r"\.bak|\.backup|\.orig|-bak-", p.name):
                flags.append("backup")
            if bases[base_name(p.name)] > 1:
                flags.append("dup?")
            kind = "symlink→" + self.show(realpath(p)) if p.is_symlink() else "dir" if p.is_dir() else "file"
            size, amount = self.size(p, seen)
            rows.append((amount, [p.name, kind, size, date(p), self.flag(flags)]))
        self.add("Top level", ["name", "kind", "size", "last-modified", "flags"],
                 [row for _, row in sorted(rows, key=lambda r: r[0], reverse=True)])

    def purpose(self, repo):
        for name in ("README.md", "CLAUDE.md", "AGENTS.md"):
            for line in read_text(repo / name).splitlines():
                if line.strip() and not line.lstrip().startswith("#"):
                    return redact(line.strip())[:90]
        return ""

    def repos(self, workspace_dirs):
        roots = [self.path(p) for p in workspace_dirs]
        rows, repos, origins = [], [], Counter()
        seen = set()
        for root in roots:
            entries = [p for p in children(root) if p.is_dir()]
            self.measure(entries)
            for repo in entries:
                if not repo.is_dir():
                    continue
                target = realpath(repo)
                if repo.is_symlink() or target in seen:
                    rows.append([self.show(repo), "→ " + self.show(target), "", "", "", "", "", "", ""])
                    continue
                seen.add(target)
                if protected(repo):
                    rows.append([self.show(repo), "secrets (not read)", "", "", "", "", "", self.size(repo)[0], ""])
                    continue
                git_marker = repo / ".git"
                if not git_marker.exists():
                    rows.append([self.show(repo), self.purpose(repo), "", "", "", "", "", self.size(repo)[0], self.flag(["not-git"])])
                    continue
                if not self.available("git"):
                    continue
                status, error = self.git(repo, "status", "--porcelain=v2", "-b")
                if error:
                    rows.append([self.show(repo), self.purpose(repo), error, error, error, "", "", self.size(repo)[0], ""])
                    continue
                branch, dirty, ab = "", 0, "+0 -0"
                for line in status.splitlines():
                    if line.startswith("# branch.head "):
                        branch = line[len("# branch.head "):]
                    elif line.startswith("# branch.ab "):
                        ab = line[len("# branch.ab "):]
                    elif line and not line.startswith("#"):
                        dirty += 1
                remote, remote_error = self.git(repo, "config", "--get", "remote.origin.url")
                normalized = origin(remote)
                stamp, stamp_error = self.git(repo, "log", "-1", "--format=%ct")
                try:
                    committed = datetime.fromtimestamp(int(stamp), timezone.utc).strftime("%Y-%m-%d")
                except (ValueError, OverflowError, OSError):
                    committed = stamp_error or "unknown"
                flags = ["no-remote"] if not normalized and remote_error != "timeout" else []
                rows.append([self.show(repo), self.purpose(repo), branch, dirty, ab, committed,
                             remote_error if remote_error == "timeout" else normalized, self.size(repo)[0], flags])
                if normalized:
                    origins[normalized] += 1
                repos.append(repo)
        for row in rows:
            if isinstance(row[-1], list):
                if origins[row[6]] > 1:
                    row[-1].append("dup-origin")
                row[-1] = self.flag(row[-1])
        self.add("Workspace repos", ["name", "purpose", "branch", "dirty count", "ahead/behind", "last commit", "origin", "size", "flags"], rows)
        self.worktrees(repos, roots)

    def worktrees(self, repos, roots):
        rows, seen = [], set()
        for repo in repos:
            output, error = self.git(repo, "worktree", "list", "--porcelain")
            if error:
                if error == "timeout":
                    rows.append([self.show(repo), "timeout", "", ""])
                continue
            entries = output.strip().split("\n\n")
            for block in entries[1:]:
                fields = dict(line.partition(" ")[::2] for line in block.splitlines())
                if "worktree" not in fields:
                    continue
                path = Path(fields["worktree"])
                target = realpath(path)
                if target in seen:
                    continue
                seen.add(target)
                flags = []
                if "prunable" in fields:
                    flags.append("prunable")
                if not path.is_dir():
                    flags.append("missing-dir")
                if not any(target.is_relative_to(realpath(root)) for root in roots):
                    flags.append("outside-workspace")
                branch = fields.get("branch", "detached").removeprefix("refs/heads/")
                rows.append([self.show(repo), self.show(path), branch, self.flag(flags)])
        self.add("Worktrees", ["repo", "path", "branch", "flags"], rows)

    def units(self):
        unit_root = self.home / ".config/systemd/user"
        suffixes = (".service", ".timer", ".socket", ".target", ".path", ".mount",
                    ".automount", ".slice", ".scope", ".swap", ".device")
        units = [p for p in children(unit_root) if p.is_file() and p.suffix in suffixes]
        output, error = self.run(["systemctl", "--user", "list-units", "--all", "--plain", "--no-legend", "--type=service,timer"])
        states = {}
        for line in output.splitlines():
            parts = line.split()
            if len(parts) >= 4:
                states[parts[0]] = (parts[2], parts[3])
        rows = []
        for unit in units:
            flags, working = [], "unset"
            for line in read_text(unit).splitlines():
                key, sep, value = line.strip().partition("=")
                if not sep or key not in ("WorkingDirectory", "ExecStart"):
                    continue
                try:
                    words = shlex.split(value)
                except ValueError:
                    continue
                if not words:
                    continue
                token = words[0]
                if key == "WorkingDirectory":
                    token = token.lstrip("-")
                else:
                    token = token.lstrip("-+!:@")
                token = token.replace("%h", str(self.home)).replace("%t", "<runtime>")
                if "%" in token or "$" in token or "<runtime>" in token:
                    if key == "WorkingDirectory":
                        working = "unknown"
                    continue
                if key == "WorkingDirectory":
                    exists = self.path(token).is_dir()
                    working = "yes" if exists else "no"
                elif token.startswith("/"):
                    exists = Path(token).is_file()
                else:
                    exists = shutil.which(token) is not None
                if not exists and "orphan" not in flags:
                    flags.append("orphan")
            state, sub = states.get(unit.name, (error or "unknown", error or "unknown"))
            rows.append([unit.name, state, sub, working, self.flag(flags)])
        self.add("Systemd user units", ["unit", "state", "sub", "WorkingDirectory exists", "flags"], rows)
        return [p.name for p in units]

    def sessions(self, directory, units):
        output, error = self.run(["tmux", "ls", "-F", "#S"])
        names = set(output.splitlines())
        rows, seen = [], set()
        entries = [p for p in children(self.path(directory)) if p.is_dir()]
        self.measure(entries)
        for p in entries:
            size, _ = self.size(p, seen)
            has_unit = any(p.name in unit for unit in units)
            has_tmux = p.name in names
            try:
                old = time.time() - p.lstat().st_mtime > 14 * 86400
            except OSError:
                old = False
            flags = ["orphan?"] if not has_unit and not has_tmux and old else []
            rows.append([p.name, size, date(p), "yes" if has_unit else "no",
                         error or ("yes" if has_tmux else "no"), self.flag(flags)])
        self.add("Sessions", ["name", "size", "mtime", "has-unit", "has-tmux", "flags"], rows)

    def config_sections(self):
        rows, seen = [], set()
        for name in ("skills", "agents", "plugins", "projects", "rules", "worktrees", "commands", "hooks"):
            p = self.home / ".claude" / name
            if not p.exists() and not p.is_symlink():
                continue
            size, _ = self.size(p, seen)
            count = "→ " + self.show(realpath(p)) if p.is_symlink() else len(children(p))
            rows.append([name, count, size])
        # Backup metadata is also useful here for configuration files below HOME.
        for p in children(self.home / ".claude"):
            if re.search(r"\.bak|\.backup|\.orig|-bak-", p.name):
                rows.append([p.name, "", self.size(p, seen)[0]])
                self.flags.update(["backup"])
        self.add("Claude config", ["name", "entry count", "size"], rows,
                 ["backup: " + p.name for p in children(self.home / ".claude")
                  if re.search(r"\.bak|\.backup|\.orig|-bak-", p.name)])
        rows, seen = [], set()
        for p in children(self.home / ".config/crss"):
            if p.is_file() or p.is_symlink():
                rows.append([p.name, self.size(p, seen)[0], date(p)])
        self.add("Overlay", ["name", "size", "mtime"], rows)

    def file_count(self, root):
        count, seen, stack = 0, set(), [root]
        while stack:
            path = stack.pop()
            if path.is_symlink() or protected(path):
                continue
            target = realpath(path)
            if target in seen:
                continue
            seen.add(target)
            if path.is_dir():
                stack.extend(children(path))
            elif path.is_file():
                count += 1
        return count

    def memory(self, root):
        if not root:
            self.note("Memory namespaces omitted: memory_root is not configured")
            return
        rows, seen = [], set()
        root = self.path(root)
        for group in ("agents", "shared"):
            for namespace in children(root / group):
                if not namespace.is_dir():
                    continue
                # Shared namespaces may have private/public subdivisions too.
                subdirs = [p for p in children(namespace) if p.is_dir()]
                if namespace.is_symlink() or protected(namespace):
                    paths = [namespace]
                elif group == "agents" or subdirs:
                    paths = subdirs
                else:
                    paths = [namespace]
                for p in paths:
                    if not p.is_dir():
                        continue
                    size, amount = self.size(p, seen)
                    count = "" if amount == -1 or protected(p) else self.file_count(p)
                    label = self.show(p)
                    if protected(p):
                        label += " (not read)"
                    rows.append([label, count, size])
        self.add("Memory namespaces", ["namespace", "file count", "size"], rows)


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(errors="backslashreplace")
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--json", action="store_true", help="emit generic JSON sections")
    mode.add_argument("--md", action="store_true", help="emit markdown tables (default)")
    parser.add_argument("--config", metavar="FILE")
    parser.add_argument("--home", default=os.environ.get("HOME", str(Path.home())), metavar="DIR")
    args = parser.parse_args()
    inv = Inventory(Path(args.home).absolute())
    overlay = os.environ.get("CRSS_HOME") or str(Path(os.environ.get("XDG_CONFIG_HOME", str(inv.home / ".config"))) / "crss")
    config_path = Path(args.config or os.environ.get("HOST_TOOLS_CONFIG") or str(Path(overlay) / "host-tools.json"))
    config = {}
    text = read_text(config_path)
    if text:
        try:
            config = json.loads(text).get("host-map", {})
            if not isinstance(config, dict):
                raise ValueError("host-map must be an object")
        except (ValueError, AttributeError):
            inv.note("Invalid host-map config; using defaults")
            config = {}
    workspace_dirs = config.get("workspace_dirs", ["workspace"])
    if not isinstance(workspace_dirs, list) or not all(isinstance(p, str) for p in workspace_dirs):
        workspace_dirs = ["workspace"]
        inv.note("Invalid workspace_dirs; using defaults")
    inv.top()
    inv.repos(workspace_dirs)
    # Collect units first for session matching, render them last.
    units = inv.units()
    unit_section = inv.sections.pop()
    sessions_dir = config.get("sessions_dir", ".sessions")
    inv.sessions(sessions_dir if isinstance(sessions_dir, str) else ".sessions", units)
    inv.config_sections()
    memory_root = config.get("memory_root")
    inv.memory(memory_root if isinstance(memory_root, str) else None)
    inv.sections.append(unit_section)
    inv.note("HOME size: " + inv.size(inv.home)[0])
    inv.note("Flags: " + str(sum(inv.flags.values())) + " (" + ", ".join(f"{k}={v}" for k, v in sorted(inv.flags.items())) + ")")
    result = clean(dict(tool="host-map", generated=datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                        host=socket.gethostname(), sections=inv.sections, notes=inv.notes))
    if args.json:
        print(json.dumps(result, ensure_ascii=False))
    else:
        def cell(value):
            return str(value).replace("\\", "\\\\").replace("|", "\\|").replace("\n", "<br>").replace("\r", "")
        print("# " + result["tool"] + " — " + result["host"] + "\n\n" + result["generated"])
        for section in result["sections"]:
            print("\n## " + section["title"] + "\n")
            print("| " + " | ".join(map(cell, section["columns"])) + " |")
            print("| " + " | ".join("---" for _ in section["columns"]) + " |")
            for row in section["rows"]:
                print("| " + " | ".join(map(cell, row)) + " |")
            for note in section["notes"]:
                print("\n- " + note)
        print("\n## Notes\n")
        for note in result["notes"]:
            print("- " + note)


if __name__ == "__main__":
    main()
