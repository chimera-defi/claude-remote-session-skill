#!/usr/bin/env bash
# Tests for session-compact.sh. No live tmux, no real session, no real
# /compact anywhere in this file. Two layers:
#   1. Sourced, in-process tests against the pure _decide function and the
#      non-pure-but-stubbable helpers (_evaluate_row, _marker_hit,
#      _write_marker, _do_compact) — fast, no subprocess.
#   2. Subprocess/CLI tests that exec a COPY of session-compact.sh in an
#      isolated dir (no real session-doctor.sh/session-handoff.sh sibling),
#      with a stub session-handoff on PATH and $SESSION_COMPACT_SENSOR
#      pointing at a fixture script — proves the real dispatch/flag/exit-code
#      contract, still with zero tmux and zero I/O against anything real.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/session-compact.sh"
# shellcheck disable=SC1090
source "$SCRIPT"   # source-guarded: must NOT run dispatch
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }
has(){ if printf '%s' "$2" | grep -qF "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — pattern not found: $3 in: $2"; fi; }
lacks(){ if printf '%s' "$2" | grep -qF "$3"; then fail=$((fail+1)); echo "FAIL: $1 — pattern SHOULD NOT be present: $3 in: $2"; else pass=$((pass+1)); fi; }

# ============================================================================
# Layer 1: _decide — the pure eligibility function.
# d() fixes tmux_session/remote_name/pid/cwd/last_ts to placeholders so each
# call only has to spell out the fields that vary for that test, in the
# exact positional order _decide expects: min max idle protected compacted
# landed dirty marker_hit.
# ============================================================================
d() { _decide "$1" "$2" sess remote pid cwd "$3" 2026-01-01T00:00:00 "$4" "$5" "$6" "$7" "$8"; }

# --- each skip reason, exactly once -----------------------------------------
ok "decide-never-touched"     "$(d 60 0 never no  no      unknown clean   na)" "skip:never-touched"
ok "decide-outside-window-lo" "$(d 60 0 30    no  no      unknown clean   na)" "skip:outside-window"
ok "decide-protected"         "$(d 60 0 90    yes no      unknown clean   na)" "skip:protected"
ok "decide-landed-and-clean"  "$(d 60 0 90    no  no      yes     clean   na)" "skip:landed-and-clean"
ok "decide-already-compacted" "$(d 60 0 90    no  yes     no      unknown na)" "skip:already-compacted"
# pane-safety ("pane-<reason>") is NOT part of _decide (it requires I/O) —
# covered separately in the _evaluate_row section below.

# --- a fully-eligible row ----------------------------------------------------
ok "decide-fully-eligible" "$(d 60 0 90 no no unknown clean na)" "eligible"

# --- landed=yes + DIRTY is still eligible (only landed AND clean skips) -----
ok "decide-landed-dirty-still-eligible" "$(d 60 0 90 no no yes DIRTY na)" "eligible"

# --- compacted=unknown + matching marker -> skip; no marker -> eligible ----
ok "decide-unknown-marker-match"  "$(d 60 0 90 no unknown unknown unknown yes)" "skip:already-compacted"
ok "decide-unknown-no-marker"     "$(d 60 0 90 no unknown unknown unknown no)"  "eligible"

# --- --max-idle 0 means unbounded -------------------------------------------
ok "decide-max-idle-0-unbounded" "$(d 60 0 100000 no no unknown clean na)" "eligible"
# and max-idle IS enforced when non-zero
ok "decide-outside-window-hi" "$(d 60 120 200 no no unknown clean na)" "skip:outside-window"

# --- the documented escape hatch back to the original window ---------------
ok "decide-escape-hatch-30-60" "$(d 30 60 45 no no unknown clean na)" "eligible"
ok "decide-escape-hatch-30-60-too-old" "$(d 30 60 90 no no unknown clean na)" "skip:outside-window"

# --- ragged/short row: direct call with far fewer than 13 args must not crash
out="$(_decide 60 0 sess 2>&1)"; rc=$?
ok "decide-ragged-no-crash-exit"   "$rc" "0"
has "decide-ragged-no-crash-output" "$out" "skip:"

