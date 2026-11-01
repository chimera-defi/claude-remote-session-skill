#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" CRSS_HOME="$TMP/config" XDG_STATE_HOME="$TMP/state"
export XDG_CONFIG_HOME="$TMP/config" PATH="$TMP/bin:/usr/bin:/bin"
unset HOST_TOOLS_CONFIG
mkdir -p "$HOME" "$CRSS_HOME" "$TMP/bin"
cat > "$TMP/bin/systemctl" <<'STUB'
#!/usr/bin/env python3
import json, os, sys, time
if os.environ.get('BROKEN_SYSTEMCTL'):
    sys.exit(1)
if 'list-timers' in sys.argv:
    print(json.dumps([{'unit': n + '.timer', 'activates': n + '.service',
                       'last': (time.time() - age) * 1e6 if age else 0}
                      for n, age in [('urgent', 120), ('later', 120),
                                     ('stale', 4 * 3600), ('calendar', 4 * 3600), ('never', 0)]]))
elif any(a.endswith('.timer') for a in sys.argv):
    if 'calendar.timer' in sys.argv:
        print('TimersCalendar={ OnCalendar=hourly ; next_elapse=unused }')
    else:
        print('TimersMonotonic={ OnUnitActiveUSec=1h ; next_elapse=0 }')
        print('TimersMonotonic={ OnBootUSec=5min ; next_elapse=0 }')
else:
    failed = any(n + '.service' in sys.argv for n in ('urgent', 'later'))
    print('Result=' + ('exit-code' if failed else 'success'))
    print('ExecMainStatus=' + ('1' if failed else '0'))
    print('ActiveEnterTimestamp=' + ('' if 'never.service' in sys.argv else 'unused'))
    print('Description=Fixture job')
STUB
cat > "$TMP/bin/systemd-analyze" <<'STUB'
#!/bin/sh
printf '%s\n' '    Next elapse: Thu 2000-01-01 01:00:00 UTC' '   Iteration #2: Thu 2000-01-01 02:00:00 UTC'
STUB
cat > "$TMP/bin/phone-send" <<'STUB'
#!/usr/bin/env python3
import json, os, pathlib, sys
with open(os.environ['HOME'] + '/calls', 'a') as f:
    f.write(json.dumps(sys.argv[1:]) + '\n')
if '--file' in sys.argv:
    text = pathlib.Path(sys.argv[sys.argv.index('--file') + 1]).read_text()
    assert len(text.splitlines()) <= 15
    assert 'APPROVAL: approve this GATE exactly.' in text
STUB
chmod +x "$TMP/bin/"*
python3 - "$HOME" "$CRSS_HOME" <<'PY'
import datetime as dt, json, pathlib, sqlite3, sys
h, c = map(pathlib.Path, sys.argv[1:])
now = dt.datetime.now(dt.timezone.utc).isoformat().replace('+00:00', 'Z')
with sqlite3.connect(h/'bus.sqlite') as db:
    db.execute('CREATE TABLE coordination_messages (sequence INTEGER, message_id TEXT, sender TEXT, recipient TEXT, task_id TEXT, kind TEXT, summary TEXT, evidence_json TEXT, created_at TEXT)')
    db.execute('CREATE TABLE coordination_acks (message_id TEXT, recipient TEXT)')
    rows = [(1, 'one', 'worker', 'alerts', '', 'report', 'APPROVAL: approve this GATE exactly.', '{"detail":"EXECUTION_APPROVED remains pending"}', now),
            (2, 'two', 'worker', 'alerts', '', 'report', 'Routine task finished.', '{}', now),
            (3, 'three', 'kepler', 'reports', '', 'report', 'Research report finished.', '{}', now),
            (4, 'four', 'worker', 'alerts', '', 'question', 'Please choose a maintenance window.', '{}', now),
            (5, 'five', 'worker', 'alerts', '', 'report', 'Decision recorded.', '{"decision":"EXECUTION_APPROVED pending"}', now),
            (6, 'six', 'worker', 'alerts', '', 'report', 'Gate pinned tests ran; APPROVAL.json updated; approved execution chain ok.', '{}', now)]
    db.executemany('INSERT INTO coordination_messages VALUES (?,?,?,?,?,?,?,?,?)', rows)
    db.execute('INSERT INTO coordination_acks VALUES (?,?)', ('two', 'alerts'))
