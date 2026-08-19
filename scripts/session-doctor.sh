#!/usr/bin/env bash
# session-doctor.sh — audit and clean up agenthost remote-control sessions across
# the layers they live in: tmux windows, systemd --user units, the Anthropic
# session registry (GET /v1/sessions), and per-session git worktrees
# (~/.claude/worktrees/, created by session-git-prep.sh for dirty/busy repos).
# Local reaping alone does not relieve session-count pressure, because the
# registry accumulates disconnected and zombie ("connected" but process-gone)
# entries independently, and worktrees accumulate independently of both.
#
# Usage:
#   session-doctor.sh                      # report (read-only) — default
#   session-doctor.sh reap-local           # remove DEAD local sessions (proc gone / orphaned unit+script)
#   session-doctor.sh registry-stale [--days N]   # list registry sessions disconnected > N days (default 30)
#   session-doctor.sh worktree-stale       # list ~/.claude/worktrees/ dirs whose owning session is dead
#
# Safety:
#   * Protected names (claude-remote*, *openclaw*, *hermes*) are NEVER reaped.
#   * A tmux/systemd entry is only reaped when its claude process is genuinely gone.
#   * Registry DELETION is intentionally NOT automated (it is account-facing and
#     irreversible). registry-stale prints candidates + the exact curl to run by hand.
#   * Worktree removal is intentionally NOT automated (a dead session's worktree may
#     hold unpushed/uncommitted work). worktree-stale prints candidates, each one's
#     dirty/unpushed status, and the exact commands to run by hand after review.
set -uo pipefail

UD="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
BIN="$HOME/.local/bin"
PROTECT='claude-remote|openclaw|hermes'
MODE="${1:-report}"; shift || true
DAYS=30; FORCE=no
while [ $# -gt 0 ]; do case "$1" in --days) DAYS="$2"; shift 2;; --force) FORCE=yes; shift;; *) shift;; esac; done
# DAYS is spliced verbatim into an embedded Python snippet below (registry-stale
# mode) as a bare identifier, e.g. `DAYS=$DAYS`. An unvalidated non-numeric value
# (typo, empty string) is therefore live Python, not data — it throws an uncaught
# NameError/SyntaxError there instead of a clean usage error. Validate here so a
# bad --days fails fast with a readable message.
case "$DAYS" in
  ''|*[!0-9]*) echo "session-doctor: --days requires a non-negative integer, got '$DAYS'" >&2; exit 2 ;;
