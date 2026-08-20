#!/usr/bin/env bash
# session-preserve — verify a session's work is durable BEFORE reaping it.
#
# Usage:
#   session-preserve <tmux-session>            # audit only (default). exit 0 = safe to reap
#   session-preserve <tmux-session> --rescue   # + copy non-junk untracked files to a rescue dir
#   session-preserve <tmux-session> --wip      # + commit uncommitted TRACKED changes as a WIP commit
#   session-preserve --all                     # audit every live ah_/agenthost_ session
#
# WHY THIS EXISTS (2026-08-17): a reap sweep was nearly run against a fleet
# audited with `git log @{u}..`, which returns NOTHING when a branch has no
# upstream configured — so 10,162 local-only commits were reported as "0
# unpushed". Never use @{u} for this. Use `git log HEAD --not --remotes`, and
# treat "repo has no remote at all" as its own finding.
set -uo pipefail

RESCUE_ROOT="$HOME/.sessions/rescued-$(date +%Y-%m-%d)"
# Junk that every session regenerates — never worth rescuing or blocking a reap.
JUNK_RE='(^|/)(\.claude/skills|\.claude/token-reduce-state|\.claude/tmp-briefs|\.superpowers|__pycache__|\.pytest_cache|node_modules|\.venv|\.gstack)(/|$)'

MODE_RESCUE=no; MODE_WIP=no; TARGET=""; ALL=no
while [ $# -gt 0 ]; do
  case "$1" in
    --rescue) MODE_RESCUE=yes; shift ;;
    --wip)    MODE_WIP=yes; shift ;;
    --all)    ALL=yes; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) TARGET="$1"; shift ;;
  esac
done

rundir_of() {  # $1 = tmux session -> cwd of the claude process
  local pid cpid
  pid=$(tmux list-panes -t "$1" -F '#{pane_pid}' 2>/dev/null | head -1) || return 1
  [ -n "$pid" ] || return 1
  cpid=$(pgrep -P "$pid" 2>/dev/null | head -1)
  [ -n "$cpid" ] || return 1
  readlink "/proc/$cpid/cwd" 2>/dev/null
}

audit_one() {
  local s="$1" cwd br nremote local_only unreach dirty untracked reasons
  cwd=$(rundir_of "$s")
  echo "### $s"
  if [ -z "$cwd" ]; then echo "   rundir: UNKNOWN (proc gone) — verdict: SAFE-TO-REAP (nothing to preserve)"; return 0; fi
  echo "   rundir: $cwd"
  if ! git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
    echo "   (not a git repo) — verdict: SAFE-TO-REAP"; return 0
  fi

  br=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
  nremote=$(git -C "$cwd" remote 2>/dev/null | wc -l)
  echo "   branch: $br"
  echo "   remotes configured: $nremote"

  # Correct local-only count. NOT @{u}.. — that is silent without an upstream.
  local_only=$(git -C "$cwd" log --oneline HEAD --not --remotes 2>/dev/null | wc -l)
  echo "   commits not on any remote: $local_only"
  if [ "$nremote" -eq 0 ]; then
    echo "   ^^ repo has NO REMOTE — these commits exist ONLY on this disk. Pushing is impossible"
    echo "      until a remote is added; the local branch ref IS the only copy."
  fi

  # What actually decides reap safety: is HEAD reachable from a named branch?
  # If yes, removing the worktree/tmux session cannot orphan the commits.
  if git -C "$cwd" for-each-ref --format='%(refname:short)' refs/heads \
       | while read -r b; do git -C "$cwd" merge-base --is-ancestor HEAD "refs/heads/$b" 2>/dev/null && echo hit && break; done | grep -q hit; then
    unreach=no
  else
    unreach=yes
  fi
  echo "   HEAD reachable from a named local branch: $([ "$unreach" = no ] && echo yes || echo 'NO')"

  dirty=$(git -C "$cwd" diff --name-only HEAD 2>/dev/null | grep -vE "$JUNK_RE" | wc -l)
  untracked=$(git -C "$cwd" ls-files --others --exclude-standard 2>/dev/null | grep -vE "$JUNK_RE" | wc -l)
  echo "   uncommitted TRACKED changes (non-junk): $dirty"
  echo "   untracked files (non-junk): $untracked"
  [ "$untracked" -gt 0 ] && git -C "$cwd" ls-files --others --exclude-standard 2>/dev/null \
      | grep -vE "$JUNK_RE" | head -10 | sed 's/^/       /'

  if [ "$MODE_WIP" = yes ] && [ "$dirty" -gt 0 ]; then
    git -C "$cwd" add -A -- . ':!*.claude/skills' 2>/dev/null
    git -C "$cwd" commit -q -m "wip(session-preserve): checkpoint before reaping $s" 2>/dev/null \
      && echo "   WIP committed on $br" || echo "   WIP commit FAILED — do not reap"
    dirty=0
  fi

  if [ "$MODE_RESCUE" = yes ] && [ "$untracked" -gt 0 ]; then
    mkdir -p "$RESCUE_ROOT"
    git -C "$cwd" ls-files --others --exclude-standard 2>/dev/null | grep -vE "$JUNK_RE" | while read -r rel; do
      cp -f "$cwd/$rel" "$RESCUE_ROOT/${s}__$(printf '%s' "$rel" | tr '/' '_')" 2>/dev/null \
        && echo "   rescued: $rel"
    done
    untracked=0
  fi

  reasons=""
  [ "$unreach"   = yes ] && reasons="$reasons HEAD-not-on-a-branch"
  [ "$dirty"     -gt 0 ] && reasons="$reasons uncommitted-tracked-changes"
  [ "$untracked" -gt 0 ] && reasons="$reasons untracked-files"
  if [ -n "$reasons" ]; then
    echo "   VERDICT: NOT-SAFE-TO-REAP —$reasons"
    echo "            re-run with --wip and/or --rescue, then re-audit."
    return 1
  fi
  echo "   VERDICT: SAFE-TO-REAP (work is on branch '$br'; NEVER delete that branch)"
  return 0
}

if [ "$ALL" = yes ]; then
  rc=0
  for s in $(tmux ls -F '#{session_name}' 2>/dev/null | grep -E '^(ah_|agenthost_)' | sort); do
    audit_one "$s" || rc=1; echo
  done
  exit $rc
fi

[ -n "$TARGET" ] || { echo "usage: session-preserve <tmux-session> [--rescue] [--wip] | --all" >&2; exit 2; }
audit_one "$TARGET"
