#!/usr/bin/env bash
# session-restart <session> [--dry-run] [--if-outdated] [--expect-version V] [--nudge | --nudge-file F]
#                 [--wait-idle [--interval S] [--idle-polls N] [--max-wait S]]
#
# Gracefully restart ONE idle crss Claude session onto the installed Claude Code
# binary, resuming its own conversation. This is the supported form of the hand-run
# graceful-restart runbook (restart1.sh + watcher.sh), with its gaps closed:
#   - resolution is read-only; every refusal happens before any key is sent;
#   - the busy test reads one escape-aware snapshot of the pane and parses the
#     prompt box (footer, spinner, typed text), not a grep of the whole screen;
#   - the resume pin is restored on every abort, and claude's argv must be exactly
#     what this session's own supervisor loop launches (script edited since launch
#     -> refuse).
#
# The flow: write the running sessionId to the session's one-shot resume pin, type
# /exit + Enter into the pane, and let the supervisor loop relaunch claude with
# --resume <sessionId> on the new binary. The new process is verified (version,
# sessionId, --remote-control name, --resume uuid) before the run reports OK.
#
# <session> is the tmux name <prefix>_<name> or the remote/unit name <prefix>-<name>
# for any prefix in the configured prefix set. Unknown prefix or unsafe name: exit 2.
#
# Busy (not idle) when any of these holds (the first one found is reported):
#   - registry status is present and not "idle";
#   - the claude process is younger than CRSS_RESTART_MIN_AGE seconds (a run under
#     30s makes the loop back off 300s);
#   - the footer below the prompt box shows a running turn, shell or agent row
#     ("esc to interrupt", "· N shells", "◯ ", "Enter to confirm");
#   - a spinner line ("… (") sits directly above the prompt box;
#   - the "Exit and stop tasks" dialog is open;
#   - the prompt box holds typed (non-ghost) text;
#   - a child process of claude is running that CRSS_RESTART_CHILD_ALLOW does not
#     allow (MCP servers and similar are allowed; a shell child never is);
#   - the pane has no prompt box at all.
# Transcript text above the prompt never counts.
#
# Exit codes:
#   0  restarted and verified (OK); or UP-TO-DATE with --if-outdated; or --dry-run
#      with nothing blocking (DRY-RUN)
#   1  refused, nothing changed (busy, protected, unknown script shape, no claude
#      process, foreign pin, ...); or --wait-idle reached --max-wait (REFUSED(deadline))
#      or the tmux session disappeared (REFUSED(gone))
#   2  usage error (also: admission denied, as session-resume does)
#   3  /exit WAS sent but the relaunch did not verify (timeout, wrong version,
#      sessionId or remote-control name, exit blocked): something changed, inspect it
#   4  skipped: the "Exit and stop tasks" dialog appeared (in-session scheduled tasks);
#      Escape was sent, the pin restored, the session unchanged (SKIPPED(scheduled-tasks))
#
# Every run ends with ONE stable status line on stdout:
#   session-restart: <S>: <STATUS> <details>
# where STATUS is OK, UP-TO-DATE, DRY-RUN, REFUSED(<reason>), FAIL(<reason>) or
# SKIPPED(scheduled-tasks). Progress lines start with the same prefix. Child processes
# are reported as pid(basename argv0) only: their full argv is never printed.
#
# Env knobs (tests set these): CRSS_CLAUDE_HOME, CRSS_UNIT_DIR, CRSS_BIN_DIR,
# CRSS_RESTART_POLL (2), CRSS_RESTART_WAIT (120), CRSS_RESTART_EXIT_GRACE (20),
# CRSS_RESTART_MIN_AGE (35), CRSS_RESTART_TYPE_SETTLE (1), CRSS_RESTART_NUDGE_DELAY (8),
# CRSS_RESTART_CHILD_ALLOW (extra child-process pattern), CRSS_PROTECT_NAMES.
set -uo pipefail

# Autonomous actuation uses the single Agent Host authority; diagnostics/manual
# control retain their existing behavior. No provider/model fallback here.
_crss_admit() {
  local helper_dir helper
  helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -f "$helper_dir/autonomous-admission.sh" ]; then
    helper="$helper_dir/autonomous-admission.sh"
  else
    helper="$(command -v autonomous-admission 2>/dev/null)" || return 2
  fi
  bash "$helper" "$@"
}
_admission_read_only=0
_admission_target=""
_admission_skip_next=0
for _admission_arg in "$@"; do
  if [ "$_admission_skip_next" = 1 ]; then _admission_skip_next=0; continue; fi
  case "$_admission_arg" in
    --dry-run|--help|-h) _admission_read_only=1 ;;
    --expect-version|--nudge-file|--interval|--idle-polls|--max-wait) _admission_skip_next=1 ;;
    -*) ;;
    *) [ -n "$_admission_target" ] || _admission_target="$_admission_arg" ;;
  esac
