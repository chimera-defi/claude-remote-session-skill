#!/usr/bin/env bash
# session-doctor.sh — audit and clean up agenthost remote-control sessions across
# the THREE layers they live in: tmux windows, systemd --user units, and the
# Anthropic session registry (GET /v1/sessions). Local reaping alone does not
# relieve session-count pressure, because the registry accumulates disconnected
# and zombie ("connected" but process-gone) entries independently.
#
# Usage:
#   session-doctor.sh                      # report (read-only) — default
#   session-doctor.sh reap-local           # remove DEAD local sessions (proc gone / orphaned unit+script)
#   session-doctor.sh registry-stale [--days N]   # list registry sessions disconnected > N days (default 30)
#
# Safety:
#   * Protected names (claude-remote*, *openclaw*, *hermes*) are NEVER reaped.
#   * A tmux/systemd entry is only reaped when its claude process is genuinely gone.
#   * Registry DELETION is intentionally NOT automated (it is account-facing and
#     irreversible). registry-stale prints candidates + the exact curl to run by hand.
set -uo pipefail

UD="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
BIN="$HOME/.local/bin"
PROTECT='claude-remote|openclaw|hermes'
MODE="${1:-report}"; shift || true
DAYS=30; FORCE=no
while [ $# -gt 0 ]; do case "$1" in --days) DAYS="$2"; shift 2;; --force) FORCE=yes; shift;; *) shift;; esac; done

registry_json() {
  local tok org
  tok=$(python3 -c "import json;print(json.load(open('$HOME/.claude/.credentials.json'))['claudeAiOauth']['accessToken'])" 2>/dev/null) || return 1
  org=$(python3 -c "import json;print(json.load(open('$HOME/.claude.json')).get('oauthAccount',{}).get('organizationUuid',''))" 2>/dev/null)
  curl -s -m 25 https://api.anthropic.com/v1/sessions \
    -H "Authorization: Bearer $tok" -H "x-organization-uuid: $org" \
    -H "anthropic-version: 2023-06-01" -H "anthropic-beta: ccr-byoc-2025-07-29" 2>/dev/null
}

live_tmux()  { tmux ls 2>/dev/null | cut -d: -f1; }
# Liveness by the tmux PANE's foreground command, NOT by guessing the remote-control
# name from the tmux session name (they often differ, e.g. tmux agenthost_chimera-control
# vs remote-control chimera-server-control). claude/node = running; sleep = supervisor
# backoff (still alive); a bare shell = supervisor loop exited = genuinely dead.
proc_alive() {  # $1 = tmux session name
  case "$(tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null)" in
    claude|node|sleep) return 0 ;;
    *) return 1 ;;
  esac
}

case "$MODE" in
  report)
    echo "=== LOCAL: tmux sessions ==="
    for s in $(live_tmux); do
      alive=$(proc_alive "$s" && echo yes || echo NO-PROC)
      prot=$(echo "$s" | grep -qiE "$PROTECT" && echo " [PROTECTED]" || true)
      printf "  %-52s proc=%s%s\n" "$s" "$alive" "$prot"
    done
    echo "=== LOCAL: systemd units without a live tmux (orphans) ==="
    for u in $(ls "$UD" 2>/dev/null | grep '^agenthost-.*\.service$'); do
      base="${u%.service}"; tm="agenthost_${base#agenthost-}"
      live_tmux | grep -qx "$tm" || echo "  ORPHAN unit: $u"
    done
    echo "=== REGISTRY: staleness summary ==="
    registry_json | python3 -c "
import sys,json,datetime
try: arr=json.load(sys.stdin)
except: print('  (registry unavailable)'); sys.exit()
arr=arr if isinstance(arr,list) else arr.get('sessions',arr.get('data',[]))
from collections import Counter
now=datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
def agedays(s):
    try: return (now-datetime.datetime.fromisoformat((s.get('updated_at') or s.get('created_at'))[:19])).days
    except: return -1
