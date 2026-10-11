#!/usr/bin/env bash
# telemetry-report.sh — summarize artifacts/telemetry/events.jsonl: spawn
# count and the global-skills-catalog size trend (the context-bloat proxy
# record-spawn-telemetry.sh captures on every spawn).
#   telemetry-report.sh --kids [--of <name|uuid>] [--limit N]   # this launcher's children (live/reaped/gone), brief, final report, transcript, next action; report only
set -uo pipefail

# ── Host-local overlay config ────────────────────────────────────────────────
# See examples/crss-overlay/README.md. Parses (never sources) $CRSS_HOME/config.sh
# for CRSS_* vars; an env var already set wins over the file; a missing/unreadable
# file is fine (generic defaults below apply). Copied verbatim in every script
# that reads overlay config — see tests/test-crss-overlay-config.sh.
# CRSS-CONFIG-LOADER-START
_crss_load_config() {
  local _crss_home _crss_cfg _crss_line _crss_key _crss_val
  _crss_home="${CRSS_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/crss}"
  export CRSS_HOME="$_crss_home"
  _crss_cfg="$_crss_home/config.sh"
  [ -r "$_crss_cfg" ] || return 0
  while IFS= read -r _crss_line || [ -n "$_crss_line" ]; do
    [[ "$_crss_line" =~ ^(CRSS_[A-Z0-9_]+)=(.*)$ ]] || continue
    _crss_key="${BASH_REMATCH[1]}"
    _crss_val="${BASH_REMATCH[2]}"
    _crss_val="${_crss_val%$'\r'}"
    case "$_crss_val" in
      \"*\") _crss_val="${_crss_val#\"}"; _crss_val="${_crss_val%\"}" ;;
      \'*\') _crss_val="${_crss_val#\'}"; _crss_val="${_crss_val%\'}" ;;
    esac
    if [ -z "${!_crss_key+x}" ]; then export "${_crss_key}=${_crss_val}"; fi
  done < "$_crss_cfg"
  return 0
}
_crss_load_config
# CRSS-CONFIG-LOADER-END
: "${CRSS_WORKSPACE:=$HOME/workspace}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# See record-spawn-telemetry.sh for why the fallback is derived from
# CRSS_WORKSPACE (host-local overlay, see examples/crss-overlay/) rather than
# from $SCRIPT_DIR: this script is also deployed as a flat copy to
# ~/.local/bin, where git rev-parse has nothing to find and a fallback
# derived from the deployed location would silently point at the wrong
# directory. "claude-remote-session-skill" is this project's own repo name,
# not a host-specific value.
REPO_ROOT="${TELEMETRY_ROOT:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$CRSS_WORKSPACE/claude-remote-session-skill")}"
EVENTS_FILE="$REPO_ROOT/artifacts/telemetry/events.jsonl"

MODE=summary; ME_NAME=""; ME_ID=""; OF=""; LIMIT=25
while [ "$#" -gt 0 ]; do
  case "$1" in
    --kids) MODE=kids; shift ;;
    --of) OF="${2:?--of needs a name or uuid}"; shift 2 ;;
    --limit) LIMIT="${2:?--limit needs a number}"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
if ! [[ "$LIMIT" =~ ^[0-9]+$ ]]; then echo "--limit needs a non-negative integer" >&2; exit 2; fi
LIVE=""
if [ "$MODE" = kids ]; then
  if [ -z "$OF" ]; then
    ME="$("$SCRIPT_DIR/record-spawn-telemetry.sh" --whoami 2>/dev/null || true)"
    ME_NAME="${ME%%$'\t'*}"; ME_ID="${ME#*$'\t'}"
  fi
  LIVE="$(tmux list-sessions -F '#S' 2>/dev/null || true)"
fi
CLAUDE_HOME="${CRSS_CLAUDE_HOME:-$HOME/.claude}"
UNIT_DIR="${CRSS_UNIT_DIR:-$HOME/.config/systemd/user}"
STARTS_LOG="${CRSS_SESSIONS_DIR:-$HOME/.sessions}/session-starts.log"
if [ ! -f "$EVENTS_FILE" ] && [ "$MODE" != kids ]; then
  echo "No telemetry yet: $EVENTS_FILE does not exist."
  exit 0