(c/'host-tools.json').write_text(json.dumps({'linnet-digest': {
    'bus_db': '~/bus.sqlite', 'mailboxes': ['alerts'],
    'operator_units': ['urgent.service'], 'owners': {'later.service': 'job owner'},
    'bus_post_cmd': ['phone-send', 'post', '--recipient', '{recipient}', '--summary-file', '{summary_file}', '--key', '{idempotency_key}'],
    'bus_recipients': ['digest-reader'], 'phone_cmd': ['phone-send', 'send', '--to', 'telegram', '--quiet', '--file', '{file}']}}))
PY
run() { python3 "$ROOT/scripts/linnet-digest.py" --home "$HOME" "$@"; }
sha256sum "$HOME/bus.sqlite" > "$TMP/before"
run --dry-run --sink file --sink bus --sink phone > "$TMP/dry"
sha256sum -c "$TMP/before"
test ! -e "$XDG_STATE_HOME/crss/linnet"
test ! -e "$HOME/agent-memory"
test ! -e "$HOME/calls"
python3 - "$TMP/dry" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
needs = text.split('## Needs the operator', 1)[1].split('## What happened', 1)[0]
assert 'APPROVAL: approve this GATE exactly.' in needs
assert '{"detail":"EXECUTION_APPROVED remains pending"}' in needs
assert 'Please choose a maintenance window.' in needs
assert 'Decision recorded.' in needs
assert '{"decision":"EXECUTION_APPROVED pending"}' in needs
assert 'Gate pinned tests ran' not in needs
assert 'urgent.service' in needs
assert 'later.service' not in needs
assert 'job owner' in text and 'never.service' in text
wait = text.split('## Can wait', 1)[1].split('## Kepler', 1)[0]
assert 'stale.service last ran' in wait
assert 'calendar.service last ran' in wait
assert 'unacked: 4' in text and 'worker / report: 4' in text
assert 'sequence 3' in text and 'Research report finished.' in text
assert 'mode=ro' in text
PY
# Observe sqlite.connect in a real subprocess, rejecting every writable connection.
mkdir -p "$TMP/observe"
cat > "$TMP/observe/sitecustomize.py" <<'PY'
import os, sqlite3
original = sqlite3.connect
def readonly(database, *args, **kwargs):
    assert str(database).startswith('file:') and str(database).endswith('?mode=ro')
    assert kwargs.get('uri') is True
    with open(os.environ['HOME'] + '/ro-open', 'a') as f:
        f.write('read-only\n')
    return original(database, *args, **kwargs)