# ============================================================================
# Layer 2: _evaluate_row — adds the marker-file lookup + the live pane-safety
# call. We point $_SESSION_HANDOFF_BIN directly at a stub (bypassing
# _find_helper's co-located-first resolution, which would otherwise find the
# REAL scripts/session-handoff.sh sitting right next to session-compact.sh)
# — a seam the memoized resolver gives us for free.
# ============================================================================
STUBDIR="$(mktemp -d)"
trap 'rm -rf "$STUBDIR"' EXIT

# _write_stub_handoff — a reusable stub whose behavior is driven by env vars
# read at call time (exported by the test before invoking session-compact
# code, so each fresh `bash $bin ...` subprocess still sees them):
#   STUB_LOG              - every call appended here as "CALL <args>"
#   STUB_READY_SESSIONS   - space-separated sessions `ready` reports SAFE for
#   STUB_READY_REASON     - reason for non-SAFE sessions (default: busy)
#   STUB_BUSY_POLLS       - `check` reports busy this many times per session,
#                           then ready forever after (default 0 = ready immediately)
#   STUB_STATE            - dir for the per-session poll counters
_write_stub_handoff() {
  cat > "$STUBDIR/session-handoff" <<'EOF'
#!/usr/bin/env bash
[ -n "${STUB_LOG:-}" ] && echo "CALL $*" >> "$STUB_LOG"
case "$1" in
  ready)
    s="$2"
    for r in ${STUB_READY_SESSIONS:-}; do
      if [ "$r" = "$s" ]; then echo "ready: $s SAFE"; exit 0; fi
    done
    echo "ready: $s NOT-SAFE reason=${STUB_READY_REASON:-busy}"; exit 1 ;;
  check)
    s="$2"; polls="${STUB_BUSY_POLLS:-0}"
    cf="${STUB_STATE:-/tmp}/check_$s"
    n=0; [ -f "$cf" ] && n="$(cat "$cf")"
    n=$((n+1)); echo "$n" > "$cf"
    if [ "$n" -le "$polls" ]; then
      echo "check: $s  state=busy  unit-active=yes  model=x"; exit 1
    else
      echo "check: $s  state=ready  unit-active=yes  model=x"; exit 0
    fi ;;
  send)
    s="$2"
    if [ "${STUB_SEND_FAIL:-no}" = yes ]; then
      echo "send: UNVERIFIED on $s" >&2; exit 1
    fi
    echo "send: landed on $s"; exit 0 ;;
esac
EOF
  chmod +x "$STUBDIR/session-handoff"
}
_write_stub_handoff

# reset per-test env each time
_reset_stub_env() {
  STUB_LOG="$(mktemp)"; export STUB_LOG
  STUB_STATE="$(mktemp -d)"; export STUB_STATE
  export STUB_READY_SESSIONS="" STUB_READY_REASON="busy" STUB_BUSY_POLLS=0 STUB_SEND_FAIL=no
}

_reset_stub_env
_SESSION_HANDOFF_BIN="$STUBDIR/session-handoff"
STUB_READY_SESSIONS="readysess"
row_ready=(readysess remote 1 /cwd 90 2026-01-01T00:00:00 no no unknown clean)
row_notready=(notreadysess remote 1 /cwd 90 2026-01-01T00:00:00 no no unknown clean)
ok "evalrow-eligible-through-pane-check" "$(_evaluate_row 60 0 "${row_ready[@]}")" "eligible"
ok "evalrow-pane-unsafe-reason-propagated" "$(_evaluate_row 60 0 "${row_notready[@]}")" "skip:pane-busy"
# a pure-check failure (e.g. protected) must short-circuit BEFORE the live
# ready call — assert the stub was never invoked for that session.
_reset_stub_env
row_protected=(protsess remote 1 /cwd 90 2026-01-01T00:00:00 yes no unknown clean)
decision="$(_evaluate_row 60 0 "${row_protected[@]}")"
ok "evalrow-protected-short-circuit-decision" "$decision" "skip:protected"
lacks "evalrow-protected-short-circuit-no-pane-call" "$(cat "$STUB_LOG")" "protsess"

# ============================================================================
# _marker_hit / _write_marker — real filesystem I/O, sandboxed via HOME
# override (same convention session-doctor.sh's tests use).
# ============================================================================
_REAL_HOME="$HOME"
HOME="$(mktemp -d)"

