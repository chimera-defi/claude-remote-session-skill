#!/usr/bin/env bash
# session-spawn-server — let the phone START new sessions on this host, with no agent in the loop.
#
# Wraps Claude Code's native Remote Control server mode (`claude remote-control --spawn ...`,
# CLI >= 2.1.30x; check `claude remote-control --help`) in the same envelope new-session uses:
# a tmux session running a restart loop, a generated start script and a systemd user unit. The
# server shows up as an environment in the Claude app / claude.ai/code; "new session" there starts
# a fresh session in <dir> on this host (in its own git worktree with --spawn worktree).
#
#   session-spawn-server install <dir> [--name N] [--spawn worktree|same-dir] [--capacity N]
#                                      [--model M] [--permission-mode M] [--dry-run]
#   session-spawn-server status
#   session-spawn-server uninstall <name>
#
# Why each choice (see references/phone-spawn.md):
#   * `remote-control` takes no --settings/--model (verified: "Unknown argument: --settings"), so the
#     first-party base URL the bridge needs and the optional model go in as env on the exec line;
#     spawned sessions inherit them. A proxy ANTHROPIC_BASE_URL silently stops registration.
#   * Plain relaunch on exit, never `-c`: `remote-control -c` errors when nothing was recorded in the
#     last ~4h, so a server down overnight would crash-loop.
#   * Names live under `crss-spawn-*`, outside the session prefix, so session-doctor never sees the
#     unit as a session (or an orphan to reap).
#   * Spawned sessions default to --permission-mode auto (the CLI's classifier gates each action),
#     not bypassPermissions: anyone holding the account on a phone can start one, unattended crss
#     lanes are a different trust case. bypassPermissions is an explicit --permission-mode opt-in.
#   * In a git dir the pre-created session is off (--no-create-session-in-dir): it would sit in the
#     checkout itself, which may be a canonical checkout on local main.
# Tests: tests/test-session-spawn-server.sh.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

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
# Same claude resolution as new-session.
if [ -z "${CRSS_CLAUDE_BIN:-}" ]; then
  if [ -x /usr/bin/claude ]; then CRSS_CLAUDE_BIN=/usr/bin/claude; else CRSS_CLAUDE_BIN="$(command -v claude 2>/dev/null || echo claude)"; fi
fi
: "${CRSS_BIN_DIR:=$HOME/.local/bin}"
: "${CRSS_SYSTEMD_DIR:=$HOME/.config/systemd/user}"
: "${CRSS_RC_BASE_URL:=https://api.anthropic.com}"
: "${CRSS_SPAWN_SERVER_CAPACITY:=4}"
: "${CRSS_SPAWN_SERVER_PERMISSION_MODE:=auto}"
: "${CRSS_SYSTEMCTL:=systemctl}"
: "${CRSS_TMUX:=$(command -v tmux 2>/dev/null || echo tmux)}"
PFX=crss-spawn

usage() { sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { echo "session-spawn-server: $1" >&2; exit "${2:-1}"; }

cmd_install() {
  local dir="" name="" spawn="" cap="$CRSS_SPAWN_SERVER_CAPACITY" model="" pmode="$CRSS_SPAWN_SERVER_PERMISSION_MODE" dry=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) name="${2:-}"; shift 2 ;;
      --spawn) spawn="${2:-}"; shift 2 ;;
      --capacity) cap="${2:-}"; shift 2 ;;
      --model) model="${2:-}"; shift 2 ;;
      --permission-mode) pmode="${2:-}"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      -h|--help) usage; exit 0 ;;
      -*) die "unknown flag: $1" 2 ;;
      *) [ -z "$dir" ] || die "one <dir> only" 2; dir="$1"; shift ;;
    esac
  done
  [ -n "$dir" ] || { usage >&2; exit 2; }
  [ -d "$dir" ] || die "not a directory: $dir" 2
  dir="$(cd "$dir" && pwd)"
  local is_git=no
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 && is_git=yes
  [ -n "$spawn" ] || { [ "$is_git" = yes ] && spawn=worktree || spawn=same-dir; }
  case "$spawn" in worktree|same-dir) ;; *) die "--spawn must be worktree or same-dir (session mode exits with its one session)" 2 ;; esac
  [ "$spawn" = worktree ] && [ "$is_git" = no ] && die "--spawn worktree needs a git repo: $dir" 2
  [[ "$cap" =~ ^[1-9][0-9]*$ ]] || die "--capacity must be a positive integer" 2
  case "$pmode" in acceptEdits|auto|bypassPermissions|default|dontAsk|plan) ;; *) die "bad --permission-mode: $pmode" 2 ;; esac
  [ -n "$name" ] || name="$(basename "$dir")"
  name="$(printf '%s' "$name" | tr 'A-Z_ .' 'a-z---' | tr -cd 'a-z0-9-')"
  [ -n "$name" ] || die "empty --name after sanitising" 2
  local model_re='^[][A-Za-z0-9._:-]+$'
  [ -z "$model" ] || [[ "$model" =~ $model_re ]] || die "bad --model: $model" 2

  local unit="$PFX-$name" start="$CRSS_BIN_DIR/$PFX-$name-start.sh" svc="$CRSS_SYSTEMD_DIR/$PFX-$name.service"
  local log="$HOME/.local/state/crss/$unit.log"
  local rc_flags="--name $name --spawn $spawn --capacity $cap --permission-mode $pmode"
  [ "$is_git" = yes ] && rc_flags="$rc_flags --no-create-session-in-dir"
  local envs
  envs="export ANTHROPIC_BASE_URL=$(printf '%q' "$CRSS_RC_BASE_URL")"
  [ -n "$model" ] && envs="$envs ANTHROPIC_MODEL=$(printf '%q' "$model")"

  local start_body svc_body
  start_body="$(cat <<SCRIPT
