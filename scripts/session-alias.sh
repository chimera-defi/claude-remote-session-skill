#!/usr/bin/env bash
# session-alias — resolve a short, stable session alias for a workdir folder and
# persist it. Invoked by new-session.sh (like session-git-prep). Prints the alias.
#
# Usage: session-alias <foldername> [--alias <x>] [--set-default] [--no-save]
#
# --alias is PER-SPAWN and does not change the folder's stored default; pass
# --set-default alongside it to actually persist the new default.
set -uo pipefail

# Host overlay config: see crss-lib.sh.
_crss_lib="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/crss-lib.sh"
# shellcheck source=scripts/crss-lib.sh
. "$_crss_lib" || { echo "${0##*/}: missing $_crss_lib; install crss-lib.sh next to this script" >&2; exit 2; }
_crss_load_config

# ── Session-name prefix recognition ─────────────────────────────────────────
# Session-name prefix: see crss-lib.sh.
_crss_prefix_init

# ALIAS_PROTECT: folders never aliased, so their token survives in the session name (session-doctor
# protects by substring). Narrower than session-doctor PROTECT on purpose: a dev folder that merely
# contains "claude-remote" should alias. Empty means protect nothing; an empty ERE would match every
# folder, so fall back to a pattern that matches nothing.
: "${CRSS_ALIAS_PROTECT_NAMES:=}"
ALIAS_PROTECT="$CRSS_ALIAS_PROTECT_NAMES"
[ -n "$ALIAS_PROTECT" ] || ALIAS_PROTECT='^$'
# Invalid ERE -> grep exits 2 -> read as "not protected". Fail closed: alias nothing.
_crss_rc=0; grep -qiE -- "$ALIAS_PROTECT" </dev/null 2>/dev/null || _crss_rc=$?; [ "$_crss_rc" -le 1 ] || {
  echo "session-alias: CRSS_ALIAS_PROTECT_NAMES is not a valid regex ('$ALIAS_PROTECT'); refusing to alias any folder until it's fixed" >&2
  ALIAS_PROTECT='.'
}
CAP=18
STORE="${SESSION_ALIAS_STORE:-$HOME/.claude/session-aliases}"

FOLDER=""; ALIAS_ARG=""; NOSAVE=no; AUDIT=no; SETDEFAULT=no
while [ $# -gt 0 ]; do
  case "$1" in
    -a|--alias)      ALIAS_ARG="${2:-}"; shift 2 ;;
    -n|--no-save)    NOSAVE=yes; shift ;;   # resolve only, never write the store (dry-run)
    --set-default)   SETDEFAULT=yes; shift ;;  # opt in to PERSISTING an explicit --alias
    --audit-store)   AUDIT=yes; shift ;;    # report-only: no foldername needed
    *) [ -z "$FOLDER" ] && FOLDER="$1"; shift ;;
  esac
done
[ "$AUDIT" = yes ] || [ -n "$FOLDER" ] || { echo "usage: session-alias <foldername> [--alias <x>] [--set-default] [--no-save] | session-alias --audit-store" >&2; exit 2; }
save() { [ "$NOSAVE" = yes ] || store_upsert "$1" "$2"; }

sanitize() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//'; }

