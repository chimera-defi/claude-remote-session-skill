#!/usr/bin/env python3
"""Read-only host services and resources, using only the Python standard library.

Usage: servers [--json | --md] [--config FILE] [--home DIR]
Config lookup: --config, HOST_TOOLS_CONFIG, then
${CRSS_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/crss}/host-tools.json.
Missing files use defaults. Only the "servers" object is used, with keys:
  extra_mounts: list of paths (in addition to / and HOME)
  ports: object mapping port strings to display labels
  collapse_prefixes: list of user-unit prefixes to summarize
  system_patterns: list of system-unit regexes (defaults to common daemons)
  stopped_expected: list of unit-name regexes; also checked against process
                    names, with and without a .service suffix, if no unit matches
  components: list of objects with name, optional unit/process regex, port integer,
              and status_cmd (argv list for a read-only command; never a shell)
SERVERS_PROC overrides /proc for resource and cgroup reads. All subprocesses
have a five-second timeout. No files are written; secrets directories are never
opened, including through symlinks. Process arguments and systemd environments
are never inspected. Output strings are redacted in both formats.
"""

import argparse
from collections import Counter
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import pwd
import re
import socket
import subprocess


DEFAULT_SYSTEM_PATTERNS = [
    r"docker|ssh|nginx|caddy|postgres|redis|tailscale|cloudflared|ollama"
]
SECRET_PATTERNS = [
    r"sk-[A-Za-z0-9_-]{16,}",
    r"gh[pousr]_[A-Za-z0-9]{20,}",
    r"github_pat_[A-Za-z0-9_]{20,}",
    r"xox[abprs]-[A-Za-z0-9-]{10,}",
    r"AKIA[0-9A-Z]{16}",
    r"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}",
    r"\b[0-9a-fA-F]{40,}\b",
    r"[A-Za-z0-9+/=_-]{48,}",
]


def redact(s):
    """Remove credential shapes from any output string, regardless of source."""
    s = re.sub(r"://[^\s/@:]+:[^\s/@]+@", "://[REDACTED]@", str(s))
    s = re.sub(r"Environment=.*", "Environment=[REDACTED]", s, flags=re.I)
    s = re.sub(
        r"((?:key|token|secret|password|passwd|apikey|api_key|auth)\s*[=:]\s*)"
        r"([\"']?)[^\s\"']+",
        r"\1\2[REDACTED]", s, flags=re.I,
    )
    for pattern in SECRET_PATTERNS:
        s = re.sub(pattern, "[REDACTED]", s)
    return s


def sanitize(value):
    if isinstance(value, str):
        return redact(value)
    if isinstance(value, list):
        return [sanitize(item) for item in value]
    if isinstance(value, dict):
        return {redact(key): sanitize(item) for key, item in value.items()}
    return value


def section(title, columns):
    return {"title": title, "columns": columns, "rows": [], "notes": []}


def safe_path(path):
    """Check both lexical and resolved ancestors before opening a file."""
    path = Path(path).expanduser().absolute()
    if "secrets" in path.parts or "secrets" in path.resolve().parts:
        raise OSError("secrets directory skipped")
    return path


def read_text(path):
    return safe_path(path).read_text(encoding="utf-8", errors="replace")


def run(argv, notes):
    """Return (stdout, problem); never include argv or stderr in output."""
    command = Path(argv[0]).name
    try:
        result = subprocess.run(
            argv, capture_output=True, text=True, encoding="utf-8", errors="replace",
            timeout=5, check=False, stdin=subprocess.DEVNULL,
        )
    except FileNotFoundError:
        problem = "missing command"
    except subprocess.TimeoutExpired:
        problem = "timeout"
    except OSError:
        problem = "unavailable"
    else:
        if result.returncode == 0:
            return result.stdout, ""
        problem = "exit {}".format(result.returncode)
    notes.append("{}: {}".format(command, problem))
    return "", problem


def error_row(sec, problem):
    if problem == "timeout":
        sec["rows"].append(["timeout"] + [""] * (len(sec["columns"]) - 1))


def load_config(args, notes):
    base = os.environ.get("CRSS_HOME") or str(
        Path(os.environ.get("XDG_CONFIG_HOME") or str(Path(args.home) / ".config")) / "crss"
    )
    path = args.config or os.environ.get("HOST_TOOLS_CONFIG") or str(Path(base) / "host-tools.json")
    try:
        data = json.loads(read_text(path))
        config = data.get("servers", {})
        if not isinstance(config, dict):
            raise ValueError("servers must be an object")
        return config
    except FileNotFoundError:
        return {}
    except (OSError, ValueError, AttributeError, RuntimeError):
        notes.append("Config unavailable or invalid; using defaults")
        return {}