done
if [ "${CRSS_AUTONOMOUS:-0}" = 1 ] && [ "$_admission_read_only" = 0 ]; then
  _crss_admit restart "${CRSS_ADMISSION_SUBJECT:-${_admission_target:-unknown}}" >&2 || exit 2
fi

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
# CRSS_SESSION_PREFIX is what NEW sessions get; CRSS_LEGACY_PREFIXES is a
# `|`-separated list of EXTRA prefixes still RECOGNISED when parsing an existing
# name (see scripts/session-registry.sh for the full contract). Both feed one
# validated alternation, _crss_prefix_re. Copied verbatim in every script that
# needs it — see tests/test-crss-overlay-config.sh.
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

usage() { sed -n '2,3p' "$0" | sed 's/^# \{0,1\}//' >&2; exit "${1:-2}"; }

CLAUDE_HOME="${CRSS_CLAUDE_HOME:-$HOME/.claude}"
UNIT_DIR="${CRSS_UNIT_DIR:-$HOME/.config/systemd/user}"
BIN_DIR="${CRSS_BIN_DIR:-$HOME/.local/bin}"
POLL="${CRSS_RESTART_POLL:-2}"
WAIT="${CRSS_RESTART_WAIT:-120}"
EXIT_GRACE="${CRSS_RESTART_EXIT_GRACE:-20}"
MIN_AGE="${CRSS_RESTART_MIN_AGE:-35}"
TYPE_SETTLE="${CRSS_RESTART_TYPE_SETTLE:-1}"
NUDGE_DELAY="${CRSS_RESTART_NUDGE_DELAY:-8}"
CHILD_ALLOW='mcp|playwright|chrome|context7|serena|uvx|npm exec|node /|bun '
[ -n "${CRSS_RESTART_CHILD_ALLOW:-}" ] && CHILD_ALLOW="$CHILD_ALLOW|$CRSS_RESTART_CHILD_ALLOW"

# Protected names: the same semantics as session-doctor.sh (an empty value protects
# nothing; an invalid ERE protects everything, with a note).
: "${CRSS_PROTECT_NAMES:=claude-remote}"
PROTECT="$CRSS_PROTECT_NAMES"
[ -n "$PROTECT" ] || PROTECT='^$'
_crss_rc=0; grep -qiE -- "$PROTECT" </dev/null 2>/dev/null || _crss_rc=$?; [ "$_crss_rc" -le 1 ] || {
  echo "session-restart: CRSS_PROTECT_NAMES is not a valid regex ('$PROTECT'); treating EVERY session as protected until it's fixed" >&2
  PROTECT='.'
}
_is_protected() {
  local t="$1" v
  for v in "$t" "${t//_/-}" "${t//-/_}"; do
    grep -qiE -- "$PROTECT" <<<"$v" && return 0
  done
  return 1
}

# ── Python helpers (programs are read from heredocs; no program text is shell-expanded) ──
# Output fields are joined with the ASCII unit separator, which is not IFS whitespace,
# so empty fields survive `read`.
IFS= read -r -d '' PY_PARSE <<'PY' || true
import json, re, shlex, sys
SEP = "\x1f"
path = sys.argv[1]
s = open(path, encoding="utf-8", errors="replace").read()
def err(word, msg):
    print(SEP.join(["err", word, msg.replace("\n", " ")]))
    sys.exit(0)
NOPIN = "start script's loop has no resume pin; /exit would relaunch with --continue - refusing"
bm = re.search(r"^BACKEND=(.*)$", s, re.M)
if bm is not None:
    try:
        bp = shlex.split(bm.group(1))
    except ValueError:
        bp = []
    if len(bp) != 1 or bp[0] != "claude":
        err("backend", "backend '%s' is not supported by session-restart (only claude loops carry a resume pin)" % (bp[0] if len(bp) == 1 else "?"))
pm = re.search(r"tmux send-keys -t \"[^\"]+\" (\x27LOG_FILE=.*?\ndone\x27)", s, re.S)
if pm is None:
    err("usage-shape", "no supervisor loop payload (tmux send-keys ... 'LOG_FILE=... done') in " + path)
try:
    payload = shlex.split(pm.group(1))[0]
except (ValueError, IndexError):
    err("usage-shape", "supervisor loop payload did not parse")
