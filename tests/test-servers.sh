#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
S="$HERE/../scripts/servers.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
isolate_overlay
unset HOST_TOOLS_CONFIG XDG_CONFIG_HOME
export SERVERS_PROC="$TMP/proc" SERVERS_TEST_FIXTURE="$TMP/fixture"
mkdir -p "$TMP/bin" "$TMP/empty" "$TMP/fixture" "$TMP/mount" "$SERVERS_PROC/101" "$SERVERS_PROC/102" "$TMP/secrets"
ln -s "$TMP/mount" "$TMP/mount-alias"
ln -s "$TMP/secrets" "$TMP/hidden"
cat > "$SERVERS_PROC/meminfo" <<'EOF'
MemTotal:       100000 kB
MemFree:         10000 kB
MemAvailable:    40000 kB
SwapTotal:       20000 kB
SwapFree:        15000 kB
EOF
printf '0.10 0.20 0.30 1/40 99\n' > "$SERVERS_PROC/loadavg"
printf '3600.50 7200.0\n' > "$SERVERS_PROC/uptime"
printf '0::/user.slice/user-1000.slice/alpha-session.scope/alpha-daemon.service\n' > "$SERVERS_PROC/101/cgroup"
printf '0::/system.slice/alpha-worker.scope\n' > "$SERVERS_PROC/102/cgroup"
cat > "$TMP/fixture/ss" <<'EOF'
tcp LISTEN 0 128 [::1]:9000 [::]:* users:(("alpha-daemon",pid=101,fd=7))
udp UNCONN 0 0 0.0.0.0:5353 0.0.0.0:*
tcp LISTEN 0 128 127.0.0.1:8080 0.0.0.0:* users:(("alpha-worker",pid=102,fd=5),("alpha-helper",pid=103,fd=5))
EOF
cat > "$TMP/fixture/user" <<'EOF'
alpha-daemon.service loaded active running Alpha ghp_FAKE123456789012345678901234 token=xyz12345abc
alpha-clock.timer loaded active waiting Clock
alpha-session-1.service loaded active running Session one
alpha-session-2.service loaded inactive dead Session two
alpha-session-3.service loaded active running Session three
alpha-broken.service loaded failed failed Broken
alpha-env.service loaded active running Environment=PRIVATE_VALUE
EOF
cat > "$TMP/fixture/system" <<'EOF'
alpha-system.service loaded active running Alpha system daemon
alpha-paused.service loaded inactive dead Paused
alpha-awake.service loaded active running Awake
alpha-unrelated.service loaded active running Unrelated
EOF
cat > "$TMP/fixture/processes" <<'EOF'
    PID COMMAND
    101 alpha-daemon
    102 alpha-worker
    104 alpha-fallback
EOF
cat > "$TMP/fixture/top" <<'EOF'
    PID USER COMMAND %CPU %MEM RSS
    201 fixture-other alpha-small 0.1 0.2 100
    202 fixture-other alpha-large 2.0 3.0 900
    203 fixture-other alpha-mid 1.0 2.0 400
    204 fixture-other alpha-four 0.0 0.0 90
    205 fixture-other alpha-five 0.0 0.0 80
    206 fixture-other alpha-six 0.0 0.0 70
    207 fixture-other alpha-seven 0.0 0.0 60
    208 fixture-other alpha-eight 0.0 0.0 50
    209 fixture-other alpha-nine 0.0 0.0 40
    210 fixture-other alpha-ten 0.0 0.0 30
    211 fixture-other alpha-eleven 0.0 0.0 20