def config_list(config, key, notes, default=()):
    value = config.get(key, list(default))
    if not isinstance(value, list):
        notes.append("Config {} must be a list".format(key))
        return list(default)
    return value


def patterns(values, notes):
    result = []
    for value in values:
        try:
            result.append(re.compile(value))
        except (re.error, TypeError):
            notes.append("Invalid regex ignored")
    return result


def resources(home, proc, config):
    sec = section("Resources", ["Resource", "Total", "Used", "Available", "Details"])
    seen = set()
    for path in ["/", home] + config_list(config, "extra_mounts", sec["notes"]):
        if not isinstance(path, str):
            sec["notes"].append("Invalid mount path ignored")
            continue
        try:
            resolved = str(Path(path).expanduser().resolve())
        except (OSError, RuntimeError):
            sec["notes"].append("Mount path unavailable")
            continue
        if resolved in seen:
            sec["rows"].append(["Disk " + path, "", "", "", "→ " + resolved])
            continue
        seen.add(resolved)
        output, problem = run(["df", "-kP", "--", resolved], sec["notes"])
        if problem:
            if problem == "timeout":
                sec["rows"].append(["Disk " + path, "timeout", "", "", ""])
            continue
        # Parse from the numeric tail; mount points and filesystem names may contain spaces.
        match = re.search(r"^.+?\s+(\d+)\s+(\d+)\s+(\d+)\s+\d+%\s+(.+)$", output, re.M)
        if match:
            sec["rows"].append(["Disk " + path] + [int(match[i]) for i in (1, 2, 3)] + ["KiB"])
        else:
            sec["notes"].append("df: unrecognized output")
    try:
        mem = {key: int(value) for key, value in re.findall(r"^(\w+):\s+(\d+)", read_text(proc / "meminfo"), re.M)}
        for label, total_key, free_key in [("RAM", "MemTotal", "MemAvailable"), ("Swap", "SwapTotal", "SwapFree")]:
            total = mem[total_key]
            free = mem.get(free_key, mem.get("MemFree", 0))
            sec["rows"].append([label, total, max(0, total - free), free, "KiB"])
    except (OSError, ValueError, KeyError, RuntimeError):
        sec["notes"].append("meminfo unavailable or invalid")
    sec["rows"].append(["CPUs", os.cpu_count() or "unknown", "", "", "logical"])
    for filename, label in [("loadavg", "Load average"), ("uptime", "Uptime")]:
        try:
            values = read_text(proc / filename).split()
            value = " / ".join(str(float(v)) for v in values[:3]) if filename == "loadavg" else float(values[0])
            sec["rows"].append([label, value, "", "", "1 / 5 / 15 minutes" if filename == "loadavg" else "seconds"])
        except (OSError, ValueError, IndexError, RuntimeError):
            sec["notes"].append(filename + " unavailable or invalid")
    return sec


def cgroup_unit(proc, pid):
    try:
        content = read_text(proc / str(pid) / "cgroup")
    except (OSError, RuntimeError):
        return ""
    units = re.findall(r"(?:^|/)([^/\n:]+\.(?:service|scope))(?=/|$)", content, re.M)
    return units[-1] if units else ""


def listening(proc, config):
    sec = section("Listening ports", ["Proto", "Local address", "Port", "Process", "PID", "Unit", "Owner", "Service"])
    output, problem = run(["ss", "-H", "-tulnp"], sec["notes"])
    ports = set()
    labels = config.get("ports", {})
    if not isinstance(labels, dict):
        sec["notes"].append("Config ports must be an object")
        labels = {}
    for line in output.splitlines():
        fields = line.split(None, 6)
        if len(fields) < 6:
            continue
        address, _, port = fields[4].rpartition(":")
        if not port.isdigit():
            continue
        port = int(port)
        ports.add(port)
        processes = re.findall(r'\("([^"\n]+)",pid=(\d+)', fields[6] if len(fields) == 7 else "")
        for name, pid in processes or [("", "")]:
            sec["rows"].append([
                fields[0], address.strip("[]"), port, name, int(pid) if pid else "",
                cgroup_unit(proc, pid) if pid else "", name or "other-user/unknown",
                str(labels.get(str(port), "")),
            ])
    error_row(sec, problem)
    sec["rows"].sort(key=lambda row: (row[2] if isinstance(row[2], int) else -1, str(row[1])))
    return sec, ports, problem


