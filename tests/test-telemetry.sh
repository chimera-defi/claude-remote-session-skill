#!/usr/bin/env bash
# record-spawn-telemetry.sh + telemetry-report.sh end to end: spawn events (best-effort when dirs are missing),
# reap events (outcome allow-list, clean fact), tier lookup, and the report joining reaps to spawns across both
# session-name spellings (unmatched reaps counted, reused names paired with their own spawn).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
isolate_overlay
RECORD="$HERE/../scripts/record-spawn-telemetry.sh"
REPORT="$HERE/../scripts/telemetry-report.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/skills/foo" "$T/skills/bar" "$T/workdir/.claude"
echo "some skill content" > "$T/skills/foo/SKILL.md"
echo "more skill content" > "$T/skills/bar/SKILL.md"
echo "project instructions" > "$T/workdir/.claude/CLAUDE.md"
ev="$T/r/artifacts/telemetry/events.jsonl"
rec() { TELEMETRY_ROOT="$T/r" CLAUDE_SKILLS_DIR="${SKILLS:-$T/skills}" bash "$RECORD" "$@"; }
report() { TELEMETRY_ROOT="$T/r" bash "$REPORT"; }

# spawn events
rec myproj myp px-myp-0101-0000 px_myp-0101-0000 workspace sonnet "$T/workdir" light low "doc typo fix" 600000 >/dev/null
line="$(cat "$ev")"
has "spawn: remote name" "$line" '"remote_name": "px-myp-0101-0000"'
has "spawn: global skills counted" "$line" '"global_skills_count": 2'
has "spawn: CLAUDE.md bytes" "$line" '"claude_md_bytes": 21'
hasre "spawn: routing" "$line" '"routing": \{"compact_window": "600000", "effort": "low", "reason": "doc typo fix", "tier": "light"\}'
CRSS_ESCALATED_FROM=px_l-1 rec myproj myp px-myp-0101-0001 px_myp-0101-0001 workspace sonnet "$T/workdir" standard "" why >/dev/null
has "spawn: appends, records escalated_from" "$(tail -1 "$ev")" '"escalated_from": "px_l-1"'
ok "spawn: second event appended" "$(wc -l < "$ev" | tr -d ' ')" 2
SKILLS="$T/missing" rec other o px-o-0101-0000 px_o-0101-0000 sessions sonnet "$T/no-such-workdir" >/dev/null; rc=$?
ok "missing dirs: best-effort exit 0" "$rc" 0; has "missing dirs: zeroed" "$(tail -1 "$ev")" '"global_skills_count": 0'
rec empty e px-e-0101-0000 px_e-0101-0000 sessions sonnet "" >/dev/null
has "empty workdir does not probe /CLAUDE.md" "$(tail -1 "$ev")" '"claude_md_bytes": 0'
has "report counts spawns" "$(report)" 'spawns recorded: 4'

# reap events
rm -f "$ev"
rec --reap ah_x-0001 yes ok "finish line met"; rec --reap ah_x-0002 no bogus
hasre "reap: event shape" "$(sed -n 1p "$ev")" '"event": "reap".*"forced": true.*"outcome": "ok"'
hasre "reap: unknown outcome collapses to unknown" "$(sed -n 2p "$ev")" '"outcome": "unknown"'
ok "reap: recorder never fails" "$(rec --reap 2>&1; echo $?)" "0"
rec --reap ah_c-1 no ok "" yes; rec --reap ah_c-2 yes ok
ok "reap: only an audited non-forced reap says clean=yes" "$(tail -2 "$ev" | grep -o '"clean": "[a-z]*"' | tr '\n' ' ')" '"clean": "yes" "clean": "unknown" '