pins = [l for l in payload.split("\n") if l.startswith("RESUME_PIN=")]
if len(pins) != 1:
    err("no-pin-loop", NOPIN)
try:
    pin = shlex.split(pins[0])[0][len("RESUME_PIN="):]
except (ValueError, IndexError):
    err("no-pin-loop", NOPIN)
if not pin.startswith("/") or "$" in pin:
    err("no-pin-loop", NOPIN)
launches = [l.strip() for l in payload.split("\n") if l.rstrip().endswith('--resume "$RESUME_ID"')]
if len(launches) != 1:
    err("no-pin-loop", NOPIN)
try:
    toks = shlex.split(launches[0])
except ValueError:
    err("no-pin-loop", NOPIN)
if len(toks) < 3 or toks[-2:] != ["--resume", "$RESUME_ID"]:
    err("no-pin-loop", NOPIN)
base = toks[:-2]
rc = ""
if "--remote-control" in base and base.index("--remote-control") + 1 < len(base):
    rc = base[base.index("--remote-control") + 1]
print(SEP.join(["ok", json.dumps(base), pin, base[0], rc]))
PY

IFS= read -r -d '' PY_REG <<'PY' || true
import json, sys
SEP = "\x1f"
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = None
if not isinstance(d, dict):
    print("bad")
    sys.exit(0)
vals = []
for k in ("sessionId", "version", "status"):
    v = d.get(k)
    vals.append("" if v is None else str(v))
print(SEP.join(["ok"] + vals))
PY

# argv modes: "info" reports rc/resume of a live claude; "match" also checks that its
# argv is exactly this start script's launch (base tokens, then nothing, --continue,
# or --resume <uuid>).
IFS= read -r -d '' PY_ARGV <<'PY' || true
import json, sys
SEP = "\x1f"
mode, pid = sys.argv[1], sys.argv[2]
try:
    data = open("/proc/%s/cmdline" % pid, "rb").read()
except OSError:
    print("gone")
    sys.exit(0)
parts = data.split(b"\0")
if parts and parts[-1] == b"":
    parts = parts[:-1]
argv = [x.decode("utf-8", "replace") for x in parts]
if mode == "match":
    base = json.loads(sys.argv[3])
    bin_ = sys.argv[4]
    if len(argv) > 1 and argv[0] != bin_ and argv[1] == bin_:
        argv = argv[1:]
    n = len(base)
    if argv[:n] != base:
        print(SEP.join(["bad", "running claude was not launched by this start script's loop (script edited since launch?)"]))
        sys.exit(0)
    tail = argv[n:]
    if tail not in ([], ["--continue"]) and not (len(tail) == 2 and tail[0] == "--resume"):
        print(SEP.join(["bad", "running claude was not launched by this start script's loop (script edited since launch?)"]))
        sys.exit(0)
def val(flag):
    if flag in argv:
        i = argv.index(flag)
        if i + 1 < len(argv):
            return argv[i + 1]
    return ""
print(SEP.join(["ok", val("--remote-control"), val("--resume")]))
PY

# Pane analysis. Mode "busy": print the first busy reason, nothing when idle.
# Mode "typed": print the non-ghost text on the prompt line with whitespace removed.
IFS= read -r -d '' PY_PANE <<'PY' || true
import re, sys
mode = sys.argv[1] if len(sys.argv) > 1 else "busy"
raw = sys.stdin.buffer.read().decode("utf-8", "replace").split("\n")
if raw and raw[-1] == "":
    raw = raw[:-1]
PROMPT = "❯"
ESC_OSC = r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"
ESC_CSI = r"\x1b\[[0-9;:?]*[ -/]*[@-~]"
ESC_ANY = r"\x1b."
ESC_ALL = re.compile(ESC_OSC + "|" + ESC_CSI + "|" + ESC_ANY)
SGR = re.compile(r"\x1b\[([0-9;]*)m")
plain = [ESC_ALL.sub("", l) for l in raw]
idx = [i for i, l in enumerate(plain) if PROMPT in l]
def typed(line):
    seg = line.split(PROMPT, 1)[1]
    dim = False
    out = []
    i = 0
    while i < len(seg):
        if seg[i] == "\x1b":
            m = SGR.match(seg, i)
            if m:
                for code in (m.group(1).split(";") if m.group(1) else ["0"]):
                    if code in ("0", "", "22"):
                        dim = False
                    elif code == "2":
                        dim = True
                i = m.end()
                continue
            m = ESC_ALL.match(seg, i)
            i = m.end() if m else i + 1
            continue
        if not dim:
            out.append(seg[i])
        i += 1
    return "".join(c for c in "".join(out) if not c.isspace())
