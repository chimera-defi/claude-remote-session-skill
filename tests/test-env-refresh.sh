#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
isolate_overlay
TOOL="$HERE/../scripts/env-refresh.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
unset HOST_TOOLS_CONFIG XDG_CONFIG_HOME XDG_STATE_HOME
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
mkdir -p "$HOME/.codex" "$HOME/agent-memory/dirty" "$HOME/agent-memory/remote" "$TMP/bin"
mkdir -p "$HOME/transcripts" "$HOME/.claude" "$HOME/.codex/sessions"
printf 'claude' > "$HOME/transcripts/fixture.jsonl"
printf 'codex' > "$HOME/.codex/sessions/fixture.jsonl"
ln -s "$HOME/transcripts" "$HOME/.claude/projects"
# Keep every command hermetic, including both CLI version probes.
export PATH="$TMP/bin:/usr/bin:/bin"
cat > "$TMP/bin/claude" <<'SH'
#!/bin/sh
echo 'Claude fixture 1.0'
exit 0
claude-opus-4-1
SH
cat > "$TMP/bin/codex" <<'SH'
#!/bin/sh
echo 'codex fixture 1.0'
SH
cat > "$TMP/bin/usage-audit" <<'SH'
#!/bin/sh
echo 'token=abc123secretvalue'
echo 'usage fixture ready'
SH
cat > "$TMP/bin/session-doctor" <<'SH'
#!/bin/sh
printf '%s\n' 'opus fixture one' 'opus fixture two'
SH
cat > "$TMP/bin/record-spawn" <<'SH'
#!/bin/sh
printf '%s\n' "$1" >> "$HOME/spawns"
SH
chmod 755 "$TMP/bin/"*
printf '{"models":[{"slug":"codex-fixture"}]}' > "$HOME/.codex/models_cache.json"
for repo in dirty remote; do
  git -C "$HOME/agent-memory/$repo" init -q
  git -C "$HOME/agent-memory/$repo" -c user.name=Fixture -c user.email=fixture@example.org \
    -c commit.gpgsign=false commit -qm 'fixture' --allow-empty
done
printf 'dirty\n' > "$HOME/agent-memory/dirty/note"
git -C "$HOME/agent-memory/remote" remote add origin https://example.org/memory.git
python3 - "$HOME" <<'PY'
import datetime as dt, json, pathlib, sys
h = pathlib.Path(sys.argv[1])
(h/'lessons.jsonl').write_text(''.join(json.dumps({'ts': ts, 'outcome': outcome})+'\n'
    for ts, outcome in [(dt.datetime.now(dt.timezone.utc).isoformat(), 'saved:fixture'),
                        (dt.datetime.now(dt.timezone.utc).isoformat(), 'skip:fixture'),
                        ('2000-01-01T00:00:00Z', 'saved:old')]))
(h/'config.json').write_text(json.dumps({'env-refresh': {
    'lessons_log': '~/lessons.jsonl', 'spawn_cmd': ['record-spawn']}}))
PY
export HOST_TOOLS_CONFIG="$HOME/config.json"
run() { python3 "$TOOL" "$@"; }
state="$HOME/.local/state/crss/env-refresh"
report=$(run); rc=$?
ok 'first run due without ack' "$rc" 10
python3 - "$report" <<'PY'
import pathlib, sys
s = pathlib.Path(sys.argv[1]).read_text()
assert len(s.splitlines()) < 120
assert 'no ack' in s and 'usage fixture ready' in s and '2 lines' in s
assert 'saved = 1' in s and 'skipped = 1' in s
assert 'dirty: dirty=1' in s and 'remote: dirty=0' in s
assert 'no remote=yes' in s and 'no remote=no' in s and 'NONE' in s
assert '~/.claude/projects: 6 bytes' in s and '~/.codex/sessions: 5 bytes' in s
assert 'abc123secretvalue' not in s and '[REDACTED]' in s
PY
ok 'report metrics, line budget and credential redaction' "$?" 0
run ack >/dev/null
run >/dev/null; rc=$?
ok 'acked fingerprint is OK' "$rc" 0
# Place an ID across a chunk boundary to exercise the carry-over scan.
python3 - "$TMP/bin/claude" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
with p.open('ab') as f:
    f.write(b' ' * (1024*1024 - p.stat().st_size - 8))
    f.write(b'claude-fable-5-1\n')
PY
report=$(run); rc=$?
ok 'new Claude model is due' "$rc" 10
has 'report names new model across chunks' "$(cat "$report")" 'claude-fable-5-1'
run ack >/dev/null
printf '{"models":[{"slug":"codex-fixture"},{"id":"codex-next"}]}' > "$HOME/.codex/models_cache.json"
run >/dev/null; rc=$?
ok 'new Codex slug is due' "$rc" 10
cp "$state/fingerprint.json" "$TMP/acked.json"
# Exercise the installed-copy layout used by the systemd service as well.
mkdir -p "$HOME/.claude/skills"
ln -s "$HERE/.." "$HOME/.claude/skills/gstack-session-spawn"
cp "$TOOL" "$TMP/bin/env-refresh"
TOOL="$TMP/bin/env-refresh"
run --spawn >/dev/null; first_rc=$?
run --spawn >/dev/null; second_rc=$?
python3 - "$HOME" "$state" "$TMP/acked.json" "$first_rc" "$second_rc" <<'PY'
import json, pathlib, sys
h, state, ack = map(pathlib.Path, sys.argv[1:4])
assert sys.argv[4:] == ['10', '10']
calls = (h/'spawns').read_text().splitlines()
assert len(calls) == 1 and pathlib.Path(calls[0]).is_file()
brief = pathlib.Path(calls[0]).read_text()
assert 'codex-next' in brief and str(state/'reports') in brief
assert '{new_models}' not in brief and '{reasons}' not in brief and '{report_path}' not in brief
assert (state/'fingerprint.json').read_bytes() == ack.read_bytes()
history = [json.loads(line) for line in (state/'history.jsonl').read_text().splitlines()]
assert sum(row.get('spawned', False) for row in history) == 1
PY
ok 'one spawn carries rendered brief; repeat suppressed; ack untouched' "$?" 0
# Compare every fixture byte and mtime, including an initially absent state dir.
python3 - "$HOME" > "$TMP/before" <<'PY'
import pathlib, sys
for p in sorted(pathlib.Path(sys.argv[1]).rglob('*')):
    print(p, p.stat().st_mtime_ns, p.read_bytes() if p.is_file() else '')
PY
run --dry-run --spawn --force > "$TMP/dry-report"; rc=$?
run --dry-run --state-dir "$HOME/absent" >/dev/null
python3 - "$HOME" > "$TMP/after" <<'PY'
import pathlib, sys
for p in sorted(pathlib.Path(sys.argv[1]).rglob('*')):
    print(p, p.stat().st_mtime_ns, p.read_bytes() if p.is_file() else '')
PY
ok 'dry run remains due' "$rc" 10
ok 'dry run writes nothing, including git locks and spawns' "$(yn cmp -s "$TMP/before" "$TMP/after")" yes
has 'dry run prints report' "$(cat "$TMP/dry-report")" '# Environment refresh'
finish 'env-refresh'
