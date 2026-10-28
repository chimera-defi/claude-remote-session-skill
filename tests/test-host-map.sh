#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
Q="$HERE/../scripts/host-map.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
isolate_overlay
unset HOST_TOOLS_CONFIG
# All external commands used by the inventory are fixture-scoped or deterministic.
GIT="$(command -v git)"; export GIT
mkdir -p "$TMP/bin" "$HOME/workspace" "$HOME/.sessions/old" "$HOME/.sessions/live" \
  "$HOME/.config/systemd/user" "$HOME/.config/crss" "$HOME/.claude/skills" \
  "$HOME/.claude/projects" "$HOME/memory/agents/x/private" \
  "$HOME/memory/agents/x/public" "$HOME/memory/agents/x/secrets" "$HOME/memory/shared/public"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
for name in a b; do
  "$GIT" init -q -b main "$HOME/workspace/$name"
  printf '# Heading\n\nNeutral purpose ghp_%s token=%s\n' 'FAKE123456789012345678901234' 'abc123secret' > "$HOME/workspace/$name/README.md"
  "$GIT" -C "$HOME/workspace/$name" add README.md
  "$GIT" -C "$HOME/workspace/$name" -c user.name=Fixture -c user.email=fixture@example.com commit -qm initial
  "$GIT" -C "$HOME/workspace/$name" remote add origin 'https://example.org/neutral/repo.git'
done
"$GIT" -C "$HOME/workspace/b" remote set-url origin 'ssh://git@example.org/neutral/repo'
"$GIT" -C "$HOME/workspace/a" update-ref refs/remotes/origin/main HEAD
"$GIT" -C "$HOME/workspace/a" branch --set-upstream-to=origin/main main >/dev/null
"$GIT" -C "$HOME/workspace/a" -c user.name=Fixture -c user.email=fixture@example.com commit --allow-empty -qm ahead
"$GIT" init -q -b main "$HOME/workspace/d"
"$GIT" -C "$HOME/workspace/a" worktree add -qb extra "$HOME/dropped"
rm -rf "$HOME/dropped"
printf 'dirty\n' > "$HOME/workspace/a/untracked"
printf '%s\n' '[Service]' "WorkingDirectory=$HOME/missing" 'ExecStart=/fixture-missing/bin/alpha-daemon --token=hidden' \
  'Environment=PRIVATE_VALUE=never-print-this' > "$HOME/.config/systemd/user/alpha-live.service"
printf 'ignored contents\n' > "$HOME/.claude/CLAUDE.md.bak-x"
printf 'original\n' > "$HOME/report"
printf 'backup\n' > "$HOME/report.bak"
printf 'token=%s\n' 'abc123secret' > "$HOME/memory/agents/x/secrets/key.txt"
printf 'public\n' > "$HOME/memory/agents/x/public/note.md"
printf 'private\n' > "$HOME/memory/agents/x/private/note.md"
printf 'shared\n' > "$HOME/memory/shared/public/note.md"
ln -s "$HOME/workspace" "$HOME/workspace-link"
ln -s "$HOME/memory/agents/x/public" "$HOME/.claude/plugins"
mkdir -p "$HOME/workspace/c"; ln -s "$HOME/memory/agents/x/secrets/key.txt" "$HOME/workspace/c/README.md"
python3 - "$HOME" "$TMP/config.json" <<'PY'
import json, os, pathlib, sys, time
home = pathlib.Path(sys.argv[1])
os.utime(home / '.sessions/old', (time.time() - 30 * 86400,) * 2)
pathlib.Path(sys.argv[2]).write_text(json.dumps({'host-map': {'memory_root': 'memory'}, 'servers': {'memory_root': 'ignored'}}))
PY
cat > "$TMP/bin/git" <<'STUB'
#!/bin/bash
# Reject unexpected commands, paths outside fixture HOME, and writable Git calls.
[[ ${GIT_OPTIONAL_LOCKS:-} == 0 && $1 == -C && $2 == "$HOME/"* ]] || exit 91
case "$3" in status|config|worktree|log|rev-parse) exec "$GIT" "$@" ;; *) exit 92 ;; esac
STUB
cat > "$TMP/bin/du" <<'STUB'
#!/bin/bash
[[ $1 == -sk && $2 == -- && $3 == "$HOME"* ]] || exit 91
case "$3" in */report) printf '8192\t%s\n' "$3" ;; *) printf '4\t%s\n' "$3" ;; esac
STUB
cat > "$TMP/bin/systemctl" <<'STUB'
#!/bin/bash
[[ ${FIXTURE_SERVICES:-} == 1 ]] || exit 127
printf 'alpha-live.service loaded active running Neutral service\n'
STUB
cat > "$TMP/bin/tmux" <<'STUB'
#!/bin/bash
[[ ${FIXTURE_SERVICES:-} == 1 ]] || exit 127
printf 'old\nlive\n'
STUB
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH"
# Snapshot before inspecting, including file contents, to detect accidental writes.
python3 - "$HOME" > "$TMP/before.json" <<'PY'
import hashlib, json, os, pathlib, sys
root = pathlib.Path(sys.argv[1])
print(json.dumps(sorted((str(p.relative_to(root)), p.lstat().st_mtime_ns,
                        os.readlink(p) if p.is_symlink() else hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else '')
                       for p in root.rglob('*'))))
