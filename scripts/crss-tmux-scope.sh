#!/usr/bin/env bash
# crss-tmux-scope [status|adopt|migrate-scripts] [--apply]
#
# Keeps tmux servers out of session units' cgroups. Every crss unit is
# Type=oneshot RemainAfterExit=yes with KillMode=control-group: whichever unit
# first runs `tmux new-session` forks the shared server INTO ITS OWN cgroup, and
# a later `systemctl --user stop/restart` of that one unit kills the server and
# every session on it (2026-10-24: 29 sessions). Panes already live in their own
# tmux-spawn-*.scope, so only the server process needs to be elsewhere.
# new-session's generated start scripts launch tmux via `systemd-run --user
# --scope`; this tool fixes what predates that.
#
#   status           (default) each server socket under $TMUX_TMPDIR/tmux-$UID,
#                    its pid and cgroup; TRAPPED = inside a .service cgroup.
#   adopt            move each TRAPPED server into its own transient scope
#                    (crss-tmux-server-<socket>-<pid>.scope). A cgroup move sends
#                    no signal; sessions keep running. Dry-run without --apply.
#   migrate-scripts  rewrite bare `tmux new-session` lines in
#                    ~/.local/bin/*-start.sh to launch through systemd-run --scope
#                    (backup <script>.bak-precgroup kept). Dry-run without --apply.
#
# Sockets owned on purpose by their unit (ExecStop=... kill-server, e.g.
# crss-spawn-workspace) are reported but left alone unless --include-owned.
# Exit: 0 ok/nothing trapped; 1 something still trapped or a step failed; 2 usage.
set -uo pipefail

CMD="${1:-status}"; [ $# -gt 0 ] && shift
APPLY=0; INCLUDE_OWNED=0
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    --include-owned) INCLUDE_OWNED=1 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "crss-tmux-scope: unknown arg $a" >&2; exit 2 ;;
  esac
done
SOCKDIR="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"
BIN_DIR="${CRSS_BIN_DIR:-$HOME/.local/bin}"

_cgroup() { sed -n 's/^0:://p' "/proc/$1/cgroup" 2>/dev/null; }
# A unit whose ExecStop kills this socket's whole server owns it deliberately.
_owned_by_unit() {  # <unit> <socket-name>
  grep -qE "^ExecStop=.*tmux (-L $2|-S [^ ]*/$2) kill-server" <<<"$(systemctl --user cat "$1" 2>/dev/null)"
}

_servers() {  # prints: socket-name pid cgroup
  local s n p
  for s in "$SOCKDIR"/*; do
    [ -S "$s" ] || continue
    n="$(basename "$s")"
    p="$(tmux -S "$s" display-message -p '#{pid}' 2>/dev/null)" || continue
    [ -n "$p" ] && printf '%s %s %s\n' "$n" "$p" "$(_cgroup "$p")"
  done
}

cmd_status_adopt() {
  local rc=0 n p cg unit scope
  while read -r n p cg; do
    unit="${cg##*/}"
    case "$unit" in
      *.service) ;;
      *) echo "ok       $n pid=$p $unit"; continue ;;
    esac
    if [ "$INCLUDE_OWNED" = 0 ] && _owned_by_unit "$unit" "$n"; then
      echo "owned    $n pid=$p $unit (its ExecStop kills this server on purpose)"; continue
    fi
    if [ "$CMD" != adopt ] || [ "$APPLY" = 0 ]; then
      echo "TRAPPED  $n pid=$p $unit — stopping/restarting that unit kills every session on '$n'"
      [ "$CMD" = adopt ] && echo "         would move pid $p into crss-tmux-server-$n-$p.scope (re-run with --apply)"
      rc=1; continue
    fi
    scope="crss-tmux-server-$n-$p.scope"
    if busctl --user call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
         org.freedesktop.systemd1.Manager StartTransientUnit 'ssa(sv)a(sa(sv))' \
         "$scope" fail 2 PIDs au 1 "$p" Description s "crss tmux server (socket $n)" 0 >/dev/null; then
      sleep 0.5
      cg="$(_cgroup "$p")"
      if [ "${cg##*/}" = "$scope" ]; then
        echo "adopted  $n pid=$p $unit -> $scope"
      else
        echo "FAILED   $n pid=$p still in ${cg##*/}" >&2; rc=1
      fi
    else
      echo "FAILED   $n pid=$p: StartTransientUnit refused" >&2; rc=1
    fi
  done < <(_servers)
  return "$rc"
}

# Matches only a line that STARTS with a bare `tmux new-session` (already-wrapped lines start with
# systemd-run or the generated _crss_tmux helper and are left alone).
cmd_migrate() {
  local f rc=0 n=0
  for f in "$BIN_DIR"/*-start.sh; do
    [ -f "$f" ] || continue
    grep -qE '^tmux new-session ' "$f" || continue
    n=$((n+1))
    if [ "$APPLY" = 0 ]; then echo "would migrate $f"; continue; fi
    cp -p "$f" "$f.bak-precgroup" || { echo "FAILED backup $f" >&2; rc=1; continue; }
    sed -i -E 's|^tmux new-session |systemd-run --user --scope --quiet --collect -- tmux new-session |' "$f" \
      && echo "migrated $f" || { echo "FAILED $f" >&2; rc=1; }
  done
  [ "$n" = 0 ] && echo "no start script in $BIN_DIR has a bare tmux new-session line"
  return "$rc"
}

case "$CMD" in
  status|adopt) cmd_status_adopt ;;
  migrate-scripts) cmd_migrate ;;
  *) echo "crss-tmux-scope: unknown command $CMD (status|adopt|migrate-scripts)" >&2; exit 2 ;;
esac