ok "marker-hit-no-file" "$(_marker_hit nosession 2026-01-01T00:00:00)" "no"
_write_marker markedsess 2026-01-01T00:00:00 2026-01-01T00:05:00 compacted
ok "marker-hit-match"    "$(_marker_hit markedsess 2026-01-01T00:00:00)" "yes"
ok "marker-hit-mismatch" "$(_marker_hit markedsess 2026-02-02T00:00:00)" "no"
has "marker-file-well-formed-json" "$(cat "$HOME/.sessions/compact-markers/markedsess.json")" '"result": "compacted"'

HOME="$_REAL_HOME"

# ============================================================================
# _do_compact — send + poll-to-completion, with the seen-busy-before-ready
# guard, the per-session single-issue guard, and the timeout path.
# ============================================================================
_reset_stub_env
STUB_BUSY_POLLS=2   # busy for 2 polls, ready on the 3rd -> success before timeout
out="$(_do_compact compactok 30)"; rc=$?
ok "docompact-success-exit"   "$rc" "0"
ok "docompact-success-output" "$out" "compacted"

_reset_stub_env
STUB_BUSY_POLLS=999   # never becomes ready within the timeout
out="$(_do_compact compacttimeout 2)"; rc=$?
ok "docompact-timeout-exit"   "$rc" "1"
ok "docompact-timeout-output" "$out" "timeout"

_reset_stub_env
STUB_SEND_FAIL=yes
out="$(_do_compact compactsendfail 5)"; rc=$?
ok "docompact-send-failed-exit"   "$rc" "1"
ok "docompact-send-failed-output" "$out" "send-failed"

# never issue /compact twice to the SAME session in one invocation
_reset_stub_env
STUB_BUSY_POLLS=0
_do_compact compacttwice 5 >/dev/null
out2="$(_do_compact compacttwice 5 2>&1)"; rc2=$?
ok "docompact-no-double-issue-exit" "$rc2" "1"
has "docompact-no-double-issue-msg" "$out2" "refusing to send /compact"
# and it must not have sent a SECOND /compact — exactly one send line for it
sendcount="$(grep -c 'CALL send compacttwice /compact' "$STUB_LOG")"
ok "docompact-no-double-issue-single-send" "$sendcount" "1"

# ============================================================================
# Layer 3: CLI/subprocess tests. Copy session-compact.sh ALONE into an
# isolated dir (no session-doctor.sh/session-handoff.sh sibling — forces
# PATH-only resolution, exactly like test-session-send.sh's DEPLOY pattern),
# stub session-handoff + systemctl on PATH, point $SESSION_COMPACT_SENSOR at
# a fixture script.
# ============================================================================
ISO="$(mktemp -d)"
cp "$SCRIPT" "$ISO/session-compact.sh"
BIN="$(mktemp -d)"
cp "$STUBDIR/session-handoff" "$BIN/session-handoff"
cat > "$BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "CALL $*" >> "${SYSTEMCTL_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$BIN/systemctl"
FIXTURE_DIR="$(mktemp -d)"
cat > "$FIXTURE_DIR/sensor.sh" <<EOF
#!/usr/bin/env bash
cat "$FIXTURE_DIR/rows.tsv"
EOF
chmod +x "$FIXTURE_DIR/sensor.sh"

_row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }

_run() {  # _run <mode/args...> — invokes the isolated copy with stubs wired up
  PATH="$BIN:$PATH" SESSION_COMPACT_SENSOR="$FIXTURE_DIR/sensor.sh" \
    HOME="$CLI_HOME" bash "$ISO/session-compact.sh" "$@"
}

CLI_HOME="$(mktemp -d)"
_reset_stub_env

# --- report: basic eligible/skip rows, defaults are 60 / unbounded ---------
{
  _row readysess   remote 1 /cwd 90 2026-01-01T00:00:00 no no unknown clean
  _row notreadysess remote 1 /cwd 90 2026-01-01T00:00:00 no no unknown clean
} > "$FIXTURE_DIR/rows.tsv"
STUB_READY_SESSIONS="readysess"
out="$(_run report)"; rc=$?
ok   "cli-report-exit0"          "$rc" "0"
has  "cli-report-header-default-window" "$out" "idle >= 60m"
lacks "cli-report-header-no-upper-bound-by-default" "$out" "<= "
has  "cli-report-eligible-row"   "$out" "readysess"
has  "cli-report-reason-eligible" "$(printf '%s' "$out" | grep readysess)" "eligible"
has  "cli-report-reason-pane-busy" "$(printf '%s' "$out" | grep notreadysess)" "pane-busy"