PY
out=$("$Q" --json --home "$HOME" --config "$TMP/config.json"); rc=$?
ok 'JSON exits successfully without services' "$rc" 0
printf '%s\n' "$out" > "$TMP/out.json"
has 'duplicate origin flagged' "$out" dup-origin
hasre 'deleted worktree flagged' "$out" 'prunable|missing-dir'
has 'old session orphan candidate' "$out" 'orphan?'
has 'backup flag' "$out" backup
has 'duplicate sibling flag' "$out" 'dup?'
has 'missing command note' "$out" 'systemctl: command unavailable'
has 'missing tmux note' "$out" 'tmux: command unavailable'
hasnt 'token redacted' "$out" 'ghp_FAKE123456789012345678901234'
hasnt 'assignment redacted and secrets never read' "$out" abc123secret
hasnt 'environment never emitted' "$out" never-print-this
hasnt 'argv never emitted' "$out" hidden
hasnt 'other config keys ignored' "$out" ignored
python3 - "$TMP/out.json" <<'PY'
import json, sys
x = json.load(open(sys.argv[1]))
assert set(x) == {'tool', 'generated', 'host', 'sections', 'notes'}
assert x['tool'] == 'host-map' and x['generated'].endswith('Z')
s = {v['title']: v for v in x['sections']}
assert len(s) == 8
for sec in s.values():
    assert set(sec) == {'title', 'columns', 'rows', 'notes'}
    assert all(len(row) == len(sec['columns']) for row in sec['rows'])
    assert all(isinstance(cell, (str, int, float)) for row in sec['rows'] for cell in row)
