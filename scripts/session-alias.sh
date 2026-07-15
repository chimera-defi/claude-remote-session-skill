#!/usr/bin/env bash
# session-alias — resolve a short, stable session alias for a workdir folder and
# persist it. Invoked by new-session.sh (like session-git-prep). Prints the alias.
#
# Usage: session-alias <foldername> [--alias <x>]
set -uo pipefail

# PROTECT: keep in sync with session-doctor.sh. Protected folders are NEVER
# aliased — session-doctor protects sessions by substring-matching the name, so
# the identifying token must remain in it.
PROTECT='claude-remote|openclaw|hermes'
CAP=18
STORE="${SESSION_ALIAS_STORE:-$HOME/.claude/session-aliases}"

FOLDER=""; ALIAS_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    -a|--alias) ALIAS_ARG="${2:-}"; shift 2 ;;
    *) [ -z "$FOLDER" ] && FOLDER="$1"; shift ;;
  esac
done
[ -n "$FOLDER" ] || { echo "usage: session-alias <foldername> [--alias <x>]" >&2; exit 2; }

sanitize() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//'; }

infer() { # $1 = folder ; echo alias
  local f="$1" acr="" w
  if [ "${#f}" -le "$CAP" ]; then sanitize "$f"; return; fi
  local IFS='-'; for w in $f; do acr="${acr}${w:0:1}"; done
  acr="$(sanitize "$acr")"
  [ "${#acr}" -ge 2 ] && printf '%s' "$acr" || sanitize "${f:0:$CAP}"
}

store_lookup() { [ -f "$STORE" ] && awk -F'\t' -v f="$1" '$1==f{print $2; exit}' "$STORE"; }

store_upsert() { # $1 folder $2 alias — atomic
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
if printf '%s' "$FOLDER" | grep -qiE "$PROTECT"; then
  [ -n "$ALIAS_ARG" ] && echo "session-alias: '$FOLDER' is protected; ignoring --alias" >&2
  sanitize "$FOLDER"; exit 0
fi
# 1. explicit --alias -> sanitize, store, print
if [ -n "$ALIAS_ARG" ]; then
  a="$(sanitize "$ALIAS_ARG")"; [ -n "$a" ] || a="$(infer "$FOLDER")"
  store_upsert "$FOLDER" "$a"; printf '%s\n' "$a"; exit 0
fi
# 2. stored alias -> reuse
s="$(store_lookup "$FOLDER")"
if [ -n "$s" ]; then printf '%s\n' "$s"; exit 0; fi
# 3. infer + store
a="$(infer "$FOLDER")"; store_upsert "$FOLDER" "$a"; printf '%s\n' "$a"
