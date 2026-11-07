#!/usr/bin/env bash
# session-restart <tmux-session> [--dry-run] [--wait-idle] [--nudge]
#   Restart one live, idle Claude session onto the installed CLI, keeping its conversation: pin the running
#   sessionId, type /exit, and let the session's start-script loop relaunch claude with --resume <sessionId>.
#   The relaunch is verified (version, sessionId, --remote-control name, --resume) before OK.
#   Busy means refused with nothing sent: registry status not idle, claude younger than CRSS_RESTART_MIN_AGE,
#   a running footer or spinner under the prompt, "Exit and stop tasks" on screen, typed text at the prompt,
#   or a child process that is a shell (always) or is outside the allowlist. Transcript text above the prompt never counts.
#   --wait-idle re-checks every CRSS_RESTART_INTERVAL and restarts after CRSS_RESTART_IDLE_POLLS idle polls in a row.
#   --nudge sends the session a short note after OK.
# Exit: 0 OK or DRY-RUN; 1 nothing changed (REFUSED or SKIPPED); 2 usage; 3 FAIL after /exit was sent.
# Env: CRSS_HOME (KEY=VALUE lines in its config.sh; the environment wins), CRSS_CLAUDE_HOME, CRSS_UNIT_DIR, CRSS_BIN_DIR, CRSS_PROTECT_NAMES,
#   CRSS_RESTART_CHILD_ALLOW, CRSS_RESTART_POLL (2), CRSS_RESTART_WAIT (120), CRSS_RESTART_MIN_AGE (35),
#   CRSS_RESTART_NUDGE_DELAY (8), CRSS_RESTART_INTERVAL (60), CRSS_RESTART_IDLE_POLLS (3),
#   CRSS_RESTART_MAX_WAIT (28800).
set -o pipefail
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
set -u
CLAUDE_HOME="${CRSS_CLAUDE_HOME:-$HOME/.claude}"
UNIT_DIR="${CRSS_UNIT_DIR:-$HOME/.config/systemd/user}"
BIN_DIR="${CRSS_BIN_DIR:-$HOME/.local/bin}"
POLL="${CRSS_RESTART_POLL:-2}"; WAIT="${CRSS_RESTART_WAIT:-120}"; MIN_AGE="${CRSS_RESTART_MIN_AGE:-35}"
NUDGE_DELAY="${CRSS_RESTART_NUDGE_DELAY:-8}"; INTERVAL="${CRSS_RESTART_INTERVAL:-60}"
IDLE_POLLS="${CRSS_RESTART_IDLE_POLLS:-3}"; MAX_WAIT="${CRSS_RESTART_MAX_WAIT:-28800}"
: "${CRSS_PROTECT_NAMES:=claude-remote}"
CHILD_ALLOW='mcp|playwright|chrome|context7|serena|uvx|npm exec|node /|bun '
[ -n "${CRSS_RESTART_CHILD_ALLOW:-}" ] && CHILD_ALLOW="$CHILD_ALLOW|$CRSS_RESTART_CHILD_ALLOW"

usage() { echo "usage: session-restart <tmux-session> [--dry-run] [--wait-idle] [--nudge]" >&2; exit 2; }
S="" DRY=0 WAITIDLE=0 NUDGE=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --wait-idle) WAITIDLE=1 ;;
    --nudge) NUDGE=1 ;;
    -*|"") usage ;;
    *) [ -z "$S" ] || usage; S="$a" ;;
  esac
done
[ -n "$S" ] || usage

CPID="" R="" SID="" PIN="" EXP="" REGV="" LAUNCH="" RW="" RM="" FSTATUS="" NSUF="" SCRIPT=""
REG_SID="" REG_VER="" REG_STATUS="" PREV_HAS=0 PREV="" ARGV=() NARGV=() CA=()
out() { echo "session-restart: $S: $*"; }
protected() {
  local v
  [ -n "$CRSS_PROTECT_NAMES" ] || return 1
  for v in "$1" "${1//_/-}" "${1//-/_}"; do grep -qiE -- "$CRSS_PROTECT_NAMES" <<<"$v" && return 0; done
  return 1
}
if protected "$S"; then out "REFUSED(protected) session name matches CRSS_PROTECT_NAMES; never restarted"; exit 1; fi