# --- explicit escape hatch to the original 30-60 window still works --------
out2="$(_run report --min-idle 30 --max-idle 60)"; rc2=$?
ok  "cli-report-escape-hatch-exit0" "$rc2" "0"
has "cli-report-escape-hatch-window-text" "$out2" "idle >= 30m, <= 60m"

# --- sweep with neither --dry-run nor --apply exits 2, mutates nothing -----
: > "$STUB_LOG"
_run sweep >/dev/null 2>&1; rcn=$?
ok "cli-sweep-neither-flag-exit2" "$rcn" "2"
ok "cli-sweep-neither-flag-no-calls" "$(cat "$STUB_LOG")" ""

# --- sweep --dry-run performs no send (ready calls are fine, send is not) --
: > "$STUB_LOG"
outd="$(_run sweep --dry-run)"; rcd=$?
ok  "cli-sweep-dryrun-exit0" "$rcd" "0"
has "cli-sweep-dryrun-would-compact" "$outd" "would-compact: readysess"
has "cli-sweep-dryrun-pane-check-happened" "$(cat "$STUB_LOG")" "ready readysess"
lacks "cli-sweep-dryrun-no-send" "$(cat "$STUB_LOG")" "send"

# --- sweep --apply actually compacts an eligible row + writes a marker -----
: > "$STUB_LOG"
STUB_BUSY_POLLS=1
outa="$(_run sweep --apply --timeout 20)"; rca=$?
ok  "cli-sweep-apply-exit0" "$rca" "0"
has "cli-sweep-apply-compacted" "$outa" "compacted: readysess"
has "cli-sweep-apply-sent-compact" "$(cat "$STUB_LOG")" "send readysess /compact"
has "cli-sweep-apply-marker-written" "$(cat "$CLI_HOME/.sessions/compact-markers/readysess.json" 2>&1)" '"result": "compacted"'
STUB_BUSY_POLLS=0

# --- ragged/short TSV row through the real read-loop: no crash -------------
printf 'onlyname\n' > "$FIXTURE_DIR/rows.tsv"
outr="$(_run report 2>&1)"; rcr=$?
ok  "cli-report-ragged-row-exit0" "$rcr" "0"
has "cli-report-ragged-row-listed" "$outr" "onlyname"
has "cli-report-ragged-row-reason" "$(printf '%s' "$outr" | grep onlyname)" "bad-idle-field"

# --- numeric validation idiom -----------------------------------------------
outv="$(_run report --min-idle notanumber 2>&1)"; rcv=$?
ok "cli-report-bad-min-idle-exit2" "$rcv" "2"
has "cli-report-bad-min-idle-msg" "$outv" "requires a non-negative integer"

# --- before-relay: the critical fail-closed case ----------------------------
{ _row failsess remote 1 /cwd 90 2026-01-01T00:00:00 no no unknown clean; } > "$FIXTURE_DIR/rows.tsv"
: > "$STUB_LOG"
STUB_READY_SESSIONS="failsess"
STUB_BUSY_POLLS=999   # never verifies -> before-relay must not send the real message
# --timeout must come BEFORE the session name — before-relay only recognizes
# it as a leading flag (see the script's own comment on why: a free-form
# message must never be mistaken for a flag).
outf="$(_run before-relay --timeout 2 failsess "THE REAL MESSAGE" 2>&1)"; rcf=$?
ok    "cli-relay-unverified-exit-nonzero" "$([ "$rcf" -ne 0 ] && echo yes || echo no)" "yes"
has   "cli-relay-unverified-says-fail-closed" "$outf" "FAILING CLOSED"
lacks "cli-relay-unverified-message-not-sent" "$(cat "$STUB_LOG")" "THE REAL MESSAGE"
has   "cli-relay-unverified-compact-was-sent" "$(cat "$STUB_LOG")" "send failsess /compact"
[ -f "$CLI_HOME/.sessions/compact-markers/failsess.json" ] && { fail=$((fail+1)); echo "FAIL: cli-relay-unverified-no-marker — marker file exists but must not"; } || { pass=$((pass+1)); }
STUB_BUSY_POLLS=0

