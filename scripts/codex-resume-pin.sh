#!/usr/bin/env bash
# codex-resume-pin: keep a Codex lane's thread across a reboot/crash, and make
# every resume pass its sandbox explicitly.
#
# Why: the Codex start-script loop restarted a FRESH `codex` each time, so a
# crash or reboot lost the lane's thread (the Claude loop has RESUME_PIN).
# And a resumed thread does NOT keep the sandbox it ran with: codex-cli 0.160
# takes it from the current config (here danger-full-access) unless the resume
# passes one (verified 2026-10-03: `codex exec resume` with no override wrote a
# file from a thread that started read-only; with `-c sandbox_mode="read-only"`
# it was blocked). Interactive `codex resume` takes `-s/-a` directly.
#
# Subcommands (all read $CODEX_HOME/sessions, default ~/.codex):
#   sandbox-of [--explicit] <args>  the sandbox the args name (-s/--sandbox X, or
#                                   `-c sandbox_mode=X`); read-only when none
#                                   (--explicit: print nothing when none).
#   resume-args <id> <codex args>   argv for an interactive resume: `resume <id>`
#                                   + the args, with an explicit `-s <sandbox>`
#                                   added when the args lack one (never the config
#                                   default).
#   latest <cwd> <since-epoch>      newest thread id whose session cwd is <cwd>
#                                   and whose rollout was written at/after <since>.
#   check <id> <expected>           exit 0 when the thread's LAST recorded
#                                   sandbox_policy is <expected>; 1 on mismatch;
#                                   3 when nothing is recorded yet.
#   watch <pin> <cwd> <since> <expected> <pid|child-of:PPID> [interval]
#                                   while <pid> (or PPID's codex/node child) lives: keep <pin> = newest thread
#                                   id for <cwd>; if that thread's recorded
#                                   sandbox_policy differs from <expected>, log it
#                                   and kill <pid> (fail closed: the loop's
#                                   backoff then retries, it never runs wider).
#                                   <expected> "-" = record the pin only.
# Exit: 0 ok, 1 mismatch/none, 2 usage, 3 not recorded yet.
set -uo pipefail

CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
usage() { sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 2; }

sandbox_of() {
  local want="" prev="" explicit=no
  [ "${1:-}" = "--explicit" ] && { explicit=yes; shift; }
  for a in "$@"; do
    case "$prev" in
      -s|--sandbox) want="$a" ;;
      -c|--config) case "$a" in sandbox_mode=*) want="${a#sandbox_mode=}"; want="${want//\"/}" ;; esac ;;
    esac
    case "$a" in --sandbox=*) want="${a#--sandbox=}" ;; esac
    prev="$a"
  done
  case "$want" in
    read-only|workspace-write|danger-full-access) echo "$want" ;;
    "") [ "$explicit" = yes ] || echo read-only ;;
    *) echo "codex-resume-pin: unknown sandbox '$want'" >&2; return 1 ;;
  esac
}

# stdout: "<mtime> <id>" per matching rollout; the caller sorts.
_threads_for() {
  python3 - "$CODEX_HOME_DIR/sessions" "$1" "$2" <<'PY'
import glob, json, os, sys
root, cwd, since = sys.argv[1], os.path.realpath(sys.argv[2]), float(sys.argv[3])
for f in glob.glob(os.path.join(root, "**", "rollout-*.jsonl"), recursive=True):
    try:
        m = os.path.getmtime(f)
        if m < since:
            continue
        with open(f) as fh:
            meta = json.loads(fh.readline())
        p = meta.get("payload", {})
        # Interactive lane threads only: a `codex exec` helper run in the same cwd
        # must never steal the pin.
        if p.get("originator") == "codex-tui" and os.path.realpath(p.get("cwd", "")) == cwd and p.get("id"):
            print(f"{m:.3f} {p['id']}")
    except Exception:
        continue
PY
}

latest() { _threads_for "$1" "$2" | sort -n | tail -1 | cut -d' ' -f2; }

_rollout_of() { find "$CODEX_HOME_DIR/sessions" -name "rollout-*-$1.jsonl" 2>/dev/null | head -1; }

check() {
  local f last
  f="$(_rollout_of "$1")"; [ -n "$f" ] || return 3
  last="$(grep -o '"sandbox_policy":{"type":"[a-z-]*"' "$f" | tail -1 | sed 's/.*"type":"//; s/"$//')"
  [ -n "$last" ] || return 3
  [ "$last" = "$2" ]
}

watch() {
  local pin="$1" cwd="$2" since="$3" expected="$4" pid="$5" interval="${6:-20}" id cur rc
  # child-of:PPID resolves the foreground codex (or its node wrapper) under the
  # loop shell each tick, since a TUI can't be backgrounded to learn its pid.
  _target() {
    case "$pid" in
      child-of:*) pgrep -P "${pid#child-of:}" -x codex 2>/dev/null | head -1 || true
                  [ -n "$(pgrep -P "${pid#child-of:}" -x codex 2>/dev/null)" ] || pgrep -P "${pid#child-of:}" -x node 2>/dev/null | head -1 ;;
      *) kill -0 "$pid" 2>/dev/null && echo "$pid" ;;
    esac
  }
  local tgt
  while tgt="$(_target)"; [ -n "$tgt" ]; do
    id="$(latest "$cwd" "$since")"
    if [ -n "$id" ]; then
      cur="$(cat "$pin" 2>/dev/null || true)"
      if [ "$cur" != "$id" ]; then
        mkdir -p "$(dirname "$pin")" && printf '%s\n' "$id" > "$pin.tmp.$$" && mv -f "$pin.tmp.$$" "$pin"
      fi
      if [ "$expected" = "-" ]; then rc=0; else check "$id" "$expected"; rc=$?; fi
      if [ "$rc" -eq 1 ]; then
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] codex-resume-pin event=SANDBOX-MISMATCH thread=$id expected=$expected — killing pid $tgt" >&2
        kill "$tgt" 2>/dev/null
        return 1
      fi
    fi
    sleep "$interval"
  done
  return 0
}

cmd="${1:-}"; shift || true
case "$cmd" in
  sandbox-of) sandbox_of "$@" ;;
  resume-args)
    [ $# -ge 1 ] || usage
    id="$1"; shift
    sb="$(sandbox_of "$@")" || exit 1
    printf 'resume\n%s\n' "$id"
    # An explicit -s/--sandbox in the args is kept; otherwise add the resolved one.
    has_s=no
    for a in "$@"; do case "$a" in -s|--sandbox|--sandbox=*) has_s=yes ;; esac; done
    for a in "$@"; do printf '%s\n' "$a"; done
    [ "$has_s" = yes ] || printf -- '-s\n%s\n' "$sb"
    ;;
  latest) [ $# -eq 2 ] || usage; latest "$1" "$2" ;;
  check) [ $# -eq 2 ] || usage; check "$1" "$2" ;;
  watch) [ $# -ge 5 ] || usage; watch "$@" ;;
  *) usage ;;
esac