# has_mmdd_group: true if a hyphen field of $1 is a plausible MMDD. Gates the long-numeric-run check,
# so a port or ticket number is not mistaken for a session name.
has_mmdd_group() {
  local IFS='-' f mm dd
  for f in $1; do
    [ "${#f}" -eq 4 ] || continue
    case "$f" in *[!0-9]*) continue ;; esac
    mm=$((10#${f:0:2})); dd=$((10#${f:2:2}))
    if [ "$mm" -ge 1 ] && [ "$mm" -le 12 ] && [ "$dd" -ge 1 ] && [ "$dd" -le 31 ]; then
      return 0
    fi
  done
  return 1
}

# looks_like_session_name: true when $1 IS, or is a dated fragment of, a generated session name.
# Such a value is never used or stored as an alias (it would double the prefix and re-poison the store).
# Matches: the configured prefix; a long numeric run PAIRED with an MMDD group; an MMDD-HHMM pair; or
# a trailing -MMDD. Digits must validate as a real date. Case-fold first: the store is user-editable.
looks_like_session_name() {
  local v; v="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [[ "$v" =~ ^(${_crss_prefix_re})[-_] ]] && return 0
  grep -qE -- '-[0-9]{5,}' <<<"$v" && has_mmdd_group "$v" && return 0
# Check every [0-9]{4}-[0-9]{4} run, not just the first: an earlier non-date pair must not hide a real timestamp.
  local pair mm dd hh mi
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    mm=$((10#${pair:0:2})); dd=$((10#${pair:2:2}))
    hh=$((10#${pair:5:2})); mi=$((10#${pair:7:2}))
    if [ "$mm" -ge 1 ] && [ "$mm" -le 12 ] && [ "$dd" -ge 1 ] && [ "$dd" -le 31 ] \
       && [ "$hh" -ge 0 ] && [ "$hh" -le 23 ] && [ "$mi" -ge 0 ] && [ "$mi" -le 59 ]; then
      return 0
    fi
  done < <(printf '%s' "$v" | grep -oE -- '[0-9]{4}-[0-9]{4}')
  local tail d
  tail="$(printf '%s' "$v" | grep -oE -- '-[0-9]{4}$')" || return 1
  d="${tail#-}"; mm=$((10#${d:0:2})); dd=$((10#${d:2:2}))
  [ "$mm" -ge 1 ] && [ "$mm" -le 12 ] && [ "$dd" -ge 1 ] && [ "$dd" -le 31 ]
}

# desessionify: strip the prefix (case-insensitive, like looks_like_session_name) and trailing date/time
# runs, so a session-named folder yields a clean alias.
desessionify() { printf '%s' "$1" | sed -E "s/^(${_crss_prefix_re})[-_]//I; s/(-[0-9]{4,})+\$//"; }

infer() { # $1 = folder ; echo alias
  local f="$1" acr="" w a prev=""
# Strip to a fixed point: a folder poisoned more than one layer deep would otherwise keep the prefix.
  while looks_like_session_name "$f" && [ "$f" != "$prev" ]; do
    prev="$f"; f="$(desessionify "$f")"
  done
  if [ "${#f}" -le "$CAP" ]; then
    a="$(sanitize "$f")"
  else
    local IFS='-'; for w in $f; do acr="${acr}${w:0:1}"; done
    acr="$(sanitize "$acr")"
    if [ "${#acr}" -ge 2 ]; then a="$acr"; else a="$(sanitize "${f:0:$CAP}")"; fi
  fi
# Never emit an empty alias (e.g. a symbols-only name): fall back to a charset-safe checksum.
  [ -n "$a" ] || a="s$(printf '%s' "$f" | cksum | cut -d' ' -f1)"
# Final safety net: infer() must never emit a session-name-shaped alias.
  looks_like_session_name "$a" && a="s$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
  printf '%s' "$a"
}

store_lookup() { [ -f "$STORE" ] && awk -F'\t' -v f="$1" '$1==f{print $2; exit}' "$STORE"; }

store_upsert() { # $1 folder $2 alias — atomic; refuses to persist a poisoned alias
  if looks_like_session_name "$2"; then
    echo "session-alias: refusing to store session-name-shaped alias '$2' for '$1'" >&2
    return 0
  fi
  # A folder KEY containing a literal tab/newline would corrupt the TSV store
  # itself (extra fields, or extra physical "lines" from one entry — awk/read
  # are line-oriented, so a newline mid-value splits one record into several
  # garbage ones). A directory basename never legitimately needs either
  # character, so refuse to persist rather than corrupt the file for every
  # entry that shares it.
  case "$1" in
    *$'\t'*|*$'\n'*)
      echo "session-alias: refusing to store folder key containing tab/newline (alias '$2')" >&2
      return 0 ;;
  esac
  mkdir -p "$(dirname "$STORE")"
  exec 9>"${STORE}.lock"; flock 9
  local tmp; tmp="$(mktemp "${STORE}.XXXXXX")"
  { [ -f "$STORE" ] && grep -q . "$STORE" && awk -F'\t' -v f="$1" '$1!=f' "$STORE"; } > "$tmp" 2>/dev/null || true
  printf '%s\t%s\n' "$1" "$2" >> "$tmp"
  mv -f "$tmp" "$STORE"
  flock -u 9
}

# --audit-store: read-only report of stored entries where a fresh infer() disagrees. Nothing is rewritten:
# a stored value may be a deliberate short alias. Review by hand: keep it, set --alias, or delete the line.
if [ "$AUDIT" = yes ]; then
  drifted=0; total=0
  if [ -f "$STORE" ]; then
    while IFS="$(printf '\t')" read -r afolder astored; do
      case "$afolder" in ""|\#*) continue ;; esac
      total=$((total+1))
      afresh="$(infer "$afolder")"
      if [ "$afresh" != "$astored" ]; then
        echo "DRIFT  folder='$afolder'  stored='$astored'  infer-now='$afresh'"
        drifted=$((drifted+1))
      fi
    done < "$STORE"
  fi
  echo "audit: $drifted drifted / $total total entries in $STORE (not modified — review manually)"
  exit 0
fi
# Resolution order:
# 0. protected -> sanitized folder, never stored, --alias ignored (warn)
# Never grep an empty FOLDER: the default '^$' pattern would match it.
if [ -n "$FOLDER" ] && grep -qiE "$ALIAS_PROTECT" <<<"${FOLDER%$'\n'}"; then
  [ -n "$ALIAS_ARG" ] && echo "session-alias: '$FOLDER' is protected; ignoring --alias" >&2
  sanitize "$FOLDER"; exit 0
fi
# 1. explicit --alias: per-spawn only. Persisting it renamed folders after their tasks ended (drift),
# so it is stored only with --set-default.
if [ -n "$ALIAS_ARG" ]; then
  a="$(sanitize "$ALIAS_ARG")"
  if [ -z "$a" ] || looks_like_session_name "$a"; then
    [ -n "$a" ] && echo "session-alias: alias '$a' looks like a session name; inferring a clean one instead" >&2
    a="$(infer "$FOLDER")"
  fi
  [ "$SETDEFAULT" = yes ] && save "$FOLDER" "$a"
  printf '%s\n' "$a"; exit 0
fi
# 2. stored alias -> reuse, UNLESS poisoned (session-name-shaped). Poisoned entries
# can arrive from an external writer, a manual edit, or legacy data, so validate on
# READ too — discard, infer a clean alias, and self-heal the store.
s="$(store_lookup "$FOLDER")"
if [ -n "$s" ]; then
  if looks_like_session_name "$s"; then
    echo "session-alias: stored alias '$s' for '$FOLDER' looks like a session name; re-inferring" >&2
    a="$(infer "$FOLDER")"; save "$FOLDER" "$a"; printf '%s\n' "$a"; exit 0
  fi
  printf '%s\n' "$s"; exit 0
fi
# 3. infer + store
a="$(infer "$FOLDER")"; save "$FOLDER" "$a"; printf '%s\n' "$a"