if mode == "typed":
    print(typed(raw[idx[-1]]) if idx else "<no prompt line>")
    sys.exit(0)
if not idx:
    print("no prompt line (dialog or not at the prompt)")
    sys.exit(0)
p = idx[-1]
footer = "\n".join(plain[p + 1:])
m = re.search("esc to interrupt|· [0-9]+ shells?|◯ |Enter to confirm", footer)
if m:
    print("footer shows '%s'" % m.group(0))
    sys.exit(0)
for l in plain[max(0, p - 4):p]:
    # spinner glyphs as escapes: a non-ASCII bracket class fails the scripts/*.sh byte-locale guard
    if re.match("[\u273b\u273d\u2736\u00b7\u2722*] .*… \\(", l):
        print("spinner above prompt")
        sys.exit(0)
if any("Exit and stop tasks" in l for l in plain):
    print("exit dialog open")
    sys.exit(0)
if typed(raw[p]):
    print("typed input on the prompt")
PY

# ── Arguments ────────────────────────────────────────────────────────────────
TARGET="" DRY=0 IFOUT=0 EXPECT_VER="" NUDGE=0 NUDGE_FILE="" WAITIDLE=0
INTERVAL=60 IDLE_POLLS=3 MAX_WAIT=28800
TUNING_FLAG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)        DRY=1; shift ;;
    --if-outdated)    IFOUT=1; shift ;;
    --expect-version) EXPECT_VER="${2:-}"; [ $# -ge 2 ] || usage; shift 2 ;;
    --nudge)          NUDGE=1; shift ;;
    --nudge-file)     NUDGE_FILE="${2:-}"; [ $# -ge 2 ] || usage; shift 2 ;;
    --wait-idle)      WAITIDLE=1; shift ;;
    --interval)       INTERVAL="${2:-}"; TUNING_FLAG="${TUNING_FLAG:---interval}"; [ $# -ge 2 ] || usage; shift 2 ;;
    --idle-polls)     IDLE_POLLS="${2:-}"; TUNING_FLAG="${TUNING_FLAG:---idle-polls}"; [ $# -ge 2 ] || usage; shift 2 ;;
    --max-wait)       MAX_WAIT="${2:-}"; TUNING_FLAG="${TUNING_FLAG:---max-wait}"; [ $# -ge 2 ] || usage; shift 2 ;;
    -h|--help)        usage 0 ;;
    -*)               echo "session-restart: unknown flag $1" >&2; usage ;;
    *)                [ -z "$TARGET" ] || usage; TARGET="$1"; shift ;;
  esac
done
[ -n "$TARGET" ] || usage
if [ "$NUDGE" = 1 ] && [ -n "$NUDGE_FILE" ]; then
  echo "session-restart: --nudge and --nudge-file are mutually exclusive" >&2; exit 2
fi
if [ -n "$NUDGE_FILE" ] && { [ ! -f "$NUDGE_FILE" ] || [ ! -r "$NUDGE_FILE" ] || [ ! -s "$NUDGE_FILE" ]; }; then
  echo "session-restart: --nudge-file '$NUDGE_FILE' must be a readable non-empty file" >&2; exit 2
fi
if [ -n "$TUNING_FLAG" ] && [ "$WAITIDLE" = 0 ]; then
  echo "session-restart: $TUNING_FLAG only applies with --wait-idle" >&2; exit 2
fi
_is_decimal() { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]; }
_is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }
for _v in "$POLL" "$TYPE_SETTLE" "$NUDGE_DELAY" "$INTERVAL"; do
  _is_decimal "$_v" || { echo "session-restart: '$_v' is not a non-negative number of seconds" >&2; exit 2; }
done
for _v in "$WAIT" "$EXIT_GRACE" "$MIN_AGE" "$MAX_WAIT"; do
  _is_int "$_v" || { echo "session-restart: '$_v' is not a whole number of seconds" >&2; exit 2; }
done
_is_int "$IDLE_POLLS" && [ "$IDLE_POLLS" -ge 1 ] || { echo "session-restart: --idle-polls must be a whole number >= 1" >&2; exit 2; }
if [ -n "$EXPECT_VER" ] && [[ "$EXPECT_VER" =~ [[:space:]] ]]; then
  echo "session-restart: --expect-version must be a single token" >&2; exit 2
fi

# <session> -> S (tmux name <prefix>_<rest>) and R (remote/unit name <prefix>-<rest>).
PFX="" REST=""
if [[ "$TARGET" =~ ^($_crss_prefix_re)[_-](.+)$ ]]; then
  PFX="${BASH_REMATCH[1]}"; REST="${BASH_REMATCH[2]}"