# report join: tmux-spelled reap joins a hyphen-spelled spawn and vice versa; no-routing spawn is the "none" row
cat > "$ev" <<'J'
{"event":"spawn","timestamp":"2026-10-05T10:00:00+00:00","session":"ah_a-0001","remote_name":"ah-a-0001","routing":{"tier":"light","effort":"","reason":"x"},"meta":{}}
{"event":"spawn","timestamp":"2026-10-05T10:00:00+00:00","session":"ah_old-0002","remote_name":"ah-old-0002","meta":{}}
{"event":"reap","timestamp":"2026-10-05T10:30:00+00:00","session":"ah-a-0001","forced":false,"outcome":"ok"}
{"event":"reap","timestamp":"2026-10-05T11:00:00+00:00","session":"ah_old-0002","forced":true,"outcome":"unknown"}
{"event":"reap","timestamp":"2026-10-05T11:00:00+00:00","session":"ah_ghost-9","forced":true,"outcome":"unknown"}
J
o="$(report)"
hasre "report: join across spellings" "$o" 'light +1 +1 +0 +0 +30 +ok=1'
hasre "report: none row" "$o" 'none +1 +1 +1 +0 +60 +unknown=1'
has "report: unmatched reap counted" "$o" "unmatched to a spawn: 1"
cat > "$ev" <<'J'
{"event":"spawn","timestamp":"2026-10-05T10:00:00+00:00","session":"ah_r-1","remote_name":"ah-r-1","routing":{"tier":"light"},"meta":{}}
{"event":"reap","timestamp":"2026-10-05T10:10:00+00:00","session":"ah_r-1","forced":false,"outcome":"ok"}
{"event":"spawn","timestamp":"2026-10-05T10:20:00+00:00","session":"ah_r-1","remote_name":"ah-r-1","routing":{"tier":"heavy"},"meta":{}}
{"event":"reap","timestamp":"2026-10-05T10:50:00+00:00","session":"ah-r-1","forced":false,"outcome":"failed"}
J
o="$(report)"
hasre "report: reused name pairs reap with its own spawn (light)" "$o" 'light +1 +1 +0 +0 +10 +ok=1'
hasre "report: reused name pairs reap with its own spawn (heavy)" "$o" 'heavy +1 +1 +0 +0 +30 +failed=1'

# tier lookup across spellings
cat > "$ev" <<'J'
{"event":"spawn","timestamp":"2026-10-05T10:00:00+00:00","session":"ah_e-1","remote_name":"ah-e-1","routing":{"tier":"light"},"meta":{}}
{"event":"spawn","timestamp":"2026-10-05T10:00:00+00:00","session":"ah_e-2","remote_name":"ah-e-2","routing":{"tier":"heavy"},"meta":{}}
{"event":"spawn","timestamp":"2026-10-05T10:00:00+00:00","session":"ah_e-3","remote_name":"ah-e-3","meta":{}}
J
ok "tier-of underscore spelling" "$(rec --tier-of ah_e-1)" light
ok "tier-of hyphen spelling" "$(rec --tier-of ah-e-2)" heavy
ok "tier-of untiered" "$(rec --tier-of ah_e-3)" ""

# session-doctor refuses an unknown outcome before touching anything
o="$(bash "$HERE/../scripts/session-doctor.sh" reap ah_nope-0001 --outcome bogus 2>&1)"; rc=$?
ok "doctor: bad --outcome exit 2" "$rc" "2"; has "doctor: bad --outcome message" "$o" "--outcome must be"

