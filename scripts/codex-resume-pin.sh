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
#   sandbox-of [--flag] <args>      the ONE parser of the codex lane argv (flag table and
#                                   rules: the python block and tests/test-codex-resume-pin.sh).
#                                   Prints the effective sandbox (the -s/--sandbox flag, else
#                                   -c sandbox_mode, else read-only); --flag prints it only when
#                                   a -s/--sandbox FLAG names it (the loop appends `-s` unless
#                                   one does). Exit 1 on anything it cannot classify.
#   read-pin <file>                 print the UUID. Exit 0 ok; 1 no pin file (lstat ENOENT);
#                                   2 anything else (other stat error, symlink, dir, unreadable,
#                                   empty, multi-line, not one canonical lowercase UUID).
#   exists <uuid>                   0 exactly one rollout (path on stdout); 1 the search
#                                   completed and found none (and no broken symlink anywhere
#                                   under sessions/); 2 error (bad uuid, sessions dir missing or
#                                   unreadable, find failed, >1 match, dangling link).
#   verify-lane <uuid> <cwd>        0 the rollout's session_meta has an absolute cwd (realpath)
#                                   == <cwd> and originator == codex-tui; 1 foreign; 2 anything
#                                   unverifiable (no single rollout, no session_meta/cwd).
# Exit codes are per subcommand; 2 is also usage.
set -uo pipefail

CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
usage() { sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 2; }

# The one argv grammar (codex 0.160). Fails closed (exit 1) on anything it cannot classify, so
# this parser and codex's own clap can never disagree about which token is a flag.
sandbox_of() {
  python3 - "$@" <<'PY'
import sys
args = sys.argv[1:]
mode = "effective"
if args and args[0] == "--flag":
    mode = "flag"; args = args[1:]
VALID = ("read-only", "workspace-write", "danger-full-access")
SHORT = {"-m": "--model", "-s": "--sandbox", "-a": "--ask-for-approval", "-c": "--config", "-p": "--profile"}
LONG_VAL = {"--model", "--sandbox", "--ask-for-approval", "--config", "--profile", "--enable",
            "--disable", "--local-provider", "--add-dir"}
LONG_BOOL = {"--search", "--oss", "--strict-config", "--no-alt-screen", "--no-daemon"}
def die(msg):
    print("codex-resume-pin: " + msg, file=sys.stderr); sys.exit(1)
flags, configs = [], []
i = 0
while i < len(args):
    t = args[i]; i += 1
    if t == "--":
        die("bare '--' in codex args")
    if t.startswith("--"):
        name, eq, val = t.partition("=")
        if name in LONG_BOOL:
            if eq: die("%s takes no value" % name)
            continue
        if name not in LONG_VAL: die("unsupported flag %s" % name)
        if not eq:
            if i >= len(args): die("%s needs a value" % name)
            val = args[i]; i += 1
            if val.startswith("-"): die("%s value starts with '-'" % name)
    elif t.startswith("-") and len(t) > 1:
        short = t[:2]
        if short not in SHORT: die("unsupported flag %s" % t)
        name = SHORT[short]
        if len(t) > 2:
            val = t[2:]
            if val.startswith("="): die("%s: attached value starts with '='" % short)
        else:
            if i >= len(args): die("%s needs a value" % short)
            val = args[i]; i += 1
            if val.startswith("-"): die("%s value starts with '-'" % short)
    else:
        die("positional token in codex args")
    if name == "--sandbox":
        if val not in VALID: die("unknown sandbox %r" % val)
        flags.append(val)
    elif name == "--config":
        if "=" not in val: die("-c value has no '='")
        key, _, v = val.partition("=")
        key = key.strip()
        if key == "sandbox_mode":
            v = v.strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'": v = v[1:-1]
            if v not in VALID: die("unknown sandbox %r" % v)
            configs.append(v)
        elif key.startswith("sandbox_workspace_write."):
            pass
        elif key.startswith("sandbox"):
            die("unsupported -c key %s" % key)
if len(flags) > 1: die("more than one -s/--sandbox flag")
if len(configs) > 1: die("more than one sandbox_mode -c")
if flags and configs and flags[0] != configs[0]:
    die("conflicting sandboxes %r (flag) and %r (-c)" % (flags[0], configs[0]))
if mode == "flag":
    if flags: print(flags[0])
else:
    print(flags[0] if flags else configs[0] if configs else "read-only")
PY
}