assert s['Top level']['rows'][0][0] == 'report'
assert any(r[0] == 'workspace-link' and '→' in r[2] for r in s['Top level']['rows'])
repos = s['Workspace repos']['rows']
assert sum('dup-origin' in r[-1] for r in repos) == 2
assert next(r for r in repos if r[0].endswith('/a'))[3] == 1
assert next(r for r in repos if r[0].endswith('/a'))[2:5:2] == ['main', '+1 -0']
assert next(r for r in repos if r[0].endswith('/c'))[1] == ''
assert 'not-git' in next(r for r in repos if r[0].endswith('/c'))[-1]
assert 'no-remote' in next(r for r in repos if r[0].endswith('/d'))[-1]
assert len(s['Worktrees']['rows']) == 1
assert 'outside-workspace' in s['Worktrees']['rows'][0][-1]
assert s['Systemd user units']['rows'][0][-2:] == ['no', 'orphan']
assert next(r for r in s['Sessions']['rows'] if r[0] == 'live')[3] == 'yes'
assert next(r for r in s['Sessions']['rows'] if r[0] == 'old')[-1] == 'orphan?'
mem = s['Memory namespaces']['rows']
assert next(r for r in mem if '/secrets' in r[0])[1] == ''
assert next(r for r in mem if '/private' in r[0])[1] == 1
assert next(r for r in mem if '/shared/public' in r[0])[1] == 1
PY
ok 'JSON sections and fixture facts' "$?" 0
services=$(FIXTURE_SERVICES=1 "$Q" --json --home "$HOME" --config "$TMP/config.json")
has 'systemd state from stub' "$services" '"active", "running"'
hasnt 'tmux stub prevents old-session orphan flag' "$services" 'orphan?'
md=$("$Q" --home "$HOME" --config "$TMP/config.json")
has 'markdown table' "$md" '| name | kind | size |'
has 'markdown memory table' "$md" '## Memory namespaces'
hasnt 'markdown token redacted' "$md" 'ghp_FAKE123456789012345678901234'
hasnt 'markdown assignment redacted' "$md" abc123secret
explicit=$("$Q" --md --home "$HOME" --config "$TMP/config.json")
has 'explicit markdown' "$explicit" '## Top level'
no_config=$("$Q" --json --home "$HOME")
has 'missing config uses defaults' "$no_config" 'memory_root is not configured'
hasnt 'memory omitted without config' "$no_config" '"title": "Memory namespaces"'
env_config=$(HOST_TOOLS_CONFIG="$TMP/config.json" "$Q" --json --home "$HOME")
has 'environment config' "$env_config" '"title": "Memory namespaces"'
mkdir -p "$TMP/overlay"; cp "$TMP/config.json" "$TMP/overlay/host-tools.json"
overlay_config=$(CRSS_HOME="$TMP/overlay" "$Q" --json --home "$HOME")
has 'overlay config' "$overlay_config" '"title": "Memory namespaces"'
mkdir -p "$TMP/xdg/crss"; cp "$TMP/config.json" "$TMP/xdg/crss/host-tools.json"
xdg_config=$(env -u CRSS_HOME XDG_CONFIG_HOME="$TMP/xdg" "$Q" --json --home "$HOME")
has 'XDG config' "$xdg_config" '"title": "Memory namespaces"'
python3 - "$HOME" "$TMP/before.json" <<'PY'
import hashlib, json, os, pathlib, sys
root = pathlib.Path(sys.argv[1])
after = sorted((str(p.relative_to(root)), p.lstat().st_mtime_ns,
                os.readlink(p) if p.is_symlink() else hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else '')
               for p in root.rglob('*'))
assert json.loads(pathlib.Path(sys.argv[2]).read_text()) == [list(r) for r in after]
PY
ok 'inventory leaves fixture unchanged' "$?" 0
# Exercise exact timeout handling without waiting 20 seconds in CI.
python3 - "$Q" "$HOME" <<'PY'
import importlib.util, pathlib, subprocess, sys
from unittest.mock import patch
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('host_map', sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
inv = m.Inventory(pathlib.Path(sys.argv[2]))
with patch.object(m.subprocess, 'run', side_effect=subprocess.TimeoutExpired('du', 20)) as run:
    assert inv.size(inv.home)[0] == 'timeout'
    assert run.call_args.kwargs['timeout'] == 20
with patch.object(m.subprocess, 'run', side_effect=subprocess.TimeoutExpired('git', 5)) as run:
    assert inv.git(inv.home, 'status', '--porcelain=v2', '-b')[1] == 'timeout'
    assert run.call_args.kwargs['timeout'] == 5
assert 'timeout' in str(inv.notes)
with patch.object(m.shutil, 'which', return_value=None):
    other = m.Inventory(inv.home)
    assert other.run(['tmux', 'ls'])[1] == 'unavailable'
with patch.object(pathlib.Path, 'open', side_effect=AssertionError('protected read')):
    assert m.read_text(inv.home / 'memory/agents/x/secrets/key.txt') == ''
    assert m.read_text(inv.home / 'workspace/c/README.md') == ''
samples = ['sk-' + 'a' * 20, 'ghp_' + 'a' * 25, 'github_pat_' + 'a' * 25,
           'xoxb-' + 'a' * 20, 'AKIA' + 'A' * 16, 'eyJ' + 'a' * 10 + '.' + 'b' * 10 + '.' + 'c' * 10,
           'a' * 40, 'Z' * 50, 'token=abc123secret', 'PASSWORD:private-value',
           'token="abc123secret"', "auth='abc123secret'", 'mytoken=abc123secret',
           'https://user:pass@example.org/repo']
for sample in samples:
    assert '[REDACTED]' in m.redact(sample), sample
assert m.origin('https://user:pass@example.org/neutral/repo.git') == 'example.org/neutral/repo'
PY
ok 'timeouts, protected reads, missing commands and redaction' "$?" 0
finish "host-map"
