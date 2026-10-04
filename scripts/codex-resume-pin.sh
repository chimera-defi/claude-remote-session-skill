#!/usr/bin/env bash
# codex-resume-pin: read-side checks for a Codex lane's explicitly pinned thread.
#
# Why: the Codex start-script loop restarted a FRESH `codex` each time, so a crash or
# reboot lost the lane's thread (the Claude loop has RESUME_PIN). And a resumed thread
# does NOT keep the sandbox it ran with: codex-cli 0.160 takes it from the current
# config unless the resume passes one (verified 2026-10-03: `codex exec resume` with no
# override wrote a file from a thread that started read-only). So the start loop passes
# an explicit sandbox on EVERY attempt, fresh or resume.
#
# The pin file (~/.sessions/resume/<remote>.codex-thread) is written ONLY by a person or
# agent, on purpose: one canonical lowercase UUID. Nothing here writes it, and nothing
# guesses a thread (no "newest in cwd", no open-file inference). Every read below fails
# closed; only a PROVEN absence may lead to a fresh launch.
#
# Subcommands (rollouts are read from $CODEX_HOME/sessions, default ~/.codex):
#   sandbox-of [--explicit] <args>  the one sandbox the args name (-s/--sandbox X,
#                                   --sandbox=X, -c sandbox_mode=X; TOML quotes allowed);
#                                   read-only when none (--explicit: print nothing).
#                                   Exit 1 on an unknown value, a missing value, or two
#                                   different sandboxes.
#   read-pin <file>                 print the UUID. Exit 0 ok; 1 no pin file at all;
#                                   2 bad (symlink/dir/unreadable/empty/multi-line/not
#                                   exactly one canonical lowercase UUID).
#   exists <uuid>                   0 exactly one rollout (path on stdout); 1 the search
#                                   completed and found none; 2 error (bad uuid, sessions
#                                   dir missing/unreadable, find failed, >1 match).
#   verify-lane <uuid> <cwd>        0 the rollout's session_meta cwd (realpath) == <cwd>
#                                   and originator == codex-tui; 1 foreign; 2 error.
# Exit codes are per subcommand; 2 is also usage.
set -uo pipefail

CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
usage() { sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 2; }

sandbox_of() {
  local explicit=no prev="" a a2 v found=""
  [ "${1:-}" = "--explicit" ] && { explicit=yes; shift; }
  _take() {
    v="$(printf '%s' "$1" | tr -d "\"' ")"
    case "$v" in
      read-only|workspace-write|danger-full-access) ;;
      *) echo "codex-resume-pin: unknown sandbox '$v'" >&2; return 1 ;;
    esac
    if [ -n "$found" ] && [ "$found" != "$v" ]; then
      echo "codex-resume-pin: conflicting sandboxes '$found' and '$v'" >&2; return 1
    fi
    found="$v"
  }
  for a in "$@"; do
    case "$prev" in
      -s|--sandbox) _take "$a" || return 1 ;;
      -c|--config) a2="${a// /}"; case "$a2" in sandbox_mode=*) _take "${a2#sandbox_mode=}" || return 1 ;; esac ;;
    esac
    case "$a" in --sandbox=*) _take "${a#--sandbox=}" || return 1 ;; esac
    prev="$a"
  done
  case "$prev" in -s|--sandbox) echo "codex-resume-pin: $prev needs a value" >&2; return 1 ;; esac
  if [ -n "$found" ]; then echo "$found"; elif [ "$explicit" = no ]; then echo read-only; fi
}

read_pin() {
  local f="$1"
  [ -e "$f" ] || [ -L "$f" ] || return 1
  if [ -L "$f" ] || [ ! -f "$f" ] || [ ! -r "$f" ]; then
    echo "codex-resume-pin: pin is not a regular readable file" >&2; return 2
  fi
  python3 - "$f" <<'PY' || return 2
import re, sys
data = open(sys.argv[1], "rb").read()
if data.endswith(b"\n"):
    data = data[:-1]
try:
    s = data.decode("ascii")
except UnicodeDecodeError:
    sys.exit("codex-resume-pin: pin is not ASCII")
if not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", s):
    sys.exit("codex-resume-pin: pin is not exactly one canonical lowercase UUID")
print(s)
PY
}

# stdout: the single rollout path. Exit as documented under `exists`.
_find_rollout() {
  local id="$1" root="$CODEX_HOME_DIR/sessions" out n
  [[ "$id" =~ $UUID_RE ]] || { echo "codex-resume-pin: not a canonical uuid" >&2; return 2; }
  if [ ! -d "$root" ] || [ ! -r "$root" ] || [ ! -x "$root" ]; then
    echo "codex-resume-pin: sessions dir missing/unreadable" >&2; return 2
  fi
  out="$(find "$root" -type f -name "rollout-*-$id.jsonl" -print 2>/dev/null)" || { echo "codex-resume-pin: find failed" >&2; return 2; }
  [ -z "$out" ] && return 1
  n="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
  [ "$n" -eq 1 ] || { echo "codex-resume-pin: $n rollouts match $id" >&2; return 2; }
  printf '%s\n' "$out"
}

verify_lane() {
  local f rc
  f="$(_find_rollout "$1")"; rc=$?
  [ "$rc" -eq 0 ] || return 2
  python3 - "$f" "$2" <<'PY'
import json, os, sys
f, cwd = sys.argv[1], os.path.realpath(sys.argv[2])
try:
    with open(f) as fh:
        p = json.loads(fh.readline()).get("payload", {})
except Exception as e:
    print(f"codex-resume-pin: unreadable rollout: {e}", file=sys.stderr); sys.exit(2)
if p.get("originator") == "codex-tui" and os.path.realpath(p.get("cwd", "")) == cwd:
    sys.exit(0)
print(f"codex-resume-pin: foreign thread (cwd={p.get('cwd')!r} originator={p.get('originator')!r})", file=sys.stderr)
sys.exit(1)
PY
}

cmd="${1:-}"; shift || true
case "$cmd" in
  sandbox-of) sandbox_of "$@" ;;
  read-pin) [ $# -eq 1 ] || usage; read_pin "$1" ;;
  exists) [ $# -eq 1 ] || usage; _find_rollout "$1" ;;
  verify-lane) [ $# -eq 2 ] || usage; verify_lane "$@" ;;
  *) usage ;;
esac