# Pane analysis, read from stdin with capture-pane -e. Mode busy prints the first busy reason; mode typed prints
# the non-dim text on the prompt line with whitespace removed. Glyphs are built with chr() so this file stays ASCII.
IFS= read -r -d '' PANE_PY <<'PY' || true
import re, sys
mode = sys.argv[1]
raw = sys.stdin.buffer.read().decode("utf-8", "replace").split("\n")
ESC = re.compile(r"\x1b\[[0-9;:?]*[ -/]*[@-~]|\x1b.")
SGR = re.compile(r"(\x1b\[[0-9;]*m)")
PROMPT, DOT, CIRC = chr(0x276f), chr(0xb7), chr(0x25ef)
plain = [ESC.sub("", l) for l in raw]
idx = [i for i, l in enumerate(plain) if PROMPT in l]
def typed(line):
    out, dim = [], False
    for tok in SGR.split(line.split(PROMPT, 1)[1]):
        if tok.startswith("\x1b["):
            for c in tok[2:-1].split(";"):
                dim = c == "2" or (dim and c not in ("", "0", "22"))
        elif not dim:
            out.append(ESC.sub("", tok))
    return re.sub(r"\s", "", "".join(out))
if mode == "typed":
    print(typed(raw[idx[-1]]) if idx else "")
    sys.exit(0)
if any("Exit and stop tasks" in l for l in plain):
    print("exit dialog open"); sys.exit(0)
if not idx:
    print("no prompt line"); sys.exit(0)
p = idx[-1]
m = re.search("esc to interrupt|" + DOT + " [0-9]+ shells?|" + CIRC + " |Enter to confirm", "\n".join(plain[p + 1:]))
if m:
    print("footer shows '%s'" % m.group(0)); sys.exit(0)
spin = "[" + chr(0x273b) + chr(0x273d) + chr(0x2736) + DOT + chr(0x2722) + "*] .*" + chr(0x2026) + " \\("
if any(re.match(spin, l) for l in plain[max(0, p - 4):p]):
    print("spinner above prompt"); sys.exit(0)
if typed(raw[p]):
    print("typed input on the prompt")
PY

fail() { RW="$1"; RM="$2"; return 1; }
# argval FLAG ARG...: the word after FLAG, or nothing.
argval() {
  local flag="$1" prev="" a; shift
  for a in "$@"; do [ "$prev" = "$flag" ] && { echo "$a"; return 0; }; prev="$a"; done
  return 0
}
# claude_under PID: the first process with comm claude under PID, walking down the tree.
claude_under() {
  local c kids=()
  [ -n "${1:-}" ] || return 1
  mapfile -t kids < <(pgrep -P "$1" 2>/dev/null)
  for c in "${kids[@]}"; do
    [ "$(cat "/proc/$c/comm" 2>/dev/null)" = claude ] && { echo "$c"; return 0; }
  done
  for c in "${kids[@]}"; do claude_under "$c" && return 0; done
  return 1
}
# reg_read PID: sessionId, version and status from claude's registry file. Fails when unreadable.
reg_read() {
  local f="$CLAUDE_HOME/sessions/$1.json"
  REG_SID="$(jq -r '.sessionId // empty' "$f" 2>/dev/null)" || return 1
  REG_VER="$(jq -r '.version // empty' "$f" 2>/dev/null)"
  REG_STATUS="$(jq -r '.status // empty' "$f" 2>/dev/null)"
  [ -n "$REG_SID" ]
}