#!/usr/bin/env bash
# Generated by session-spawn-server; local-only, never commit. Remote Control spawn server for $dir.
SESSION="$unit"
LOG="$log"
if [ "\${1:-}" = --loop ]; then
  # Runs inside tmux. Always a plain relaunch (never -c); a quick exit (<30s) backs off 5 min.
  cd "$dir" || exit 1
  $envs
  mkdir -p "\$(dirname "\$LOG")"
  while true; do
    S=\$(date +%s)
    echo "[\$(date -u +%FT%TZ)] start" >> "\$LOG"
    $CRSS_CLAUDE_BIN remote-control $rc_flags
    echo "[\$(date -u +%FT%TZ)] exit \$?" >> "\$LOG"
    if [ \$((\$(date +%s) - S)) -lt 30 ]; then sleep 300; else sleep 5; fi
  done
fi
if $CRSS_TMUX has-session -t "\$SESSION" 2>/dev/null; then echo "\$SESSION already running"; exit 0; fi
exec $CRSS_TMUX new-session -d -s "\$SESSION" -x 220 -y 50 -c "$dir" "$start --loop"
SCRIPT
)"
  svc_body="$(cat <<UNIT
[Unit]
Description=crss phone spawn server ($name: $dir)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$start
ExecStop=$CRSS_TMUX kill-session -t $unit
Environment=HOME=$HOME
Environment=PATH=$PATH

[Install]
WantedBy=default.target
UNIT
)"
  if [ "$dry" = 1 ]; then
    printf '== %s ==\n%s\n== %s ==\n%s\n' "$start" "$start_body" "$svc" "$svc_body"
    return 0
  fi
  [ -e "$svc" ] && die "$svc exists; run: session-spawn-server uninstall $name" 1
  mkdir -p "$CRSS_BIN_DIR" "$CRSS_SYSTEMD_DIR"
  printf '%s\n' "$start_body" > "$start" && chmod 755 "$start"
  printf '%s\n' "$svc_body" > "$svc"
  # Unattended start: nobody can answer the folder-trust dialog.
  local seed=""
  if [ -f "$HERE/session-trust-seed.sh" ]; then seed="$HERE/session-trust-seed.sh"; elif command -v session-trust-seed >/dev/null 2>&1; then seed="$(command -v session-trust-seed)"; fi
  if [ -n "$seed" ]; then bash "$seed" "$dir" || echo "session-spawn-server: WARN trust seed failed for $dir; run 'claude' there once" >&2
  else echo "session-spawn-server: WARN session-trust-seed not found; run 'claude' in $dir once" >&2; fi
  $CRSS_SYSTEMCTL --user daemon-reload && $CRSS_SYSTEMCTL --user enable --now "$unit.service" || die "systemctl enable failed for $unit.service" 1
  echo "installed $unit: dir=$dir spawn=$spawn capacity=$cap model=${model:-account-default} permission-mode=$pmode"
  echo "phone: Claude app > Code > environment '$name' > new session. Pane: tmux attach -t $unit"
}

cmd_status() {
  local f n
  for f in "$CRSS_SYSTEMD_DIR"/$PFX-*.service; do
    [ -e "$f" ] || { echo "no spawn servers installed"; return 0; }
    n="$(basename "$f" .service)"
    printf '%-32s unit=%-9s tmux=%s\n' "$n" "$($CRSS_SYSTEMCTL --user is-active "$n.service" 2>/dev/null || true)" \
      "$($CRSS_TMUX has-session -t "$n" 2>/dev/null && echo up || echo down)"
  done
}

cmd_uninstall() {
  local name="${1:-}"; [ -n "$name" ] || die "usage: session-spawn-server uninstall <name>" 2
  name="${name#"$PFX"-}"
  local unit="$PFX-$name"
  [ -e "$CRSS_SYSTEMD_DIR/$unit.service" ] || die "no such spawn server: $unit" 1
  $CRSS_SYSTEMCTL --user disable --now "$unit.service" >/dev/null 2>&1 || true
  $CRSS_TMUX kill-session -t "$unit" 2>/dev/null || true
  rm -f "$CRSS_SYSTEMD_DIR/$unit.service" "$CRSS_BIN_DIR/$unit-start.sh"
  $CRSS_SYSTEMCTL --user daemon-reload >/dev/null 2>&1 || true
  echo "removed $unit (sessions it spawned and their worktrees are untouched)"
}

case "${1:-}" in
  install) shift; cmd_install "$@" ;;
  status) shift; cmd_status ;;
  uninstall) shift; cmd_uninstall "$@" ;;
  -h|--help|"") usage; [ -n "${1:-}" ] ;;
  *) die "unknown command: $1" 2 ;;
esac