def list_units(user, notes):
    argv = ["systemctl"] + (["--user"] if user else [])
    output, problem = run(argv + ["list-units", "--all", "--plain", "--no-legend", "--type=service,timer" if user else "--type=service"], notes)
    units = []
    for line in output.splitlines():
        fields = line.lstrip(" ●*\t").split(None, 4)
        if len(fields) >= 4:
            units.append(fields[:4] + [redact(fields[4])[:80] if len(fields) == 5 else ""])
    return units, problem


def user_services(config):
    sec = section("User services", ["Unit", "Load", "Active", "Sub", "Description"])
    units, problem = list_units(True, sec["notes"])
    prefixes = [p for p in config_list(config, "collapse_prefixes", sec["notes"]) if isinstance(p, str) and p]
    grouped = {}
    rows = []
    for unit in units:
        prefix = next((p for p in prefixes if unit[0].startswith(p)), None)
        if prefix:
            grouped.setdefault(prefix, []).append(unit)
        else:
            rows.append((unit[2] == "failed", unit))
    for prefix, members in grouped.items():
        def counts(index):
            return ", ".join("{}={}".format(k, v) for k, v in sorted(Counter(u[index] for u in members).items()))
        states = Counter(u[2] + "/" + u[3] for u in members)
        state_counts = ", ".join("{}={}".format(k, v) for k, v in sorted(states.items()))
        rows.append((any(u[2] == "failed" for u in members), [prefix + "*", counts(1), counts(2), state_counts, "{} units".format(len(members))]))
    sec["rows"] = [row for failed, row in sorted(rows, key=lambda item: (not item[0], item[1][0]))]
    error_row(sec, problem)
    return sec, units, problem


def process_names(notes):
    output, problem = run(["ps", "-eo", "pid,comm"], notes)
    processes = []
    for line in output.splitlines():
        fields = line.split(None, 1)
        if len(fields) == 2 and fields[0].isdigit():
            processes.append((int(fields[0]), fields[1]))
    return processes, problem


def system_services(config, processes, ps_problem):
    sec = section("System services of interest", ["Unit / process", "Active", "Sub", "Expected"])
    units, problem = list_units(False, sec["notes"])
    interest = patterns(config_list(config, "system_patterns", sec["notes"], DEFAULT_SYSTEM_PATTERNS), sec["notes"])
    expected = patterns(config_list(config, "stopped_expected", sec["notes"]), sec["notes"])
    for unit in sorted(units, key=lambda u: (u[2] != "failed", u[0])):
        stopped = any(p.search(unit[0]) for p in expected)
        if stopped or any(p.search(unit[0]) for p in interest):
            flag = ("stopped (expected)" if unit[2] in ("inactive", "failed") else "RUNNING (expected stopped)") if stopped else ""
            sec["rows"].append([unit[0], unit[2], unit[3], flag])
    for pattern in expected:
        if any(pattern.search(u[0]) for u in units):
            continue
        matches = [(pid, name) for pid, name in processes if pattern.search(name) or pattern.search(name + ".service")]
        for pid, name in matches:
            sec["rows"].append(["{} (pid {})".format(name, pid), "running", "process", "RUNNING (expected stopped)"])
        if not matches:
            sec["rows"].append([pattern.pattern, ps_problem or "not found", "", "unknown" if ps_problem else "stopped (expected)"])
    error_row(sec, problem)
    return sec, units, problem


def tmux_sessions():
    sec = section("tmux sessions", ["Name", "Windows", "Attached", "Last activity"])
    output, problem = run(["tmux", "ls", "-F", "#{session_name}\t#{session_windows}\t#{session_attached}\t#{session_activity}"], sec["notes"])
    for line in output.splitlines():
        fields = line.split("\t")
        if len(fields) != 4:
            continue
        try:
            timestamp = datetime.fromtimestamp(int(fields[3]), timezone.utc).isoformat().replace("+00:00", "Z")
            sec["rows"].append([fields[0], int(fields[1]), int(fields[2]), timestamp])
        except (ValueError, OSError, OverflowError):
            sec["notes"].append("Invalid tmux session ignored")
    error_row(sec, problem)
    return sec


