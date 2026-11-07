#!/usr/bin/env bash
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
# script is a pure read-only query layer over that existing log, not a fresh
# Age = the EARLIEST log line for the session name, not the latest restart. tmux's
# #{session_created} resets on each systemd restart and under-reports age (the dangerous
# direction for reap). It is a fallback only for live sessions with no log entry.
set -uo pipefail

# Parses (never sources) $CRSS_HOME/config.sh for CRSS_* vars; env vars win. Copied verbatim
# into every script that reads it (tests/test-crss-overlay-config.sh pins it).
# CRSS-CONFIG-LOADER-START
_crss_load_config() {
  local _crss_home _crss_cfg _crss_line _crss_key _crss_val
  _crss_home="${CRSS_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/crss}"
  export CRSS_HOME="$_crss_home"
  _crss_cfg="$_crss_home/config.sh"
  [ -r "$_crss_cfg" ] || return 0
  while IFS= read -r _crss_line || [ -n "$_crss_line" ]; do
    [[ "$_crss_line" =~ ^(CRSS_[A-Z0-9_]+)=(.*)$ ]] || continue
    _crss_key="${BASH_REMATCH[1]}"
    _crss_val="${BASH_REMATCH[2]}"
    _crss_val="${_crss_val%$'\r'}"
    case "$_crss_val" in
      \"*\") _crss_val="${_crss_val#\"}"; _crss_val="${_crss_val%\"}" ;;
      \'*\') _crss_val="${_crss_val#\'}"; _crss_val="${_crss_val%\'}" ;;
    esac
    if [ -z "${!_crss_key+x}" ]; then export "${_crss_key}=${_crss_val}"; fi
  done < "$_crss_cfg"
  return 0
}
_crss_load_config
# CRSS-CONFIG-LOADER-END

# CRSS_SESSION_PREFIX names NEW sessions (default "cs"). CRSS_LEGACY_PREFIXES are extra
# prefixes recognised when parsing but never generated. Each token must match
# ^[a-z][a-z0-9]{0,15}$, which also makes the alternation safe. An invalid prefix falls back
# to the default; any invalid legacy token drops the WHOLE legacy list, never an empty
# pattern (that would match everything on a reap path). Copied verbatim into each script that needs it.
# CRSS-PREFIX-RE-START
_crss_valid_prefix_tok() { [[ "$1" =~ ^[a-z][a-z0-9]{0,15}$ ]]; }
if [ -z "${CRSS_SESSION_PREFIX+x}" ]; then
  CRSS_SESSION_PREFIX=cs
fi
if ! _crss_valid_prefix_tok "$CRSS_SESSION_PREFIX"; then
  echo "crss: CRSS_SESSION_PREFIX '$CRSS_SESSION_PREFIX' is invalid (want ^[a-z][a-z0-9]{0,15}\$) — falling back to 'cs'" >&2
  CRSS_SESSION_PREFIX=cs
fi
_crss_prefix_re="$CRSS_SESSION_PREFIX"
if [ -n "${CRSS_LEGACY_PREFIXES:-}" ]; then
  _crss_legacy_re=""
  _crss_legacy_ok=yes
  while IFS= read -r _crss_legacy_tok; do
    [ -n "$_crss_legacy_tok" ] || continue
    if _crss_valid_prefix_tok "$_crss_legacy_tok"; then
      _crss_legacy_re="${_crss_legacy_re}|${_crss_legacy_tok}"
    else
      _crss_legacy_ok=no
    fi
  done < <(printf '%s\n' "$CRSS_LEGACY_PREFIXES" | tr '|' '\n')
  if [ "$_crss_legacy_ok" = yes ]; then
    _crss_prefix_re="${_crss_prefix_re}${_crss_legacy_re}"
  else
    echo "crss: CRSS_LEGACY_PREFIXES '$CRSS_LEGACY_PREFIXES' has an invalid element (want each ^[a-z][a-z0-9]{0,15}\$) — ignoring ALL legacy prefixes" >&2
  fi
fi
# CRSS-PREFIX-RE-END

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
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
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
