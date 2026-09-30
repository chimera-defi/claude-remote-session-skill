#!/usr/bin/env bash
# session-alias — resolve a short, stable session alias for a workdir folder and
# persist it. Invoked by new-session.sh (like session-git-prep). Prints the alias.
#
# Usage: session-alias <foldername> [--alias <x>] [--set-default] [--no-save]
#
# --alias is PER-SPAWN and does not change the folder's stored default; pass
# --set-default alongside it to actually persist the new default.
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

# ALIAS_PROTECT — folders never aliased, so their identifying token survives in
# the session name (session-doctor protects sessions by substring-matching the
# name; stripping the token via an acronym would silently drop that protection).
#
# INTENTIONALLY NARROWER than session-doctor.sh's reap PROTECT (which defaults
# to the skill's own name, "claude-remote"): a folder whose name merely
# *contains* "claude-remote" (e.g. this repo, claude-remote-session-skill) is a
# normal dev session that SHOULD alias and SHOULD be reapable when dead. Do
# not fold this into CRSS_PROTECT_NAMES. Generic default is empty (no folders
# alias-protected); a host that runs other always-on bridge sessions can set
# CRSS_ALIAS_PROTECT_NAMES to e.g. my-other-bridge via $CRSS_HOME/config.sh
# (see examples/crss-overlay/) to protect those too. An empty ALIAS_PROTECT
# would make the `grep -qiE` below match EVERY folder (an empty ERE matches
# any line) — the opposite of
# the intended "protect nothing" default — so empty falls back to a pattern
# that matches nothing.
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
# doing so yields doubled `<prefix>-<prefix>-...-MMDD-MMDD` names and re-poisons
# the store. Matches: the configured prefix ($_crss_prefix_re, see the
# CRSS-PREFIX-RE block above) with a -/_ separator; a long numeric run (timestamp/random suffix, e.g.
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
#
# Case-fold to lowercase before the prefix check: the store is documented as
# user-editable (session-aliases.example: "edit freely") and this is also the
# read-path guard for values from an external writer, so a hand-typed value with
# the prefix upper-cased (e.g. `<PREFIX>-foo-bar`, no embedded date, so none of
# the digit checks below would catch it either) must not slip past a
# case-sensitive prefix match — found via targeted probing of the read path
# with a mixed-case stored value.
looks_like_session_name() {
  local v; v="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [[ "$v" =~ ^(${_crss_prefix_re})[-_] ]] && return 0
  printf '%s' "$v" | grep -qE -- '-[0-9]{5,}' && has_mmdd_group "$v" && return 0
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
  done < <(printf '%s' "$v" | grep -oE -- '[0-9]{4}-[0-9]{4}')
  local tail d
  tail="$(printf '%s' "$v" | grep -oE -- '-[0-9]{4}$')" || return 1
  d="${tail#-}"; mm=$((10#${d:0:2})); dd=$((10#${d:2:2}))
  [ "$mm" -ge 1 ] && [ "$mm" -le 12 ] && [ "$dd" -ge 1 ] && [ "$dd" -le 31 ]
}

# desessionify — strip session-name decoration (recognised prefix, trailing
# date/timestamp runs) so a folder that is itself a session name yields a
# clean alias from the meaningful part instead of doubling the decoration.
# Prefix match is case-insensitive (sed's `I` flag) to match
# looks_like_session_name's case-folding: without it, a mixed-case folder
# like `PFX-project-0101-1234` keeps its `PFX-` prefix after the date is
# stripped, the fixed-point loop in infer() can't make progress past
# `PFX-project`, and infer() falls back to an opaque checksum alias via its
# final safety net instead of the clean `project` a same-cased folder would get.
desessionify() { printf '%s' "$1" | sed -E "s/^(${_crss_prefix_re})[-_]//I; s/(-[0-9]{4,})+\$//"; }

infer() { # $1 = folder ; echo alias
  local f="$1" acr="" w a prev=""
  # De-sessionify to a fixed point, not just once: a folder that is poisoned
  # MORE than one layer deep (e.g. `<prefix>-<prefix>-x-0722-0725`, itself the
  # doubled name a prior poisoning incident produces) would otherwise survive a
  # single pass still wearing the configured prefix and re-trigger the exact
  # doubling this guard exists to stop. Loop until desessionify stops changing
  # the string.
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
  # dangling separator (e.g. "px-0715-0630-"). Fall back to a short,
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
# 1. explicit --alias -> sanitize, validate, print. PER-SPAWN ONLY: it does NOT
# become the folder's stored default unless --set-default is passed.
#
# It used to persist unconditionally, and that was the dominant source of alias
# drift in practice. `--alias` names the *task* far more often than the *folder*
# (`--alias crss-prs`, `trs-fix`, `db-migrate`, `api-cleanup`), so one spawn
# permanently renamed the folder and every later bare `new-session <folder>`
# inherited a name describing work that finished weeks ago. Two audits found
# 11-of-37 and 11-of-42 entries drifted, and every single one was this shape --
# none were collisions. Making the common case non-destructive is the fix; the
# rare "I really do want to rename this folder for good" case opts in explicitly.
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
