#!/usr/bin/env bash
# crss-module — run optional host-local module hooks.
set -uo pipefail
CRSS_HOME="${CRSS_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/crss}"
MODULES_DIR="$CRSS_HOME/modules"

die() { echo "crss-module: $*" >&2; exit 2; }
usage() { die 'usage: crss-module list | install <name>|--all [--dry-run] | test <name> | path <name>'; }
valid_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]*$ ]]; }
module_path() {
  valid_name "$1" || die "invalid module name: $1"
  [ -d "$MODULES_DIR/$1" ] || die "module not found: $1"
  printf '%s\n' "$MODULES_DIR/$1"
}
run_hook() {
  local dir hook="$2"
  dir="$(module_path "$1")" || return "$?"
  [ -f "$dir/$hook.sh" ] && [ -x "$dir/$hook.sh" ] || die "module $1 requires executable $hook.sh"
  CRSS_MODULE_DIR="$dir" CRSS_BIN_DIR="${CRSS_BIN_DIR:-$HOME/.local/bin}" \
    CRSS_DRY_RUN="$dry_run" "$dir/$hook.sh"
}

command="${1:-}"
[ "$#" -gt 0 ] || usage
shift
dry_run=0
case "$command" in
  list)
    [ "$#" -eq 0 ] || usage
    for dir in "$MODULES_DIR"/*; do
      [ -d "$dir" ] || continue
      name="${dir##*/}"
      valid_name "$name" || continue
      status=missing
      [ ! -f "$dir/install.sh" ] || status=present
      printf '%s\tinstall.sh: %s\n' "$name" "$status"
    done
    ;;
  install)
    [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
    target="$1"
    if [ "$#" -eq 2 ]; then
      [ "$2" = --dry-run ] || usage
      dry_run=1
    fi
    if [ "$target" = --all ]; then
      for dir in "$MODULES_DIR"/*; do
        [ -d "$dir" ] || continue
        name="${dir##*/}"
        valid_name "$name" || continue
        run_hook "$name" install || exit "$?"
      done
    else
      run_hook "$target" install || exit "$?"
    fi
    ;;
  test)
    [ "$#" -eq 1 ] || usage
    run_hook "$1" test || exit "$?"
    ;;
  path)
    [ "$#" -eq 1 ] || usage
    module_path "$1" || exit "$?"
    ;;
  *) usage ;;
esac
