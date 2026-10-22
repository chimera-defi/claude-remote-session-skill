#!/usr/bin/env bash
set -u

_patterns() {
  local file="${CRSS_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/crss}/quota-patterns.txt"
  if [ -r "$file" ]; then cat "$file"; return; fi
  cat <<'EOF'
# transient/auth — never quota (Claude transcripts on this host)
transient	API Error: Rate limited
transient	OAuth session expired
transient	Login expired
transient	Response stalled mid-stream
# codex — installed Codex CLI 0.163.0 binary strings (not yet seen at runtime on this host)
codex-quota	hit your usage limit
codex-quota	Quota exceeded. Check your plan and billing details
codex-quota	usage_limit_reached
codex-quota	quota_exceeded
codex-quota	usage_not_included
codex-quota	credits_depleted
# claude — Claude CLI isApiErrorMessage text in ~/.claude/projects transcripts on this host
claude-quota	hit your monthly spend limit
claude-quota	hit your session limit
claude-quota	hit your weekly limit
claude-quota	would exceed your account's rate limit
EOF
}

classify() {
  local input=${1:--} line row cls pat lc
  local -a patterns=()
  if [ "$input" = - ]; then mapfile -t _input_lines; else mapfile -t _input_lines < "$input"; fi
  while IFS= read -r row; do
    [[ "$row" == '#'* || -z "$row" ]] && continue
    patterns+=("$row")
  done < <(_patterns)
  for line in "${_input_lines[@]}"; do
    lc=${line,,}
    for row in "${patterns[@]}"; do
      IFS=$'\t' read -r cls pat <<< "$row"
      if [[ "$lc" == *"${pat,,}"* ]]; then
        if [ "$cls" = transient ]; then echo none; return 0; fi
        printf '%s\nmatched: %s\n' "$cls" "$line"
        case "$cls" in codex-quota) return 10 ;; claude-quota) return 11 ;; *) return 0 ;; esac
      fi
    done
  done
  printf 'none\n'
}

# Both status scans follow a symlinked root (~/.claude/projects is one on some hosts).
codex_status() {
  local root=${CRSS_CODEX_SESSIONS_DIR:-$HOME/.codex/sessions} age=${CRSS_QUOTA_CODEX_MAX_AGE_MIN:-720}
  python3 - "$root" "$age" <<'PY'
import json,os,sys,time,datetime
root,age=sys.argv[1],float(sys.argv[2]); now=time.time(); files=[]
for dp,_,fs in os.walk(root,followlinks=True):
  for fn in fs:
    if fn.endswith('.jsonl'):
      p=os.path.join(dp,fn)
      try: m=os.path.getmtime(p)
      except OSError: continue
      if now-m<=age*60: files.append((m,p))
def iso(t): return datetime.datetime.fromtimestamp(t,datetime.timezone.utc).isoformat().replace('+00:00','Z') if t else 'null'
def find(x):
  if isinstance(x,dict):
    if isinstance(x.get('rate_limits'),dict): return x['rate_limits']
    for v in x.values():
      r=find(v)
      if r is not None: return r
  elif isinstance(x,list):
    for v in x:
      r=find(v)
      if r is not None: return r
  return None
for _,p in sorted(files,reverse=True):          # newest rollout that has a snapshot
  last=None
  with open(p,errors='ignore') as f:
    for ln in f:
      if '"rate_limits":{' in ln: last=ln
  if last is None: continue
  try: r=find(json.loads(last))
  except ValueError: r=None
  if r is None: continue
  typ=r.get('rate_limit_reached_type'); wins=[w for w in (r.get('primary'),r.get('secondary')) if isinstance(w,dict)]
  for w in wins:
    used=w.get('used_percent'); reset=w.get('resets_at')
    if (typ is not None or (isinstance(used,(int,float)) and used>=100)) and (reset is None or reset>now):
      print('codex-quota rate_limit_reached_type=%s used_percent=%s resets_at=%s source=%s'%(typ if typ is not None else 'null',used,iso(reset),p)); sys.exit(10)
  if typ is not None and not wins:
    print('codex-quota rate_limit_reached_type=%s used_percent=null resets_at=null source=%s'%(typ,p)); sys.exit(10)
  print('ok used_percent=%s source=%s'%(wins[0].get('used_percent') if wins else 'null',p)); sys.exit(0)
print('unknown')
PY
}

claude_status() {
  local root=${CRSS_CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects} age=${CRSS_QUOTA_CLAUDE_WINDOW_MIN:-30} hit rc
  # newest-first list of "<path>:<line>\t<text>" for recent API-error lines; classify picks the first quota one
  hit=$(python3 - "$root" "$age" <<'PY'
import json,os,sys,time,datetime
root,age=sys.argv[1],float(sys.argv[2]); now=time.time(); files=[]
for dp,_,fs in os.walk(root,followlinks=True):
  for fn in fs:
    if fn.endswith('.jsonl'):
      p=os.path.join(dp,fn)
      try: m=os.path.getmtime(p)
      except OSError: continue
      if now-m<=age*60: files.append((m,p))
for _,p in sorted(files,reverse=True):
  rows=[]
  with open(p,errors='ignore') as f:
    for n,ln in enumerate(f,1):
      if '"isApiErrorMessage":true' not in ln: continue
      try: d=json.loads(ln)
      except ValueError: continue
      try: ts=datetime.datetime.fromisoformat(d.get('timestamp','').replace('Z','+00:00')).timestamp()
      except ValueError: ts=0
      if now-ts>age*60: continue        # the line's own time, not the file's mtime
      c=d.get('message',{}).get('content',[])
      t=c[0].get('text','') if c and isinstance(c[0],dict) else ''
      if t: rows.append('%s:%d\t%s'%(p,n,t.replace('\n',' ')))
  for r in reversed(rows): print(r)
PY
)
  while IFS=$'\t' read -r src text; do
    [ -n "$text" ] || continue
    printf '%s\n' "$text" | classify >/dev/null 2>&1; rc=$?
    if [ "$rc" = 11 ]; then printf 'claude-quota text=%s source=%s\n' "$text" "$src"; return 11; fi
  done <<< "$hit"
  echo ok
}

case "${1:---help}" in
  classify) shift; classify "${1:--}" ;;
  codex-status) codex_status ;;
  claude-status) claude_status ;;
  log) shift; file=${CRSS_ROUTING_LOG:-$HOME/.sessions/routing-log.jsonl}; mkdir -p "$(dirname "$file")" 2>/dev/null || true
    python3 - "$file" "$@" <<'PY' 2>/dev/null || echo 'quota-check: routing log write failed' >&2
import json,sys,datetime,os
d={'ts':datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00','Z')}
for a in sys.argv[2:]:
 if '=' in a:
  k,v=a.split('=',1); d[k]=v
with open(sys.argv[1],'a') as f: f.write(json.dumps(d,separators=(',',':'))+'\n')
PY
    exit 0 ;;
  -h|--help) echo 'Usage: quota-check {classify [FILE|-]|codex-status|claude-status|log key=value...|--help}' ;;
  *) echo 'quota-check: unknown subcommand' >&2; exit 2 ;;
esac
