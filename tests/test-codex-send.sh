#!/usr/bin/env bash
# Hermetic local socket and queue fixture; never contact a desktop thread.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
SEND="$HERE/../scripts/session-send.sh"

# Capture only the optional bridge configuration before replacing HOME/CRSS_HOME.
mapfile -t bridge_settings < <(python3 - <<'PY'
import os
import re
from pathlib import Path
keys = ('CRSS_CODEX_BRIDGE_PATH', 'CRSS_CODEX_BRIDGE_MODULE')
values = {key: os.environ[key] for key in keys if key in os.environ}
home = os.environ.get('CRSS_HOME') or str(Path(os.environ.get('XDG_CONFIG_HOME') or Path.home() / '.config') / 'crss')
try:
    with (Path(home) / 'config.sh').open(newline='') as source:
        for line in source:
            match = re.fullmatch(r'(CRSS_[A-Z0-9_]+)=(.*)', line.removesuffix('\n').removesuffix('\r'))
            if not match:
                continue
            key, value = match.groups()
            if len(value) >= 2 and value[0] in "\"'" and value[-1] == value[0]:
                value = value[1:-1]
            if key in keys:
                values.setdefault(key, value)
except OSError:
    pass
for key in keys:
    print(values.get(key, ''))
PY
)
BRIDGE_PATH="${bridge_settings[0]:-}"
BRIDGE_MODULE="${bridge_settings[1]:-}"
FIX_HOME="$CRSS_TEST_TMP/h"
CODEX_HOME="$(mktemp -d /tmp/cxs.XXXXXX)"
STATE="$CRSS_TEST_TMP/state"
CONFIG="$CRSS_TEST_TMP/crss"
mkdir -p "$FIX_HOME/.local/bin" "$CONFIG" "$CODEX_HOME/sessions" "$CODEX_HOME/app-server-control"
listener_pid=""
trap 'if [ -n "$listener_pid" ]; then kill "$listener_pid" 2>/dev/null || true; wait "$listener_pid" 2>/dev/null || true; fi; rm -rf "$CODEX_HOME"' EXIT

fixture_env=(env -i HOME="$FIX_HOME" PATH="$PATH" LANG=C.UTF-8 CODEX_HOME="$CODEX_HOME"
  XDG_STATE_HOME="$STATE" CRSS_HOME="$CONFIG" CRSS_CODEX_BIN="$FIX_HOME/.local/bin/codex")
clean() { "${fixture_env[@]}" "$@"; }
send() { clean bash "$SEND" "$@"; }
calls() { if [ -f "$FIX_HOME/codex-calls.log" ]; then wc -l < "$FIX_HOME/codex-calls.log"; else echo 0; fi; }
name_thread() {
  clean python3 - "$1" <<'PY'
import os, sqlite3, sys
with sqlite3.connect(os.environ['CODEX_HOME'] + '/state_5.sqlite') as con:
    con.execute('UPDATE threads SET name=? WHERE id=?', (None if sys.argv[1] == 'NULL' else sys.argv[1], '11111111-2222-3333-4444-555555555555'))
PY
}
last_audit() {
  clean python3 - "$1" <<'PY'
import json, os, sys
from pathlib import Path
row = json.loads((Path(os.environ['XDG_STATE_HOME']) / 'crss/codex-send.jsonl').read_text().splitlines()[-1])
print(json.dumps(row[sys.argv[1]]) if isinstance(row[sys.argv[1]], bool) else row[sys.argv[1]])
PY
}

clean python3 - <<'PY'
import os, sqlite3
from pathlib import Path
home = Path(os.environ['CODEX_HOME'])
with sqlite3.connect(home / 'state_5.sqlite') as con:
    con.execute('CREATE TABLE threads (id TEXT, name TEXT, cwd TEXT, updated_at INTEGER, model TEXT, agent_role TEXT, archived INTEGER, git_branch TEXT, sandbox_policy TEXT, approval_mode TEXT, rollout_path TEXT)')
    for uuid, name, archived in [('11111111-2222-3333-4444-555555555555', 'Fixture thread', 0), ('22222222-2222-3333-4444-555555555555', None, 0), ('33333333-2222-3333-4444-555555555555', 'Archived fixture', 1)]:
        rollout = home / 'sessions' / (uuid + '.jsonl')
        rollout.touch()
        con.execute('INSERT INTO threads VALUES (?,?,?,?,?,?,?,?,?,?,?)', (uuid, name, '/srv/fixture', 1700000000, 'fixture', None, archived, None, None, None, str(rollout)))
PY
cat > "$FIX_HOME/.local/bin/codex" <<'PY'
#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
home = Path.home()
with (home / 'codex-calls.log').open('a') as log:
    log.write('queue\n')