EOF
cat > "$TMP/bin/stub" <<'EOF'
#!/bin/bash
case "${0##*/}" in
  ss)
    [[ "$*" == '-H -tulnp' ]] || exit 90
    cat "$SERVERS_TEST_FIXTURE/ss" ;;
  systemctl)
    case "$*" in
      '--user list-units --all --plain --no-legend --type=service,timer') cat "$SERVERS_TEST_FIXTURE/user" ;;
      'list-units --all --plain --no-legend --type=service') cat "$SERVERS_TEST_FIXTURE/system" ;;
      *) exit 90 ;;
    esac ;;
  tmux)
    [[ "$1 $2" == 'ls -F' ]] || exit 90
    printf 'alpha-session\t2\t1\t1700000000\n' ;;
  ps)
    case "$*" in
      '-eo pid,comm') cat "$SERVERS_TEST_FIXTURE/processes" ;;
      '-eo pid,user,comm,%cpu,%mem,rss --sort=-rss') cat "$SERVERS_TEST_FIXTURE/top" ;;
      *) exit 90 ;;
    esac ;;
  df)
    [[ "$1 $2 $3" == '-kP -- /'* ]] || exit 90
    printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nfixture 1000 250 750 25%% %s\n' "$3" ;;
  alpha-status)
    printf 'ready token=xyz12345abc ghp_FAKE123456789012345678901234\nHIDDEN_SECOND_LINE\n' ;;
esac
EOF
chmod 755 "$TMP/bin/stub"
for command in ss systemctl tmux ps df alpha-status; do ln -s stub "$TMP/bin/$command"; done
PYTHON="$(command -v python3)"
export PATH="$TMP/bin:$PATH"
"$PYTHON" - "$TMP" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
config = {"servers": {
    "extra_mounts": [str(root / 'mount'), str(root / 'mount-alias')],
    "ports": {"9000": "alpha-api"},
    "collapse_prefixes": ["alpha-session-"],
    "system_patterns": ["^alpha-system"],
    "stopped_expected": [r"^alpha-paused\.service$", r"^alpha-awake\.service$", r"^alpha-fallback\.service$", "^alpha-absent$"],
    "components": [{"name": "alpha-component", "unit": "^alpha-daemon", "process": "^alpha-daemon$", "port": 9000, "status_cmd": ["alpha-status"]},
                   {"name": "alpha-offline", "port": 9999}]
}, "host-map": {"ports": {"5353": "MUST_NOT_APPEAR"}}, "memory-total": {"components": ["MUST_NOT_APPEAR"]}}
(root / 'config.json').write_text(json.dumps(config))
(root / 'alternate.json').write_text(json.dumps({"servers": {"ports": {"9000": "alternate-api"}}}))
(root / 'secrets' / 'config.json').write_text(json.dumps({"servers": {"ports": {"9000": "SECRET_FILE_CONTENT"}}}))
PY
out=$("$PYTHON" "$S" --json --home "$HOME" --config "$TMP/config.json"); rc=$?
ok 'JSON exits successfully' "$rc" 0
printf '%s\n' "$out" > "$TMP/output.json"
hasnt 'token shape removed' "$out" ghp_FAKE123456789012345678901234
hasnt 'assignment value removed' "$out" xyz12345abc
hasnt 'systemd environment value removed' "$out" PRIVATE_VALUE
has 'redaction marker' "$out" '[REDACTED]'
hasnt 'other tool config ignored' "$out" MUST_NOT_APPEAR
hasnt 'status command only first line' "$out" HIDDEN_SECOND_LINE
has 'unknown socket owner' "$out" other-user/unknown
has 'configured service label' "$out" alpha-api
has 'inactive expected stop' "$out" 'stopped (expected)'
has 'active expected stop' "$out" 'RUNNING (expected stopped)'
has 'process fallback' "$out" 'alpha-fallback (pid 104)'
hasnt 'system units filtered' "$out" alpha-unrelated
hasnt 'user units collapsed' "$out" alpha-session-1
has 'collapsed total' "$out" '3 units'
has 'collapsed active count' "$out" 'active=2'
has 'collapsed inactive count' "$out" 'inactive=1'
has 'collapsed sub count' "$out" 'running=2'
has 'collapsed active/sub count' "$out" 'active/running=2'
has 'last cgroup component' "$out" alpha-daemon.service
has 'scope cgroup' "$out" alpha-worker.scope
hasnt 'earlier cgroup component ignored' "$out" alpha-session.scope
has 'UTC session activity' "$out" 2023-11-14T22:13:20Z
hasnt 'other user anonymized' "$out" fixture-other
"$PYTHON" - "$TMP/output.json" "$TMP/mount" <<'PY'
import datetime, json, sys
d = json.load(open(sys.argv[1]))
assert set(d) == {'tool', 'generated', 'host', 'sections', 'notes'}
assert d['tool'] == 'servers' and isinstance(d['host'], str)
assert datetime.datetime.fromisoformat(d['generated'].replace('Z', '+00:00')).utcoffset().total_seconds() == 0
assert len(d['sections']) == 7
for s in d['sections']:
    assert set(s) == {'title', 'columns', 'rows', 'notes'}
    assert all(len(r) == len(s['columns']) for r in s['rows'])
    assert all(isinstance(c, (str, int, float)) for r in s['rows'] for c in r)
    assert not s['notes'], s['notes']