fi
if [ -z "$PFX" ] || ! [[ "$REST" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
  echo "session-restart: unsafe or unknown session name '$TARGET' (want <prefix>_<name> or <prefix>-<name>, prefix from the configured set)" >&2
  exit 2
fi
S="${PFX}_${REST}"
R="${PFX}-${REST}"

prog() { echo "session-restart: $S: $*"; }
FTAIL=""
# final <exit-code> <status text>: the one stable status line, then any detail lines.
final() {
  prog "$2"
  if [ -n "$FTAIL" ]; then printf '%s\n' "$FTAIL" | sed 's/^/  | /'; fi
  exit "$1"
}

if _is_protected "$S" || _is_protected "$R"; then
  prog "REFUSED(protected) session name matches CRSS_PROTECT_NAMES; never restarted"
  exit 1
fi

# ── Resolution (read-only) ───────────────────────────────────────────────────
# resolve sets the globals below. On refusal it returns 1 with RWORD (reason word)
# and RMSG (detail).
RWORD="" RMSG=""
PIN="" BASE_JSON="" LAUNCH_BIN="" SCRIPT="" CPID="" SID="" RC_OLD="" ARGV_RESUME=""
EXP="" REG_SID="" REG_VER="" REG_STATUS="" PIN_CUR=""
fail_r() { RWORD="$1"; RMSG="$2"; return 1; }

# reg_read <claude pid>: fills REG_SID / REG_VER / REG_STATUS from Claude's registry entry.
reg_read() {
  local out tag
  REG_SID="" REG_VER="" REG_STATUS=""
  out="$(python3 -c "$PY_REG" "$CLAUDE_HOME/sessions/$1.json" 2>/dev/null)" || return 1
  IFS=$'\x1f' read -r tag REG_SID REG_VER REG_STATUS <<<"$out"
  [ "$tag" = ok ]
}

# claude_under <pane pid>: the first descendant (depth <= 3) whose comm is exactly claude.
claude_under() {
  local level=1 frontier="$1" next="" p c
  while [ "$level" -le 3 ] && [ -n "$frontier" ]; do
    next=""
    for p in $frontier; do
      for c in $(pgrep -P "$p" 2>/dev/null); do
        if [ "$(cat "/proc/$c/comm" 2>/dev/null)" = claude ]; then echo "$c"; return 0; fi
        next="$next $c"
      done
    done
    frontier="$next"; level=$((level + 1))
  done
  return 1
}

# is_self_ancestor <pid>: true when pid is this script or one of its ancestors.
is_self_ancestor() {
  local p=$$ pp
  while [ -n "$p" ] && [ "$p" -gt 1 ]; do
    [ "$p" = "$1" ] && return 0
    pp="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
    p="$pp"
  done
  return 1
}

resolve() {
  local out tag a b c d vout m t2 f2 f3 pv
  # 1. start script: the unit's ExecStart, else <bin>/<remote>-start.sh.
  if [ -f "$UNIT_DIR/$R.service" ]; then
    SCRIPT="$(sed -n 's/^ExecStart=//p' "$UNIT_DIR/$R.service" | head -1)"
  else
    SCRIPT="$BIN_DIR/$R-start.sh"
  fi
  if [ -z "$SCRIPT" ] || [ ! -f "$SCRIPT" ] || [ ! -r "$SCRIPT" ]; then
    fail_r no-start-script "start script '$SCRIPT' is not a readable file"; return 1
  fi
  # 2. the start script's loop: backend, resume pin, and the claude launch line.
  out="$(python3 -c "$PY_PARSE" "$SCRIPT" 2>/dev/null)" || { fail_r usage-shape "start script $SCRIPT did not parse"; return 1; }
  IFS=$'\x1f' read -r tag a b c d <<<"$out"
  if [ "$tag" != ok ]; then
    fail_r "$a" "$b"; return 1
  fi
  BASE_JSON="$a"; PIN="$b"; LAUNCH_BIN="$c"; RC_OLD="$d"
  # 3. the tmux session and its pane's claude process (exact targets).
  if ! tmux has-session -t "=$S" 2>/dev/null; then
    fail_r no-tmux "tmux session $S does not exist"; return 1
  fi
  pv="$(tmux display-message -p -t "=$S:" '#{pane_pid}' 2>/dev/null)"
  CPID=""
  [ -n "$pv" ] && CPID="$(claude_under "$pv")"
  if [ -z "$CPID" ]; then
    fail_r no-claude "no claude process under pane pid ${pv:-?}"; return 1
  fi
  # 4. never restart the process running this script.
  if is_self_ancestor "$CPID"; then
    fail_r self "claude pid $CPID is this script's own ancestor"; return 1
  fi
  # 5. Claude's registry entry for that pid.
  if ! reg_read "$CPID"; then
    fail_r no-registry "no readable registry entry $CLAUDE_HOME/sessions/$CPID.json"; return 1
  fi
  if ! [[ "$REG_SID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
    fail_r no-registry "registry entry for pid $CPID has no valid sessionId"; return 1
  fi
  SID="$REG_SID"
  # 6. the live argv must be exactly the loop's launch (never printed).
  m="$(python3 -c "$PY_ARGV" match "$CPID" "$BASE_JSON" "$LAUNCH_BIN" 2>/dev/null)"
  IFS=$'\x1f' read -r t2 f2 f3 <<<"$m"
  case "$t2" in
    ok) RC_OLD="$f2"; ARGV_RESUME="$f3" ;;
    gone) fail_r no-claude "claude pid $CPID exited while its argv was read"; return 1 ;;
    *) fail_r argv-mismatch "$f2"; return 1 ;;
  esac
  # 7. the one-shot pin: empty, or it must name this session or the uuid this claude was launched with.
  PIN_CUR=""
  if [ -e "$PIN" ]; then
    PIN_CUR="$(head -1 "$PIN" 2>/dev/null)"
  fi
  if [ -n "$PIN_CUR" ] && [ "$PIN_CUR" != "$SID" ] && [ "$PIN_CUR" != "$ARGV_RESUME" ]; then
    fail_r foreign-pin "pin $PIN names $PIN_CUR, which is neither sessionId $SID nor this claude's --resume uuid"; return 1
  fi
  # 8. the version this restart lands on.
  if [ -n "$EXPECT_VER" ]; then
    EXP="$EXPECT_VER"
  else
    vout="$(timeout 20 "$LAUNCH_BIN" --version 2>/dev/null)" || vout=""
    EXP="${vout%% *}"
  fi
  if [ -z "$EXP" ]; then
    fail_r version-unknown "could not read the expected version from '$LAUNCH_BIN --version' (pass --expect-version)"; return 1
  fi
  return 0
}

# pane_busy <claude pid>: prints the first busy reason; prints nothing when idle.
pane_busy() {
  local cp="$1" age pane why c a0 cmd
  reg_read "$cp" 2>/dev/null || true
  if [ -n "$REG_STATUS" ] && [ "$REG_STATUS" != idle ]; then
    echo "registry status '$REG_STATUS'"; return 0
  fi
  age="$(ps -o etimes= -p "$cp" 2>/dev/null | tr -d ' ')"
  if [ -n "$age" ] && [ "$age" -lt "$MIN_AGE" ] 2>/dev/null; then
    echo "claude running only ${age}s (< $MIN_AGE; a <30s run makes the loop back off 300s)"; return 0
  fi
  if ! pane="$(tmux capture-pane -e -p -t "=$S:" 2>/dev/null)"; then
    echo "pane capture failed"; return 0
  fi
  why="$(python3 -c "$PY_PANE" busy <<<"$pane")"
  if [ -n "$why" ]; then echo "$why"; return 0; fi
  for c in $(pgrep -P "$cp" 2>/dev/null); do
    a0="$(tr '\0' '\n' < "/proc/$c/cmdline" 2>/dev/null | head -1)"
    a0="${a0##*/}"
    # A shell child is a running tool command; its argv text may still match the allowlist.
    case "$a0" in
      bash|sh|zsh|dash|ksh|fish) echo "child process $c($a0)"; return 0 ;;
    esac
    cmd="$(tr '\0' ' ' < "/proc/$c/cmdline" 2>/dev/null)"
    if grep -qE -- "$CHILD_ALLOW" <<<"$cmd"; then continue; fi
    echo "child process $c(${a0:-?})"; return 0
  done
  return 1
}