mode = (home / 'fake-codex-mode').read_text().strip()
thread = sys.argv[sys.argv.index('--thread') + 1]
message = sys.argv[sys.argv.index('--message') + 1]
if mode == 'match':
    with (Path(os.environ['CODEX_HOME']) / 'sessions' / (thread + '.jsonl')).open('a') as log:
        log.write(json.dumps({'type': 'response_item', 'payload': {'type': 'message', 'role': 'user', 'content': [{'type': 'input_text', 'text': message}]}}) + '\n')
    print(f'Queued message aaaaaaaa-0000-4000-8000-000000000001 for thread {thread}.')
elif mode == 'mismatch':
    print('Queued message aaaaaaaa-0000-4000-8000-000000000001 for thread 99999999-2222-3333-4444-555555555555.')
else:
    print('unrelated text')
PY
chmod +x "$FIX_HOME/.local/bin/codex"
"${fixture_env[@]}" python3 - <<'PY' &
import os, socket
from pathlib import Path
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
    server.bind(os.environ['CODEX_HOME'] + '/app-server-control/app-server-control.sock')
    server.listen()
    (Path(os.environ['CODEX_HOME']) / 'ready').touch()
    while True:
        client, _ = server.accept()
        client.close()
PY
listener_pid=$!
for _ in {1..100}; do
  [ -f "$CODEX_HOME/ready" ] && break
  sleep 0.02
done
ok "fixture socket ready" "$(yn test -f "$CODEX_HOME/ready")" yes

REF=cs-666ff6ccaa5b3c07feaa3a95d3a4bd2c
IDENTITY=codex-dst-sha256-4e58ff1197aa2a230d31977cd11ab2fbb8baa3b135e23ccc6e934aa08380e62a
NULL_IDENTITY=codex-dst-sha256-ca46ddbadcc16cb01f697cc365f25eb8cb1214e0585c4fc4915e70f659805593
MESSAGE=hello-fixture-7f3a
run_cases() {
  local expected="$1" out rc before hash audit
  name_thread 'Fixture thread'
  out="$(send codex:list 2>&1)"; rc=$?
  ok "$expected list exit" "$rc" 0
  has "$expected golden ref" "$out" "$REF"
  has "$expected golden identity" "$out" "$IDENTITY"
  has "$expected list bridge" "$out" "bridge=$expected"
  hasnt "$expected excludes archived" "$out" 'Archived fixture'
  out="$(send codex:list --json)"; rc=$?
  ok "$expected json exit" "$rc" 0
  ok "$expected valid json" "$(yn clean python3 -c 'import json,sys; rows=json.load(sys.stdin); assert len(rows)==2' <<< "$out")" yes
  name_thread NULL
  out="$(send codex:list)"
  has "$expected NULL golden identity" "$out" "$NULL_IDENTITY"
  name_thread 'Fixture thread'

  echo match > "$FIX_HOME/fake-codex-mode"
  before="$(calls)"
  # Whitespace normalization and --file share the same send validation.
  printf '  %s\n' "$MESSAGE" > "$CRSS_TEST_TMP/message"
  out="$(send "codex:$REF" --expect-identity "$IDENTITY" --file "$CRSS_TEST_TMP/message" 2>&1)"; rc=$?
  ok "$expected match exit" "$rc" 0
  has "$expected send bridge" "$out" "bridge=$expected"
  ok "$expected match calls once" "$(( $(calls) - before ))" 1
  if [ "$expected" = module ]; then
    hasre 'module acceptance observed' "$out" 'ACCEPTED|PROCESSING_OBSERVED'
    has 'module new rollout evidence' "$out" NEW_MATCHING_ROLLOUT_USER_MESSAGE
  fi
  ok "$expected queued audit" "$(last_audit outcome)" QUEUED
  hash="$(clean python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$MESSAGE")"
  ok "$expected normalized digest" "$(last_audit normalized_message_sha256)" "$hash"
  audit="$(cat "$STATE/crss/codex-send.jsonl")"
  hasnt "$expected audit excludes message" "$audit" "$MESSAGE"

  echo mismatch > "$FIX_HOME/fake-codex-mode"
  before="$(calls)"
  out="$(send "codex:$REF" mismatch-test 2>&1)"; rc=$?
  ok "$expected mismatch exit" "$rc" 1
  has "$expected mismatch no resend" "$out" 'do NOT resend'
  ok "$expected mismatch no retry" "$(( $(calls) - before ))" 1
  ok "$expected mismatch audit uncertain" "$(last_audit queue_uncertain)" true

  echo none > "$FIX_HOME/fake-codex-mode"
  before="$(calls)"
  out="$(send "codex:$REF" no-receipt-test 2>&1)"; rc=$?
  ok "$expected no receipt exit" "$rc" 1
  has "$expected no receipt no resend" "$out" 'do NOT resend'
  ok "$expected no receipt no retry" "$(( $(calls) - before ))" 1

  name_thread Renamed
  before="$(calls)"
  out="$(send "codex:$REF" --expect-identity "$IDENTITY" identity-test 2>&1)"; rc=$?
  ok "$expected renamed exit" "$rc" 2
  has "$expected renamed explains identity" "$out" identity
  has "$expected renamed refresh instruction" "$out" 'session-send codex:list'
  ok "$expected renamed no dispatch" "$(( $(calls) - before ))" 0
  ok "$expected renamed audit" "$(last_audit outcome)" REFUSED_IDENTITY_MISMATCH

  before="$(calls)"
  out="$(send codex:cs-xyz bad-ref-test 2>&1)"; rc=$?
  ok "$expected bad ref exit" "$rc" 2
  out="$(send "codex:$REF" '   ' 2>&1)"; rc=$?
  ok "$expected empty exit" "$rc" 2
  ok "$expected invalid inputs no dispatch" "$(( $(calls) - before ))" 0
  echo "$expected cases complete"
}