s = {s['title']: s for s in d['sections']}
resources = s['Resources']['rows']
assert ['RAM', 100000, 60000, 40000, 'KiB'] in resources
assert ['Swap', 20000, 5000, 15000, 'KiB'] in resources
assert any(r[:2] == ['Uptime', 3600.5] for r in resources)
assert any(r[:2] == ['Load average', '0.1 / 0.2 / 0.3'] for r in resources)
assert sum(r[1] == 1000 for r in resources) == 3
assert any(r[4] == '→ ' + sys.argv[2] for r in resources)
ports = s['Listening ports']['rows']
assert [r[2] for r in ports] == [5353, 8080, 8080, 9000]
assert ports[-1][3:7] == ['alpha-daemon', 101, 'alpha-daemon.service', 'alpha-daemon']
users = s['User services']['rows']
assert users[0][0] == 'alpha-broken.service'
assert sum(r[0] == 'alpha-session-*' for r in users) == 1
assert all(len(r[4]) <= 80 for r in users)
components = s['Named components']['rows']
assert components[0][2:4] == ['101', 'yes'] and components[1][3] == 'no'
top = s['Top processes']['rows']
assert len(top) == 10 and top[0][0] == 202 and top[-1][0] == 210
assert all(r[1] == 'other' for r in top)
PY
ok 'schema, resources, deduplication, sort, grouping and component states' "$?" 0
md=$("$PYTHON" "$S" --md --config "$TMP/config.json" --home "$HOME")
default_md=$("$PYTHON" "$S" --config "$TMP/config.json" --home "$HOME")
has 'explicit Markdown table' "$md" '| Proto | Local address | Port |'
hasre 'default is Markdown' "$default_md" '^# servers$'
hasnt 'Markdown token removed' "$md" ghp_FAKE123456789012345678901234
hasnt 'Markdown assignment removed' "$md" xyz12345abc
hasnt 'default Markdown token removed' "$default_md" ghp_FAKE123456789012345678901234

# All config lookup tiers, explicit missing config, and secrets symlinks.
out=$(HOST_TOOLS_CONFIG="$TMP/alternate.json" "$PYTHON" "$S" --json --config "$TMP/config.json")
has 'explicit config takes precedence' "$out" alpha-api
out=$(HOST_TOOLS_CONFIG="$TMP/alternate.json" "$PYTHON" "$S" --json)
has 'environment config' "$out" alternate-api
mkdir -p "$TMP/overlay" "$TMP/xdg/crss" "$HOME/.config/crss"
cp "$TMP/alternate.json" "$TMP/overlay/host-tools.json"
cp "$TMP/alternate.json" "$TMP/xdg/crss/host-tools.json"
cp "$TMP/alternate.json" "$HOME/.config/crss/host-tools.json"
out=$(CRSS_HOME="$TMP/overlay" "$PYTHON" "$S" --json)
has 'overlay config' "$out" alternate-api
out=$(CRSS_HOME='' XDG_CONFIG_HOME="$TMP/xdg" "$PYTHON" "$S" --json)
has 'XDG config' "$out" alternate-api
out=$(CRSS_HOME='' "$PYTHON" "$S" --json --home "$HOME")
has 'home config' "$out" alternate-api
out=$(HOST_TOOLS_CONFIG="$TMP/alternate.json" "$PYTHON" "$S" --json --config "$TMP/missing.json")
hasnt 'explicit missing config uses defaults' "$out" alternate-api
hasnt 'default components empty' "$out" alpha-component
out=$("$PYTHON" "$S" --json --config "$TMP/hidden/config.json")
ok 'secret config exits zero' "$?" 0
hasnt 'symlink into secrets not opened' "$out" SECRET_FILE_CONTENT
has 'secret config noted' "$out" 'Config unavailable'
printf '{broken' > "$TMP/broken.json"
out=$("$PYTHON" "$S" --json --config "$TMP/broken.json")
ok 'invalid config exits zero' "$?" 0
has 'invalid config noted' "$out" 'Config unavailable'