# 0 pin (UUID on stdout) / 1 no pin file (lstat ENOENT) / 2 anything else.
read_pin() {
  python3 - "$1" <<'PY'
import os, re, stat, sys
f = sys.argv[1]
def bad(msg):
    print("codex-resume-pin: " + msg, file=sys.stderr); sys.exit(2)
try:
    st = os.lstat(f)
except FileNotFoundError:
    sys.exit(1)
except OSError as e:
    bad("cannot stat pin: %s" % e)
if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode):
    bad("pin is not a regular file")
try:
    data = open(f, "rb").read()
except OSError as e:
    bad("cannot read pin: %s" % e)
if data.endswith(b"\n"):
    data = data[:-1]
try:
    s = data.decode("ascii")
except UnicodeDecodeError:
    bad("pin is not ASCII")
if not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", s):
    bad("pin is not exactly one canonical lowercase UUID")
print(s)
PY
}

# stdout: the single rollout path. Exit as documented under `exists`. Symlinks are followed
# (find -L); a broken one anywhere under the root means the search cannot prove absence.
_find_rollout() {
  local id="$1" root tmp rc n p
  [[ "$id" =~ $UUID_RE ]] || { echo "codex-resume-pin: not a canonical uuid" >&2; return 2; }
  root="$(realpath -e -- "$CODEX_HOME_DIR/sessions" 2>/dev/null)" || { echo "codex-resume-pin: sessions dir missing" >&2; return 2; }
  if [ ! -d "$root" ] || [ ! -r "$root" ] || [ ! -x "$root" ]; then
    echo "codex-resume-pin: sessions dir unreadable" >&2; return 2
  fi
  tmp="$(mktemp)" || return 2
  find -L "$root" -name "rollout-*-$id.jsonl" -print0 > "$tmp" 2>/dev/null; rc=$?
  if [ "$rc" -ne 0 ]; then rm -f "$tmp"; echo "codex-resume-pin: find failed" >&2; return 2; fi
  n="$(tr -cd '\0' < "$tmp" | wc -c | tr -d ' ')"
  if [ "$n" -eq 0 ]; then
    rm -f "$tmp"
    p="$(find -L "$root" -type l -print -quit 2>/dev/null)" || { echo "codex-resume-pin: broken-link scan failed" >&2; return 2; }
    [ -z "$p" ] || { echo "codex-resume-pin: broken symlink under sessions: cannot prove absence" >&2; return 2; }
    return 1
  fi
  if [ "$n" -ne 1 ]; then rm -f "$tmp"; echo "codex-resume-pin: $n rollouts match $id" >&2; return 2; fi
  IFS= read -r -d '' p < "$tmp"; rm -f "$tmp"
  case "$p" in *$'\n'*) echo "codex-resume-pin: rollout path contains a newline" >&2; return 2 ;; esac
  [ -f "$p" ] || { echo "codex-resume-pin: rollout is not a regular file (dangling link?)" >&2; return 2; }
  printf '%s\n' "$p"
}

verify_lane() {
  local f rc
  f="$(_find_rollout "$1")"; rc=$?
  [ "$rc" -eq 0 ] || return 2
  python3 - "$f" "$2" <<'PY'
import json, os, sys
f, lane = sys.argv[1], os.path.realpath(sys.argv[2])
def unverifiable(msg):
    print("codex-resume-pin: " + msg, file=sys.stderr); sys.exit(2)
try:
    with open(f) as fh:
        first = json.loads(fh.readline())
except Exception as e:
    unverifiable("unreadable rollout: %s" % e)
if not isinstance(first, dict) or first.get("type") != "session_meta":
    unverifiable("first line is not session_meta")
p = first.get("payload")
if not isinstance(p, dict):
    unverifiable("session_meta has no payload object")
cwd = p.get("cwd")
if not isinstance(cwd, str) or not cwd or not os.path.isabs(cwd):
    unverifiable("session_meta cwd missing or not absolute: %r" % (cwd,))
if p.get("originator") == "codex-tui" and os.path.realpath(cwd) == lane:
    sys.exit(0)
print("codex-resume-pin: foreign thread (cwd=%r originator=%r)" % (cwd, p.get("originator")), file=sys.stderr)
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