# --- before-relay: the primary happy path — eligible session -> compact ->
# verify -> THEN relay the real message. The other before-relay tests only
# exercise its PIECES (sweep --apply proves compact+marker in isolation;
# not-stale proves the skip-compact routing); this is the one place the
# actual "compact, verify, THEN relay" composition inside the before-relay
# arm itself gets exercised end to end. STUB_BUSY_POLLS=1 (not 0) is
# deliberate: _do_compact's seen-busy guard requires observing at least one
# busy poll before it will accept "ready" as done, so a stub that goes
# ready on the very first check would never satisfy it.
{ _row okrelay remote 1 /cwd 90 2026-01-01T00:00:00 no no unknown clean; } > "$FIXTURE_DIR/rows.tsv"
: > "$STUB_LOG"
STUB_READY_SESSIONS="okrelay"
STUB_BUSY_POLLS=1
_run before-relay okrelay "the real relayed message" >/dev/null 2>&1; rch=$?
ok  "cli-relay-happypath-exit0"            "$rch" "0"
has "cli-relay-happypath-compact-sent"     "$(cat "$STUB_LOG")" "send okrelay /compact"
has "cli-relay-happypath-message-sent"     "$(cat "$STUB_LOG")" "send okrelay the real relayed message"
has "cli-relay-happypath-marker-written"   "$(cat "$CLI_HOME/.sessions/compact-markers/okrelay.json" 2>&1)" '"result": "compacted"'
STUB_BUSY_POLLS=0

# --- before-relay: not eligible (below the idle window) -> relays directly -
{ _row freshsess remote 1 /cwd 5 2026-01-01T00:00:00 no no unknown clean; } > "$FIXTURE_DIR/rows.tsv"
: > "$STUB_LOG"
outk="$(_run before-relay freshsess "hello there")"; rck=$?
ok  "cli-relay-not-stale-exit0"    "$rck" "0"
has "cli-relay-not-stale-says-so"  "$outk" "not stale/eligible"
has "cli-relay-not-stale-relayed"  "$(cat "$STUB_LOG")" "send freshsess hello there"
lacks "cli-relay-not-stale-no-compact-sent" "$(cat "$STUB_LOG")" "/compact"

# --- before-relay: --file variant reaches session-handoff unmangled --------
MSGFILE="$(mktemp)"; printf 'file-relayed message\n' > "$MSGFILE"
: > "$STUB_LOG"
_run before-relay freshsess --file "$MSGFILE" >/dev/null 2>&1; rcfile=$?
ok  "cli-relay-file-variant-exit0" "$rcfile" "0"
has "cli-relay-file-variant-forwarded" "$(cat "$STUB_LOG")" "send freshsess --file $MSGFILE"
rm -f "$MSGFILE"

# ============================================================================
# install-timer: writes units, enables nothing, refuses to clobber
# ============================================================================
IT_CFG="$(mktemp -d)"
IT_HOME="$(mktemp -d)"
SYSTEMCTL_LOG="$(mktemp)"; export SYSTEMCTL_LOG
run_it() { PATH="$BIN:$PATH" XDG_CONFIG_HOME="$IT_CFG" HOME="$IT_HOME" bash "$ISO/session-compact.sh" "$@"; }

run_it install-timer >/dev/null 2>&1; rc1=$?
ok  "cli-installtimer-exit0" "$rc1" "0"
SVC="$IT_CFG/systemd/user/session-compact-report.service"
TMR="$IT_CFG/systemd/user/session-compact-report.timer"
[ -f "$SVC" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: cli-installtimer-service-written — $SVC missing"; }
[ -f "$TMR" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: cli-installtimer-timer-written — $TMR missing"; }
has "cli-installtimer-execstart-report-mode" "$(cat "$SVC" 2>/dev/null)" "ExecStart=$IT_HOME/.local/bin/session-compact report"
lacks "cli-installtimer-execstart-not-sweep" "$(cat "$SVC" 2>/dev/null)" "sweep"
ok  "cli-installtimer-no-systemctl-calls" "$(cat "$SYSTEMCTL_LOG")" ""

out2="$(run_it install-timer 2>&1)"; rc2=$?
ok  "cli-installtimer-refuse-without-force-exit2" "$rc2" "2"
has "cli-installtimer-refuse-without-force-msg" "$out2" "refusing to overwrite"

run_it install-timer --force >/dev/null 2>&1; rc3=$?
ok  "cli-installtimer-force-overwrites-exit0" "$rc3" "0"
ok  "cli-installtimer-force-no-systemctl-calls" "$(cat "$SYSTEMCTL_LOG")" ""

echo "session-compact: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
