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
crss spawn NAME DIR [--model M] [--effort E] [--title T] [--worktree] [--brief FILE] [-- extra claude args]
crss up [NAME...]                 start sessions that have an env file but no tmux session
crss ls [NAME...] [--json]        NAME STATUS VERSION SID DIR TITLE (also ah_* sessions started by other tools)
crss peek NAME [LINES]            header line (NAME STATUS TITLE) + last LINES (30) non-blank pane lines
crss wait NAME... [--timeout S]   until each is idle (turn over, brief sent), on a dialog, or down; exit 0 all idle, 1 timeout, 2 other
crss send NAME (TEXT... | --file F)   paste + Enter; delivered | queued (0), UNVERIFIED (1), refused (2)
crss restart (NAME... | --all) [--wait-idle]   /exit; the loop resumes the same session id
crss reap NAME [--force]          drop the env file, kill tmux, remove a clean pushed worktree
State in $CRSS_STATE/NAME.env; tmux session ah_NAME. Config: $CRSS_CONFIG (default
~/.config/crss/crss.env) may set CRSS_STATE, CRSS_DEFAULT_ARGS. CRSS_NO_SYSTEMD=1 skips systemd-run.
CRSS_NAMES=auto|plain (spawn; default auto): Claude titles the session itself, or ah-NAME. Rename: crss send NAME "/rename T"
H
}
die() { echo "crss: $*" >&2; exit 1; }
tm() { $CRSS_TMUX "$@"; }
envf() { echo "$CRSS_STATE/$1.env"; }
need() { [ -f "$(envf "$1")" ] || die "no such session: $1"; }
load() { need "$1"; DIR='' WT='' SID='' BRIEF='' NAMES='' TITLE=''; CMD=() ARGS=() ENVS=(); . "$(envf "$1")"; }
names() {
  if [ $# -gt 0 ]; then printf '%s\n' "$@"; return; fi
  local f; for f in "$CRSS_STATE"/*.env; do [ -e "$f" ] && basename "$f" .env; done; return 0
}

# claude pid: the pane process or a descendant that has a session record
cpid() {
  local pp c g kids
  pp=$(tm display-message -p -t "=ah_$1:" '#{pane_pid}' 2>/dev/null) || return 0
  [ -n "$pp" ] || return 0
  kids=$(pgrep -P "$pp" || true)
  for c in "$pp" $kids $(for g in $kids; do pgrep -P "$g" || true; done); do
    if [ -f "$HOME/.claude/sessions/$c.json" ]; then echo "$c"; return 0; fi
  done
  return 0
}
rec() { local p; p=$(cpid "$1"); if [ -n "$p" ]; then cat "$HOME/.claude/sessions/$p.json" 2>/dev/null || true; fi; }
field() { rec "$1" | jq -r ".$2 // empty" 2>/dev/null || true; }
working() { case $(field "$1" status) in busy | shell) return 0 ;; esac; return 1; } # shell: a shell command is running
# /clear and in-TUI /resume change the session id; follow the live record
sync_sid() {
  local s; load "$1"; s=$(field "$1" sessionId)
  if [ -n "$s" ] && [ "$s" != "$SID" ]; then sed -i "s|^SID=.*|SID=$s|" "$(envf "$1")"; SID=$s; fi
}
# session title: latest custom title, else latest AI title in the transcript tail, else the spawn title
title_of() { # NAME, with or without an env file
  local SID='' TITLE='' f='' t=''
  if [ -f "$(envf "$1")" ]; then load "$1"; else SID=$(field "$1" sessionId); fi
  [ -z "$SID" ] || f=$(compgen -G "$HOME/.claude/projects/*/$SID.jsonl" | head -1 || true)
  [ -z "$f" ] || t=$(tail -n 400 "$f" | { grep -E '^\{"type":"(custom|ai)-title"' || true; } |
    jq -rs '(map(.customTitle // empty) | last) // (map(.aiTitle // empty) | last) // empty' 2>/dev/null || true)
  t=${t:-$TITLE}; echo "${t//[$'\t\n']/ }"
}
paste_to() { # NAME FILE
  tm load-buffer -b "crss-$$" "$2"
  tm paste-buffer -p -d -b "crss-$$" -t "=ah_$1:"
  sleep 0.3
  tm send-keys -t "=ah_$1:" Enter
}

cmd_spawn() {
  local n=${1:-} dir=${2:-} model='' effort='' title='' wt='' brief='' extra=() args=() sid nm=${CRSS_NAMES:-auto}
  [[ $n =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "bad name: '$n'"
  [ -d "$dir" ] || die "no such dir: $dir"
  shift 2
  while [ $# -gt 0 ]; do
    case $1 in
      --model) model=$2; shift 2 ;;
      --effort) effort=$2; shift 2 ;;
      --title) title=$2; shift 2 ;;
      --worktree) wt=1; shift ;;
      --brief) brief=$2; [ -r "$brief" ] || die "cannot read $brief"; shift 2 ;;
      --) shift; extra=("$@"); break ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ -e "$(envf "$n")" ] && die "$n already exists"
  case $nm in auto | plain) ;; *) die "CRSS_NAMES must be auto or plain, not '$nm'" ;; esac
  if [ -n "$title" ]; then nm=auto; fi
  dir=$(cd "$dir" && pwd -P)
  if [ -n "$wt" ]; then
    local base=HEAD
    git -C "$dir" rev-parse -q --verify origin/main >/dev/null && base=origin/main
    git -C "$dir" rev-parse -q --verify "session/$n" >/dev/null && die "branch session/$n exists (kept by an earlier reap); pick another name"
    mkdir -p "$HOME/.claude/worktrees"
    git -C "$dir" worktree add -q "$HOME/.claude/worktrees/$n" -b "session/$n" "$base"
    dir=$HOME/.claude/worktrees/$n; wt=$dir
  fi
  read -ra args <<<"${CRSS_DEFAULT_ARGS:-}"
  [ -n "$model" ] && args+=(--model "$model")
  [ -n "$effort" ] && args+=(--effort "$effort")
  args+=("${extra[@]}")
  sid=$(python3 -c 'import uuid;print(uuid.uuid4())')
  mkdir -p "$CRSS_STATE"
  if [ -n "$brief" ]; then cp "$brief" "$CRSS_STATE/$n.brief"; brief=$CRSS_STATE/$n.brief; fi
  {
    echo "DIR=$(printf %q "$dir")"
    [ -n "$wt" ] && echo "WT=$(printf %q "$wt")"
    echo "SID=$sid"
    echo "ARGS=($([ ${#args[@]} -gt 0 ] && printf '%q ' "${args[@]}"))"
    echo "ENVS=()"
    [ "$nm" = auto ] && echo "NAMES=auto"
    [ -n "$title" ] && echo "TITLE=$(printf %q "$title")"
    [ -n "$brief" ] && echo "BRIEF=$(printf %q "$brief")"
  } >"$(envf "$n")"
  cmd_up "$n"
}