: > "$CONFIG/config.sh"
run_cases fallback
if [ -n "$BRIDGE_PATH" ] && [ -n "$BRIDGE_MODULE" ]; then
  if clean python3 -B -c 'import sys,importlib; sys.path.insert(0,sys.argv[1]); importlib.import_module(sys.argv[2])' "$BRIDGE_PATH" "$BRIDGE_MODULE"; then
    printf 'CRSS_CODEX_BRIDGE_PATH="%s"\nCRSS_CODEX_BRIDGE_MODULE="%s"\n' "$BRIDGE_PATH" "$BRIDGE_MODULE" > "$CONFIG/config.sh"
    run_cases module
  else
    ok 'configured bridge imports' no yes
  fi
else
  echo 'SKIP: module-bridge cases (no CRSS_CODEX_BRIDGE_* configured)'
fi
# Exercise ambiguity and the dispatch callback without invoking a real bridge.
clean python3 - "$HERE/../scripts/codex-send.py" <<'PYTEST'
import argparse
import contextlib
import importlib.util
import io
import subprocess
import sys
from types import SimpleNamespace
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('codex_sender', sys.argv[1])
sender = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sender)
ref = 'cs-666ff6ccaa5b3c07feaa3a95d3a4bd2c'
args = argparse.Namespace(ref=ref, expect_identity='expected', origin='fixture')

class Audit:
    def __init__(self, unwritable=False):
        self.records = []
        self.unwritable = unwritable

    def write(self, record):
        if self.unwritable:
            raise OSError('fixture audit unavailable')
        self.records.append(record)

    def best_effort(self, record):
        if not self.unwritable:
            self.write(record)

class Bridge:
    def session_status(self, ref):
        return {'session': {'destination_identity': 'expected', 'name': 'Fixture', 'cwd': '/srv/fixture'}}

    def send_message(self, ref, message, caller_origin=None, *, audit_sink=None):
        try:
            audit_sink({'outcome': 'DISPATCH_PENDING', 'destination_identity': 'changed'})
        except RuntimeError:
            audit_sink({'outcome': 'REJECTED', 'queue_uncertain': False})
            raise
        raise AssertionError('identity race dispatched')

with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
    audit = Audit()
    assert sender.module_send(Bridge(), args, 'fixture', audit) == 2
    assert audit.records[-1]['outcome'] == 'REFUSED_IDENTITY_MISMATCH'
    for code in ('STATE_INTEGRITY_FAILURE', 'WORKER_UNAVAILABLE'):
        for pending, attached, uncertain, want in ((False, False, False, 2), (True, False, False, 1),
                                                  (True, True, False, 2), (False, True, True, 1)):
            def fail(ref, message, caller_origin=None, *, audit_sink=None):
                if pending:
                    audit_sink({'outcome': 'DISPATCH_PENDING', 'destination_identity': 'expected'})
                exc = RuntimeError('fixture failure')
                exc.code = code
                if attached:
                    exc.codex_audit = {'outcome': 'UNKNOWN' if uncertain else 'REJECTED', 'queue_uncertain': uncertain}
                raise exc
            bridge = SimpleNamespace(session_status=Bridge().session_status, send_message=fail)
            assert sender.module_send(bridge, args, 'fixture', Audit()) == want

    # Actual fallback preflight uses only the fixture DB/socket; queue results are mocked.
    args.expect_identity = None
    receipt = 'Queued message aaaaaaaa-0000-4000-8000-000000000001 for thread 11111111-2222-3333-4444-555555555555.'
    for result, want in ((subprocess.CompletedProcess([], 7, receipt), 0),
                         (subprocess.TimeoutExpired([], 20, output=receipt.encode()), 0),
                         (subprocess.TimeoutExpired([], 20), 1),
                         (subprocess.CompletedProcess([], 0, receipt + receipt), 1),
                         (OSError('fixture transport failure'), 1)):
        options = {'side_effect': result} if isinstance(result, Exception) else {'return_value': result}
        with patch.object(sender.subprocess, 'run', **options) as run:
            assert sender.fallback_send(args, 'fixture', Audit()) == want
            assert run.call_count == 1
    with patch.object(sender.subprocess, 'run') as run:
        assert sender.fallback_send(args, 'fixture', Audit(unwritable=True)) == 2
        run.assert_not_called()
print('safety semantics: passed')
PYTEST
ok 'dispatch safety semantics' "$?" 0
finish codex-send
