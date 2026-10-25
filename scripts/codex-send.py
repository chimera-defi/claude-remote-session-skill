#!/usr/bin/env python3
"""Send once to a local Codex desktop thread, with a durable message-free audit."""

from __future__ import annotations

import argparse
import hashlib
import importlib
import json
import os
import re
import shutil
import socket
import sqlite3
import stat
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

QUEUE_RE = re.compile(r"Queued message ([0-9a-fA-F-]+) for thread ([0-9a-fA-F-]+)\.")
SAFE_ENV = ("HOME", "USER", "LOGNAME", "PATH", "LANG", "LC_ALL", "LC_CTYPE", "SHELL", "TERM", "TZ", "CODEX_HOME")


def load_config() -> None:
    home = os.environ.get("CRSS_HOME") or str(
        Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "crss")
    os.environ["CRSS_HOME"] = home
    try:
        with (Path(home) / "config.sh").open(encoding="utf-8", newline="") as source:
            for line in source:
                match = re.fullmatch(r"(CRSS_[A-Z0-9_]+)=(.*)", line.removesuffix("\n").removesuffix("\r"))
                if not match:
                    continue
                key, value = match.groups()
                if len(value) >= 2 and value[0] in "\"'" and value[-1] == value[0]:
                    value = value[1:-1]
                os.environ.setdefault(key, value)
    except OSError:
        pass


def select_bridge() -> Any:
    path = os.environ.get("CRSS_CODEX_BRIDGE_PATH")
    module = os.environ.get("CRSS_CODEX_BRIDGE_MODULE")
    if path and module:
        sys.path.insert(0, path)
        sys.dont_write_bytecode = True  # Treat the configured checkout as read-only.
        try:
            bridge = importlib.import_module(module)
            if not all(callable(getattr(bridge, key, None)) for key in
                       ("list_sessions", "session_status", "send_message")):
                raise AttributeError("bridge functions missing")
            return bridge
        except Exception as exc:
            print(f"codex-send: configured bridge {module} unavailable ({type(exc).__name__}); using fallback", file=sys.stderr)
    return None


def utc(seconds: float | None = None) -> str:
    return (datetime.now(timezone.utc) if seconds is None else
            datetime.fromtimestamp(seconds, timezone.utc)).isoformat()