pane_tail() {
  tmux capture-pane -p -t "=$S:" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -5
}

restore_pin() {
  if [ "$PREV_EXISTS" = 1 ]; then
    if [ -n "$PREV_CONTENT" ]; then printf '%s\n' "$PREV_CONTENT" > "$PIN"; else : > "$PIN"; fi
  else
    rm -f "$PIN"
  fi
}

NEW_VER="" PREV_EXISTS=0 PREV_CONTENT="" FSTATUS=""
# run_flow: the single-shot flow, after resolve and a clean busy test. Sets FSTATUS
# (and FTAIL on a failure). Returns 0 OK, 1 refused before/at the key press (retryable),
# 3 FAIL (something changed), 4 SKIPPED.
run_flow() {
  local old="$CPID" tmp why typed t_enter now newpid rc_new resume_new first_seen="" dt
  local vf=() x joined
  FTAIL=""
  PREV_EXISTS=0; PREV_CONTENT=""
  if [ -e "$PIN" ]; then PREV_EXISTS=1; PREV_CONTENT="$(head -1 "$PIN" 2>/dev/null)"; fi
  if ! mkdir -p "$(dirname "$PIN")" 2>/dev/null; then
    FSTATUS="REFUSED(pin-write) cannot create $(dirname "$PIN")"; return 1
  fi
  tmp="$PIN.tmp.$$"
  if ! { printf '%s\n' "$SID" > "$tmp" && mv -f "$tmp" "$PIN"; }; then
    rm -f "$tmp"; FSTATUS="REFUSED(pin-write) cannot write $PIN"; return 1
  fi
  # The race check: the pane must still be idle after the pin was written.
  why="$(pane_busy "$old")"
  if [ -n "$why" ]; then
    restore_pin; FSTATUS="REFUSED(race) $why"; return 1
  fi
  tmux send-keys -t "=$S:" -l /exit
  sleep "$TYPE_SETTLE"
  typed="$(tmux capture-pane -e -p -t "=$S:" 2>/dev/null | python3 -c "$PY_PANE" typed)"
  if [ "$typed" != "/exit" ]; then
    for _ in 1 2 3 4 5; do tmux send-keys -t "=$S:" BSpace; done
    restore_pin
    FSTATUS="REFUSED(prompt) prompt shows '$typed' not '/exit'"; return 1
  fi
  tmux send-keys -t "=$S:" Enter
  t_enter="$(date +%s)"
  while :; do
    now="$(date +%s)"
    if [ $((now - t_enter)) -ge "$WAIT" ]; then
      FTAIL="$(pane_tail)"
      FSTATUS="FAIL(timeout) no verified relaunch after ${WAIT}s; pin left in place so a later relaunch still resumes $SID"
      return 3
    fi
    sleep "$POLL"
    if grep -qF 'Exit and stop tasks' <<<"$(tmux capture-pane -p -t "=$S:" 2>/dev/null)"; then
      tmux send-keys -t "=$S:" Escape
      restore_pin
      FSTATUS="SKIPPED(scheduled-tasks) exit dialog cancelled; session unchanged"; return 4
    fi
    now="$(date +%s)"
    if kill -0 "$old" 2>/dev/null && [ $((now - t_enter)) -gt "$EXIT_GRACE" ]; then
      tmux send-keys -t "=$S:" Escape
      restore_pin
      FTAIL="$(pane_tail)"
      FSTATUS="FAIL(exit-blocked) claude pid $old still running ${EXIT_GRACE}s after /exit; pin restored, session left as it was"
      return 3
    fi
    pv="$(tmux display-message -p -t "=$S:" '#{pane_pid}' 2>/dev/null)"
    newpid=""
    [ -n "$pv" ] && newpid="$(claude_under "$pv")"
    if [ -n "$newpid" ] && [ "$newpid" != "$old" ] && reg_read "$newpid" && [ -n "$REG_SID" ]; then
      if [ "$REG_SID" != "$SID" ]; then
        [ -n "$first_seen" ] || first_seen="$now"
        # The registry may lag the relaunch: keep polling up to 10 more seconds for the sessionId.
        if [ $((now - first_seen)) -lt 10 ]; then continue; fi
      fi
      rc_new="" resume_new=""
      IFS=$'\x1f' read -r x rc_new resume_new <<<"$(python3 -c "$PY_ARGV" info "$newpid" 2>/dev/null)"
      vf=()
      [ "$REG_VER" = "$EXP" ] || vf+=("version $REG_VER (want $EXP)")
      [ "$REG_SID" = "$SID" ] || vf+=("sessionId $REG_SID (want $SID)")
      [ "$rc_new" = "$RC_OLD" ] || vf+=("remote-control '$rc_new' (want '$RC_OLD')")
      [ "$resume_new" = "$SID" ] || vf+=("--resume '$resume_new' (want $SID)")
      if [ "${#vf[@]}" -gt 0 ]; then
        joined=""
        for x in "${vf[@]}"; do joined="${joined:+$joined; }$x"; done
        FSTATUS="FAIL(verify) $joined"
        return 3
      fi
      dt=$((now - t_enter))
      NEW_VER="$REG_VER"
      FSTATUS="OK pid $old -> $newpid version $REG_VER sessionId $SID remote-control $rc_new (${dt}s)"
      return 0
    fi
  done
}