# Kids scan: Desktop identity, name normalization, transcript digests and read-only scans.
(
  unset TMUX TMUX_PANE CLAUDE_CODE_SESSION_ID CRSS_LAUNCHER CLAUDE_CODE_ENTRYPOINT
  export HOME="$T/home"
  export CRSS_CLAUDE_HOME="$HOME/.claude" CRSS_UNIT_DIR="$HOME/units"
  export CRSS_SESSIONS_DIR="$HOME/.sessions" TELEMETRY_ROOT="$T/r"
  mkdir -p "$T/bin" "$CRSS_UNIT_DIR"
  cat > "$T/bin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "$1" = list-sessions ]; then echo px_live-0101; else exit 1; fi
SH
  chmod +x "$T/bin/tmux"; export PATH="$T/bin:$PATH"
  rm -f "$ev"
  export CLAUDE_CODE_SESSION_ID=11111111-1111-1111-1111-111111111111
  done_dir="$HOME/.claude/worktrees/px-done-0101"; gone_dir="$HOME/.claude/worktrees/px-gone-0101"
  CRSS_SPAWN_BACKEND=claude rec p p px-done-0101 px_done-0101 workspace sonnet "$done_dir"
  has "kids: launcher UUID shape" "$(tail -1 "$ev")" '"launcher": {"entry": "", "name": "", "session_id": "11111111-1111-1111-1111-111111111111"}'
  CRSS_SPAWN_BACKEND=claude rec p p px-live-0101 px_live-0101 workspace sonnet "$T/live"
  has "kids: backend recorded" "$(tail -1 "$ev")" '"backend": "claude"'
  CRSS_SPAWN_BACKEND=codex CRSS_LAUNCHER=px_hub rec p p px-named-0101 px_named-0101 workspace sonnet "$T/named"
  CRSS_SPAWN_BACKEND=claude rec p p px-gone-0101 px_gone-0101 workspace sonnet "$gone_dir"
  touch "$CRSS_UNIT_DIR/px-gone-0101.service"
  CLAUDE_CODE_SESSION_ID=22222222-2222-2222-2222-222222222222 rec p p px-other-0101 px_other-0101 workspace sonnet "$T/other"
  CLAUDE_CODE_SESSION_ID="" rec p p px-old-0101 px_old-0101 workspace sonnet "$T/old"
  hasnt "kids: legacy event unattributed" "$(tail -1 "$ev")" '"launcher"'
  CLAUDE_CODE_SESSION_ID=not-a-uuid rec p p px-bad-0101 px_bad-0101 workspace sonnet "$T/bad"
  hasnt "kids: bad UUID dropped" "$(tail -1 "$ev")" '"launcher"'
  rec --reap px-done-0101 no ok "" yes
  python3 - "$ev" "$CRSS_CLAUDE_HOME" "$done_dir" "$gone_dir" <<'PYFIX' || exit 1
import datetime, json, os, pathlib, re, sys
path, home, done, gone = sys.argv[1:]
spawns = [json.loads(x) for x in pathlib.Path(path).read_text().splitlines()]
def fixture(workdir, uuid, entries):
    proj = pathlib.Path(home) / "projects" / re.sub(r"[^A-Za-z0-9]", "-", workdir)
    proj.mkdir(parents=True, exist_ok=True)
    timestamp = next(e["timestamp"] for e in spawns if e.get("workdir") == workdir)
    timestamp = (datetime.datetime.fromisoformat(timestamp) + datetime.timedelta(seconds=1)).isoformat()
    fn = proj / (uuid + ".jsonl")
    fn.write_text("".join(json.dumps(dict(e, timestamp=timestamp)) + "\n" for e in entries) + '{"partial":')
    decoy = proj / uuid / "subagents" / "agent-x.jsonl"
    decoy.parent.mkdir(parents=True)
    decoy.write_text(json.dumps(dict(assistant("DECOY-SUBAGENT", "end_turn"), timestamp=timestamp)) + "\n")
    os.utime(decoy, (2000000100, 2000000100))
    return fn
def user(text, **kw): return dict(type="user", message={"content": text}, **kw)
def assistant(text, stop): return dict(type="assistant", message={"content": [{"type": "text", "text": text}], "stop_reason": stop})
done_fn = fixture(done, "aaaaaaaa-0000-0000-0000-000000000001", [
    user("task-notification text", origin={"kind": "task-notification"}),
    user("isMeta text", isMeta=True), user("<command-name>/compact</command-name>"),
    user("<local-command-stdout>Compacted</local-command-stdout>"), user("/compact"),
    user("compact decoy", isCompactSummary=True),
    user("tool result decoy", toolUseResult={}),
    user([{"type": "tool_result", "content": "tool-only decoy"}]),
    user('<pasted_content id="x">\nLane: BRIEF-MARKER do the thing</pasted_content>', origin={"kind": "human"}, entrypoint="cli"),
    user([{"type": "tool_result", "content": "tool result"}], toolUseResult={}),
    assistant("mid narration", "tool_use"), {"type": "system", "subtype": "compact_boundary"},
    user("SUMMARY-MARKER", isCompactSummary=True), assistant("REPORT-MARKER done", "end_turn"),
    assistant("later narration", "tool_use"),
    {"type": "ai-title", "aiTitle": "TITLE-MARKER"}, {"type": "last-prompt", "lastPrompt": "decoy"}])
fixture(gone, "bbbbbbbb-0000-0000-0000-000000000002", [user("BRIEF-GONE"), assistant("REPORT-GONE", "end_turn")])
# Older timestamp wins the brief even when its mtime is newer.
start = datetime.datetime.fromisoformat(spawns[0]["timestamp"])
def write_at(name, seconds, entries, mtime):
    fn = done_fn.parent / (name + ".jsonl")
    fn.write_text("".join(json.dumps(dict(e, timestamp=(start + datetime.timedelta(seconds=seconds)).isoformat())) + "\n" for e in entries))
    os.utime(fn, (mtime, mtime))
os.utime(done_fn, (2000000000, 2000000000))
write_at("pre-window", -300, [user("DECOY-PRE"), assistant("DECOY-PRE", "end_turn")], 2000000300)
write_at("sdk", 2, [{"type": "last-prompt"}, user("DECOY-SDK", entrypoint="sdk-cli"), assistant("DECOY-SDK", "end_turn")], 2000000200)
# Malformed bytes/scalars and null tmux metadata must be harmless.
(done_fn.parent / "bad.jsonl").write_bytes(b'null\n[]\n\xff\n')
sessions = pathlib.Path(home) / "sessions"
sessions.mkdir()
(sessions / "null.json").write_text('{"tmux":null}')
live_fn = fixture(next(e["workdir"] for e in spawns if e.get("session") == "px_live-0101"), "cccccccc-0000-0000-0000-000000000003", [user("LIVE-BRIEF"), assistant("LIVE-REPORT", "end_turn")])
(sessions / "x.json").write_text(json.dumps({"sessionId": live_fn.stem, "tmux": "px_live-0101:@1.%1"}))
PYFIX
  digest() { python3 - "$ev" "$CRSS_CLAUDE_HOME/projects" <<'PYHASH'
import hashlib, pathlib, sys
paths = [pathlib.Path(sys.argv[1])] + sorted(pathlib.Path(sys.argv[2]).rglob("*.jsonl"))
for p in paths: print(hashlib.sha256(p.read_bytes()).hexdigest())
PYHASH
  }
  before="$(digest)"
  o="$(bash "$REPORT" --kids)"; rc=$?
  ok "kids: exit 0" "$rc" 0
  has "kids: counts" "$o" '4 matched (1 live, 1 reaped, 2 gone)'
  hasre "kids: normalized reap" "$o" 'px_done-0101 .*REAPED outcome=ok clean=yes'
  has "kids: genuine brief" "$o" 'brief:  Lane: BRIEF-MARKER do the thing'
  hasnt "kids: window excludes decoys" "$o" 'DECOY-'
  has "kids: cli window only" "$o" 'pick=window(1)'
  has "kids: live exact transcript" "$o" 'pick=exact(live)'
  has "kids: final report" "$o" 'report: REPORT-MARKER done  [final=end_turn]'
  has "kids: title" "$o" 'title:  TITLE-MARKER'
  has "kids: reaped next" "$o" 'next: unit removed at reap'
  hasnt "kids: never resume reaped" "$o" 'session-resume px_done'
  hasre "kids: live" "$o" 'px_live-0101 .*LIVE'
  has "kids: codex transcript" "$o" 'transcript: n/a (codex backend)'
  has "kids: send live" "$o" 'next: session-send px_live-0101'
  hasre "kids: gone" "$o" 'px_gone-0101 .*GONE'
  has "kids: resume hint" "$o" 'next: session-resume px-gone-0101 --uuid bbbbbbbb-0000-0000-0000-000000000002'
  has "kids: same UUID named child" "$o" px_named-0101
  for other in px_other-0101 px_old-0101 px_bad-0101; do hasnt "kids: excludes $other" "$o" "$other"; done
  named="$(bash "$REPORT" --kids --of px-hub)"
  has "kids: normalized launcher name" "$named" px_named-0101
  has "kids: named count" "$named" '1 matched'
  hasnt "kids: named excludes UUID-only" "$named" px_done-0101
  has "kids: zero limit" "$(bash "$REPORT" --kids --limit 0)" '0 shown (--limit 0)'
  ok "kids: help" "$(bash "$REPORT" --help >/dev/null; echo $?)" 0
  ok "kids: limit" "$(bash "$REPORT" --kids --limit 1 | grep -c '^px_')" 1
  ok "kids: whoami UUID" "$(rec --whoami)" $'\t'11111111-1111-1111-1111-111111111111
  o="$(CLAUDE_CODE_SESSION_ID="" rec --whoami)"; rc=$?
  ok "kids: empty whoami" "$o" $'\t'; ok "kids: empty whoami exit" "$rc" 0
  o="$(env -u CLAUDE_CODE_SESSION_ID bash "$REPORT" --kids 2>&1)"; rc=$?
  ok "kids: no identity exit" "$rc" 2
  has "kids: no identity message" "$o" 'pass --of <name|uuid>'
  ok "kids: scans read-only" "$(digest)" "$before"
  python3 - "$CRSS_CLAUDE_HOME/projects" <<'PYPAD' || exit 1
import json, pathlib, sys
fn = next(pathlib.Path(sys.argv[1]).glob("*/aaaaaaaa*.jsonl"))
original = fn.read_bytes()
padding = (json.dumps({"type": "progress", "padding": "x" * 1000}) + "\n").encode()
fn.write_bytes(original + b"\n" + padding * 500)
PYPAD
  before="$(digest)"
  has "kids: large file tail seek" "$(bash "$REPORT" --kids)" 'REPORT-MARKER done  [final=end_turn]'
  ok "kids: large scan read-only" "$(digest)" "$before"
  # Make the 256KB seek land exactly on the final report's line boundary.
  python3 - "$CRSS_CLAUDE_HOME/projects" <<'PYBOUNDARY' || exit 1
import json, pathlib, sys
fn = next(pathlib.Path(sys.argv[1]).glob("*/aaaaaaaa*.jsonl"))
lines = fn.read_bytes().splitlines(keepends=True)
i = next(i for i, line in enumerate(lines) if b"REPORT-MARKER done" in line)
report = lines[i]
narration = json.dumps({"type":"assistant", "message":{"content":[{"type":"text", "text":"boundary narration"}], "stop_reason":"tool_use"}}).encode() + b"\n"
prefix, suffix = b'{"type":"progress","padding":"', b'"}\n'
pad = prefix + b'x' * (262144 - len(report) - len(narration) - len(prefix) - len(suffix)) + suffix
assert len(report + narration + pad) == 262144
fn.write_bytes(b''.join(lines[:i]) + report + narration + pad)
PYBOUNDARY
  has "kids: exact tail boundary keeps end_turn" "$(bash "$REPORT" --kids)" 'REPORT-MARKER done  [final=end_turn]'
  python3 - "$CRSS_CLAUDE_HOME/projects" <<'PYHUGE' || exit 1
import pathlib, sys
fn = next(pathlib.Path(sys.argv[1]).glob("*/aaaaaaaa*.jsonl"))
with fn.open("ab") as fh: fh.write(b'{"type":"progress","padding":"' + b'x' * (3 * 1024 * 1024) + b'"}\n')
PYHUGE
  before="$(digest)"
  has "kids: oversized trailing line regrows" "$(bash "$REPORT" --kids)" 'REPORT-MARKER done  [final=end_turn]'
  ok "kids: oversized scan read-only" "$(digest)" "$before"
  # A second CLI file has an older mtime but a later first-entry timestamp.
  python3 - "$CRSS_CLAUDE_HOME/projects" <<'PYMULTI' || exit 1
import json, os, pathlib, sys, datetime
fn = next(pathlib.Path(sys.argv[1]).glob("*/aaaaaaaa*.jsonl"))
entries = [json.loads(x) for x in fn.read_bytes().splitlines() if x.startswith(b'{"type": "user"')]
t = datetime.datetime.fromisoformat(entries[0]["timestamp"]) + datetime.timedelta(seconds=1)
other = fn.with_name("dddddddd-0000-0000-0000-000000000004.jsonl")
other.write_text(json.dumps({"type":"user", "timestamp":t.isoformat(), "entrypoint":"cli", "message":{"content":"WRONG-BRIEF"}}) + "\n" + json.dumps({"type":"assistant", "message":{"content":[{"type":"text","text":"NEW-REPORT"}], "stop_reason":"end_turn"}}) + "\n")
os.utime(other, (2000000001, 2000000001))
os.utime(fn, (2000000002, 2000000002))
PYMULTI
  o="$(bash "$REPORT" --kids)"
  has "kids: timestamp chooses brief" "$o" 'brief:  Lane: BRIEF-MARKER do the thing'
  python3 - "$CRSS_CLAUDE_HOME/projects" <<'PYMTIME' || exit 1
import os, pathlib, sys
fn = next(pathlib.Path(sys.argv[1]).glob("*/dddddddd*.jsonl"))
os.utime(fn, (2000000003, 2000000003))
PYMTIME
  o="$(bash "$REPORT" --kids)"
  has "kids: newest report and separate brief source" "$o" 'report: NEW-REPORT  [final=end_turn]'
  has "kids: names separate brief source" "$o" 'brief-from:'
  has "kids: both CLI windows" "$o" 'pick=window(2)'
  # Reuse a live name: its old spawn must retain its reap, not inherit liveness.
  rec --reap px-live-0101 no ok "" yes
  CRSS_SPAWN_BACKEND=claude rec p p px-live-0101 px_live-0101 workspace sonnet "$T/live"
  has "kids: reused live name" "$(bash "$REPORT" --kids)" '5 matched (1 live, 2 reaped, 2 gone)'
  long_name="$(printf '%101s' '' | tr ' ' x)"
  ok "kids: shared launcher truncation" "$(CRSS_LAUNCHER="$long_name" rec --whoami)" "${long_name:0:100}"$'\t'"$CLAUDE_CODE_SESSION_ID"
  before="$(digest)"; rec --future-flag >/dev/null 2>&1
  ok "kids: unknown recorder flag cannot write" "$(digest)" "$before"
  mkdir -p "$T/skew"; cp "$REPORT" "$T/skew/telemetry-report.sh"
  printf '#!/usr/bin/env bash\necho junk >> "$TELEMETRY_ROOT/artifacts/telemetry/events.jsonl"\n' > "$T/skew/record-spawn-telemetry.sh"
  chmod +x "$T/skew/record-spawn-telemetry.sh"
  env -u CLAUDE_CODE_SESSION_ID bash "$T/skew/telemetry-report.sh" --kids >/dev/null 2>&1
  ok "kids: old recorder cannot write" "$(digest)" "$before"
  printf '%s %s\n' "$pass" "$fail" > "$T/kids-counts"
) > "$T/kids-results" 2>&1
# Preserve the shared assertion counters: the isolated block runs in a subshell.
cat "$T/kids-results"
if ! read -r pass fail 2>/dev/null < "$T/kids-counts"; then
  fail=$((fail+1)); echo "FAIL: kids block aborted before writing counters"
fi

finish "telemetry"
