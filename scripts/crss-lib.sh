# shellcheck shell=bash
# crss-lib.sh — functions shared by the crss scripts. Sourced, never run: it only defines
# functions. Each script finds it next to its own resolved path (never via PATH) and exits 2
# if it is missing. Deploy it to ~/.local/bin/crss-lib.sh before any script that sources it.
# tests/test-crss-overlay-config.sh pins the behavior.

# _crss_load_config — parses (never sources) $CRSS_HOME/config.sh for CRSS_* vars; an env var
# already set wins; a missing file is fine. See examples/crss-overlay/README.md.
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

# _crss_prefix_init — sets _crss_prefix_re. CRSS_SESSION_PREFIX names NEW sessions (default
# "cs"). CRSS_LEGACY_PREFIXES (|-separated) are recognised when parsing but never generated.
# Each token must match ^[a-z][a-z0-9]{0,15}$, which also makes the alternation safe. An invalid
# prefix falls back to the default; any invalid legacy token drops the WHOLE legacy list, never
# an empty pattern (that would match everything on a reap path).
_crss_valid_prefix_tok() { [[ "$1" =~ ^[a-z][a-z0-9]{0,15}$ ]]; }
# shellcheck disable=SC2034  # _crss_prefix_re is read by the sourcing script
_crss_prefix_init() {
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
}

# _crss_admit <args...> — run the single Agent Host admission gate (autonomous-admission.sh) for
# an autonomous action. Looks for the helper beside the CALLING script (BASH_SOURCE[1]; falls
# back to this lib's own dir for top-level calls), then on PATH; fails closed (exit 2) if neither.
_crss_admit() {
  local helper_dir helper
  helper_dir="$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")" && pwd)"
  if [ -f "$helper_dir/autonomous-admission.sh" ]; then
    helper="$helper_dir/autonomous-admission.sh"
  else
    helper="$(command -v autonomous-admission 2>/dev/null)" || return 2
  fi
  bash "$helper" "$@"
}

# _find_helper <basename> — co-located <basename>.sh first (beside the CALLING script, via
# BASH_SOURCE[1]; falls back to this lib's dir for top-level calls), then PATH; fails safe on a miss.
_find_helper() {
  local base="$1" here
  here="$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")" >/dev/null 2>&1 && pwd)"
  if [ -f "$here/${base}.sh" ]; then printf '%s\n' "$here/${base}.sh"; return 0; fi
  if command -v "$base" >/dev/null 2>&1; then command -v "$base"; return 0; fi
  return 1
}

# tmux_to_base — tmux session name to remote-control name ("<prefix>_slug" -> "<prefix>-slug"),
# or "" when the name is not ours. Needs _crss_prefix_init to have run first.
tmux_to_base() {
  if [[ "$1" =~ ^(${_crss_prefix_re})_(.*)$ ]]; then
    echo "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"
  else
    echo ""
  fi
}

# _encode_cwd <path> — the ~/.claude/projects/<encoded> dir name for a cwd. Pure string transform;
# '.' -> '-' must run before '/' -> '-'.
_encode_cwd() {
  local p="$1"
  p="${p//./-}"
  printf '%s\n' "${p//\//-}"
}

# _is_protected <text> — match CRSS_PROTECT_NAMES against the text and its hyphen/underscore
# forms, so one term protects tmux, unit and title names alike. Fails closed: a grep error
# (invalid regex) counts as protected.
# shellcheck disable=SC2154  # CRSS_PROTECT_NAMES is set by _crss_load_config in the caller
_is_protected() {
  local v rc
  [ -n "$CRSS_PROTECT_NAMES" ] || return 1
  for v in "$1" "${1//_/-}" "${1//-/_}"; do grep -qiE -- "$CRSS_PROTECT_NAMES" <<<"$v" 2>/dev/null; rc=$?; [ "$rc" -ne 1 ] && return 0; done
  return 1
}
