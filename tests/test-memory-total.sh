#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
isolate_overlay
TOOL="$HERE/../scripts/memory-total.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
unset HOST_TOOLS_CONFIG XDG_CONFIG_HOME
mkdir -p "$HOME/.claude/rules" "$HOME/.config/x" "$HOME/workspace/sample/docs" \
  "$HOME/.claude/projects/-proj/memory" "$HOME/stores/agents/a/private/secrets" \
  "$HOME/stores/shared/public" "$HOME/.claude/skills/one" "$HOME/.claude/agents" \
  "$HOME/.claude/plugins/cache" "$TMP/bin" "$HOME/knowledge" "$HOME/workspace/sample/.claude/worktrees/hidden"
export PATH="$TMP/bin:$PATH"
cat > "$TMP/bin/alpha-status" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'token=FAKEvisiblevalue' 'Environment=HIDDEN_VALUE' 'alpha-status-ready'
SH
chmod 755 "$TMP/bin/alpha-status"
printf '@RTK.md\n@~/.config/x/local.md\n' > "$HOME/.claude/CLAUDE.md"
printf '@CLAUDE.md\n' > "$HOME/.claude/RTK.md"
printf '@third.md\n' > "$HOME/.config/x/local.md"
printf 'third instruction\n' > "$HOME/.config/x/third.md"
printf 'global rule\n' > "$HOME/.claude/rules/style.md"
printf 'home instructions\n' > "$HOME/AGENTS.md"
printf 'project instructions\n' > "$HOME/workspace/sample/CLAUDE.md"
printf 'documentation\n' > "$HOME/workspace/sample/docs/guide.md"
printf 'hidden instructions\n' > "$HOME/workspace/sample/.claude/worktrees/hidden/CLAUDE.md"
printf 'ordinary memory\n' > "$HOME/stores/agents/a/private/note.md"
printf 'shared memory\n' > "$HOME/stores/shared/public/note.md"
printf '%s\n' 'ghp_FAKE012345678901234567890123' 'password=hunter2xyz' > "$HOME/stores/agents/a/private/secrets/credential"
printf '%s\n' 'ghp_FAKE012345678901234567890123' > "$HOME/knowledge/token=FAKEfilename"
printf '%s\n' 'transcript content' > "$HOME/.claude/projects/-proj/session.jsonl"
printf '%s\n' '---' 'description: A small fixture skill.' '---' 'Body is not startup context.' > "$HOME/.claude/skills/one/SKILL.md"
printf 'agent body\n' > "$HOME/.claude/agents/helper.md"
printf 'plugin payload\n' > "$HOME/.claude/plugins/cache/item"
ln -s one "$HOME/.claude/skills/two"
python3 - "$HOME" <<'PY'
import json, pathlib, sys
home = pathlib.Path(sys.argv[1])
memory = home / '.claude/projects/-proj/memory/MEMORY.md'
memory.write_bytes(b'line\n' * 250)
slug = str(home / 'workspace/sample').replace('/', '-')
(home / '.claude/projects' / slug).symlink_to('-proj', target_is_directory=True)
(home / 'config.json').write_text(json.dumps({'memory-total': {
    'memory_root': '~/stores', 'workspace_dirs': ['~/workspace'],
    'kb_sources': [{'name': 'ghp_FAKE012345678901234567890123 token=FAKEsource', 'path': '~/knowledge'}],
    'kb_status_cmd': ['alpha-status'], 'extra_start_files': ['~/.config/x/third.md']},
    'servers': {'memory_root': '~/not-selected'}}))