class Audit:
    def __init__(self, bridge: str, ref: str, expected: str | None, message: str) -> None:
        self.message = message
        self.base = dict(bridge=bridge, destination_ref=ref, destination_identity="",
                         expected_destination_identity=expected or "",
                         normalized_message_sha256=hashlib.sha256(message.encode()).hexdigest(),
                         message_chars=len(message), outcome="REJECTED", queue_uncertain=False,
                         queued_message_id="", error="")

    def write(self, record: dict[str, Any]) -> None:
        # Whitelist fields: a bridge must never accidentally persist message text.
        row = {**self.base, **{key: value for key, value in record.items() if key in self.base}}
        row.update(ts=utc(), bridge=self.base["bridge"],
                   expected_destination_identity=self.base["expected_destination_identity"],
                   normalized_message_sha256=self.base["normalized_message_sha256"],
                   message_chars=self.base["message_chars"])
        error = str(row["error"] or "")
        row["error"] = error.replace(self.message, "[message]")[:256] if self.message else error[:256]
        directory = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state") / "crss"
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(directory, 0o700)
        fd = os.open(directory / "codex-send.jsonl", os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as target:
            os.fchmod(target.fileno(), 0o600)
            target.write(json.dumps(row, ensure_ascii=False) + "\n")
            target.flush()
            os.fsync(target.fileno())

    def best_effort(self, record: dict[str, Any]) -> None:
        try:
            self.write(record)
        except Exception as exc:
            print(f"codex-send: audit unavailable ({exc}) bridge={self.base['bridge']}", file=sys.stderr)


def fallback_rows(limit: int | None = None) -> list[dict[str, Any]]:
    home = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex").expanduser()
    uri = (home / "state_5.sqlite").resolve().as_uri() + "?mode=ro"
    con = sqlite3.connect(uri, uri=True)
    try:
        con.row_factory = sqlite3.Row
        con.execute("PRAGMA query_only=ON")
        query = "SELECT id,name,cwd,updated_at FROM threads WHERE archived=0 ORDER BY updated_at DESC, id DESC"
        rows = con.execute(query + (" LIMIT ?" if limit else ""), (limit,) if limit else ()).fetchall()
    finally:
        con.close()
    result = []
    for raw in rows:
        row = dict(raw)
        payload = json.dumps(dict(uuid=row["id"], name=row["name"], cwd=row["cwd"]),
                             sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        row.update(session_ref="cs-" + hashlib.sha256(row["id"].encode()).hexdigest()[:32],
                   destination_identity="codex-dst-sha256-" + hashlib.sha256(payload.encode()).hexdigest())
        result.append(row)
    return result


def resolve(ref: str) -> dict[str, Any]:
    for row in fallback_rows():
        if row["session_ref"] == ref:
            return row
    raise RuntimeError("active Codex thread not found")


def mismatch_message(expected: str, row: dict[str, Any]) -> str:
    return (f"identity mismatch: expected {expected}, current {row['destination_identity']} "
            f"name={row.get('name') or '-'} cwd={row.get('cwd')}; "
            "re-run session-send codex:list and confirm")


def report_error(exc: Exception, bridge: str, uncertain: bool) -> int:
    print(f"codex-send: {'UNCERTAIN' if uncertain else 'REFUSED'} bridge={bridge}: "
          f"{exc} {getattr(exc, 'code', '')}".rstrip(), file=sys.stderr)
    if uncertain:
        print(f"codex-send: do NOT resend; check the thread, or wait for its bus reply bridge={bridge}", file=sys.stderr)
    return 1 if uncertain else 2


def module_send(bridge: Any, args: argparse.Namespace, message: str, audit: Audit) -> int:
    pending = False
    last_outcome = ""
    mismatch = False
    current: dict[str, Any] = {}

    def sink(record: dict[str, Any]) -> None:
        nonlocal pending, last_outcome, mismatch, current
        last_outcome = record.get("outcome", last_outcome)
        is_pending = record.get("outcome") == "DISPATCH_PENDING"
        if is_pending:
            pending = True
            current = {**current, **record}
        if is_pending and args.expect_identity and record.get("destination_identity") != args.expect_identity:
            mismatch = True
        # The module invokes this again on its exception path; only pending may raise.
        if is_pending:
            audit.write(record)
            if mismatch:
                audit.write({**record, "outcome": "REFUSED_IDENTITY_MISMATCH", "queue_uncertain": False})
                raise RuntimeError("destination identity changed before dispatch")
        else:
            if mismatch:
                record = {**record, "outcome": "REFUSED_IDENTITY_MISMATCH", "queue_uncertain": False}
            audit.best_effort(record)

    try:
        if args.expect_identity:
            current = bridge.session_status(args.ref)["session"]
            if current["destination_identity"] != args.expect_identity:
                audit.write({"destination_identity": current["destination_identity"],
                             "outcome": "REFUSED_IDENTITY_MISMATCH"})
                return report_error(RuntimeError(mismatch_message(args.expect_identity, current)), "module", False)
        result = bridge.send_message(args.ref, message, caller_origin=args.origin, audit_sink=sink)
    except Exception as exc:
        if mismatch:
            try:
                current = bridge.session_status(args.ref)["session"]
            except Exception:
                pass
            detail = f"{mismatch_message(args.expect_identity, current)}; {exc} {getattr(exc, 'code', '')}"
            return report_error(RuntimeError(detail), "module", False)
        record = getattr(exc, "codex_audit", None)
        uncertain = bool(record.get("queue_uncertain") or record.get("outcome") == "UNKNOWN") if record is not None else pending
        audit.best_effort({**(record or {}), "outcome": (record or {}).get("outcome", "UNKNOWN" if uncertain else "REJECTED"),
                           "queue_uncertain": uncertain, "error": f"{exc} {getattr(exc, 'code', '')}"})
        return report_error(exc, "module", uncertain)
    print(f"codex-send: {result['observed_state']} bridge=module ref={args.ref} "
          f"name={result['session'].get('name') or '-'} queued_message_id={result['queued_message_id']} "
          f"evidence={','.join(result.get('observed_state_evidence', []))}")
    for warning in result.get("warnings", []):
        print(f"codex-send: {warning} bridge=module", file=sys.stderr)
    return 0


def fallback_send(args: argparse.Namespace, message: str, audit: Audit) -> int:
    record: dict[str, Any] = {}
    try:
        row = resolve(args.ref)
        record["destination_identity"] = row["destination_identity"]
        if args.expect_identity and row["destination_identity"] != args.expect_identity:
            record["outcome"] = "REFUSED_IDENTITY_MISMATCH"
            raise RuntimeError(mismatch_message(args.expect_identity, row))
        sock = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex").expanduser() / "app-server-control/app-server-control.sock"
        if not stat.S_ISSOCK(sock.stat().st_mode):
            raise RuntimeError("Codex control endpoint is not a socket; not sent")
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
            probe.settimeout(0.5)
            probe.connect(str(sock))
        audit.write({**record, "outcome": "DISPATCH_PENDING", "queue_uncertain": True})
        if resolve(args.ref)["destination_identity"] != row["destination_identity"]:
            raise RuntimeError("destination identity changed before queue; not sent; re-run session-send codex:list and confirm")
    except Exception as exc:
        audit.best_effort({**record, "error": str(exc)})
        return report_error(RuntimeError(f"{exc}; not sent"), "fallback", False)

    output: str | bytes = ""
    warning = False
    error = ""
    try:
        binary = os.environ.get("CRSS_CODEX_BIN") or shutil.which("codex")
        if not binary:
            raise OSError("codex binary unavailable")
        proc = subprocess.run([binary, "queue", "--remote", "unix://" + str(sock),
                               "--thread", row["id"], "--message", message],
                              capture_output=True, text=True, errors="replace", timeout=20,
                              env={key: os.environ[key] for key in SAFE_ENV if key in os.environ}, check=False)
        output = proc.stdout or ""
        warning = proc.returncode != 0
    except subprocess.TimeoutExpired as exc:
        output = exc.stdout or ""
        warning = True
        error = "queue timed out"
    except (OSError, subprocess.SubprocessError, UnicodeError) as exc:
        error = str(exc)
    if isinstance(output, bytes):
        output = output.decode("utf-8", errors="replace")
    matches = list(QUEUE_RE.finditer(output))
    matched = len(matches) == 1 and matches[0][2].lower() == row["id"].lower()
    record.update(outcome="QUEUED" if matched else "UNKNOWN", queue_uncertain=not matched,
                  queued_message_id=matches[0][1] if len(matches) == 1 else "",
                  error=error if not matched else "")
    audit.best_effort(record)
    if not matched:
        return report_error(RuntimeError(error or "no unique matching queue receipt"), "fallback", True)
    if warning:
        print("codex-send: receipt matched despite a nonzero exit or timeout; do not resend bridge=fallback", file=sys.stderr)
    print(f"codex-send: QUEUED bridge=fallback ref={args.ref} name={row.get('name') or '-'} "
          f"queued_message_id={record['queued_message_id']} (receipt only; acceptance not observed)")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("list", "send"))
    command, remaining = parser.parse_known_args()
    listing = argparse.ArgumentParser(prog=f"{parser.prog} list")
    listing.add_argument("--limit", type=int, default=20)
    listing.add_argument("--json", action="store_true")
    sending = argparse.ArgumentParser(prog=f"{parser.prog} send")
    sending.add_argument("ref")
    sending.add_argument("--expect-identity")
    sending.add_argument("--origin", default="crss codex-send")
    sending.add_argument("message", nargs="?")
    sending.add_argument("--file", type=Path)
    child = listing if command.command == "list" else sending
    args = child.parse_intermixed_args(remaining)
    args.command = command.command
    if args.command == "send" and (args.message is None) == (args.file is None):
        sending.error("provide exactly one of message or --file")
    if args.command == "list" and not 1 <= args.limit <= 100:
        parser.error("--limit must be from 1 to 100")
    load_config()
    bridge = select_bridge()
    kind = "module" if bridge else "fallback"
    try:
        if args.command == "list":
            rows = bridge.list_sessions(args.limit)["sessions"] if bridge else fallback_rows(args.limit)
            rows = [dict(session_ref=row["session_ref"], name=row.get("name") or "-", cwd=row["cwd"],
                         updated=utc(row["updated_at"]), destination_identity=row["destination_identity"], bridge=kind)
                    for row in rows]
            if args.json:
                print(json.dumps(rows, ensure_ascii=False))
            else:
                print("session_ref\tname\tcwd\tupdated\tdestination_identity\tbridge")
                for row in rows:
                    print("\t".join(str(value) for key, value in row.items() if key != "bridge") + f"\tbridge={kind}")
            return 0
        if not re.fullmatch(r"cs-[0-9a-f]{32}", args.ref):
            raise ValueError("bad ref: expected cs- followed by 32 lowercase hex characters")
        message = (args.file.read_text(encoding="utf-8") if args.file else args.message).strip()
        if not message or len(message) > 4000 or "\x00" in message:
            raise ValueError("message must contain 1..4000 characters and no NUL")
    except Exception as exc:
        return report_error(exc, kind, False)
    audit = Audit(kind, args.ref, args.expect_identity, message)
    return module_send(bridge, args, message, audit) if bridge else fallback_send(args, message, audit)


if __name__ == "__main__":
    sys.exit(main())
