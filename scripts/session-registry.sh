#!/usr/bin/env bash
# session-registry — query live-session age. Read-only; no new state file.
#
# Usage:
#   session-registry                     # report: every live session (recognised prefix), oldest first
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

# ── Host-local overlay config ────────────────────────────────────────────────
# See examples/crss-overlay/README.md. Parses (never sources) $CRSS_HOME/config.sh
# for CRSS_* vars; an env var already set wins over the file; a missing/unreadable
# file is fine (generic defaults below apply). Copied verbatim in every script
# that reads overlay config — see tests/test-crss-overlay-config.sh.
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

# ── Session-name prefix recognition ─────────────────────────────────────────
# CRSS_SESSION_PREFIX is what NEW sessions get (generic default: "cs", short
# for "claude session" — lowercase, short, memorable, and distinct from any
# prefix a given host used before). CRSS_LEGACY_PREFIXES is a `|`-separated
# list of EXTRA prefixes still RECOGNISED when parsing an existing name but
# NEVER used to generate one (a host migrating off an old prefix sets
# CRSS_SESSION_PREFIX=<new> and CRSS_LEGACY_PREFIXES=<old>, e.g. oldhost — see
# examples/crss-overlay/). Both feed one
# validated alternation, _crss_prefix_re, that every parse/generate site below
# uses instead of a hardcoded prefix. Each element must match
# ^[a-z][a-z0-9]{0,15}$ — that charset can't contain ERE metacharacters, so
# validating IS escaping here. An invalid CRSS_SESSION_PREFIX falls back to
# the generic default; ANY invalid element in CRSS_LEGACY_PREFIXES drops the
# WHOLE legacy list (not just that element) rather than guessing which of
# several bad values was meant — never to an empty pattern, which would make
# the alternation match everything (the dangerous direction in a reap path).
# Copied verbatim in every script that needs it — see
# tests/test-crss-overlay-config.sh.
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

while [ $# -gt 0 ]; do
  case "$1" in
    --older-than)
      v="${2:-}"; shift 2
      case "$v" in
        *d) n="${v%d}"; unit=86400 ;;
        *h) n="${v%h}"; unit=3600 ;;
        *)  echo "session-registry: --older-than wants Nd or Nh, got '$v'" >&2; exit 2 ;;
      esac
      # The numeric part must be validated BEFORE it reaches bash arithmetic:
      # an unvalidated value (empty, non-digit, or fractional — e.g. 'd', 'abcd',
      # '3.5d') is spliced verbatim into `$(( n * unit ))` and either throws an
      # unbound-variable/syntax error with the wrong exit code (1, not the usage
      # exit 2) or — for a case bash's arithmetic parses as a bare word rather
      # than erroring — silently falls through with OLDER_THAN_SEC left unset,
      # reporting a bogus "no session matches" instead of a usage error.
      case "$n" in
        ''|*[!0-9]*) echo "session-registry: --older-than wants Nd or Nh, got '$v'" >&2; exit 2 ;;
      esac
      # 10# forces base-10 so a leading zero (e.g. '08d') isn't parsed as an
      # invalid octal literal (same class of bug session-doctor.sh's --days
      # guards against with the same fix).
      OLDER_THAN_SEC=$(( 10#$n * unit ))
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