PY
out=$("$TOOL" --json --home "$HOME" --project "$HOME/workspace/sample" --config "$HOME/config.json"); rc=$?
ok 'json exits successfully' "$rc" 0
hasnt 'token absent' "$out" 'ghp_FAKE012345678901234567890123'
hasnt 'assignment absent' "$out" 'token=FAKE'
hasnt 'password absent' "$out" 'hunter2xyz'
hasnt 'unit environment absent' "$out" 'HIDDEN_VALUE'
has 'secrets labeled' "$out" 'secrets (not read)'
has 'redaction visible' "$out" '[REDACTED]'
has 'status stub used' "$out" 'alpha-status-ready'
hasnt 'other config ignored' "$out" 'not-selected'
hasnt 'worktrees excluded' "$out" 'hidden/CLAUDE.md'
has 'aliases shown' "$out" '→'
printf '%s\n' "$out" > "$TMP/report.json"
checks=$(python3 - "$TMP/report.json" "$HOME" <<'PY'
import json, pathlib, sys
d = json.loads(pathlib.Path(sys.argv[1]).read_text())
h = pathlib.Path(sys.argv[2])
sections = {s['title']: s for s in d['sections']}
assert d['tool'] == 'memory-total' and len(sections) == 6
assert d['generated'].endswith('+00:00')
for s in sections.values():
    assert all(len(row) == len(s['columns']) for row in s['rows'])
    assert s['notes']
s = sections['Session-start context']
for suffix in ['/.claude/RTK.md', '/.config/x/local.md', '/.config/x/third.md']:
    rows = [r for r in s['rows'] if r[2].endswith(suffix)]
    assert len(rows) == 1 and rows[0][6] == 'yes'
auto = [r for r in s['rows'] if r[1].startswith('auto-memory')][0]
assert auto[4:7] == [1000, 250, 'partial']
assert s['rows'][-1][4] == sum(r[4] for r in s['rows'][:-1])
assert any('cycle-safe' in note for note in s['notes'])
a = sections['Claude auto-memory']['rows']
assert sum(r[3] for r in a if r[1] == 'auto-memory') == 1
assert sum(r[4] for r in a if r[1] == 'auto-memory') == 1250
assert any(r[-1] == 250 for r in a if r[1] == 'auto-memory')
assert [r for r in a if r[1] == 'transcripts'][0][3] == 1
a = sections['Agent memory']['rows']
assert sum(r[3] for r in a) == 3
assert sum(r[4] for r in a) == sum(p.stat().st_size for p in (h/'stores').rglob('*') if p.is_file())
assert any(r[1] == 'documentation' and r[6] == 'no' for r in sections['Instruction files']['rows'])
a = sections['Skills & agents']['rows']
assert sum(r[3] for r in a if r[1] == 'skill') == 1
assert sum(r[-1] for r in a) > 0
print('schema/imports/cycles/partial/dedupe/totals verified')
PY
); rc=$?
ok 'structured inventory invariants' "$rc" 0
has 'all inventory checks ran' "$checks" 'totals verified'
md=$("$TOOL" --md --home "$HOME" --project "$HOME/workspace/sample" --config "$HOME/config.json")
hasre 'markdown table' "$md" '^\| store \| kind \| path \|'
hasnt 'markdown redacts token' "$md" 'ghp_FAKE012345678901234567890123'
default=$("$TOOL" --home "$HOME" --project "$HOME/workspace/sample" --config "$HOME/config.json")
has 'default is markdown' "$default" '# memory-total'
export HOST_TOOLS_CONFIG="$HOME/config.json"
envout=$("$TOOL" --json --home "$HOME" --project "$HOME/workspace/sample")
has 'environment config' "$envout" 'alpha-status-ready'
unset HOST_TOOLS_CONFIG
export CRSS_HOME="$HOME/overlay"; mkdir -p "$CRSS_HOME"
cp "$HOME/config.json" "$CRSS_HOME/host-tools.json"
overlay=$("$TOOL" --json --home "$HOME" --project "$HOME/workspace/sample")
has 'overlay config' "$overlay" 'alpha-status-ready'
missing=$("$TOOL" --json --config "$HOME/missing.json" --home "$HOME" --project "$HOME/workspace/sample")
has 'missing config defaults' "$missing" 'No memory_root configured.'
hasnt 'explicit config overrides overlay' "$missing" 'alpha-status-ready'
# Enforce content-read boundaries and no writes in the inventory process.
python3 - "$TOOL" "$HOME" <<'PY'
import contextlib, io, pathlib, runpy, sys
tool, home = sys.argv[1:]
allowed = {'CLAUDE.md', 'AGENTS.md', 'RTK.md', 'local.md', 'third.md',
           'style.md', 'MEMORY.md', 'SKILL.md', 'config.json'}
def audit(event, args):
    if event != 'open' or not isinstance(args[0], str) or not args[0].startswith(home):
        return
    p = pathlib.Path(args[0])
    assert 'secrets' not in p.parts and 'secrets' not in p.resolve().parts, p
    assert p.name in allowed, p
    assert not args[2] & (1 | 2 | 64 | 512 | 1024), 'inventory attempted a write'
sys.addaudithook(audit)
sys.argv = [tool, '--json', '--config', home+'/config.json', '--home', home, '--project', home+'/workspace/sample']
with contextlib.redirect_stdout(io.StringIO()):
    runpy.run_path(tool, run_name='__main__')
PY
ok 'stat-only secrets and content boundaries; no writes' "$?" 0
python3 - "$TOOL" "$HOME" <<'PY'
import runpy, subprocess, sys
from unittest.mock import patch
module = runpy.run_path(sys.argv[1])
Inventory = module['Inventory']
home = module['Path'](sys.argv[2])
inv = Inventory(home)
with patch('subprocess.run', side_effect=FileNotFoundError):
    inv.knowledge({'kb_status_cmd': ['absent-command']})
assert not inv.sections[0]['rows'] and any('missing' in n for n in inv.sections[0]['notes'])
inv = Inventory(home)
with patch('subprocess.run', side_effect=subprocess.TimeoutExpired('alpha-status', 5)) as call:
    inv.knowledge({'kb_status_cmd': ['alpha-status']})
assert call.call_args.kwargs['timeout'] == 5
assert any('timeout' in n for n in inv.sections[0]['notes'])
assert inv.sections[0]['rows'][0][2] == 'timeout'
inv = Inventory(home)
section, _ = inv.section('Instruction files')
with patch.object(module['Path'], 'stat', side_effect=PermissionError(13, 'Permission denied')):
    assert not inv.is_type(home/'unreadable', section, True)
assert any('Permission denied' in n for n in section['notes'])
inv = Inventory(home)
inv.workspace({'workspace_dirs': ['~/workspace']})
# A symlink loop must be noted rather than aborting the scan.
(home/'workspace/sample/loop').symlink_to('loop')
inv.workspace({'workspace_dirs': ['~/workspace']})
assert any('symbolic links' in n for n in inv.sections[-1]['notes'])
redact = module['redact']
for value in ['sk-'+'a'*20, 'ghp_'+'b'*25, 'github_pat_'+'c'*25,
              'xoxb-'+'d'*12, 'AKIA'+'A'*16, 'eyJ'+'a'*10+'.'+'b'*10+'.'+'c'*10,
              'a'*40, 'z'*50, 'password=example-value', 'https://u:p@example.org']:
    assert '[REDACTED]' in redact(value)
PY
ok 'missing command, timeout, inaccessible paths and redaction patterns' "$?" 0
finish "memory-total"
