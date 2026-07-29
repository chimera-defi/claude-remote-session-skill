#!/usr/bin/env bash
# session-alias — resolve a short, stable session alias for a workdir folder and
# persist it. Invoked by new-session.sh (like session-git-prep). Prints the alias.
#
# Usage: session-alias <foldername> [--alias <x>]
set -uo pipefail

# ALIAS_PROTECT — folders never aliased, so their identifying token survives in
# the session name (session-doctor protects sessions by substring-matching the
# name; stripping the token via an acronym would silently drop that protection).
#
# INTENTIONALLY NARROWER than session-doctor.sh's reap PROTECT
# (claude-remote|openclaw|hermes): only openclaw/hermes are ever spawned as
# new-session *folders* that must stay protected. The bare claude-remote /
# claude-remote-b RC bridge sessions are NOT created via new-session, so a folder
# that merely *contains* "claude-remote" (e.g. this repo, claude-remote-session-
# skill) is a normal dev session that SHOULD alias and SHOULD be reapable when
# dead. Do not add claude-remote here. session-doctor's PROTECT is unchanged and
# still shields the real bridge sessions by their literal names.
ALIAS_PROTECT='openclaw|hermes'
CAP=18
STORE="${SESSION_ALIAS_STORE:-$HOME/.claude/session-aliases}"

FOLDER=""; ALIAS_ARG=""; NOSAVE=no
while [ $# -gt 0 ]; do
  case "$1" in
    -a|--alias)   ALIAS_ARG="${2:-}"; shift 2 ;;
    -n|--no-save) NOSAVE=yes; shift ;;   # resolve only, never write the store (dry-run)
    *) [ -z "$FOLDER" ] && FOLDER="$1"; shift ;;
  esac
done
[ -n "$FOLDER" ] || { echo "usage: session-alias <foldername> [--alias <x>] [--no-save]" >&2; exit 2; }
save() { [ "$NOSAVE" = yes ] || store_upsert "$1" "$2"; }

sanitize() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//'; }

# looks_like_session_name — a value that IS (or is a dated/timestamped fragment of)
# a generated session name. Such a value must never be used or STORED as an alias:
# doing so yields doubled `ah-ah-...-MMDD-MMDD` names and re-poisons the store.
# Matches: ah-/ah_ prefix; an MMDD-HHMM timestamp; a trailing -MMDD date; or a long
# numeric run (timestamp/random suffix, e.g. -153051 / -4107171).
looks_like_session_name() {
  case "$1" in ah-*|ah_*) return 0 ;; esac
  printf '%s' "$1" | grep -qE '[0-9]{4}-[0-9]{4}|-[0-9]{4}$|-[0-9]{5,}'
}

# desessionify — strip session-name decoration (ah- prefix, trailing date/timestamp
# runs) so a folder that is itself a session name yields a clean alias from the
# meaningful part instead of doubling the decoration.
desessionify() { printf '%s' "$1" | sed -E 's/^ah[-_]//; s/(-[0-9]{4,})+$//'; }

infer() { # $1 = folder ; echo alias
  local f="$1" acr="" w a
  looks_like_session_name "$f" && f="$(desessionify "$f")"
  if [ "${#f}" -le "$CAP" ]; then
    a="$(sanitize "$f")"
  else
    local IFS='-'; for w in $f; do acr="${acr}${w:0:1}"; done
    acr="$(sanitize "$acr")"
    if [ "${#acr}" -ge 2 ]; then a="$acr"; else a="$(sanitize "${f:0:$CAP}")"; fi
  fi
  # Never emit an empty alias. A folder name with no [a-z0-9-] content after
  # normalization (e.g. a non-ASCII-only or symbols-only name) would otherwise
  # sanitize to "" here, which would then flow into a tmux/systemd name with a
  # dangling separator (e.g. "ah-0715-0630-"). Fall back to a short,
  # deterministic, charset-safe token derived from the folder name.
  [ -n "$a" ] || a="s$(printf '%s' "$f" | cksum | cut -d' ' -f1)"
  printf '%s' "$a"
}

store_lookup() { [ -f "$STORE" ] && awk -F'\t' -v f="$1" '$1==f{print $2; exit}' "$STORE"; }

store_upsert() { # $1 folder $2 alias — atomic; refuses to persist a poisoned alias
  if looks_like_session_name "$2"; then
    echo "session-alias: refusing to store session-name-shaped alias '$2' for '$1'" >&2
    return 0
  fi
  mkdir -p "$(dirname "$STORE")"
  exec 9>"${STORE}.lock"; flock 9
  local tmp; tmp="$(mktemp "${STORE}.XXXXXX")"
  { [ -f "$STORE" ] && grep -q . "$STORE" && awk -F'\t' -v f="$1" '$1!=f' "$STORE"; } > "$tmp" 2>/dev/null || true
  printf '%s\t%s\n' "$1" "$2" >> "$tmp"
  mv -f "$tmp" "$STORE"
  flock -u 9
}

# Resolution order (see spec):
# 0. protected -> sanitized folder, never stored, --alias ignored (warn)
if printf '%s' "$FOLDER" | grep -qiE "$ALIAS_PROTECT"; then
  [ -n "$ALIAS_ARG" ] && echo "session-alias: '$FOLDER' is protected; ignoring --alias" >&2
  sanitize "$FOLDER"; exit 0
fi
# 1. explicit --alias -> sanitize, validate, store, print
if [ -n "$ALIAS_ARG" ]; then
  a="$(sanitize "$ALIAS_ARG")"
  if [ -z "$a" ] || looks_like_session_name "$a"; then
    [ -n "$a" ] && echo "session-alias: alias '$a' looks like a session name; inferring a clean one instead" >&2
    a="$(infer "$FOLDER")"
  fi
  save "$FOLDER" "$a"; printf '%s\n' "$a"; exit 0
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
