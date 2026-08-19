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

FOLDER=""; ALIAS_ARG=""; NOSAVE=no; AUDIT=no
while [ $# -gt 0 ]; do
  case "$1" in
    -a|--alias)      ALIAS_ARG="${2:-}"; shift 2 ;;
    -n|--no-save)    NOSAVE=yes; shift ;;   # resolve only, never write the store (dry-run)
    --audit-store)   AUDIT=yes; shift ;;    # report-only: no foldername needed
    *) [ -z "$FOLDER" ] && FOLDER="$1"; shift ;;
  esac
done
[ "$AUDIT" = yes ] || [ -n "$FOLDER" ] || { echo "usage: session-alias <foldername> [--alias <x>] [--no-save] | session-alias --audit-store" >&2; exit 2; }
save() { [ "$NOSAVE" = yes ] || store_upsert "$1" "$2"; }

sanitize() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//'; }

# has_mmdd_group — true if some hyphen-delimited field of $1 is itself a
# calendar-plausible MMDD (month 01-12, day 01-31). Used to gate the long-
# numeric-run check below: a random-suffix run of 5+ digits (as seen in legacy
# session names like `discovery-0718-153051-4107171`) is only real
# session-name evidence when paired with an actual date fragment elsewhere in
# the string — a folder that merely HAS a long number (a port >= 10000, an
# invoice/issue/build id, a ticket suffix, ...) is not one just for being long.
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

# looks_like_session_name — a value that IS (or is a dated/timestamped fragment of)
# a generated session name. Such a value must never be used or STORED as an alias:
# doing so yields doubled `ah-ah-...-MMDD-MMDD` names and re-poisons the store.
# Matches: ah-/ah_ prefix; a long numeric run (timestamp/random suffix, e.g.
# -153051 / -4107171) PAIRED WITH a real MMDD date fragment elsewhere in the
# string (see has_mmdd_group); an MMDD-HHMM timestamp pair; or a trailing -MMDD
# date — the latter two only when the digits validate as a real date/time
# (below), so an arbitrary run of digits (a year, port, chain id, ticket
# suffix, a second unrelated number, ...) is not mistaken for one. Silently
# treating any digit run as date-shaped previously collided distinct folders
# onto the same alias (found live: sprint-2024/sprint-2025 -> both "sprint";
# chain-8453 -> "chain"; port-8080 -> "port"; sprint-2024-2025 / port-8080-9090
# -> same, via the two-group check; port-12345/port-54321 -> both "port" via
# the un-gated long-numeric-run check). ${d:0:2} form needs base-10 forcing so
# a leading zero (e.g. the "07" in 0728) isn't parsed as invalid octal by [ -ge ].
looks_like_session_name() {
  case "$1" in ah-*|ah_*) return 0 ;; esac
  printf '%s' "$1" | grep -qE -- '-[0-9]{5,}' && has_mmdd_group "$1" && return 0
  # Check EVERY [0-9]{4}-[0-9]{4} run, not just the first: a value can carry an
  # earlier non-date-shaped digit pair before the real embedded timestamp (e.g.
  # `project-2024-2025-0715-2359` — "2024-2025" fails the date check, but the
  # `head -1` this used to take would stop there and never look at the genuinely
  # poisoned "0715-2359" that follows). Any single matching pair is disqualifying.
  local pair mm dd hh mi
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    mm=$((10#${pair:0:2})); dd=$((10#${pair:2:2}))
    hh=$((10#${pair:5:2})); mi=$((10#${pair:7:2}))
    if [ "$mm" -ge 1 ] && [ "$mm" -le 12 ] && [ "$dd" -ge 1 ] && [ "$dd" -le 31 ] \
       && [ "$hh" -ge 0 ] && [ "$hh" -le 23 ] && [ "$mi" -ge 0 ] && [ "$mi" -le 59 ]; then
      return 0
    fi
  done < <(printf '%s' "$1" | grep -oE -- '[0-9]{4}-[0-9]{4}')
  local tail d
  tail="$(printf '%s' "$1" | grep -oE -- '-[0-9]{4}$')" || return 1
  d="${tail#-}"; mm=$((10#${d:0:2})); dd=$((10#${d:2:2}))
  [ "$mm" -ge 1 ] && [ "$mm" -le 12 ] && [ "$dd" -ge 1 ] && [ "$dd" -le 31 ]
}

# desessionify — strip session-name decoration (ah- prefix, trailing date/timestamp
# runs) so a folder that is itself a session name yields a clean alias from the
# meaningful part instead of doubling the decoration.
desessionify() { printf '%s' "$1" | sed -E 's/^ah[-_]//; s/(-[0-9]{4,})+$//'; }

infer() { # $1 = folder ; echo alias
  local f="$1" acr="" w a prev=""
  # De-sessionify to a fixed point, not just once: a folder that is poisoned
  # MORE than one layer deep (e.g. `ah-ah-x-0722-0725`, itself the doubled
  # name a prior poisoning incident produces) would otherwise survive a single
  # pass still wearing an `ah-` prefix and re-trigger the exact doubling this
  # guard exists to stop. Loop until desessionify stops changing the string.
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
  # Never emit an empty alias. A folder name with no [a-z0-9-] content after
  # normalization (e.g. a non-ASCII-only or symbols-only name) would otherwise
  # sanitize to "" here, which would then flow into a tmux/systemd name with a
  # dangling separator (e.g. "ah-0715-0630-"). Fall back to a short,
  # deterministic, charset-safe token derived from the folder name.
  [ -n "$a" ] || a="s$(printf '%s' "$f" | cksum | cut -d' ' -f1)"
  # Final safety net: infer() must never itself emit a session-name-shaped
  # alias. The fixed-point loop above handles known layered-poisoning shapes,
  # but this catches anything unforeseen (e.g. the CAP/acronym branch
  # reintroducing a matching shape) so a still-poisoned value can never flow
  # out silently unstored.
  looks_like_session_name "$a" && a="s$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
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

# --audit-store — read-only: scan every stored folder<TAB>alias line and report
# entries where a fresh infer() (today's, fixed logic) disagrees with what's
# stored. This surfaces candidates for a stale/mis-inferred alias — e.g. one
# collapsed by a since-fixed inference bug (sprint-2024/sprint-2025 both
# stored as "sprint" from before the MMDD-validation fix) — WITHOUT touching
# the store: the stored value already looks like a legitimate short alias
# (that's why the read-path self-heal in rule 2 doesn't catch it), and the
# store is documented as user-editable (session-aliases.example: "edit
# freely"), so auto-overwriting a flagged entry could just as easily clobber
# a deliberately chosen short alias. A human reviews the printed candidates
# and decides: leave it, set an explicit --alias, or delete the line so the
# next spawn re-infers cleanly.
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