def components(config, units, unit_problem, processes, ps_problem, ports, port_problem):
    sec = section("Named components", ["Name", "Unit state", "Process PIDs", "Port listening", "Status"])
    for component in config_list(config, "components", sec["notes"]):
        if not isinstance(component, dict):
            sec["notes"].append("Invalid component ignored")
            continue
        unit_state = pids = port_state = status = ""
        if "unit" in component:
            regexes = patterns([component["unit"]], sec["notes"])
            matches = [u for u in units if any(p.search(u[0]) for p in regexes)]
            unit_state = "; ".join("{}: {}/{}".format(u[0], u[2], u[3]) for u in matches) or unit_problem or "not found"
        if "process" in component:
            regexes = patterns([component["process"]], sec["notes"])
            pids = ", ".join(str(pid) for pid, name in processes if any(p.search(name) for p in regexes)) or ps_problem or "none"
        if "port" in component:
            port = component["port"]
            if isinstance(port, int) and not isinstance(port, bool) and 0 <= port <= 65535:
                port_state = port_problem or ("yes" if port in ports else "no")
            else:
                sec["notes"].append("Invalid component port ignored")
        if "status_cmd" in component:
            argv = component["status_cmd"]
            if isinstance(argv, list) and argv and all(isinstance(arg, str) and arg and "\0" not in arg for arg in argv):
                output, problem = run(argv, sec["notes"])
                status = problem or (output.splitlines()[0] if output.splitlines() else "")
            else:
                sec["notes"].append("Invalid status_cmd ignored")
        sec["rows"].append([str(component.get("name", "unnamed")), unit_state, pids, port_state, status])
    return sec


def top_processes():
    sec = section("Top processes", ["PID", "User", "Process", "CPU %", "MEM %", "RSS KiB"])
    output, problem = run(["ps", "-eo", "pid,user,comm,%cpu,%mem,rss", "--sort=-rss"], sec["notes"])
    current_user = pwd.getpwuid(os.getuid()).pw_name
    for line in output.splitlines():
        fields = line.split()
        if len(fields) < 6 or not fields[0].isdigit():
            continue
        try:
            # comm can contain spaces: the final three fields are always numeric.
            sec["rows"].append([int(fields[0]), fields[1] if fields[1] == current_user else "other", " ".join(fields[2:-3]), float(fields[-3]), float(fields[-2]), int(fields[-1])])
        except ValueError:
            continue
    sec["rows"] = sorted(sec["rows"], key=lambda row: -row[-1])[:10]
    error_row(sec, problem)
    return sec


def markdown(data):
    def cell(value):
        return str(value).replace("\\", "\\\\").replace("|", "\\|").replace("\r", "").replace("\n", "<br>")
    lines = ["# " + data["tool"], "", "Generated: {} · Host: {}".format(data["generated"], data["host"])]
    for sec in data["sections"]:
        lines += ["", "## " + sec["title"], "", "| " + " | ".join(map(cell, sec["columns"])) + " |", "| " + " | ".join("---" for _ in sec["columns"]) + " |"]
        lines += ["| " + " | ".join(map(cell, row)) + " |" for row in sec["rows"]]
        lines += ["", *["- " + cell(note) for note in sec["notes"]]]
    lines += ["- " + cell(note) for note in data["notes"]]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    output = parser.add_mutually_exclusive_group()
    output.add_argument("--json", action="store_true", help="emit the generic sections JSON object")
    output.add_argument("--md", action="store_true", help="emit Markdown tables (default)")
    parser.add_argument("--config", metavar="FILE")
    parser.add_argument("--home", default=os.environ.get("HOME", str(Path.home())), metavar="DIR")
    args = parser.parse_args()
    notes = []
    config = load_config(args, notes)
    proc = Path(os.environ.get("SERVERS_PROC", "/proc"))
    resource_section = resources(args.home, proc, config)
    port_section, ports, port_problem = listening(proc, config)
    user_section, user_units, user_problem = user_services(config)
    processes, ps_problem = process_names(notes)
    system_section, system_units, system_problem = system_services(config, processes, ps_problem)
    data = sanitize({
        "tool": "servers", "generated": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "host": socket.gethostname(),
        "sections": [resource_section, port_section, user_section, system_section, tmux_sessions(),
                     components(config, user_units + system_units, user_problem or system_problem,
                                processes, ps_problem, ports, port_problem), top_processes()],
        "notes": notes,
    })
    print(json.dumps(data, ensure_ascii=False) if args.json else markdown(data))


if __name__ == "__main__":
    main()
