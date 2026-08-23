#!/usr/bin/env bash
# session-registry — query live-session age. Read-only; no new state file.
#
# Usage:
#   session-registry                     # report: every live ah_/agenthost_ session, oldest first
#   session-registry --older-than 3d     # filter to sessions older than N days (or Nh for hours)
#
# SELF-REGISTRATION IS ALREADY WIRED: every new-session.sh spawn writes an
# `event=starting`/`event=started` line to ~/.sessions/session-starts.log via
# log_start() (see scripts/new-session.sh) on every invocation, including
# respawns of an already-running session ("already-running" event). This
# script is a pure read-only query layer over that existing log, not a fresh
# cache — a second source of truth here would just be one more thing to keep
# in sync. No new-session.sh change was needed to satisfy "self-registers".
#
# AGE = the EARLIEST log line for this session name (the original spawn), not
# the most recent restart. tmux's own #{session_created} resets on every
# systemd restart while the tmux session NAME stays the same, so it
# under-reports age for a bounced session — the dangerous direction for a
# reap/cull decision. #{session_created} is used only as a last-resort
# fallback for a live session with zero log entries (e.g. spawned before
# logging existed).
set -uo pipefail

LOG="$HOME/.sessions/session-starts.log"
OLDER_THAN_SEC=0

while [ $# -gt 0 ]; do
  case "$1" in
    --older-than)
      v="${2:-}"; shift 2
      # Validate the numeric part strictly (digits only) before splicing it into
      # arithmetic — an unvalidated value (e.g. 'xd', '3.5d', '3xd') would
      # otherwise hit `set -u`'s unbound-variable error or a bash arithmetic
      # syntax error instead of this script's own clean usage message. Same
      # class of bug session-doctor.sh's --days validation already guards
      # against; 10# forces base-10 so a leading zero (e.g. 08) isn't misread
      # as an invalid octal literal.
      n="${v%[dh]}"; unit="${v#"$n"}"
      case "$n" in
        ''|*[!0-9]*) echo "session-registry: --older-than wants Nd or Nh, got '$v'" >&2; exit 2 ;;
      esac
      case "$unit" in
        d) OLDER_THAN_SEC=$(( 10#$n * 86400 )) ;;
        h) OLDER_THAN_SEC=$(( 10#$n * 3600 )) ;;
        *) echo "session-registry: --older-than wants Nd or Nh, got '$v'" >&2; exit 2 ;;
      esac
      ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "session-registry: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

now=$(date -u +%s)

first_seen() { # $1 = tmux session name -> epoch of earliest log line, or empty
  [ -f "$LOG" ] || return 0
  local ts
  ts=$(grep -F " session=$1 " "$LOG" 2>/dev/null | head -1 | sed -n 's/^\[\([^]]*\)\].*/\1/p')
  [ -n "$ts" ] || return 0
  date -u -d "$ts" +%s 2>/dev/null
}

rows=""
for s in $(tmux ls -F '#{session_name}' 2>/dev/null | grep -E '^(ah_|agenthost_)'); do
  start=$(first_seen "$s")
  if [ -z "$start" ]; then
    start=$(tmux display-message -p -t "$s" '#{session_created}' 2>/dev/null || echo "$now")
    src=tmux-fallback
  else
    src=log
  fi
  age=$(( now - start ))
  [ "$age" -ge "$OLDER_THAN_SEC" ] || continue
  rows="${rows}${age}\t${s}\t$(date -u -d "@$start" +%Y-%m-%d 2>/dev/null)\t${src}\n"
done

[ -n "$rows" ] || { echo "session-registry: no live session matches (threshold ${OLDER_THAN_SEC}s)"; exit 0; }

printf '%b' "$rows" | sort -rn | while IFS=$'\t' read -r age s spawned src; do
  days=$(( age / 86400 ))
  printf '%-45s spawned=%s (%sd old)%s\n' "$s" "$spawned" "$days" \
    "$([ "$src" = tmux-fallback ] && echo '  [no log entry — using tmux session_created]' || echo '')"
done