# No external executables are available except the Python interpreter.
ln -s "$PYTHON" "$TMP/empty/python3"
out=$(PATH="$TMP/empty" "$PYTHON" "$S" --json --home "$HOME" --config "$TMP/missing.json"); rc=$?
ok 'commands absent exits zero' "$rc" 0
has 'missing commands noted' "$out" 'missing command'
printf '%s\n' "$out" > "$TMP/absent.json"
"$PYTHON" - "$TMP/absent.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d['notes']
assert all(not s['rows'] for s in d['sections'] if s['title'] != 'Resources')
assert any(r[0] == 'RAM' for r in d['sections'][0]['rows'])
PY
ok 'missing command sections empty, proc still usable' "$?" 0

# Simulate timeout exceptions without sleeping or relying on real host commands.
"$PYTHON" - "$S" "$TMP/config.json" "$HOME" <<'PY'
import contextlib, io, json, runpy, subprocess, sys
from unittest.mock import patch
script, config, home = sys.argv[1:]
module = runpy.run_path(script)
def timeout(argv, **kwargs):
    assert kwargs['timeout'] == 5 and kwargs['stdin'] == subprocess.DEVNULL
    raise subprocess.TimeoutExpired(argv, kwargs['timeout'])
with patch('subprocess.run', timeout), patch('sys.argv', [script, '--json', '--config', config, '--home', home]):
    stream = io.StringIO()
    with contextlib.redirect_stdout(stream):
        module['main']()
d = json.loads(stream.getvalue())
assert all('timeout' in str(s) for s in d['sections'])
assert 'timeout' in d['sections'][5]['rows'][0][-1]
PY
ok 'every subprocess bounded, timeouts become cells and continue' "$?" 0

# Redaction covers all required credential shapes and protects non-cell strings.
"$PYTHON" - "$S" <<'PY'
import runpy, sys
m = runpy.run_path(sys.argv[1])
redact = m['redact']
samples = ['sk-' + 'a' * 16, 'ghp_' + 'a' * 20, 'github_pat_' + 'a' * 20,
           'xoxb-' + 'a' * 10, 'AKIA' + 'A' * 16,
           'eyJ' + 'a' * 8 + '.' + 'b' * 8 + '.' + 'c' * 8,
           '0123456789abcdef' * 3, 'Q/' * 24]
assert all(redact(s) == '[REDACTED]' for s in samples)
for key in ['key', 'TOKEN', 'secret', 'password', 'passwd', 'apikey', 'api_key', 'auth']:
    assert 'value' not in redact(key + '=value')
    assert 'value' not in redact(key + ': "value"')
assert 'value' not in redact('access_token=value')
assert redact('https://user:pass@example.org') == 'https://[REDACTED]@example.org'
assert 'private' not in redact('Environment=private')
assert m['sanitize']({'notes': [samples[1]], 'host': samples[0]}) == {'notes': ['[REDACTED]'], 'host': '[REDACTED]'}
assert '\\|' in m['markdown']({'tool': 'servers', 'host': 'fixture', 'generated': '', 'notes': [], 'sections': [{'title': 'T', 'columns': ['C'], 'rows': [['a|b\nc']], 'notes': []}]})
PY
ok 'all redaction patterns, metadata, and Markdown escaping' "$?" 0
finish "servers"