sqlite3.connect = readonly
PY
PYTHONPATH="$TMP/observe" run --sink file --sink bus --sink phone
sha256sum -c "$TMP/before"
test -f "$HOME/ro-open"
test -f "$HOME/agent-memory/shared/public/linnet/latest.md"
test -f "$XDG_STATE_HOME/crss/linnet/last.json"
python3 - "$HOME" <<'PY'
import json, pathlib, sys
h = pathlib.Path(sys.argv[1])
calls = [json.loads(s) for s in (h/'calls').read_text().splitlines()]
assert len(calls) == 2
post, phone = calls
assert post[:3] == ['post', '--recipient', 'digest-reader']
assert post[3] == '--summary-file' and post[5] == '--key'
assert post[6].startswith('linnet-')
assert phone[:5] == ['send', '--to', 'telegram', '--quiet', '--file']
summary = pathlib.Path(post[4]).read_text()
assert summary.startswith('WHAT: Linnet digest ')
assert '/ STATUS: 4 need operator, 2 failing / NEXT: read latest.md / REPLY_TO: none' in summary
PY
# A successful rewrite receives only What happened and cannot replace alerts.
cat > "$TMP/bin/rewrite" <<'STUB'
#!/usr/bin/env python3
import sys
text = sys.stdin.read()
assert 'APPROVAL: approve this GATE exactly.' not in text
assert 'Please choose a maintenance window.' not in text
print('Routine jobs completed.')
STUB
chmod +x "$TMP/bin/rewrite"
python3 - "$CRSS_HOME/host-tools.json" "$XDG_STATE_HOME/crss/linnet/last.json" <<'PY'
import json, pathlib, sys
p, state = map(pathlib.Path, sys.argv[1:])
config = json.loads(p.read_text())
config['linnet-digest']['summarize_cmd'] = ['rewrite']
p.write_text(json.dumps(config))
state.write_text(json.dumps({'window_end': '2000-01-01T00:00:00Z'}))
PY
run --sink stdout > "$TMP/rewritten"
python3 - "$TMP/rewritten" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
assert 'Routine jobs completed.' in text.split('## What happened')[1].split('## Can wait')[0]
assert 'APPROVAL: approve this GATE exactly.' in text.split('## Needs the operator')[1].split('## What happened')[0]
PY
# A broken source must leave the other sections usable.
BROKEN_SYSTEMCTL=1 run --dry-run > "$TMP/broken"
grep -F 'unavailable:' "$TMP/broken"
# Missing bus, unknown ack schema, summarizer failure and publishing retention.
python3 - "$HOME" "$CRSS_HOME" <<'PY'
import json, pathlib, sqlite3, sys
h, c = map(pathlib.Path, sys.argv[1:])
with sqlite3.connect(h/'bus.sqlite') as db:
    db.execute('DROP TABLE coordination_acks')
    db.execute('CREATE TABLE coordination_acks (mystery TEXT)')
p = c/'host-tools.json'
config = json.loads(p.read_text())
config['linnet-digest']['summarize_cmd'] = ['false']
p.write_text(json.dumps(config))
pub = h/'agent-memory/shared/public/linnet'
for n in range(40):
    (pub/f'20000101T000000{n:06d}Z.md').write_text('old')
(pub/'keep.md').write_text('keep')
PY
run --sink file
run --dry-run > "$TMP/unknown"
grep -F 'unacked count unavailable:' "$TMP/unknown"
test -f "$HOME/agent-memory/shared/public/linnet/keep.md"
python3 - "$HOME" <<'PY'
import pathlib, re, sys
pub = pathlib.Path(sys.argv[1])/'agent-memory/shared/public/linnet'
assert len([p for p in pub.iterdir() if re.fullmatch(r'\d{8}T\d{12}Z\.md', p.name)]) == 30
PY
mv "$HOME/bus.sqlite" "$HOME/missing.sqlite"
run --dry-run > "$TMP/missing"
grep -F 'Bus unavailable:' "$TMP/missing"
# An unavailable bus preserves the cursor so recovery includes missed questions.
python3 - "$ROOT/scripts/linnet-digest.py" "$HOME" "$XDG_STATE_HOME/crss/linnet/last.json" <<'PY'
import datetime as dt, json, pathlib, subprocess, sys
tool, home, cursor = map(pathlib.Path, sys.argv[1:])
cursor.write_text(json.dumps({'window_end': (dt.datetime.now(dt.timezone.utc)
                                          - dt.timedelta(hours=1)).isoformat()}))
before = cursor.read_bytes()
failed = subprocess.run([sys.executable, str(tool), '--home', str(home), '--sink', 'stdout'],
                        check=True, capture_output=True, text=True)
assert cursor.read_bytes() == before
sources = failed.stdout.split('## Sources', 1)[1]
assert 'cursor not advanced: bus unavailable' in sources
(home/'missing.sqlite').rename(home/'bus.sqlite')
recovered = subprocess.run([sys.executable, str(tool), '--home', str(home), '--sink', 'stdout'],
                           check=True, capture_output=True, text=True)
assert 'Please choose a maintenance window.' in recovered.stdout
assert cursor.read_bytes() != before
PY
printf 'test-linnet-digest: PASS\n'
