#!/usr/bin/env bash
# crss: minimal Claude session manager. State: one env file per session in $CRSS_STATE.
# shellcheck disable=SC1090 # state and config files are sourced by design
set -euo pipefail
SELF=$(readlink -f "${BASH_SOURCE[0]}")
cfg=${CRSS_CONFIG:-$HOME/.config/crss/crss.env}
if [ -f "$cfg" ]; then . "$cfg"; fi
CRSS_STATE=${CRSS_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/crss}
CRSS_TMUX=${CRSS_TMUX:-tmux}
CRSS_CLAUDE=${CRSS_CLAUDE:-claude}

usage() {
  cat <<'H'
crss spawn NAME DIR [--model M] [--worktree] [--brief FILE] [-- extra claude args]
crss up [NAME...]                 start sessions that have an env file but no tmux session
crss ls [--json]                  NAME STATUS VERSION SID DIR
crss send NAME (TEXT... | --file F)   paste + Enter; prints delivered | queued | UNVERIFIED
crss restart (NAME... | --all) [--wait-idle]   /exit; the loop resumes the same session id
crss reap NAME [--force]          drop the env file, kill tmux, remove a clean pushed worktree
State in $CRSS_STATE/NAME.env; tmux session is ah_NAME. Config: $CRSS_CONFIG (default
~/.config/crss/crss.env) may set CRSS_STATE, CRSS_DEFAULT_ARGS. CRSS_NO_SYSTEMD=1 skips systemd-run.
H
}
die() { echo "crss: $*" >&2; exit 1; }
tm() { $CRSS_TMUX "$@"; }
envf() { echo "$CRSS_STATE/$1.env"; }
need() { [ -f "$(envf "$1")" ] || die "no such session: $1"; }
load() { need "$1"; DIR='' WT='' SID='' BRIEF=''; CMD=() ARGS=() ENVS=(); . "$(envf "$1")"; }
names() {
  if [ $# -gt 0 ]; then printf '%s\n' "$@"; return; fi
  local f; for f in "$CRSS_STATE"/*.env; do [ -e "$f" ] && basename "$f" .env; done; return 0
}

# claude pid: the descendant of the pane process that has a session record
cpid() {
  local pp c g
  pp=$(tm display-message -p -t "ah_$1" '#{pane_pid}' 2>/dev/null) || return 0
  for c in $(pgrep -P "$pp" || true) $(for g in $(pgrep -P "$pp" || true); do pgrep -P "$g" || true; done); do
    if [ -f "$HOME/.claude/sessions/$c.json" ]; then echo "$c"; return 0; fi
  done
  return 0
}
rec() { local p; p=$(cpid "$1"); if [ -n "$p" ]; then cat "$HOME/.claude/sessions/$p.json" 2>/dev/null || true; fi; }
field() { rec "$1" | jq -r ".$2 // empty" 2>/dev/null || true; }
# /clear and in-TUI /resume change the session id; follow the live record
sync_sid() {
  local s; load "$1"; s=$(field "$1" sessionId)
  if [ -n "$s" ] && [ "$s" != "$SID" ]; then sed -i "s|^SID=.*|SID=$s|" "$(envf "$1")"; SID=$s; fi
}
paste_to() { # NAME FILE
  tm load-buffer -b "crss-$$" "$2"
  tm paste-buffer -p -d -b "crss-$$" -t "ah_$1"
  sleep 0.3
  tm send-keys -t "ah_$1" Enter
}

cmd_spawn() {
  local n=${1:-} dir=${2:-} model='' wt='' brief='' extra=() args=() da sid
  [[ $n =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "bad name: '$n'"
  [ -d "$dir" ] || die "no such dir: $dir"
  shift 2
  while [ $# -gt 0 ]; do
    case $1 in
      --model) model=$2; shift 2 ;;
      --worktree) wt=1; shift ;;
      --brief) brief=$(readlink -f "$2"); shift 2 ;;
      --) shift; extra=("$@"); break ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ -e "$(envf "$n")" ] && die "$n already exists"
  dir=$(cd "$dir" && pwd -P)
  if [ -n "$wt" ]; then
    local base=HEAD
    git -C "$dir" rev-parse -q --verify origin/main >/dev/null && base=origin/main
    mkdir -p "$HOME/.claude/worktrees"
    git -C "$dir" worktree add -q "$HOME/.claude/worktrees/$n" -b "session/$n" "$base"
    dir=$HOME/.claude/worktrees/$n; wt=$dir
  fi
  python3 - "$HOME/.claude.json" "$dir" <<'P'
import json, os, sys
p, d = sys.argv[1:]
try:
    j = json.load(open(p))
except (OSError, ValueError):
    j = {}
j.setdefault("projects", {}).setdefault(d, {})["hasTrustDialogAccepted"] = True
with open(p + ".tmp", "w") as f:
    json.dump(j, f, indent=2)
os.replace(p + ".tmp", p)
P
  read -ra da <<<"${CRSS_DEFAULT_ARGS:-}"
  args=("${da[@]}")
  [ -n "$model" ] && args+=(--model "$model")
  args+=("${extra[@]}")
  sid=$(python3 -c 'import uuid;print(uuid.uuid4())')
  mkdir -p "$CRSS_STATE"
  {
    echo "DIR=$(printf %q "$dir")"
    [ -n "$wt" ] && echo "WT=$(printf %q "$wt")"
    echo "SID=$sid"
    echo "ARGS=($([ ${#args[@]} -gt 0 ] && printf '%q ' "${args[@]}"))"
    echo "ENVS=()"
    [ -n "$brief" ] && echo "BRIEF=$(printf %q "$brief")"
  } >"$(envf "$n")"
  cmd_up "$n"
}

# runs inside the pane
cmd_loop() {
  local n=$1 t0 a mark="$CRSS_STATE/$1.started"
  while [ -f "$(envf "$n")" ]; do
    load "$n"; t0=$SECONDS
    if [ ${#CMD[@]} -gt 0 ]; then
      "${CMD[@]}" || true
    else
      a=("${ARGS[@]}" --remote-control "$n" -n "$n")
      if [ -f "$mark" ]; then
        a+=(--resume "$SID")
      else
        a+=(--session-id "$SID")
        if [ -n "$BRIEF" ]; then a+=("$(cat "$BRIEF")"); fi
        touch "$mark"
      fi
      # shellcheck disable=SC2086 # CRSS_CLAUDE may carry words
      env "${ENVS[@]}" $CRSS_CLAUDE "${a[@]}" || true
    fi
    if [ $((SECONDS - t0)) -lt 30 ]; then sleep "${CRSS_SLEEP_FAST:-300}"; else sleep "${CRSS_SLEEP_SLOW:-10}"; fi
  done
}

cmd_up() {
  local n cmd
  for n in $(names "$@"); do
    load "$n"
    if tm has-session -t "ah_$n" 2>/dev/null; then sync_sid "$n"; continue; fi
    cmd="env CRSS_STATE=$(printf %q "$CRSS_STATE") $(printf %q "$SELF") _loop $n"
    if [ -z "${CRSS_NO_SYSTEMD:-}" ] && command -v systemd-run >/dev/null && [ -S "/run/user/$(id -u)/bus" ]; then
      # own scope: stopping a unit must not kill the shared tmux server
      systemd-run --user --scope --quiet --collect -- $CRSS_TMUX new-session -d -s "ah_$n" -x 220 -y 50 -c "$DIR" "$cmd"
    else
      tm new-session -d -s "ah_$n" -x 220 -y 50 -c "$DIR" "$cmd"
    fi
    echo "$n: started"
  done
}

cmd_ls() {
  local n st v rows=
  for n in $(names); do
    load "$n"
    if tm has-session -t "ah_$n" 2>/dev/null; then
      st=$(field "$n" status); v=$(field "$n" version)
      sync_sid "$n"
    else st=down v=; fi
    rows+="$n	${st:-?}	${v:--}	$SID	$DIR"$'\n'
  done
  if [ "${1:-}" = --json ]; then
    printf '%s' "$rows" | jq -R -s 'split("\n")[:-1] | map(split("\t") | {name:.[0], status:.[1], version:.[2], sid:.[3], dir:.[4]})'
  else
    printf '%s' "$rows" | while IFS=$'\t' read -r a b c d e; do printf '%-16s %-5s %-10s %.8s %s\n' "$a" "$b" "$c" "$d" "$e"; done
  fi
}

cmd_send() {
  local n=${1:-} f='' before tmp
  need "$n"; shift
  while [ $# -gt 0 ]; do
    case $1 in
      --file) f=$2; shift 2 ;;
      --expect-identity) shift 2 ;; # legacy callers
      --task-file) shift ;;
      *) break ;;
    esac
  done
  tmp=$(mktemp); trap 'rm -f "$tmp"' RETURN
  if [ -n "$f" ]; then cat "$f" >"$tmp"; else printf '%s' "$*" >"$tmp"; fi
  tm has-session -t "ah_$n" 2>/dev/null || die "$n is down (crss up $n)"
  before=$(field "$n" status)
  paste_to "$n" "$tmp"
  if [ "$before" = busy ]; then echo "queued (session busy)"; return 0; fi
  for _ in $(seq 40); do
    if [ "$(field "$n" status)" = busy ]; then echo delivered; return 0; fi
    sleep 0.25
  done
  echo "UNVERIFIED: status stayed idle"; return 3
}

restart1() { # NAME WAIT
  local n=$1 old p f
  tm has-session -t "ah_$n" 2>/dev/null || { cmd_up "$n"; return; }
  sync_sid "$n"
  if [ "$(field "$n" status)" = busy ]; then
    [ -z "$2" ] && { echo "$n: skipped, busy"; return 0; }
    for _ in $(seq 240); do [ "$(field "$n" status)" = busy ] || break; sleep 15; done
    [ "$(field "$n" status)" = busy ] && { echo "$n: skipped, still busy after 1h"; return 0; }
  fi
  old=$(cpid "$n"); f=$(mktemp); printf /exit >"$f"
  paste_to "$n" "$f"; rm -f "$f"
  sleep 5
  if tm capture-pane -p -t "ah_$n" | grep -q 'Exit and stop tasks'; then
    tm send-keys -t "ah_$n" Escape; echo "$n: skipped: has scheduled tasks"; return 0
  fi
  for _ in $(seq 60); do
    p=$(cpid "$n")
    if [ -n "$p" ] && [ "$p" != "$old" ] && [ "$(field "$n" sessionId)" = "$SID" ]; then
      echo "$n: $old -> $p version=$(field "$n" version) sessionId=$SID"; return 0
    fi
    sleep 1
  done
  echo "$n: restart not confirmed" >&2; return 1
}
cmd_restart() {
  local w='' ns=() a n rc=0
  for a in "$@"; do
    case $a in --wait-idle) w=1 ;; --all) mapfile -t ns < <(names) ;; *) ns+=("$a") ;; esac
  done
  for n in "${ns[@]}"; do need "$n"; restart1 "$n" "$w" || rc=1; done
  return $rc
}

cmd_reap() {
  local n=${1:-} force=${2:-} gd
  load "$n"
  if [ "$(field "$n" status)" = busy ] && [ "$force" != --force ]; then die "$n is busy (use --force)"; fi
  rm -f "$(envf "$n")" "$CRSS_STATE/$n.started"
  tm kill-session -t "ah_$n" 2>/dev/null || true
  echo "$n: reaped"
  [ -n "$WT" ] && [ -d "$WT" ] || return 0
  if [ -n "$(git -C "$WT" status --porcelain --ignored)" ]; then
    echo "kept $WT: uncommitted or ignored files"
  elif [ -n "$(git -C "$WT" log HEAD --not --remotes --oneline)" ]; then
    echo "kept $WT: commits not on any remote"
  else
    gd=$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir)
    git -C "$gd" worktree remove "$WT" && echo "removed $WT (branch kept)"
  fi
}

c=${1:-help}; [ $# -gt 0 ] && shift
case $c in
  spawn) cmd_spawn "$@" ;;
  _loop) cmd_loop "$@" ;;
  up) cmd_up "$@" ;;
  ls) cmd_ls "$@" ;;
  send) cmd_send "$@" ;;
  restart) cmd_restart "$@" ;;
  reap) cmd_reap "$@" ;;
  help | -h | --help) usage ;;
  *) usage >&2; exit 2 ;;
esac
