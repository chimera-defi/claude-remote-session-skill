#!/usr/bin/env bash
# session-registry — see usage() below.
# Age = the EARLIEST log line for the session name, not the latest restart. tmux's
# #{session_created} resets on each systemd restart and under-reports age (the dangerous
# direction for reap). It is a fallback only for live sessions with no log entry.
set -uo pipefail

usage() {
  cat <<'EOF'
# session-registry — query live-session age. Read-only; no new state file.
#
# Usage:
#   session-registry                     # report: every live session (recognised prefix), oldest first
#   session-registry --older-than 3d     # filter to sessions older than N days (or Nh for hours)
#   session-registry --first-seen NAME   # print NAME's first-spawn epoch from the log (exit 1, no output, if unlogged)
#
# SELF-REGISTRATION IS ALREADY WIRED: every new-session.sh spawn writes an
# `event=starting`/`event=started` line to ~/.sessions/session-starts.log via
# log_start() (see scripts/new-session.sh) on every invocation, including
# respawns of an already-running session ("already-running" event). This
# script is a pure read-only query layer over that existing log, not a fresh cache.
EOF
}

# Host overlay config: see crss-lib.sh.
_crss_lib="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/crss-lib.sh"
# shellcheck source=scripts/crss-lib.sh
. "$_crss_lib" || { echo "${0##*/}: missing $_crss_lib; install crss-lib.sh next to this script" >&2; exit 2; }
_crss_load_config

# Session-name prefix: see crss-lib.sh.
_crss_prefix_init

LOG="$HOME/.sessions/session-starts.log"
OLDER_THAN_SEC=0
FIRST_SEEN_NAME=""

while [ $# -gt 0 ]; do
  case "$1" in
    --older-than)
      v="${2:-}"; shift 2
      case "$v" in
        *d) n="${v%d}"; unit=86400 ;;
        *h) n="${v%h}"; unit=3600 ;;
        *)  echo "session-registry: --older-than wants Nd or Nh, got '$v'" >&2; exit 2 ;;
      esac
# Validate before arithmetic: a non-digit or fractional value would error or skip the threshold.
      case "$n" in
        ''|*[!0-9]*) echo "session-registry: --older-than wants Nd or Nh, got '$v'" >&2; exit 2 ;;
      esac
# 10# forces base 10 so a leading zero (08d) is not read as octal.
      OLDER_THAN_SEC=$(( 10#$n * unit ))
      ;;
    --first-seen)
      FIRST_SEEN_NAME="${2:-}"; shift 2 || shift
      [ -n "$FIRST_SEEN_NAME" ] || { echo "session-registry: --first-seen wants a session name" >&2; exit 2; }
      ;;
    -h|--help) usage; exit 0 ;;
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

# --first-seen NAME: log epoch only, no tmux fallback (it resets on restart). The reap age gate uses it.
if [ -n "$FIRST_SEEN_NAME" ]; then
  fs="$(first_seen "$FIRST_SEEN_NAME")"
  [ -n "$fs" ] || exit 1
  echo "$fs"; exit 0
fi

rows=""
for s in $(tmux ls -F '#{session_name}' 2>/dev/null | grep -E "^(${_crss_prefix_re})_"); do
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