fi

CRSS_LIVE_SESSIONS="$LIVE" python3 - "$EVENTS_FILE" "$MODE" "$ME_NAME" "$ME_ID" "$OF" "$LIMIT" "$CLAUDE_HOME" "$UNIT_DIR" "$STARTS_LOG" <<'PYEOF'
import json, sys, os, re, glob

path = sys.argv[1]
events = []
with (open(path, encoding="utf-8") if os.path.exists(path) else open(os.devnull)) as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue

spawns = [e for e in events if e.get("event", "spawn") == "spawn"]
reaps = [e for e in events if e.get("event") == "reap"]
events = spawns
# Per-tier outcomes. A tmux name (<prefix>_x-0056) and a registry/remote name
# (<prefix>-x-0056) are the same session; normalize both sides of the join. Spawns with
# no routing field, and reaps with no matching spawn, land in "none" / unmatched.
import datetime, statistics
def norm(n): return (n or "").lower().replace("_", "-")
def ts(e):
    try:
        d = datetime.datetime.fromisoformat(e["timestamp"])
        return d if d.tzinfo else d.replace(tzinfo=datetime.timezone.utc)
    except Exception: return None
by_session = {}
for e in spawns:
    for k in {norm(e.get("session")), norm(e.get("remote_name"))} - {""}:
        by_session.setdefault(k, []).append(e)
rows, unmatched, used, reap_of = {}, 0, set(), {}
for r in sorted(reaps, key=lambda x: x.get("timestamp") or ""):
    # A name can be reused: pair a reap with the latest not-yet-paired spawn of that
    # name that started at or before it, never with a later respawn.
    t1 = ts(r)
    cands = [sp for sp in by_session.get(norm(r.get("session")), [])
             if id(sp) not in used and (t1 is None or ts(sp) is None or ts(sp) <= t1)]
    sp = max(cands, key=lambda x: x.get("timestamp") or "") if cands else None
    if sp is None:
        unmatched += 1
        continue
    used.add(id(sp))
    reap_of[id(sp)] = r
    tier = (sp.get("routing") or {}).get("tier") or "none"
    row = rows.setdefault(tier, {"n": 0, "forced": 0, "clean": 0, "life": [], "out": {}})
    row["n"] += 1
    row["forced"] += 1 if r.get("forced") else 0
    row["clean"] += 1 if r.get("clean") == "yes" else 0
    t0 = ts(sp)
    if t0 and t1: row["life"].append((t1 - t0).total_seconds() / 60)
    o = r.get("outcome", "unknown")
    row["out"][o] = row["out"].get(o, 0) + 1
# Kids use the same spawn/reap pairing as the summary, without summary output.
mode, me_name, me_id, of, limit, claude_home, unit_dir, starts_log = sys.argv[2:10]
def content(e):
    c = (e.get("message") or {}).get("content", "")
    if isinstance(c, str): return c
    return next((b.get("text", "") for b in c if b.get("type") == "text"), "") if isinstance(c, list) else ""
def tidy(text): return re.sub(r"\s+", " ", text).strip()
def brief(fn):
    total = 0
    with open(fn, "rb") as fh:
        for line in fh:
            total += len(line)
            if total > 8 * 1024 * 1024: break
            try: e = json.loads(line)
            except ValueError: continue
            if (e.get("type") != "user" or e.get("isMeta") or e.get("isCompactSummary")
                or (e.get("origin") or {}).get("kind") == "task-notification" or "toolUseResult" in e): continue
            text = content(e).strip()
            # Same command/artifact exclusions as idle-report in session-doctor;
            # the end-to-end fixture pins the genuine first brief.
            if text.startswith(("<command-name>", "<local-command-stdout>")) or text == "/compact": continue
            text = re.sub(r"<task-notification\b[^>]*>.*?</task-notification>", "", text, flags=re.S)
            text = tidy(re.sub(r"</?pasted_content\b[^>]*>", "", text))
            if text: return text
    return ""
