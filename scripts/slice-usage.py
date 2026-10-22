#!/usr/bin/env python3
"""Measure per-slice token usage for Claude Code JSONL and Codex `exec --json` logs.
Reports token counts and wall time; it does not estimate dollar figures.
Reads a Claude transcript, its subagent JSONL files, and optional Codex logs.
"""

from __future__ import annotations

import argparse
import json
from datetime import datetime
from pathlib import Path
from typing import Any


FIELDS = ("slice", "model", "calls", "uncached_in", "cache_write", "cache_read", "out", "wall_s")


def _read_lines(path: Path) -> list[dict[str, Any]]:
    rows = []
    try:
        with path.open("r", encoding="utf-8") as handle:
            for line in handle:
                try:
                    value = json.loads(line)
                except (json.JSONDecodeError, UnicodeDecodeError):
                    continue
                if isinstance(value, dict):
                    rows.append(value)
    except OSError:
        return []
    return rows


def _timestamp(value: Any) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def _wall_seconds(rows: list[dict[str, Any]]) -> float | None:
    timestamps = [_timestamp(row.get("timestamp")) for row in rows if "timestamp" in row]
    timestamps = [value for value in timestamps if value is not None]
    if len(timestamps) < 2:
        return 0.0 if timestamps else None
    # Span of the slice, idle time included; rows are not always in time order.
    return (max(timestamps) - min(timestamps)).total_seconds()


def _blank(slice_name: str, model: str, wall_s: float | None) -> dict[str, Any]:
    return {
        "slice": slice_name,
        "model": model,
        "calls": 0,
        "uncached_in": 0,
        "cache_write": 0,
        "cache_read": 0,
        "out": 0,
        "wall_s": wall_s,
    }


def _claude_slice(path: Path, slice_name: str) -> list[dict[str, Any]]:
    rows = _read_lines(path)
    wall_s = _wall_seconds(rows)
    messages: dict[str, tuple[str, dict[str, Any]]] = {}
    for row in rows:
        message = row.get("message")
        if row.get("type") != "assistant" or not isinstance(message, dict):
            continue
        message_id = message.get("id")
        model = message.get("model")
        usage = message.get("usage")
        # "<synthetic>" rows are CLI error placeholders, not API calls.
        if not isinstance(message_id, str) or not isinstance(model, str) or model == "<synthetic>" or not isinstance(usage, dict):
            continue
        messages[message_id] = (model, usage)

    by_model: dict[str, dict[str, Any]] = {}
    for model, usage in messages.values():
        row = by_model.setdefault(model, _blank(slice_name, model, wall_s))
        row["calls"] += 1
        row["uncached_in"] += int(usage.get("input_tokens", 0) or 0)
        row["cache_write"] += int(usage.get("cache_creation_input_tokens", 0) or 0)
        row["cache_read"] += int(usage.get("cache_read_input_tokens", 0) or 0)
        row["out"] += int(usage.get("output_tokens", 0) or 0)
    return list(by_model.values())


def _model_in(value: Any) -> str | None:
    if not isinstance(value, dict):
        return None
    model = value.get("model")
    if isinstance(model, str):
        return model
    for key in ("item", "payload"):
        found = _model_in(value.get(key))
        if found:
            return found
    return None


def _codex_slice(path: Path) -> list[dict[str, Any]]:
    rows = _read_lines(path)
    model = next((_model_in(row) for row in rows if _model_in(row)), "codex")
    wall_s = _wall_seconds(rows)
    result = _blank(f"codex:{path.stem}", model, wall_s)
    for row in rows:
        # One prompt per `codex exec` log; a resumed thread may carry earlier turns' totals.
        if row.get("type") != "turn.completed" or not isinstance(row.get("usage"), dict):
            continue
        usage = row["usage"]
        cached = int(usage.get("cached_input_tokens", 0) or 0)
        result["calls"] += 1
        result["uncached_in"] += int(usage.get("input_tokens", 0) or 0) - cached
        result["cache_read"] += cached
        result["cache_write"] += int(usage.get("cache_write_input_tokens", 0) or 0)
        result["out"] += int(usage.get("output_tokens", 0) or 0)
    return [result] if result["calls"] else []


def collect(claude_path: Path, codex_paths: list[Path]) -> list[dict[str, Any]]:
    rows = _claude_slice(claude_path, "orchestrator")
    subagents = claude_path.with_suffix("") / "subagents"
    if subagents.is_dir():
        for path in sorted(subagents.glob("agent-*.jsonl")):
            rows.extend(_claude_slice(path, path.stem))
    for path in codex_paths:
        rows.extend(_codex_slice(path))

    totals: dict[str, dict[str, Any]] = {}
    for row in rows:
        total = totals.setdefault(row["model"], _blank("TOTAL", row["model"], None))
        for key in ("calls", "uncached_in", "cache_write", "cache_read", "out"):
            total[key] += row[key]
    return rows + [totals[model] for model in sorted(totals)]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("claude_session", type=Path)
    parser.add_argument("--codex", action="extend", nargs="+", type=Path, default=[])
    parser.add_argument("--json", action="store_true", dest="as_json")
    args = parser.parse_args(argv)
    rows = collect(args.claude_session, args.codex)
    if args.as_json:
        print(json.dumps([{key: row[key] for key in FIELDS} for row in rows], sort_keys=True))
        return 0

    print(" ".join(FIELDS))
    for row in rows:
        values = [str(row[key]) if row[key] is not None else "null" for key in FIELDS]
        print(" ".join(values))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
