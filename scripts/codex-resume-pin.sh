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
#   latest <cwd> <since-epoch> [pin]  newest thread id whose session cwd is <cwd>
#                                   and whose rollout was written at/after <since>;
#                                   ids pinned by sibling lanes (other *.codex-thread
#                                   beside [pin]) are skipped.
#   exists <id>                     exit 0 when the thread has a rollout on disk.
#   check <id> <expected> [since]           exit 0 when the thread's LAST recorded
#                                   sandbox_policy is <expected>; 1 on mismatch;
#                                   3 when nothing is recorded yet.
#   watch <pin> <cwd> <since> <expected> <pid|child-of:PPID> [interval]
#                                   while <pid> (or PPID's codex/node child) lives: keep <pin> = newest thread
#                                   id for <cwd>; if that thread's recorded
#                                   sandbox_policy differs from <expected>, log it
#                                   and kill <pid> (fail closed: the loop's
#                                   backoff then retries, it never runs wider).
#                                   <expected> "-" = record the pin only.
# [since]: only sandbox_policy lines stamped at/after it count (a resumed thread keeps
# its previous run's policy until its first new turn).
#
# Known limits (read before installing):
#  - Sandbox asymmetry: a lane spawned with NO -s runs its FRESH thread on the config
#    default (here danger-full-access), but every RESUME passes an explicit -s, read-only
#    when none was named. After a reboot such a lane comes back narrower than it ran.
#    Name -s in CRSS_CODEX_ARGS / the lane's args to keep a wider sandbox on resume.
#  - Mis-pin residual: the watcher pins the rollout the lane's own process holds open;
#    only when it holds none does it fall back to the newest codex-tui thread in the cwd.
#    A first-ever lane sharing its cwd with another codex-tui lane, with no pin yet, can
#    then adopt the sibling's newer thread (sibling-pin skipping only covers threads
#    already pinned). Give lanes distinct cwds.
#  - Trust dialog: the start script's `-c projects."<cwd>".trust_level` override is
#    unverified on a real lane dir; a resume that hits the trust prompt waits there.
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

# Newest matching thread. With a 3rd arg (a pin file), ids already pinned by a
# SIBLING lane (another *.codex-thread in the same dir) are skipped, so two lanes
# sharing a cwd cannot steal each other's thread.
latest() {
  local skip=""
  if [ -n "${3:-}" ]; then
    skip="$(for f in "$(dirname "$3")"/*.codex-thread; do
      [ -e "$f" ] && [ "$f" != "$3" ] && cat "$f" 2>/dev/null
    done)"
  fi
  _threads_for "$1" "$2" | sort -n | awk -v skip="$skip" 'BEGIN{n=split(skip,a,"\n");for(i=1;i<=n;i++)if(a[i]!="")s[a[i]]=1} !($2 in s)' | tail -1 | cut -d' ' -f2
}

# The thread whose rollout the process (or a child of it) holds open: the lane's own,
# even when a sibling in the same cwd started at the same moment. Empty when none.
_open_thread() {
  local p f
  for p in "$1" $(pgrep -P "$1" 2>/dev/null); do
    for f in /proc/"$p"/fd/*; do
      case "$(readlink "$f" 2>/dev/null)" in
        "$CODEX_HOME_DIR"/sessions/*/rollout-*.jsonl)
          f="$(readlink "$f")"; f="${f##*/}"; f="${f%.jsonl}"
          # rollout-<YYYY-MM-DDThh-mm-ss>-<uuid>: id = after the 6th dash-field
          echo "$f" | sed -E 's/^rollout-[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}-//'; return ;;
      esac
    done
  done
}

# Exit 0 when a rollout for the thread id exists (a deleted pin cannot resume).
exists() { [ -n "$(_rollout_of "$1")" ]; }

_rollout_of() { find "$CODEX_HOME_DIR/sessions" -name "rollout-*-$1.jsonl" 2>/dev/null | head -1; }

check() {
  local f last
  f="$(_rollout_of "$1")"; [ -n "$f" ] || return 3
  # Only policies recorded at/after <since> count: a resumed thread still holds
  # its previous run's policy until its first new turn, and that must not read
  # as a mismatch for the run we are enforcing.
  last="$(python3 - "$f" "${3:-0}" <<'PY'
import datetime, json, re, sys
f, since = sys.argv[1], float(sys.argv[2])
last = ""
for line in open(f, errors="replace"):
    m = re.search(r'"sandbox_policy":\{"type":"([a-z-]*)"', line)
    if not m:
        continue
    ts = None
    try:
        t = json.loads(line).get("timestamp")
        if t:
            ts = datetime.datetime.fromisoformat(t.replace("Z", "+00:00")).timestamp()
    except Exception:
        pass
    if (ts is None and since <= 0) or (ts is not None and ts >= since - 2):
        last = m.group(1)
print(last)
PY
)"
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
  local tgt seen=no t0 grace="${CODEX_PIN_GRACE:-90}"
  t0=$(date +%s)
  # The watcher starts before codex does: wait up to <grace>s for the target to
  # appear (it exits only once the target was seen and is gone, or never came).
  while :; do
    tgt="$(_target)"
    if [ -z "$tgt" ]; then
      [ "$seen" = yes ] && break
      [ $(( $(date +%s) - t0 )) -ge "$grace" ] && break
      sleep 1; continue
    fi
    seen=yes
    id="$(_open_thread "$tgt")"
    # Only a lane thread (codex-tui, this cwd, written this run) may become the pin; a
    # held helper/other-cwd rollout is ignored.
    if [ -n "$id" ] && ! _threads_for "$cwd" "$since" | awk -v i="$id" '$2==i{f=1} END{exit !f}'; then id=""; fi
    [ -n "$id" ] || id="$(latest "$cwd" "$since" "$pin")"
    if [ -n "$id" ]; then
      cur="$(cat "$pin" 2>/dev/null || true)"
      if [ "$cur" != "$id" ]; then
        mkdir -p "$(dirname "$pin")" && printf '%s\n' "$id" > "$pin.tmp.$$" && mv -f "$pin.tmp.$$" "$pin"
      fi
      if [ "$expected" = "-" ]; then rc=0; else check "$id" "$expected" "$since"; rc=$?; fi
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
  latest) [ $# -ge 2 ] || usage; latest "$@" ;;
  exists) [ $# -eq 1 ] || usage; exists "$1" ;;
  check) [ $# -ge 2 ] || usage; check "$@" ;;
  watch) [ $# -ge 5 ] || usage; watch "$@" ;;
  *) usage ;;
esac