# resolve: read-only. Sets CPID, R, SID, REGV, PIN, EXP; on refusal sets RW and RM and returns 1.
resolve() {
  local pv a
  tmux has-session -t "=$S" 2>/dev/null || { fail no-session "tmux session $S does not exist"; return; }
  pv="$(tmux display-message -p -t "=$S:" '#{pane_pid}' 2>/dev/null)"
  CPID="$(claude_under "$pv")"
  [ -n "$CPID" ] || { fail no-claude "no claude process under pane pid ${pv:-?}"; return; }
  reg_read "$CPID" || { fail no-claude "no readable registry entry for claude pid $CPID"; return; }
  SID="$REG_SID"; REGV="$REG_VER"
  mapfile -d '' -t ARGV < "/proc/$CPID/cmdline" 2>/dev/null
  R="$(argval --remote-control "${ARGV[@]}")"
  [ -n "$R" ] || { fail no-claude "claude pid $CPID has no --remote-control name"; return; }
  protected "$R" && { fail protected "remote name $R matches CRSS_PROTECT_NAMES; never restarted"; return; }
  # The binary to ask for the expected version: argv[0], or the claude element when argv[0] is a script interpreter.
  LAUNCH="${ARGV[0]:-}"
  for a in "${ARGV[@]}"; do [ "$(basename -- "$a")" = claude ] && { LAUNCH="$a"; break; }; done
  SCRIPT="$BIN_DIR/$R-start.sh"
  [ -f "$UNIT_DIR/$R.service" ] && SCRIPT="$(sed -n 's/^ExecStart=//p' "$UNIT_DIR/$R.service" | head -1)"
  [ -r "$SCRIPT" ] && [ -f "$SCRIPT" ] || { fail no-start-script "start script '$SCRIPT' is not a readable file"; return; }
  PIN="$(grep -oE 'RESUME_PIN="[^"]+"' "$SCRIPT" | head -1 | cut -d'"' -f2)"
  PIN="${PIN/#\$HOME/$HOME}"
  case "$PIN" in /*) ;; *) fail no-pin-loop "start script $SCRIPT has no absolute RESUME_PIN"; return ;; esac
  if [ -s "$PIN" ] && [ "$(head -1 "$PIN")" != "$SID" ]; then
    fail foreign-pin "pin $PIN names another session"; return
  fi
  EXP="$(timeout 20 "$LAUNCH" --version 2>/dev/null | head -1 | cut -d' ' -f1)"
  [ -n "$EXP" ] || { fail no-version "cannot read the installed version from $LAUNCH --version"; return; }
  return 0
}

# busy_reason: prints why the session is busy and returns 0; returns 1 when idle. Uses the resolved CPID.
busy_reason() {
  local pane why c a0 age
  if [ -n "$REG_STATUS" ] && [ "$REG_STATUS" != idle ]; then echo "registry status '$REG_STATUS'"; return 0; fi
  age="$(ps -o etimes= -p "$CPID" 2>/dev/null | tr -d ' ')"
  if [ -n "$age" ] && [ "$age" -lt "$MIN_AGE" ]; then echo "claude running only ${age}s"; return 0; fi
  if ! pane="$(tmux capture-pane -e -p -t "=$S:" 2>/dev/null)"; then echo "pane capture failed"; return 0; fi
  why="$(python3 -c "$PANE_PY" busy <<<"$pane")"
  if [ -n "$why" ]; then echo "$why"; return 0; fi
  local kids=()
  mapfile -t kids < <(pgrep -P "$CPID" 2>/dev/null)
  for c in "${kids[@]}"; do
    mapfile -d '' -t CA < "/proc/$c/cmdline" 2>/dev/null
    a0="$(basename -- "${CA[0]:-?}")"
    case "$a0" in bash|sh|dash|zsh|fish|ksh) echo "shell child $c($a0)"; return 0 ;; esac
    [[ "${CA[*]:-}" =~ $CHILD_ALLOW ]] && continue
    echo "child process $c($a0)"; return 0
  done
  return 1
}

restore_pin() { if [ "$PREV_HAS" = 1 ]; then printf '%s\n' "$PREV" > "$PIN"; else rm -f "$PIN"; fi; }

# run_flow: pin, /exit, relaunch, verify. 0 OK, 1 refused before the relaunch (nothing changed), 3 FAIL,
# 4 SKIPPED. FSTATUS holds the status text for every return.
run_flow() {
  local typed t0 newpid vf="" NRC NRES
  PREV_HAS=0; PREV=""
  if [ -e "$PIN" ]; then PREV_HAS=1; PREV="$(head -1 "$PIN")"; fi
  mkdir -p "$(dirname "$PIN")"
  if ! { printf '%s\n' "$SID" > "$PIN.tmp.$$" && mv -f "$PIN.tmp.$$" "$PIN"; }; then
    rm -f "$PIN.tmp.$$"; FSTATUS="REFUSED(pin-write) cannot write $PIN"; return 1
  fi
  tmux send-keys -t "=$S:" -l '/exit'
  sleep "$POLL"
  typed="$(tmux capture-pane -e -p -t "=$S:" 2>/dev/null | python3 -c "$PANE_PY" typed)"
  if [ "$typed" != /exit ]; then
    for _ in 1 2 3 4 5; do tmux send-keys -t "=$S:" BSpace; done
    restore_pin; FSTATUS="REFUSED(busy) prompt shows '$typed', not /exit"; return 1
  fi
  tmux send-keys -t "=$S:" Enter
  t0="$(date +%s)"
  while :; do
    sleep "$POLL"
    if grep -qF 'Exit and stop tasks' <<<"$(tmux capture-pane -p -t "=$S:" 2>/dev/null)"; then
      tmux send-keys -t "=$S:" Escape; restore_pin
      FSTATUS="SKIPPED(scheduled-tasks) exit dialog cancelled; session unchanged"; return 4
    fi
    if [ $(( $(date +%s) - t0 )) -ge "$WAIT" ]; then
      FSTATUS="FAIL(timeout) no verified relaunch after ${WAIT}s; pin left in place"; return 3
    fi
    newpid="$(claude_under "$(tmux display-message -p -t "=$S:" '#{pane_pid}' 2>/dev/null)")"
    if [ -z "$newpid" ] || [ "$newpid" = "$CPID" ] || ! reg_read "$newpid"; then continue; fi
    for _ in 1 2 3 4 5; do [ "$REG_SID" = "$SID" ] && break; sleep 2; reg_read "$newpid"; done
    mapfile -d '' -t NARGV < "/proc/$newpid/cmdline" 2>/dev/null
    NRC="$(argval --remote-control "${NARGV[@]}")"; NRES="$(argval --resume "${NARGV[@]}")"
    [ "$REG_VER" = "$EXP" ] || vf="$vf version $REG_VER (want $EXP);"
    [ "$REG_SID" = "$SID" ] || vf="$vf sessionId $REG_SID (want $SID);"
    [ "$NRC" = "$R" ] || vf="$vf remote-control '$NRC' (want '$R');"
    [ "$NRES" = "$SID" ] || vf="$vf --resume '$NRES' (want $SID);"
    if [ -n "$vf" ]; then FSTATUS="FAIL(verify)${vf%;}"; return 3; fi
    FSTATUS="OK pid $CPID -> $newpid version $REG_VER sessionId $SID remote-control $R"
    return 0
  done
}

nudge() {
  local f
  f="$(mktemp)"
  printf '%s\n' "Fleet maintenance: this session was restarted onto Claude Code $REG_VER at an idle point. Your conversation is intact. Wakeups, crons and background shells from the old process are gone, so re-arm anything you still need, then carry on. If you had already finished, stay idle; no reply needed." > "$f"
  sleep "$NUDGE_DELAY"
  if session-send "$S" --file "$f" >/dev/null 2>&1; then NSUF=" nudge=sent"; else NSUF=" nudge=failed"; fi
  rm -f "$f"
}

main() {
  local t0 why="" last="" count=0 need=1 rc
  t0="$(date +%s)"
  [ "$WAITIDLE" = 1 ] && need="$IDLE_POLLS"
  while :; do
    if ! resolve; then
      if [ "$WAITIDLE" = 1 ] && [ "$RW" = no-session ]; then out "REFUSED(gone) tmux session $S disappeared"; exit 1; fi
      out "REFUSED($RW) $RM"; exit 1
    fi
    if why="$(busy_reason)"; then
      [ "$WAITIDLE" = 1 ] || { out "REFUSED(busy) $why"; exit 1; }
      [ "$why" = "$last" ] || { out "waiting: $why"; last="$why"; }
      count=0
      if [ $(( $(date +%s) - t0 )) -ge "$MAX_WAIT" ]; then out "REFUSED(deadline) still busy after ${MAX_WAIT}s: $why"; exit 1; fi
      sleep "$INTERVAL"; continue
    fi
    if [ "$DRY" = 1 ]; then out "DRY-RUN would restart pid $CPID sessionId $SID version $REGV -> $EXP"; exit 0; fi
    count=$((count + 1))
    if [ "$count" -lt "$need" ]; then sleep "$INTERVAL"; continue; fi
    run_flow; rc=$?
    if [ "$rc" = 0 ]; then
      [ "$NUDGE" = 1 ] && nudge
      out "$FSTATUS$NSUF"; exit 0
    fi
    if [ "$rc" = 1 ] && [ "$WAITIDLE" = 1 ]; then count=0; sleep "$INTERVAL"; continue; fi
    out "$FSTATUS"
    [ "$rc" = 3 ] && exit 3
    exit 1
  done
}
main