disc=[s for s in arr if s.get('connection_status')=='disconnected']
zomb=[s for s in arr if s.get('connection_status')=='connected' and agedays(s)>7]
print('  total=%d  connected=%d  disconnected=%d' % (len(arr),
      sum(1 for s in arr if s.get('connection_status')=='connected'), len(disc)))
print('  disconnected >%dd (reapable): %d' % (30, sum(1 for s in disc if agedays(s)>30)))
print('  \"connected\" but >7d (likely zombies): %d' % len(zomb))
print('  session_status:', dict(Counter(s.get('session_status') for s in arr)))
"
    ;;

  reap-local)
    [ "$FORCE" = yes ] || echo "(DRY-RUN — re-run with --force to actually reap)"
    do_reap() {  # $1=tmux-name-or-empty $2=service $3=start-script
      if [ "$FORCE" = yes ]; then
        systemctl --user disable --now "$2" >/dev/null 2>&1 || true
        [ -n "$UD" ] && [ -f "$UD/$2" ] && rm -f "$UD/$2"
        [ -n "$UD" ] && [ -L "$UD/default.target.wants/$2" ] && rm -f "$UD/default.target.wants/$2"
        [ -n "$BIN" ] && [ -n "$3" ] && [ -f "$BIN/$3" ] && rm -f "$BIN/$3"
        [ -n "$1" ] && tmux kill-session -t "$1" 2>/dev/null || true
      fi
    }
    reaped=0
    # 1. tmux sessions whose claude proc is gone (skip protected).
    for s in $(live_tmux); do
      echo "$s" | grep -qiE "$PROTECT" && continue
      proc_alive "$s" && continue                      # alive → keep
      echo "DEAD tmux (no claude proc): $s"
      do_reap "$s" "agenthost-${s#agenthost_}.service" "agenthost-${s#agenthost_}-start.sh"
      reaped=$((reaped+1))
    done
    # 2. orphaned systemd units (no live tmux, service not active).
    for u in $(ls "$UD" 2>/dev/null | grep '^agenthost-.*\.service$'); do
      echo "$u" | grep -qiE "$PROTECT" && continue
      base="${u%.service}"; tm="agenthost_${base#agenthost-}"
      live_tmux | grep -qx "$tm" && continue
      systemctl --user is-active --quiet "$u" && continue   # still active → keep
      echo "ORPHAN unit (no tmux, inactive): $u"
      do_reap "" "$u" "${base}-start.sh"
      reaped=$((reaped+1))
    done
    [ "$FORCE" = yes ] && systemctl --user daemon-reload >/dev/null 2>&1 || true
    echo "$([ "$FORCE" = yes ] && echo reaped || echo would-reap) $reaped dead local item(s)"
    ;;

  registry-stale)
    echo "=== registry sessions disconnected > ${DAYS}d (deletion candidates; NOT auto-deleted) ==="
    registry_json | python3 -c "
import sys,json,datetime
arr=json.load(sys.stdin); arr=arr if isinstance(arr,list) else arr.get('sessions',arr.get('data',[]))
now=datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None); DAYS=$DAYS
def agedays(s):
    try: return (now-datetime.datetime.fromisoformat((s.get('updated_at') or s.get('created_at'))[:19])).days
    except: return -1
cand=[s for s in arr if s.get('connection_status')=='disconnected' and agedays(s)>DAYS]
cand.sort(key=agedays, reverse=True)
for s in cand:
    print('  %s  age=%3dd  status=%-9s  %s' % (s.get('id'), agedays(s), s.get('session_status'), (s.get('title') or '')[:40]))
print('  --- %d candidate(s). To delete one (VERIFY FIRST): ---' % len(cand))
print('  curl -X DELETE https://api.anthropic.com/v1/sessions/<ID> \\\\')
print('    -H \"Authorization: Bearer \$TOKEN\" -H \"x-organization-uuid: \$ORG\" \\\\')
print('    -H \"anthropic-version: 2023-06-01\" -H \"anthropic-beta: ccr-byoc-2025-07-29\"')
"
    ;;
  *) echo "usage: session-doctor.sh [report|reap-local|registry-stale [--days N]]"; exit 2;;
esac
