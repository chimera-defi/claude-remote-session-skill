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
crss spawn NAME DIR [--model M] [--effort E] [--title T] [--worktree] [--code-mode] [--brief FILE] [-- extra claude args]
crss up [NAME...]                 start sessions that have an env file but no tmux session
crss ls [NAME...] [--json]        NAME STATUS VERSION SID DIR TITLE (also ah_* sessions started by other tools); --json adds by (who spawned it); exit 2 for an unknown NAME
                                  STATUS parked: the turn is over, a background command it started still runs
crss ls --all [--hours N] [--tmp]   also transcripts no crss session has (Desktop app, plain claude) with a message in the last N (30) hours:
                                  - STATE AGE SID DIR TITLE [entrypoint, pid]; STATE ended | cut (stopped mid-turn) | live; --tmp adds headless and temp-dir runs
crss adopt SID NAME [DIR]         run such a transcript as crss session NAME (SID or its first 8+ characters); refused while a running claude has it or it was written to under 2 minutes ago
crss peek NAME [LINES]            header line (NAME STATUS TITLE) + last LINES (30) non-blank pane lines
crss wait NAME... [--timeout S]   until each is idle or parked (turn over, brief sent), on a dialog, or down; exit 0 all idle or parked, 1 timeout, 2 other
crss send NAME (TEXT... | --file F)   paste + Enter; delivered | queued (0), UNVERIFIED (1), refused (2)
crss restart (NAME... | --all) [--wait-idle]   /exit; the loop resumes the same session id
crss reap NAME [--force]          drop the env file, kill tmux, remove a clean pushed worktree
State in $CRSS_STATE/NAME.env; tmux session ah_NAME. Config: $CRSS_CONFIG (default
~/.config/crss/crss.env) may set CRSS_STATE, CRSS_DEFAULT_ARGS. CRSS_NO_SYSTEMD=1 skips systemd-run.
--code-mode: Claude Code's experimental Code Mode; no Remote Control, so not in the app, and a restart resumes it only with Code Mode on
CRSS_NAMES=auto|plain (spawn; default auto): Claude titles the session itself, or ah-NAME. Rename: crss send NAME "/rename T"
H
}
die() { echo "crss: $*" >&2; exit 1; }
tm() { $CRSS_TMUX "$@"; }
envf() { echo "$CRSS_STATE/$1.env"; }
need() { [ -f "$(envf "$1")" ] || die "no such session: $1"; }
known() { [ -f "$(envf "$1")" ] || tm has-session -t "=ah_$1" 2>/dev/null || { echo "crss: no such session: $1" >&2; return 2; }; } # also ah_* sessions without an env file
load() { need "$1"; DIR='' WT='' SID='' BRIEF='' CODE_MODE='' NAMES='' TITLE='' BY=''; CMD=() ARGS=() ENVS=(); . "$(envf "$1")"; }
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
jf() { jq -r ".$2 // empty" <<<"$1" 2>/dev/null || true; } # RECORD-JSON KEY
field() { jf "$(rec "$1")" "$2"; }
working() { case $(field "$1" status) in busy | shell) return 0 ;; esac; return 1; } # shell: a shell command is running
# Claude's record says "shell" when a finished turn left a background command running (a waiter);
# a command inside a turn read "busy" on CLI 2.1.325. To be safe "shell" is only reported as "parked"
# when the transcript shows the turn is over: its last real message is an assistant one with
# stop_reason end_turn.
# a real message: not metadata, a sub-agent's (sidechain) message or a local command's lines
UUID='^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'
REAL='def real: select(.type == "assistant" or (.type == "user" and .isMeta != true)) | select(.isSidechain != true) | select((.message.content | type == "string" and (startswith("<command-name>") or startswith("<local-command-stdout>"))) | not);'
status_of() { # NAME [record json]
  local r=${2-$(rec "$1")} st f
  st=$(jf "$r" status)
  if [ "$st" = shell ]; then
    f=$(compgen -G "$HOME/.claude/projects/*/$(jf "$r" sessionId).jsonl" | head -1 || true)
    # a half-written last line is dropped by fromjson?, so an older message could be read: stay shell
    [ -z "$f" ] || [ -n "$(tail -c1 "$f")" ] || [ "$(tail -n 200 "$f" | jq -rRn "$REAL"'[inputs | fromjson? | objects | real] | last | .message.stop_reason? // empty' 2>/dev/null || true)" != end_turn ] || st=parked
  fi
  echo "$st"
}
# /clear and in-TUI /resume change the session id; follow the live record
sync_sid() { # NAME [live session id, when the caller already has it]
  local s; load "$1"; s=${2-$(field "$1" sessionId)}
  if [ -n "$s" ] && [ "$s" != "$SID" ]; then sed -i "s|^SID=.*|SID=$s|" "$(envf "$1")"; SID=$s; fi
}
# a local slash command (/mcp ...) starts no turn: confirm it from the transcript lines added after the
# paste (their <command-name> tag); print the first line of its <local-command-stdout>, if any
local_cmd() { # FILE BYTES-BEFORE /WORD
  local t o; t=$(tail -c +$(($2 + 1)) "$1" | jq -rRn '[inputs | fromjson? | objects | select(.type == "user" or .type == "system") | (.message.content? // .content?) | strings] | join("\n")' 2>/dev/null) || return 1
  [[ $t == *"<command-name>$3</command-name>"* ]] || return 1
  echo delivered
  [[ $t == *'<local-command-stdout>'* ]] || return 0
  o=${t#*<local-command-stdout>}; o=$(sed 's/\x1b\[[0-9;]*[A-Za-z]//g' <<<"${o%%</local-command-stdout>*}" | grep -m1 '[^[:space:]]' || true)
  [ -z "$o" ] || echo "  ${o:0:200}"
}
# session title: latest custom title, else latest AI title in the transcript tail, else the spawn title
title_of() { # NAME [session id]; with or without an env file
  local SID='' TITLE='' f='' t=''
  if [ -f "$(envf "$1")" ]; then load "$1"; else SID=${2-$(field "$1" sessionId)}; fi
  [ -z "$SID" ] || f=$(compgen -G "$HOME/.claude/projects/*/$SID.jsonl" | head -1 || true)
  [ -z "$f" ] || t=$(tail -n 400 "$f" | { grep -E '^\{"type":"(custom|ai)-title"' || true; } |
    jq -rRn '[inputs | fromjson?] | (map(.customTitle // empty) | last) // (map(.aiTitle // empty) | last) // empty' 2>/dev/null || true)
  t=${t:-$TITLE}; echo "${t//[$'\t\n']/ }"
}
by_of() { # recorded caller: a crss session's NAME, else a transcript title, else the raw value
  local f t; [ -n "$1" ] || return 0; f=$(grep -lxF "SID=$1" "$CRSS_STATE"/*.env 2>/dev/null | head -1 || true)
  if [ -n "$f" ]; then basename "$f" .env; else t=$(title_of - "$1"); printf '%s\n' "${t:-$1}"; fi
}
paste_to() { # NAME FILE
  tm load-buffer -b "crss-$$" "$2"
  tm paste-buffer -p -d -b "crss-$$" -t "=ah_$1:"
  sleep 0.3
  tm send-keys -t "=ah_$1:" Enter
}

# PID, session id and status of every running claude, from its session record (Desktop- and SDK-started too)
live() {
  local f p s st
  for f in "$HOME"/.claude/sessions/*.json; do # one jq per record: a half-written one must not hide the rest
    jq -r '[.pid, .sessionId, .status // "?"] | @tsv' "$f" 2>/dev/null || true
  done |
    while IFS=$'\t' read -r p s st; do if kill -0 "$p" 2>/dev/null; then printf '%s\t%s\t%s\n' "$p" "$s" "$st"; fi; done
}
# Transcripts no crss session has, newest first: SID STATE AGE-SECONDS PID:STATUS ENTRYPOINT DIR TITLE (tabs).
# live: a running claude has the id, or the last message is under 2 minutes old. ended: the last real
# message is an assistant turn that finished (status_of's rule). cut: anything else (a prompt or a tool
# call left unanswered). Age is the last message's, since the app appends metadata to old transcripts.
others() { # HOURS SHOW-TMP KNOWN-SIDS
  local f s p st t e d age now; declare -A lp=(); now=$(date +%s)
  while IFS=$'\t' read -r p s st; do lp[$s]=$p:$st; done < <(live)
  # depth 2 leaves out SID/subagents/*.jsonl; -L because projects may be a symlink
  { find -L "$HOME/.claude/projects" -mindepth 2 -maxdepth 2 -name '*.jsonl' -mmin "-$(($1 * 60))" 2>/dev/null || true; } | while IFS= read -r f; do
    s=${f##*/}; s=${s%.jsonl}; [[ $s =~ $UUID && " $3 " != *" $s "* ]] || continue
    # newest line first, so jq stops at the first real message instead of parsing 200 long lines
    IFS=$'\t' read -r st t e d < <(tail -n 200 "$f" | tac 2>/dev/null | jq -rRn "$REAL"'first(inputs | fromjson? | objects | real)
      | [(if .type == "assistant" and .message.stop_reason == "end_turn" then "ended" else "cut" end),
         ((.timestamp // "" | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601?) // 0), (.entrypoint // "" | if . == "" then "-" else . end), (.cwd // "" | if . == "" then "-" else . end)] | join("\t")' 2>/dev/null) || continue
    [ "$t" != 0 ] || t=$(date -r "$f" +%s) # no timestamp on the message: the file's
    age=$((now - t)); [ "$age" -le $(($1 * 3600)) ] || continue
    p=${lp[$s]:-}; if [ -n "$p" ] || [ "$age" -lt 120 ]; then st=live; fi
    if [ "$st" != live ] && [ -z "$2" ]; then # headless runs and temp folders are noise unless asked for
      [ "$e" != sdk-cli ] || continue
      case $d in /tmp | /tmp/* | /var/tmp/* | /private/tmp/* | */scratchpad | */scratchpad/*) continue ;; esac
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$s" "$st" "$age" "${p:--}" "$e" "$d" "$(title_of - "$s")"
  done | sort -t$'\t' -k3,3n
}
caller() { # who runs this: a given name, the caller's conversation id, or the systemd unit
  local by=${CRSS_BY:-${CLAUDE_CODE_SESSION_ID:-}}
  [ -n "$by" ] || { by=$(tail -n1 "${CRSS_CGROUP:-/proc/self/cgroup}" 2>/dev/null || true); by=${by##*/}; [[ $by == *.service ]] || by=; }
  printf '%s\n' "${by//[$'\t\n']/ }" # printf: echo would eat a value like -n
}

cmd_spawn() {
  local n=${1:-} dir=${2:-} model='' effort='' title='' wt='' brief='' cm='' extra=() args=() sid by nm=${CRSS_NAMES:-auto}
  [[ $n =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "bad name: '$n'"
  [ -d "$dir" ] || die "no such dir: $dir"
  shift 2
  while [ $# -gt 0 ]; do
    case $1 in --model | --effort | --title | --brief) [ $# -ge 2 ] || die "$1 needs a value" ;; esac
    case $1 in
      --model) model=$2; shift 2 ;;
      --effort) effort=$2; shift 2 ;;
      --title) title=$2; shift 2 ;;
      --worktree) wt=1; shift ;;
      --code-mode) cm=1; shift ;;
      --brief) brief=$2; [ -r "$brief" ] || die "cannot read $brief"; shift 2 ;;
      --) shift; extra=("$@"); break ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ -e "$(envf "$n")" ] && die "$n already exists"
  case $nm in auto | plain) ;; *) die "CRSS_NAMES must be auto or plain, not '$nm'" ;; esac
  [[ $title != -* ]] || die "--title cannot start with '-'" # claude would read it as an option
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
  by=$(caller)
  mkdir -p "$CRSS_STATE"
  if [ -n "$brief" ]; then cp "$brief" "$CRSS_STATE/$n.brief"; brief=$CRSS_STATE/$n.brief; fi
  {
    echo "DIR=$(printf %q "$dir")"
    [ -n "$wt" ] && echo "WT=$(printf %q "$wt")"
    echo "SID=$sid"
    [ -z "$by" ] || echo "BY=$(printf %q "$by")"
    echo "ARGS=($([ ${#args[@]} -gt 0 ] && printf '%q ' "${args[@]}"))"
    echo "ENVS=()"
    [ "$nm" = auto ] && echo "NAMES=auto"
    [ -n "$cm" ] && echo "CODE_MODE=1"
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
      if [ -n "$CODE_MODE" ]; then # under --remote-control the session starts without Code Mode; -n names it instead
        ENVS+=(CLAUDE_CODE_EXPERIMENTAL_CODE_MODE=1)
        if [ -n "$first" ] && [ -n "$TITLE" ]; then a+=(-n "$TITLE"); elif [ "$NAMES" != auto ]; then a+=(-n "ah-$n"); fi
      elif [ "$NAMES" != auto ]; then
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

# A transcript no crss session has becomes one: an env file with its id, and cmd_loop resumes it.
cmd_adopt() { # SID NAME [DIR]
  local s=${1:-} n=${2:-} dir=${3:-} fs=() x by args=()
  [[ $s =~ ^[0-9a-f-]{8,36}$ ]] || die "adopt: SID is a session id or its first 8 or more characters"
  [[ $n =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "bad name: '$n'"
  if [ -e "$(envf "$n")" ] || tm has-session -t "=ah_$n" 2>/dev/null; then die "$n already exists"; fi
  mapfile -t fs < <(compgen -G "$HOME/.claude/projects/*/$s*.jsonl" || true)
  [ ${#fs[@]} -eq 1 ] || die "adopt: ${#fs[@]} transcripts match $s"
  s=$(basename "${fs[0]}" .jsonl)
  [[ $s =~ $UUID ]] || die "adopt: not a session id: '$s'" # it goes into an env file that is sourced
  x=$(grep -lxF "SID=$s" "$CRSS_STATE"/*.env 2>/dev/null | head -1 || true)
  [ -z "$x" ] || die "adopt: $s is already crss session $(basename "$x" .env)"
  x=$(live | awk -F'\t' -v s="$s" '$2 == s { printf "pid %s (%s) ", $1, $3 }')
  [ -z "$x" ] || die "adopt: $s is live in ${x% }; a second claude on one transcript would garble it. Stop that one first"
  # no session record yet (a headless run starting up) still shows as a file being written
  [ $(($(date +%s) - $(date -r "${fs[0]}" +%s))) -ge 120 ] || die "adopt: $s was written to under 2 minutes ago; something may still be running it"
  [ -n "$dir" ] || dir=$(tail -n 400 "${fs[0]}" | jq -rRn '[inputs | fromjson? | .cwd? // empty] | last // empty' 2>/dev/null || true)
  [ -d "$dir" ] || die "adopt: no such dir: '$dir' (give DIR)"
  dir=$(cd "$dir" && pwd -P); by=$(caller)
  read -ra args <<<"${CRSS_DEFAULT_ARGS:-}"
  mkdir -p "$CRSS_STATE"
  {
    echo "DIR=$(printf %q "$dir")"
    echo "SID=$s"
    [ -z "$by" ] || echo "BY=$(printf %q "$by")"
    echo "ARGS=($([ ${#args[@]} -gt 0 ] && printf '%q ' "${args[@]}"))"
    [ "${CRSS_NAMES:-auto}" != auto ] || echo "NAMES=auto"
    echo "ENVS=()"
  } >"$(envf "$n")"
  cmd_up "$n"
  echo "$n: adopted $s in $dir (tmux ah_$n, resumed by session id); crss send $n TEXT reaches it"
}

cmd_ls() {
  local n r st v x json='' filt=() rows='' rc=0 a b c d e f g all='' hrs=30 tmp='' orows=''
  while [ $# -gt 0 ]; do
    case $1 in
      --json) json=1 ;; --all) all=1 ;; --tmp) all=1 tmp=1 ;;
      --hours) all=1 hrs=${2:-}; [[ $hrs =~ ^[0-9]+$ ]] || die "ls: --hours needs a number"; hrs=$((10#$hrs)); shift ;;
      -*) die "ls: unknown option: $1" ;;
      *) filt+=("$1") ;;
    esac
    shift
  done
  [ -z "$all" ] || [ ${#filt[@]} -eq 0 ] || die "ls: --all takes no NAME"
  want() { [ ${#filt[@]} -eq 0 ] || [[ " ${filt[*]} " == *" $1 "* ]]; }
  for n in $(names); do
    want "$n" || continue
    ( load "$n" ) || { echo "$n: bad env file, skipped" >&2; continue; }
    load "$n"
    if tm has-session -t "=ah_$n" 2>/dev/null; then
      r=$(rec "$n"); st=$(status_of "$n" "$r"); v=$(jf "$r" version) # one record lookup per row: it walks the process tree
      sync_sid "$n" "$(jf "$r" sessionId)"
    else st=down v=; fi
    rows+="$n	${st:-?}	${v:--}	$SID	$DIR	@$(by_of "$BY")	$(title_of "$n")	${CODE_MODE:+ [code-mode]}"$'\n'
  done
  for n in $(tm list-sessions -F '#S' 2>/dev/null | sed -n 's/^ah_//p'); do # no env file: send reaches it, restart and reap don't
    [ -e "$(envf "$n")" ] && continue
    want "$n" || continue
    r=$(rec "$n"); st=$(status_of "$n" "$r"); v=$(jf "$r" version); x=$(jf "$r" sessionId)
    rows+="$n	${st:-?}	${v:--}	${x:--}	$(tm display-message -p -t "=ah_$n:" '#{pane_current_path}')	@	$(title_of "$n" "$x")"$'\n'
  done
  [ -z "$all" ] || orows=$(others "$hrs" "$tmp" "$(cut -f4 <<<"$rows" | tr '\n' ' ')")
  if [ -n "$json" ]; then
    printf '%s' "$rows" | jq -R -s --rawfile o <(printf '%s' "$orows") '(split("\n")[:-1] | map(split("\t") | {name:.[0], status:.[1], version:.[2], sid:.[3], dir:.[4], by:.[5][1:], title:(.[6] // "")}))
      + ($o | split("\n") | map(select(. != "") | split("\t") | {name:"-", status:.[1], version:"-", sid:.[0], dir:.[5], by:"", title:(.[6] // ""), age:(.[2] | tonumber), entry:.[4], pid:(.[3] | split(":")[0] | tonumber? // null), proc:(.[3] | split(":")[1])}))'
  else
    printf '%s' "$rows" | while IFS=$'\t' read -r a b c d e _ f g; do [ "$f" != ' [code-mode]' ] || { g=$f; f=; }; printf '%-16s %-5s %-10s %.8s %s %s%s\n' "$a" "$b" "$c" "$d" "$e" "${f:--}" "$g"; done
    [ -z "$orows" ] || while IFS=$'\t' read -r a b c d e f g; do # version column holds the age; NAME - marks a row adopt can take
      if [ "$c" -lt 3600 ]; then c=$((c / 60))m; else c=$((c / 3600))h; fi
      [ "$d" = - ] || e+=", pid ${d/:/ }"; printf '%-16s %-5s %-10s %.8s %s %s [%s]\n' - "$b" "$c" "$a" "$f" "${g:--}" "$e"
    done <<<"$orows"
  fi
  for a in "${filt[@]}"; do [ -f "$(envf "$a")" ] || [[ $'\n'$rows == *$'\n'"$a"$'\t'* ]] || { echo "crss: no such session: $a" >&2; rc=2; }; done # a typo is not an empty fleet
  return "$rc"
}
cmd_peek() { # exit 2 when there is no such session
  local n=${1:-} k=${2:-30} st=down t
  known "$n" || return 2
  if tm has-session -t "=ah_$n" 2>/dev/null; then st=$(status_of "$n"); st=${st:-?}; fi
  t=$(title_of "$n"); echo "$n $st ${t:--}"
  if [ "$st" != down ]; then tm capture-pane -p -S - -t "=ah_$n:" | { grep -v '^[[:space:]]*$' || true; } | tail -n "$k"; fi
}
# settled: tmux gone, a dialog open, or idle (or parked) on two polls in a row with the brief sent (its transcript exists)
cmd_wait() {
  local ns=() to=1800 t0=$SECONDS n st rc=0 left
  declare -A idl=() last=()
  while [ $# -gt 0 ]; do case $1 in --timeout) to=${2:-}; shift; [ $# -eq 0 ] || shift ;; *) ns+=("$1"); shift ;; esac; done
  if [ ${#ns[@]} -eq 0 ] || ! [[ $to =~ ^[0-9]+$ ]]; then echo "crss: usage: crss wait NAME... [--timeout SECONDS]" >&2; return 2; fi
  for n in "${ns[@]}"; do known "$n" || return 2; done # a misspelled name is not a session that went down
  sent() { ! grep -qs '^BRIEF=' "$(envf "$1")" || compgen -G "$HOME/.claude/projects/*/$(field "$1" sessionId).jsonl" >/dev/null; }
  while :; do
    left=0
    for n in "${ns[@]}"; do
      if ! tm has-session -t "=ah_$n" 2>/dev/null; then last[$n]=down; continue; fi
      st=$(status_of "$n"); last[$n]=${st:-?}
      if { [ "$st" = idle ] || [ "$st" = parked ]; } && sent "$n"; then idl[$n]=$((${idl[$n]:-0} + 1)); else idl[$n]=0; fi
      if [ "$st" != waiting ] && [ "${idl[$n]}" -lt 2 ]; then left=1; fi
    done
    [ "$left" = 1 ] || break
    if [ $((SECONDS - t0)) -ge "$to" ]; then rc=1; break; fi
    sleep "${CRSS_POLL:-2}"
  done
  for n in "${ns[@]}"; do echo "$n ${last[$n]}"; [[ ${last[$n]} == @(idle|parked) ]] || [ "$rc" = 1 ] || rc=2; done
  return $rc
}

cmd_send() { # exit 0 delivered or queued, 1 UNVERIFIED, 2 refused
  local n=${1:-} f='' before tmp want='' r s sid0 tf='' sz=0 cw=''
  known "$n" || return 2
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
  r=$(rec "$n"); before=$(status_of "$n" "$r"); sid0=$(jf "$r" sessionId)
  # no record means claude is starting or backing off: the text would sit in the terminal for the next launch
  [ -n "$before" ] || { echo "crss: $n has no live claude yet; retry shortly" >&2; return 2; }
  # a dialog is open: pasted text and Enter would answer it
  [ "$before" = waiting ] && { echo "crss: $n is waiting on a dialog; look at the pane" >&2; return 2; }
  if [[ $(<"$tmp") =~ ^(/[A-Za-z0-9:_-]+)([[:space:]]|$) ]]; then # transcript size before the paste, for local_cmd
    cw=${BASH_REMATCH[1]}; tf=$(compgen -G "$HOME/.claude/projects/*/$sid0.jsonl" | head -1 || true); [ -z "$tf" ] || sz=$(wc -c <"$tf")
  fi
  paste_to "$n" "$tmp"
  case $before in busy | shell) echo "queued (session $before)"; return 0 ;; esac
  # /rename T and /clear run inside the TUI and never make the session busy: confirm them by the
  # title (trimmed, as Claude stores it) or by the new session id
  if [[ $(<"$tmp") == '/rename '?* ]]; then
    want=$(<"$tmp"); want=${want#/rename }; want=${want#"${want%%[![:space:]]*}"}; want=${want%"${want##*[![:space:]]}"}
  fi
  # title_of reads the env file's id, stale after an in-TUI /clear; a broken env file must not fail a send that already pasted
  follow() { [ ! -f "$(envf "$n")" ] || ! ( load "$n" ) 2>/dev/null || sync_sid "$n" "$1"; }
  follow "$sid0"
  for _ in $(seq 40); do
    r=$(rec "$n"); s=$(jf "$r" sessionId)
    # a parked session already reads shell: it took the message once it stops being parked
    case $(if [ "$before" = parked ]; then status_of "$n" "$r"; else jf "$r" status; fi) in busy | shell) echo delivered; return 0 ;; esac
    if [ -n "$s" ] && [ "$s" != "$sid0" ]; then follow "$s"; echo delivered; return 0; fi
    if [ -n "$want" ] && [ "$(title_of "$n" "$s")" = "$want" ]; then echo delivered; return 0; fi
    [ -z "$cw" ] || [ -n "$tf" ] || tf=$(compgen -G "$HOME/.claude/projects/*/$s.jsonl" | head -1 || true) # no transcript before the paste: a file found now is all new
    if [ -n "$tf" ] && local_cmd "$tf" "$sz" "$cw"; then return 0; fi
    sleep 0.25
  done
  echo "UNVERIFIED: status stayed $before"; return 1
}

restart1() { # NAME WAIT
  local n=$1 old p f k=0
  tm has-session -t "=ah_$n" 2>/dev/null || { cmd_up "$n"; return; }
  sync_sid "$n"
  [ -n "$(field "$n" status)" ] || { echo "$n: skipped, no live claude"; return 0; }
  [ "$(field "$n" status)" = waiting ] && { echo "$n: skipped, waiting on a dialog"; return 0; }
  if working "$n"; then
    [ -z "$2" ] && { p=$(status_of "$n"); echo "$n: skipped, ${p/shell/busy}"; return 0; }
    for _ in $(seq 240); do working "$n" || break; if [ "$(status_of "$n")" = parked ]; then k=$((k + 1)); [ "$k" -lt 4 ] || break; else k=0; fi; sleep "${CRSS_BUSY_POLL:-15}"; done
    [ "$(status_of "$n")" != parked ] || { echo "$n: skipped, parked: /exit would stop the background command it left running"; return 0; }
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
  adopt) cmd_adopt "$@" ;;
  peek) cmd_peek "$@" ;;
  wait) cmd_wait "$@" ;;
  send) cmd_send "$@" ;;
  restart) cmd_restart "$@" ;;
  reap) cmd_reap "$@" ;;
  help | -h | --help) usage ;;
  *) usage >&2; exit 2 ;;
esac