def tail_report(fn):
    size = os.path.getsize(fn)
    for window in (262144, 2 * 1024 * 1024):
        final = fallback = summary = title = ""
        with open(fn, "rb") as fh:
            offset = max(0, size - window); fh.seek(offset)
            if offset: fh.readline()  # discard a partial first line
            for line in fh:
                try: e = json.loads(line)
                except ValueError: continue
                text = content(e)
                blocks = (e.get("message") or {}).get("content")
                if e.get("type") == "assistant" and isinstance(blocks, list):
                    text = " ".join(b.get("text", "") for b in blocks if b.get("type") == "text" and b.get("text"))
                text = tidy(text)
                if e.get("type") == "assistant" and text:
                    fallback = text
                    if (e.get("message") or {}).get("stop_reason") == "end_turn": final = text
                elif e.get("type") == "user" and e.get("isCompactSummary") and text: summary = text
                elif e.get("type") == "ai-title": title = e.get("aiTitle") or ""
        if final or fallback or summary or not offset: break
    return (final or fallback or summary, "end_turn" if final else "mid-turn" if fallback else "compact-summary" if summary else "none", title)
def short(text, n): return text[:n-1] + "…" if len(text) > n else text
def stamp(e):
    t = ts(e)
    return t.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%MZ") if t else "?"
def kids():
    me, want = norm(me_name), norm(of)
    if not (me or me_id or want):
        print("telemetry-report.sh --kids: no launcher identity (not in tmux, no CLAUDE_CODE_SESSION_ID); pass --of <name|uuid>", file=sys.stderr)
        sys.exit(2)
    matches = []
    for sp in spawns:
        la = sp.get("launcher") or {}
        if (want in {norm(la.get("name")), la.get("session_id", "").lower()} if want else
            (me and norm(la.get("name")) == me) or (me_id and la.get("session_id") == me_id)):
            matches.append(sp)
    matches = sorted(matches, key=lambda e: e.get("timestamp") or "", reverse=True)[:int(limit)]
    live = {norm(x) for x in os.environ.get("CRSS_LIVE_SESSIONS", "").splitlines() if x}
    def state(sp):
        return "LIVE" if {norm(sp.get("session")), norm(sp.get("remote_name"))} & live else "REAPED" if id(sp) in reap_of else "GONE"
    label = f"name={of or me_name or '-'} id={me_id[:8] or '-'}"
    if not matches:
        print(f"no spawn events attributed to launcher {label} (events before launcher recording are unattributed; try --of)")
        return
    counts = [sum(state(sp) == x for sp in matches) for x in ("LIVE", "REAPED", "GONE")]
    print(f"=== kids of launcher {label} : {len(matches)} matched ({counts[0]} live, {counts[1]} reaped, {counts[2]} gone) — report only ===")
    backends = {}
    try:
        with open(starts_log, encoding="utf-8") as fh:
            for line in fh:
                if "event=started" not in line: continue
                session, backend = re.search(r" session=(\S+) ", line), re.search(r"backend=(\S+)", line)
                if session and backend: backends[session[1]] = backend[1]
    except OSError: pass
    for sp in matches:
        session = sp.get("session", ""); base = sp.get("remote_name") or norm(session)
        backend = sp.get("backend") or backends.get(session, "?"); status = state(sp)
        detail = status
        if status == "REAPED":
            r = reap_of[id(sp)]
            detail += f" outcome={r.get('outcome', 'unknown')} clean={r.get('clean', 'unknown')} at {stamp(r)}"
            if r.get("note"): detail += f" note={r['note']}"
        elif status == "GONE": detail += " (no tmux session, no reap event)"
        print(f"{session}  model={sp.get('model', '?')} backend={backend}  spawned={stamp(sp)}  {detail}")
        fn = first = ""; pick = ""; uuid = ""
        proj = os.path.join(claude_home, "projects", re.sub(r"[^A-Za-z0-9]", "-", sp.get("workdir", "")))
        if backend != "codex":
            if status == "LIVE":
                for sf in glob.glob(os.path.join(claude_home, "sessions", "*.json")):
                    try:
                        with open(sf, encoding="utf-8") as fh: meta = json.load(fh)
                        uid = meta.get("sessionId", "")
                        candidate = os.path.join(proj, uid + ".jsonl")
                        if meta.get("tmux", "").startswith(session + ":") and os.path.isfile(candidate):
                            fn = first = candidate; pick = "exact(live)"; break
                    except (OSError, ValueError, TypeError): continue
            if not fn:
                start = ts(sp)
                later = [ts(e) for e in spawns if e.get("workdir") == sp.get("workdir") and ts(e) and start and ts(e) > start]
                end = min(later) if later else None
                candidates = []
                for candidate in glob.glob(os.path.join(proj, "*.jsonl")):
                    try:
                        with open(candidate, encoding="utf-8") as fh:
                            for line in fh:
                                try: e = json.loads(line)
                                except ValueError: continue
                                if "timestamp" not in e: continue
                                t = ts(e)
                                if t and start and t >= start - datetime.timedelta(seconds=120) and (not end or t < end): candidates.append(candidate)
                                break
                    except OSError: continue
                if candidates:
                    candidates.sort(key=os.path.getmtime); first, fn = candidates[0], candidates[-1]
                    pick = f"window({len(candidates)})"
            if fn: uuid = os.path.basename(fn)[:-6]
        report, final, title = tail_report(fn) if fn else ("", "none", "")
        print(f"  title:  {title or '(none)'}")
        print(f"  brief:  {short(brief(first), 200) if first else ''}")
        print(f"  report: {short(report, 400)}  [final={final}]")
        transcript = "n/a (codex backend)" if backend == "codex" else f"{fn} {os.path.getsize(fn)} pick={pick}" if fn else f"not found ({proj})"
        print(f"  transcript: {transcript}")
        if status == "LIVE": print(f"  next: session-send {session} --file <f>")
        elif status == "GONE" and os.path.exists(os.path.join(unit_dir, base + ".service")) and uuid:
            print(f"  next: session-resume {base} --uuid {uuid}")
        else: print(f"  next: unit removed at reap; transcript kept above; more: session-doctor history {base}")