# do_nudge: after a verified restart, send the nudge; sets NUDGE_SUFFIX.
NUDGE_SUFFIX=""
do_nudge() {
  local f="$NUDGE_FILE" tmpf="" ss rcn
  if [ "$NUDGE" = 1 ]; then
    tmpf="$(mktemp)" || { prog "WARN nudge failed (cannot create a temp file)"; NUDGE_SUFFIX=" nudge=failed"; return 0; }
    printf '%s\n' "Fleet maintenance: this session was restarted onto Claude Code $NEW_VER at an idle point. Your conversation is intact; nothing you were doing was interrupted. Wakeups, crons or monitors armed in the old process are gone, so re-arm any you still need, then carry on with your task. If you had already finished, stay idle. No reply needed." > "$tmpf"
    f="$tmpf"
  fi
  sleep "$NUDGE_DELAY"
  ss="$(command -v session-send 2>/dev/null)" || ss="$(dirname "$0")/session-send.sh"
  "$ss" "$S" --file "$f" >/dev/null 2>&1
  rcn=$?
  [ -n "$tmpf" ] && rm -f "$tmpf"
  if [ "$rcn" = 0 ]; then
    prog "nudge sent"; NUDGE_SUFFIX=" nudge=sent"
  else
    prog "WARN nudge failed (exit $rcn)"; NUDGE_SUFFIX=" nudge=failed"
  fi
  return 0
}

