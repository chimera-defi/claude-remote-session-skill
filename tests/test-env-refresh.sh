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
echo '  claude-opus-5-5   10   2,000   30,000'
echo 'SESSIONS=3 TOTAL_WEIGHTED=99'
SH
cat > "$TMP/bin/session-doctor" <<'SH'
#!/bin/sh
printf '%s\n' '  Opus subagents: 2 across 1 session(s) in the last 7 day(s)' 'opus fixture row'
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
assert 'no ack' in s and 'sessions = 3; weighted tokens = 99' in s
assert 'claude-opus-5-5: calls 10; weighted 2,000; tokens 30,000' in s
assert '2 Opus subagents across 1 sessions' in s and 'opus fixture row' not in s
assert 'saved = 1' in s and 'skipped = 1' in s
assert 'dirty: dirty=1' in s and 'remote: dirty=0' in s
assert 'remote=none' in s and 'remote=yes' in s and 'none configured' in s
assert '~/.claude/projects: 6 bytes' in s and '~/.codex/sessions: 5 bytes' in s
assert 'abc123secretvalue' not in s and 'token=' not in s
PY
ok 'report metrics, line budget and allowlisted output' "$?" 0
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
# An overlapping run must not bypass history checks or spawn while locked.
python3 - "$state" "$TOOL" <<'PY'
import os, pathlib, subprocess, sys
state, tool = map(pathlib.Path, sys.argv[1:])
holder = subprocess.Popen([sys.executable, '-c', '''
import fcntl, pathlib, sys
with pathlib.Path(sys.argv[1]).open('a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    print('locked', flush=True)
    sys.stdin.read()
''', str(state/'spawn.lock')], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
try:
    assert holder.stdout.readline().strip() == 'locked'
    result = subprocess.run([sys.executable, str(tool), '--spawn', '--force'],
                            capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result
    assert 'env-refresh: another run holds the lock; skipping spawn' in result.stdout
    assert not (pathlib.Path(os.environ['HOME'])/'spawns').exists()
    dry = subprocess.run([sys.executable, str(tool), '--dry-run', '--spawn', '--force'],
                         capture_output=True, text=True, timeout=30)
    assert dry.returncode == 10 and '# Environment refresh' in dry.stdout, dry
finally:
    holder.communicate(timeout=10)
PY
ok 'held spawn lock skips concurrent launcher' "$?" 0
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
# A spawn stamped after this run started (a newer overlapping run) still suppresses.
cp "$state/history.jsonl" "$TMP/history.saved"
python3 - "$state/history.jsonl" <<'PY'
import datetime as dt, json, pathlib, sys
path = pathlib.Path(sys.argv[1])
rows = [json.loads(line) for line in path.read_text().splitlines()]
future = (dt.datetime.now(dt.timezone.utc) + dt.timedelta(hours=1)).isoformat()
rows = [dict(row, generated=future) if row.get('spawned') else row for row in rows]
path.write_text(''.join(json.dumps(row) + '\n' for row in rows))
PY
run --spawn >/dev/null
python3 -c 'import pathlib, sys; assert len(pathlib.Path(sys.argv[1]).read_text().splitlines()) == 1' "$HOME/spawns"
ok 'newer history spawn suppresses a repeat' "$?" 0
# Secrets planted in every source never reach the report, JSON, history or stderr.
python3 - "$TOOL" "$TMP/leak" <<'PY'
import json, os, pathlib, subprocess, sys
tool, root = sys.argv[1], pathlib.Path(sys.argv[2])
home, bin_dir = root/'home', root/'bin'
(home/'.codex').mkdir(parents=True)
bin_dir.mkdir()
values = ['fixture spaced value', 'q r s', 'prefix-escaped-tail', 'zz' + 'x' * 30,
          'fixture' + '-credential-9', 'outcome-leak-7']
quoted = 'pass' + 'word: "' + values[0] + '"'
for name, body in {
    'claude': 'echo "Claude 2.1.9 ' + values[1] + '"',
    'codex': 'echo "' + quoted + '" >&2; exit 3',
    'usage-audit': 'printf "%s\\n" ' + ' '.join(repr(line) for line in (
        quoted, '{"pass' + 'word": "prefix \\"' + values[2] + '\\" tail"}',
        '  ' + values[3] + '  1  2  3', 'SESSIONS=1 TOTAL_WEIGHTED=2')),
    'session-doctor': 'echo "Opus subagents: 1 across 1 session ' + values[4] + '"',
    'spawn': 'echo "' + quoted + '" >&2; exit 4',
}.items():
    (bin_dir/name).write_text('#!/bin/sh\n' + body + '\n')
    (bin_dir/name).chmod(0o755)
(home/'.codex/models_cache.json').write_text(json.dumps({'models': [
    {'slug': 'gpt-6.1-sol'}, {'slug': values[3]}, {'slug': values[0]}]}))
(home/'lessons.jsonl').write_text(json.dumps({'ts': '2099-01-01T00:00:00Z', 'outcome': values[5]}) + '\n'
    + json.dumps({'ts': __import__('datetime').datetime.now().astimezone().isoformat(), 'outcome': 'saved:' + values[5]}) + '\n')
(home/'config.json').write_text(json.dumps({'env-refresh': {
    'lessons_log': '~/lessons.jsonl', 'spawn_cmd': ['spawn'], 'memory_root': '~/missing',
    'backup_marker': quoted, 'api_token': values[4]}}))
env = dict(os.environ, HOME=str(home), PATH=f'{bin_dir}:/usr/bin:/bin',
           HOST_TOOLS_CONFIG=str(home/'config.json'))
outputs = []
for argv in (['--dry-run'], ['--spawn', '--force', '--json'], ['ack']):
    result = subprocess.run([sys.executable, tool, *argv], capture_output=True, text=True, env=env, timeout=60)
    outputs += [result.stdout, result.stderr]
state = home/'.local/state/crss/env-refresh'
outputs += [p.read_text() for p in state.rglob('*') if p.is_file() and p.suffix in ('.md', '.json', '.jsonl')]
text = '\n'.join(outputs)
assert 'gpt-6.1-sol' in text and '2.1.9' in text and 'sessions = 1' in text, text
leaks = [v for v in values for chunk in (v, v[:8]) if chunk in text]
assert not leaks, leaks
PY
ok 'no planted secret reaches any output' "$?" 0
cp "$TMP/history.saved" "$state/history.jsonl"
# Compare every fixture byte and mtime, including an initially absent state dir.
python3 - "$HOME" > "$TMP/before" <<'PY'
import pathlib, sys
for p in sorted(pathlib.Path(sys.argv[1]).rglob('*')):
    print(p, p.stat().st_mtime_ns, p.read_bytes() if p.is_file() else '')
PY
run --dry-run --spawn --force > "$TMP/dry-report"; rc=$?
run --dry-run --spawn --force --state-dir "$HOME/absent" >/dev/null
python3 - "$HOME" > "$TMP/after" <<'PY'
import pathlib, sys
for p in sorted(pathlib.Path(sys.argv[1]).rglob('*')):
    print(p, p.stat().st_mtime_ns, p.read_bytes() if p.is_file() else '')
PY
ok 'dry run remains due' "$rc" 10
ok 'dry run writes nothing, including git locks and spawns' "$(yn cmp -s "$TMP/before" "$TMP/after")" yes
has 'dry run prints report' "$(cat "$TMP/dry-report")" '# Environment refresh'
finish 'env-refresh'