if mode == "kids":
    kids(); sys.exit(0)

print(f"spawns recorded: {len(events)}")
if not events:
    sys.exit(0)

skills_counts = [e.get("meta", {}).get("global_skills_count") for e in events if e.get("meta", {}).get("global_skills_count") is not None]
if skills_counts:
    print(f"global_skills_count: first={skills_counts[0]} latest={skills_counts[-1]} max={max(skills_counts)}")

print("last 5 spawns:")
for e in events[-5:]:
    meta = e.get("meta", {})
    print(f"  {e.get('timestamp')}  {e.get('remote_name')}  type={e.get('type')}  "
          f"skills={meta.get('global_skills_count')}  skills_md_bytes={meta.get('global_skills_md_bytes')}  "
          f"claude_md_bytes={meta.get('claude_md_bytes')}")

print(f"reaps recorded: {len(reaps)} (unmatched to a spawn: {unmatched})")
tiers = {}
for e in spawns:
    t = (e.get("routing") or {}).get("tier") or "none"
    tiers[t] = tiers.get(t, 0) + 1
print("by tier (spawned / reaped / forced / audited-clean / median-life-min / outcomes):")
for t in sorted(tiers):
    row = rows.get(t, {"n": 0, "forced": 0, "clean": 0, "life": [], "out": {}})
    med = f"{statistics.median(row['life']):.0f}" if row["life"] else "-"
    outs = ",".join(f"{k}={v}" for k, v in sorted(row["out"].items())) or "-"
    print(f"  {t:9} {tiers[t]:4} {row['n']:4} {row['forced']:4} {row['clean']:4} {med:>6}  {outs}")
PYEOF