main_single() {
  local why rc
  if ! resolve; then final 1 "REFUSED($RWORD) $RMSG"; fi
  if [ "$IFOUT" = 1 ] && [ "$REG_VER" = "$EXP" ]; then final 0 "UP-TO-DATE $EXP"; fi
  why="$(pane_busy "$CPID")"
  if [ -n "$why" ]; then final 1 "REFUSED(busy) $why"; fi
  if [ "$DRY" = 1 ]; then
    final 0 "DRY-RUN would restart pid $CPID sessionId $SID version $REG_VER -> $EXP pin $PIN"
  fi
  run_flow; rc=$?
  case "$rc" in
    0)
      if [ "$NUDGE" = 1 ] || [ -n "$NUDGE_FILE" ]; then do_nudge; fi
      final 0 "$FSTATUS$NUDGE_SUFFIX" ;;
    *) final "$rc" "$FSTATUS" ;;
  esac
}

main_wait() {
  local n0 deadline now count=0 why="" last="" rc
  n0="$(date +%s)"
  deadline=$((n0 + MAX_WAIT))
  while :; do
    if ! tmux has-session -t "=$S" 2>/dev/null; then
      final 1 "REFUSED(gone) tmux session $S disappeared while waiting"
    fi
    why=""
    if resolve; then
      if [ "$IFOUT" = 1 ] && [ "$REG_VER" = "$EXP" ]; then final 0 "UP-TO-DATE $EXP"; fi
      why="$(pane_busy "$CPID")"
    else
      case "$RWORD" in
        protected|backend|no-start-script|no-pin-loop|usage-shape|foreign-pin|argv-mismatch|version-unknown|self)
          final 1 "REFUSED($RWORD) $RMSG" ;;
        *) why="$RWORD: $RMSG" ;;
      esac
    fi
    if [ -z "$why" ]; then
      count=$((count + 1))
      if [ "$count" -ge "$IDLE_POLLS" ]; then
        if [ "$DRY" = 1 ]; then
          final 0 "DRY-RUN would restart pid $CPID sessionId $SID version $REG_VER -> $EXP pin $PIN"
        fi
        run_flow; rc=$?
        case "$rc" in
          0)
            if [ "$NUDGE" = 1 ] || [ -n "$NUDGE_FILE" ]; then do_nudge; fi
            final 0 "$FSTATUS$NUDGE_SUFFIX" ;;
          3|4) final "$rc" "$FSTATUS" ;;
          *)
            prog "retrying after: $FSTATUS"
            count=0; last="" ;;
        esac
      fi
    else
      count=0
      if [ "$why" != "$last" ]; then prog "waiting: $why"; last="$why"; fi
    fi
    now="$(date +%s)"
    if [ "$now" -ge "$deadline" ]; then
      final 1 "REFUSED(deadline) still busy after $((now - n0))s: ${why:-$last}"
    fi
    sleep "$INTERVAL"
  done
}

if [ "$WAITIDLE" = 1 ]; then main_wait; else main_single; fi
