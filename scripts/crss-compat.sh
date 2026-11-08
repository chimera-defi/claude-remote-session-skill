#!/usr/bin/env bash
# Old crss command names, kept only for callers outside this repo (bus router, spawn_orchestrator,
# bus-request-watchdog, env-refresh). Installed as symlinks named new-session, session-send,
# session-handoff, session-doctor and session-preserve; each translates the argv those callers use.
# Everything else should call crss directly.
set -euo pipefail
CRSS=${CRSS_BIN:-$(dirname "$(readlink -f "$0")")/crss}
[ -x "$CRSS" ] || CRSS=$CRSS.sh
die() { echo "$(basename "$0"): $*" >&2; exit 2; }
base() { local n=${1#ah_}; echo "${n#ah-}"; } # tmux ah_NAME or phone ah-NAME -> NAME
status() { "$CRSS" ls --json | jq -r --arg n "$1" '.[] | select(.name == $n) | .status'; }

new_session() { # FOLDER [workspace|sessions|auto] [--alias A] [--tier T] [--task-type T] [--task-file F] [--dry-run]
  local dry='' folder='' type=auto alias='' tier='' brief='' launcher='' dir name n0 k=1 taken m wt=() b=()
  while [ $# -gt 0 ]; do
    case $1 in
      --dry-run) dry=1; shift ;;
      --alias) alias=$2; shift 2 ;;
      --tier | --task-type) tier=$2; shift 2 ;;
      --task-file) brief=$2; shift 2 ;;
      --launcher) launcher=$2; shift 2 ;;
      --tier-reason) shift 2 ;;
      -*) die "$1 is not kept; use crss spawn" ;;
      *) if [ -z "$folder" ]; then folder=$1; else type=$1; fi; shift ;;
    esac
  done
  [ -n "$folder" ] || die "usage: new-session FOLDER [workspace|sessions|auto] [--alias A] [--task-file F]"
  local ws=${CRSS_WORKSPACE:-$HOME/workspace}/$folder ss=$HOME/.sessions/$folder
  case $type in
    workspace) dir=$ws ;;
    sessions) dir=$ss ;;
    auto) if [ -d "$ws" ]; then dir=$ws; else dir=$ss; fi ;;
    *) die "type must be workspace, sessions or auto" ;;
  esac
  name=${alias:-$folder}; name=${name,,}; name=${name//[^a-z0-9-]/-}-$(date +%m%d-%H%M); n0=$name
  taken=$'\n'$("$CRSS" ls --json | jq -r '.[].name')$'\n' # add -2, -3 if live, down or kept as a branch
  while [[ $taken == *$'\n'$name$'\n'* ]] || git -C "$dir" rev-parse -q --verify "session/$name" >/dev/null 2>&1; do
    k=$((k + 1)); name=$n0-$k
  done
  if [ -n "$dry" ]; then echo "SESSION=ah_$name"; return; fi
  if [ "$dir" = "$ss" ]; then mkdir -p "$dir"; else [ -d "$dir" ] || die "no such folder: $dir"; fi
  case $tier in
    light | review | mechanical) m=(--model haiku) ;;
    standard | build) m=(--model sonnet) ;;
    heavy | research) m=(--model sonnet --advisor claude-opus-5-5) ;;
    *) m=(--model claude-opus-5-5 --effort medium) ;;
  esac
  if [ -n "${CLAUDE_SESSION_MODEL:-}" ]; then
    m=(--model "$CLAUDE_SESSION_MODEL"); [[ $CLAUDE_SESSION_MODEL == *opus* ]] && m+=(--effort medium)
  fi
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 && wt=(--worktree)
  # a launcher that is a session gets reports back; any other (bus watchdog, desktop) says how in the brief
  if [ -n "$brief" ] && [ -n "$launcher" ] && [[ $taken == *$'\n'$(base "$launcher")$'\n'* ]]; then
    t=$(mktemp); trap 'rm -f "$t"' EXIT; { printf 'Launcher: %s. Send questions and your final report with: session-send %s --file F\n\n' "$launcher" "$launcher"; cat "$brief"; } >"$t"; brief=$t
  fi
  if [ -n "$brief" ]; then b=(--brief "$brief"); fi
  "$CRSS" spawn "$name" "$dir" "${wt[@]}" "${b[@]}" -- "${m[@]}" >/dev/null # spawn keeps its own copy of the brief
  dir=$("$CRSS" ls --json | jq -r --arg n "$name" '.[] | select(.name == $n) | .dir')
  mkdir -p "$HOME/.sessions"; echo "[$(date -u +%FT%TZ)] session=ah_$name rundir=$dir" >>"$HOME/.sessions/session-starts.log"
  echo "SESSION=ah_$name"; echo "RUNDIR=$dir"
}

case $(basename "$0") in
  new-session) new_session "$@" ;;
  session-send)
    [ $# -gt 0 ] || die "usage: session-send SESSION (MSG | --file F)"
    n=$(base "$1"); shift; exec "$CRSS" send "$n" "$@" ;;
  session-handoff) # bus consumer: exit 0 = safe to paste, else "reason=..."
    [ "${1:-}" = ready ] && [ -n "${2:-}" ] || die "only 'session-handoff ready SESSION' is kept; use crss send"
    case $(status "$(base "$2")") in
      idle) echo "ready: $2 SAFE"; exit 0 ;;
      '') die "no such session: $2" ;;
      busy) r=busy ;;
      waiting) r=menu ;;
      *) r=no-prompt ;;
    esac
    echo "not ready: $2 reason=$r"; exit 1 ;;
  session-doctor)
    case ${1:-} in
      reap) [ -n "${2:-}" ] || die "usage: session-doctor reap SESSION"; n=$(base "$2"); shift 2; exec "$CRSS" reap "$n" "$@" ;;
      idle-report | land-check) exit 0 ;; # no idle scan any more: the bus reaper then finds no candidates
      opus-subagents) # env-refresh's weekly usage line
        python3 - "${3:-2}" <<'P'
import glob, json, os, sys, time
def opus(line):
    try: return "opus" in str(json.loads(line)["message"]["model"]).lower()
    except (ValueError, KeyError, TypeError): return False
days = float(sys.argv[1]); cut = time.time() - days * 86400; hits = set(); n = 0
for f in glob.glob(os.path.expanduser("~/.claude/projects/*/*/subagents/*.jsonl")):
    if os.path.getmtime(f) < cut: continue
    with open(f, errors="replace") as fh:
        if any('"assistant"' in l and opus(l) for l in fh):
            n += 1; hits.add(f.split("/")[-3])
print("  Opus subagents: %d across %d session(s) in the last %g day(s)" % (n, len(hits), days) if n
      else "  no Opus subagent transcripts in the last %g day(s)" % days)
P
        ;;
      *) die "${1:-} is retired; use crss ls, crss reap or crss restart" ;;
    esac ;;
  session-preserve) echo "session-preserve is retired: crss reap keeps any worktree with unpushed or uncommitted work"; exit 1 ;;
  *) die "install as new-session, session-send, session-handoff, session-doctor or session-preserve" ;;
esac