# Pre-accept the folder-trust dialog. A worktree's trust is keyed by its main repo root, and running
# claude processes rewrite ~/.claude.json, so write right before each launch and re-read until it holds.
trust() {
  python3 - "$HOME/.claude.json" "$1" <<'P'
import json, os, subprocess, sys, time
p, d = sys.argv[1:]
keys = {d}
g = subprocess.run(["git", "-C", d, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                   capture_output=True, text=True).stdout.strip()
if g.endswith("/.git"):
    keys.add(os.path.dirname(g))
for _ in range(6):
    try:
        j = json.load(open(p))
    except (OSError, ValueError):  # missing, or caught mid-write: never overwrite what we can't read
        time.sleep(0.5)
        continue
    todo = [k for k in keys if not j.setdefault("projects", {}).get(k, {}).get("hasTrustDialogAccepted")]
    if not todo:
        sys.exit(0)
    for k in todo:
        j["projects"].setdefault(k, {})["hasTrustDialogAccepted"] = True
    with open(p + ".crss", "w") as f:
        json.dump(j, f, indent=2)
    os.replace(p + ".crss", p)
    time.sleep(0.5)
sys.exit(1)
P
}

# runs inside the pane
cmd_loop() {
  local n=$1 t0 a rc first
  set -m # claude gets its own foreground process group, so the pane reports "claude", not "bash"
  while [ -f "$(envf "$n")" ]; do
    load "$n"; t0=$SECONDS
    if [ ${#CMD[@]} -gt 0 ]; then
      rc=0; "${CMD[@]}" || rc=$?
    else
      trust "$DIR" || echo "crss: could not pre-trust $DIR; answer the trust dialog"
      first=1; if compgen -G "$HOME/.claude/projects/*/$SID.jsonl" >/dev/null; then first=''; fi
      a=("${ARGS[@]}")
      # NAMES=auto: a bare --remote-control lets Claude title the session (-n would stop that). The
      # flag takes an optional value, so --resume or --session-id must follow it directly.
      if [ "$NAMES" != auto ]; then
        a+=(--remote-control "ah-$n" -n "ah-$n")
      elif [ -n "$first" ] && [ -n "$TITLE" ]; then
        a+=(--remote-control "$TITLE" -n "$TITLE")
      else
        a+=(--remote-control)
      fi
      # resume once the conversation has a transcript; until then start it under SID, with the brief
      if [ -z "$first" ]; then
        a+=(--resume "$SID")
        if [ -n "$BRIEF" ]; then sed -i '/^BRIEF=/d' "$(envf "$n")"; rm -f "$BRIEF"; fi # brief is sent once
      else
        a+=(--session-id "$SID")
        if [ -n "$BRIEF" ]; then a+=("$(cat "$BRIEF")"); fi
      fi
      # shellcheck disable=SC2086 # CRSS_CLAUDE may carry words
      rc=0; env "${ENVS[@]}" $CRSS_CLAUDE "${a[@]}" || rc=$?
    fi
    # back off only on a failing start (crash loop); /exit and restart come back in seconds
    if [ "$rc" -ne 0 ] && [ $((SECONDS - t0)) -lt 30 ]; then sleep "${CRSS_BACKOFF:-300}"; else sleep "${CRSS_PAUSE:-5}"; fi
  done
}

cmd_up() {
  local n cmd scope=()
  # own scope: stopping a unit must not kill the shared tmux server
  if [ -z "${CRSS_NO_SYSTEMD:-}" ] && command -v systemd-run >/dev/null && [ -S "/run/user/$(id -u)/bus" ]; then
    scope=(systemd-run --user --scope --quiet --collect --)
  fi
  for n in $(names "$@"); do
    ( load "$n" ) || { echo "$n: bad env file, skipped" >&2; continue; }
    load "$n"
    if tm has-session -t "=ah_$n" 2>/dev/null; then sync_sid "$n"; continue; fi
    cmd="env CRSS_STATE=$(printf %q "$CRSS_STATE") ${CRSS_CONFIG:+CRSS_CONFIG=$(printf %q "$CRSS_CONFIG")} $(printf %q "$SELF") _loop $n"
    "${scope[@]}" $CRSS_TMUX new-session -d -s "ah_$n" -x 220 -y 50 -c "$DIR" "$cmd"
    echo "$n: started"
  done
}

cmd_ls() {
  local n st v x t json='' filt=() rows='' a b c d e f
  for a in "$@"; do if [ "$a" = --json ]; then json=1; else filt+=("$a"); fi; done
  want() { [ ${#filt[@]} -eq 0 ] || [[ " ${filt[*]} " == *" $1 "* ]]; }
  for n in $(names); do
    want "$n" || continue
    ( load "$n" ) || { echo "$n: bad env file, skipped" >&2; continue; }
    load "$n"
    if tm has-session -t "=ah_$n" 2>/dev/null; then
      st=$(field "$n" status); v=$(field "$n" version)
      sync_sid "$n"
    else st=down v=; fi
    rows+="$n	${st:-?}	${v:--}	$SID	$DIR	$(title_of "$n")"$'\n'
  done
  for n in $(tm list-sessions -F '#S' 2>/dev/null | sed -n 's/^ah_//p'); do # no env file: send reaches it, restart and reap don't
    [ -e "$(envf "$n")" ] && continue
    want "$n" || continue
    st=$(field "$n" status); v=$(field "$n" version); x=$(field "$n" sessionId); t=$(title_of "$n")
    rows+="$n	${st:-?}	${v:--}	${x:--}	$(tm display-message -p -t "=ah_$n:" '#{pane_current_path}')	$t"$'\n'
  done
  if [ -n "$json" ]; then
    printf '%s' "$rows" | jq -R -s 'split("\n")[:-1] | map(split("\t") | {name:.[0], status:.[1], version:.[2], sid:.[3], dir:.[4], title:(.[5] // "")})'
  else
    printf '%s' "$rows" | while IFS=$'\t' read -r a b c d e f; do printf '%-16s %-5s %-10s %.8s %s %s\n' "$a" "$b" "$c" "$d" "$e" "${f:--}"; done
  fi
}
cmd_peek() { # exit 2 when there is no such session
  local n=${1:-} k=${2:-30} st=down t
  [ -f "$(envf "$n")" ] || tm has-session -t "=ah_$n" 2>/dev/null || { echo "crss: no such session: $n" >&2; return 2; }
  if tm has-session -t "=ah_$n" 2>/dev/null; then st=$(field "$n" status); st=${st:-?}; fi
  t=$(title_of "$n"); echo "$n $st ${t:--}"
  if [ "$st" != down ]; then tm capture-pane -p -S - -t "=ah_$n:" | { grep -v '^[[:space:]]*$' || true; } | tail -n "$k"; fi
}
# settled: tmux gone, a dialog open, or idle on two polls in a row with the brief sent (its transcript exists)
cmd_wait() {
  local ns=() to=1800 t0=$SECONDS n st rc=0 left
  declare -A idl=() last=()
  while [ $# -gt 0 ]; do case $1 in --timeout) to=$2; shift 2 ;; *) ns+=("$1"); shift ;; esac; done
  [ ${#ns[@]} -gt 0 ] || die "usage: crss wait NAME... [--timeout S]"
  sent() { ! grep -qs '^BRIEF=' "$(envf "$1")" || compgen -G "$HOME/.claude/projects/*/$(field "$1" sessionId).jsonl" >/dev/null; }
  while :; do
    left=0
    for n in "${ns[@]}"; do
      if ! tm has-session -t "=ah_$n" 2>/dev/null; then last[$n]=down; continue; fi
      st=$(field "$n" status); last[$n]=${st:-?}
      if [ "$st" = idle ] && sent "$n"; then idl[$n]=$((${idl[$n]:-0} + 1)); else idl[$n]=0; fi
      if [ "$st" != waiting ] && [ "${idl[$n]}" -lt 2 ]; then left=1; fi
    done
    [ "$left" = 1 ] || break
    if [ $((SECONDS - t0)) -ge "$to" ]; then rc=1; break; fi
    sleep "${CRSS_POLL:-2}"
  done
  for n in "${ns[@]}"; do echo "$n ${last[$n]}"; [ "${last[$n]}" = idle ] || [ "$rc" = 1 ] || rc=2; done
  return $rc
}

cmd_send() { # exit 0 delivered or queued, 1 UNVERIFIED, 2 refused
  local n=${1:-} f='' before tmp
  [ -f "$(envf "$n")" ] || tm has-session -t "=ah_$n" 2>/dev/null || { echo "crss: no such session: $n" >&2; return 2; }
  shift
  while [ $# -gt 0 ]; do
    case $1 in
      --file) f=$2; shift 2 ;;
      --expect-identity) shift 2 ;; # legacy callers
      *) break ;;
    esac
  done
  [ -z "$f" ] || [ -r "$f" ] || { echo "crss: cannot read $f" >&2; return 2; }
  tm has-session -t "=ah_$n" 2>/dev/null || { echo "crss: $n is down (crss up $n)" >&2; return 2; }
  tmp=$(mktemp); trap 'rm -f "$tmp"' RETURN
  if [ -n "$f" ]; then cat "$f" >"$tmp"; else printf '%s' "$*" >"$tmp"; fi
  before=$(field "$n" status)
  # no record means claude is starting or backing off: the text would sit in the terminal for the next launch
  [ -n "$before" ] || { echo "crss: $n has no live claude yet; retry shortly" >&2; return 2; }
  # a dialog is open: pasted text and Enter would answer it
  [ "$before" = waiting ] && { echo "crss: $n is waiting on a dialog; look at the pane" >&2; return 2; }
  paste_to "$n" "$tmp"
  case $before in busy | shell) echo "queued (session $before)"; return 0 ;; esac
  for _ in $(seq 40); do
    if working "$n"; then echo delivered; return 0; fi
    sleep 0.25
  done
  echo "UNVERIFIED: status stayed idle"; return 1
}

restart1() { # NAME WAIT
  local n=$1 old p f
  tm has-session -t "=ah_$n" 2>/dev/null || { cmd_up "$n"; return; }
  sync_sid "$n"
  [ -n "$(field "$n" status)" ] || { echo "$n: skipped, no live claude"; return 0; }
  [ "$(field "$n" status)" = waiting ] && { echo "$n: skipped, waiting on a dialog"; return 0; }
  if working "$n"; then
    [ -z "$2" ] && { echo "$n: skipped, busy"; return 0; }
    for _ in $(seq 240); do working "$n" || break; sleep 15; done
    working "$n" && { echo "$n: skipped, still busy after 1h"; return 0; }
  fi
  old=$(cpid "$n"); f=$(mktemp); printf /exit >"$f"
  paste_to "$n" "$f"; rm -f "$f"
  sleep 5
  if [[ $(tm capture-pane -p -t "=ah_$n:") == *'Exit and stop tasks'* ]]; then
    tm send-keys -t "=ah_$n:" Escape; echo "$n: skipped: has scheduled tasks"; return 0
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
  local n=${1:-} force=${2:-} gd ig a sz
  load "$n"
  if working "$n" && [ "$force" != --force ]; then die "$n is busy (use --force)"; fi
  rm -f "$(envf "$n")" "$CRSS_STATE/$n.brief"
  tm kill-session -t "=ah_$n" 2>/dev/null || true
  echo "$n: reaped"
  [ -n "$WT" ] && [ -d "$WT" ] || return 0
  if [ -n "$(git -C "$WT" status --porcelain)" ]; then echo "kept $WT: uncommitted or untracked files"; return 0; fi
  if [ -n "$(git -C "$WT" log HEAD --not --remotes --oneline)" ]; then echo "kept $WT: commits not on any remote"; return 0; fi
  # git worktree remove deletes ignored files (an artifacts/ folder was lost this way): archive them first
  ig=$(mktemp); git -C "$WT" ls-files -z -o -i --exclude-standard >"$ig"
  if [ -s "$ig" ]; then
    sz=$(cd "$WT" && xargs -0 -a "$ig" stat -c %s | awk '{s+=$1} END {print s+0}')
    a=$HOME/backups/reaped-worktree-ignored/$n-$(date -u +%Y%m%dT%H%M%SZ).tgz
    if [ "$sz" -gt 2147483648 ] || ! { mkdir -p "${a%/*}" && tar -C "$WT" --null -T "$ig" -czf "$a"; }; then
      rm -f "$ig"; echo "kept $WT: ignored files over 2 GB or not archived"; return 0
    fi
    echo "archived ignored files to $a"
  fi
  rm -f "$ig"
  gd=$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir)
  git -C "$gd" worktree remove "$WT" && echo "removed $WT (branch kept)"
}

c=${1:-help}; [ $# -gt 0 ] && shift
if [ "${1:-}" = -h ] || [ "${1:-}" = --help ]; then if [ "$c" != _loop ]; then usage; exit 0; fi; fi
case $c in
  spawn) cmd_spawn "$@" ;;
  _loop) cmd_loop "$@" ;;
  up) cmd_up "$@" ;;
  ls) cmd_ls "$@" ;;
  peek) cmd_peek "$@" ;;
  wait) cmd_wait "$@" ;;
  send) cmd_send "$@" ;;
  restart) cmd_restart "$@" ;;
  reap) cmd_reap "$@" ;;
  help | -h | --help) usage ;;
  *) usage >&2; exit 2 ;;
esac