esac
# A digit-only value can still break the embedded-as-a-literal splice: Python 3
# rejects a leading-zero integer literal (e.g. `08`) as a SyntaxError ("leading
# zeros ... not permitted"), so `--days 08` would pass the digits-only check
# above yet still crash inside the Python snippet. Canonicalize to base-10 (same
# `10#` pattern session-alias.sh uses for the same class of problem) so the
# spliced value is always a plain, leading-zero-free literal.
DAYS=$((10#$DAYS))

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

# Prefix mapping. `agenthost`/`ah` are the only prefixes we own; anything else
# (e.g. codexhost_) is NOT ours and must be left alone. PROTECT (line ~22) stays
# in sync with session-alias.sh.
tmux_to_base() { case "$1" in agenthost_*) echo "agenthost-${1#agenthost_}";; ah_*) echo "ah-${1#ah_}";; *) echo "";; esac; }
svc_to_tmux()  { case "$1" in agenthost-*) echo "agenthost_${1#agenthost-}";; ah-*) echo "ah_${1#ah-}";; *) echo "$1";; esac; }

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
case "$MODE" in
  report)
    echo "=== LOCAL: tmux sessions ==="
    for s in $(live_tmux); do
      alive=$(proc_alive "$s" && echo yes || echo NO-PROC)
      prot=$(echo "$s" | grep -qiE "$PROTECT" && echo " [PROTECTED]" || true)
      printf "  %-52s proc=%s%s\n" "$s" "$alive" "$prot"
    done
    echo "=== LOCAL: systemd units without a live tmux (orphans) ==="
    for u in $(ls "$UD" 2>/dev/null | grep -E '^(agenthost|ah)-.*\.service$'); do
      base="${u%.service}"; tm="$(svc_to_tmux "$base")"
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
      base="$(tmux_to_base "$s")"; [ -z "$base" ] && continue   # not ours (e.g. codexhost_) → leave it
      proc_alive "$s" && continue                                # alive → keep
      echo "DEAD tmux (no claude proc): $s"
      do_reap "$s" "${base}.service" "${base}-start.sh"
      reaped=$((reaped+1))
    done
    # 2. orphaned systemd units (no live tmux for them). These units are
    # Type=oneshot/RemainAfterExit=yes (see new-session.sh) — once ExecStart
    # finishes, systemd holds them "active (exited)" indefinitely regardless
    # of what later happens to the tmux session they spawned, so an is-active
    # check here would almost never be false and would skip real orphans
    # (the exact case this loop exists to reap). Same liveness definition as
    # `report`'s ORPHAN listing above: no live tmux match.
    for u in $(ls "$UD" 2>/dev/null | grep -E '^(agenthost|ah)-.*\.service$'); do
      echo "$u" | grep -qiE "$PROTECT" && continue
      base="${u%.service}"; tm="$(svc_to_tmux "$base")"
      live_tmux | grep -qx "$tm" && continue
      echo "ORPHAN unit (no tmux): $u"
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
try: arr=json.load(sys.stdin)
except: print('  (registry unavailable)'); sys.exit()
arr=arr if isinstance(arr,list) else arr.get('sessions',arr.get('data',[]))
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

  worktree-stale)
    echo "=== ~/.claude/worktrees/ dirs with no live owning session (NOT auto-removed) ==="
    WT_BASE="$HOME/.claude/worktrees"
    cand=0
    for wt in "$WT_BASE"/*/; do
      [ -d "$wt" ] || continue
      wt="${wt%/}"
      branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
      # Prefer the session name embedded in the branch (session/<remote>) over the
      # worktree DIRECTORY name: session-git-prep suffixes the directory with -$$ on
      # a path collision while leaving the branch (and so the real owning tmux
      # session) unsuffixed. Deriving liveness from the directory name in that case
      # would misread a LIVE session's worktree as dead and offer to force-remove it.
      case "$branch" in
        session/*) owned=yes; remote="${branch#session/}" ;;
        *)         owned=no;  remote="$(basename "$wt")" ;;
      esac
      echo "$remote" | grep -qiE "$PROTECT" && continue
      tm="$(svc_to_tmux "$remote")"
      # Owning session still live (tmux present AND its claude proc running)? Keep it.
      if [ -n "$tm" ] && live_tmux | grep -qx "$tm" && proc_alive "$tm"; then
        continue
      fi
      cand=$((cand+1))
      dirty=clean; git -C "$wt" status --porcelain 2>/dev/null | grep -q . && dirty=DIRTY
      if git -C "$wt" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
        ahead="$(git -C "$wt" rev-list --count '@{u}..HEAD' 2>/dev/null || echo '?')"
        upstream="ahead=${ahead}"
      else
        upstream="no-upstream"
      fi
      # Resolve the main repo this worktree belongs to, from its (possibly
      # relative, on older git) --git-common-dir, so the removal command below
      # is copy-pasteable without the reviewer having to hunt for the repo.
      common_dir="$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null)"
      case "$common_dir" in /*) : ;; *) common_dir="$wt/$common_dir" ;; esac
      mainrepo="$(cd "$common_dir/.." 2>/dev/null && pwd)"
      printf '  %-60s branch=%-30s status=%-6s %s\n' "$wt" "$branch" "$dirty" "$upstream"
      if [ -n "$mainrepo" ]; then
        # %q shell-quotes each value so the printed command is safe to copy-paste
        # even if a path or branch name contains whitespace or shell metacharacters.
        q_main="$(printf '%q' "$mainrepo")"; q_wt="$(printf '%q' "$wt")"
        if [ "$owned" = yes ]; then
          q_branch="$(printf '%q' "$branch")"
          printf '    remove: git -C %s worktree remove --force %s && git -C %s branch -D %s\n' "$q_main" "$q_wt" "$q_main" "$q_branch"
        else
          # Current branch isn't the session-owned session/<remote> name (the
          # session switched branches) — only suggest removing the worktree
          # itself; force-deleting an arbitrary, possibly-unmerged branch here
          # would risk destroying work unrelated to session cleanup.
          printf '    remove: git -C %s worktree remove --force %s\n' "$q_main" "$q_wt"
          printf '    NOTE: current branch %s is not a session/* name — leaving branch cleanup for manual review\n' "$branch"
        fi
      fi
    done
    echo "  --- $cand candidate(s). VERIFY dirty/unpushed work is not needed before removing. ---"
    ;;
  *) echo "usage: session-doctor.sh [report|reap-local|registry-stale [--days N]|worktree-stale]"; exit 2;;
esac
fi
