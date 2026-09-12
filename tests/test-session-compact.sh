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

# --- Bug 2: protected/compacted/landed/dirty must fail CLOSED on any value
# outside the sensor's documented vocabulary (including "", which a
# truncated TSV row produces) rather than silently reading as the
# PERMISSIVE default ("not protected", "not landed", "not already
# compacted"). idle_minutes is valid in every case here so these reach the
# new vocabulary checks instead of being caught early by bad-idle-field.
ok "decide-malformed-protected-empty"  "$(d 60 0 90 ""      no      unknown clean   na)" "skip:malformed-row"
ok "decide-malformed-protected-junk"   "$(d 60 0 90 maybe   no      unknown clean   na)" "skip:malformed-row"
ok "decide-malformed-compacted-empty"  "$(d 60 0 90 no      ""      unknown clean   na)" "skip:malformed-row"
ok "decide-malformed-compacted-junk"   "$(d 60 0 90 no      maybe   unknown clean   na)" "skip:malformed-row"
ok "decide-malformed-landed-empty"     "$(d 60 0 90 no      no      ""      clean   na)" "skip:malformed-row"
ok "decide-malformed-landed-junk"      "$(d 60 0 90 no      no      maybe   clean   na)" "skip:malformed-row"
ok "decide-malformed-dirty-empty"      "$(d 60 0 90 no      no      unknown ""      na)" "skip:malformed-row"
ok "decide-malformed-dirty-junk"       "$(d 60 0 90 no      no      unknown maybe   na)" "skip:malformed-row"
# and the legitimate no-worktree value for landed is NOT malformed
ok "decide-landed-no-worktree-valid"   "$(d 60 0 90 no      no      no-worktree clean na)" "eligible"

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
    s="$2"
    # STUB_CHECK_BUSY_SESSIONS — sessions that report busy on EVERY check call,
    # independent of the poll-counter model below (which _do_compact's tests
    # use to go ready after N polls). Added for sweep v2's coverage: a session
    # that stays busy for the whole scan, not one that eventually finishes.
    for b in ${STUB_CHECK_BUSY_SESSIONS:-}; do
      if [ "$b" = "$s" ]; then
        echo "check: $s  state=busy  unit-active=yes  model=x"; exit 1
      fi
    done
    polls="${STUB_BUSY_POLLS:-0}"
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
  export STUB_READY_SESSIONS="" STUB_READY_REASON="busy" STUB_BUSY_POLLS=0 STUB_SEND_FAIL=no STUB_CHECK_BUSY_SESSIONS=""
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
# Bug B: _do_compact must detect completion from the TRANSCRIPT — ground
# truth, independent of pane text — not just from observed pane state. Real
# bug, confirmed 2026-09-11 against two live sessions: a genuinely-completed
# compact ("Compacted (ctrl+o to see full summary)" visibly on the pane) was
# reported "timeout" by this function, because the pane-state path requires
# observing `busy` at least once before accepting `ready`, and `busy` was
# never observed even once across the ENTIRE timeout on either real run — see
# _do_compact's own comment for the confirmed mechanism (compaction measures
# ~101s, well inside a 240s timeout, so if `busy` had ever been seen a later
# `ready` poll would have caught it well before timing out; it never did).
# STUB_BUSY_POLLS=999 below means the pane NEVER reports busy — under the OLD
# pane-only logic this could only ever end in "timeout"; success here can only
# come from the transcript path.
# ============================================================================
_encode_cwd_test_dir() {  # <home> <cwd> -> the transcript dir path (mkdir -p'd)
  local home="$1" cwd="$2" dir
  dir="$home/.claude/projects/$(_encode_cwd "$cwd")"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

_reset_stub_env
STUB_BUSY_POLLS=999
DOTB_HOME="$(mktemp -d)"
DOTB_CWD="$DOTB_HOME/proj"; mkdir -p "$DOTB_CWD"
DOTB_PROJDIR="$(_encode_cwd_test_dir "$DOTB_HOME" "$DOTB_CWD")"
# A STALE pre-existing marker — proves the fix snapshots a BASELINE and
# requires something NEWER than it, not merely "a marker exists somewhere in
# the file" (which would false-positive on a session compacted long ago that
# hasn't had a fresh turn since).
cat > "$DOTB_PROJDIR/old.jsonl" <<'EOF'
{"type":"system","subtype":"compact_boundary","timestamp":"2020-01-01T00:00:00.000Z"}
EOF
HOME="$DOTB_HOME"
# Simulates the real compact completing mid-poll (without waiting out a real
# ~101s compact): append a FRESH compact_boundary 1s after send, in the
# background, while _do_compact (foreground, 3s poll interval) is waiting.
( sleep 1; printf '{"type":"system","subtype":"compact_boundary","timestamp":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" >> "$DOTB_PROJDIR/live.jsonl" ) &
BGPID=$!
out="$(_do_compact transcriptok 30 "$DOTB_CWD")"; rc=$?
wait "$BGPID" 2>/dev/null
HOME="$_REAL_HOME"
ok "docompact-transcript-success-exit"   "$rc" "0"
ok "docompact-transcript-success-output" "$out" "compacted"
rm -rf "$DOTB_HOME"

# Fail-closed sibling: cwd given, transcript dir exists, but nothing EVER
# postdates the baseline (only the same stale 2020 marker sits there the
# whole time) AND the pane never resolves either (STUB_BUSY_POLLS=999 again)
# — must still time out, exit nonzero, print "timeout", same as the pane-only
# case above. This is the fail-closed requirement: "can't confirm" must never
# be relaxed into a false "compacted", regardless of which signal is used.
_reset_stub_env
STUB_BUSY_POLLS=999
DOTB_HOME2="$(mktemp -d)"
DOTB_CWD2="$DOTB_HOME2/proj"; mkdir -p "$DOTB_CWD2"
DOTB_PROJDIR2="$(_encode_cwd_test_dir "$DOTB_HOME2" "$DOTB_CWD2")"
cat > "$DOTB_PROJDIR2/old.jsonl" <<'EOF'
{"type":"system","subtype":"compact_boundary","timestamp":"2020-01-01T00:00:00.000Z"}
EOF
HOME="$DOTB_HOME2"
out="$(_do_compact transcriptnever 2 "$DOTB_CWD2")"; rc=$?
HOME="$_REAL_HOME"
ok "docompact-transcript-failclosed-exit"   "$rc" "1"
ok "docompact-transcript-failclosed-output" "$out" "timeout"
rm -rf "$DOTB_HOME2"

# No-cwd callers (existing tests above, and any caller that omits the new
# 3rd arg entirely) must keep working exactly as before — pane-state only,
# no transcript lookup attempted. Not a new assertion on its own; the
# pre-existing docompact-success-*/docompact-timeout-* tests above already
# call _do_compact with only 2 args and still pass, which IS the proof.

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

# ============================================================================
# sweep v2: context-aware two-trigger model. This SUPERSEDES the OLD idle-
# window-only sweep contract (idle>=60 was the ONLY trigger; --dry-run/
# --apply were both required; bare sweep errored) — see scripts/
# session-compact.sh's `sweep)` dispatch comment for the full rationale.
# report/before-relay above are UNCHANGED and still run the old model; only
# sweep's eligibility logic and CLI surface changed.
#
# These exercise the CLI contract (flags, exit codes, verdict text) through
# the same stubbed-session-handoff harness as the rest of this file. cwd is
# deliberately /nonexistent-cwd throughout — no transcript dir exists there,
# so context is always "unavailable" and every row degrades to idle-only,
# which is itself one of the required behaviors (rule 6: never guess a
# percentage). Fixture-JSONL + real-tmux-stub coverage for an ACTUAL context
# trigger (>=80% usage) lives in tests/test-session-compact-sweep.sh, which
# needs real files on disk to produce a real token count — this stub-only
# harness has no transcript to read at all.
# ============================================================================

# --- bare sweep (no flags): DEFAULT is dry-run, exits 0, mutates nothing,
# and DOES check the pane (busy-detection must run for every candidate) ------
: > "$STUB_LOG"
{ _row idlesweepsess remote 1 /nonexistent-cwd 90 2026-01-01T00:00:00 no no unknown clean; } > "$FIXTURE_DIR/rows.tsv"
out="$(_run sweep)"; rc=$?
ok  "cli-sweep-bare-exit0"        "$rc" "0"
has "cli-sweep-bare-header"       "$out" "REPORT ONLY, mutates nothing"
has "cli-sweep-bare-idle-trigger" "$(printf '%s' "$out" | grep idlesweepsess)" "would-compact: idle"
has "cli-sweep-bare-checked-pane" "$(cat "$STUB_LOG")" "check idlesweepsess"
lacks "cli-sweep-bare-no-send"    "$(cat "$STUB_LOG")" "send"

# --- any flag at all is rejected (report-only build; --apply lands in a
# follow-up commit) — exit 2, zero calls made ---------------------------------
: > "$STUB_LOG"
_run sweep --apply >/dev/null 2>&1; rcflag=$?
ok "cli-sweep-apply-not-implemented-exit2"    "$rcflag" "2"
ok "cli-sweep-apply-not-implemented-no-calls" "$(cat "$STUB_LOG")" ""

# --- busy pane -> skip: busy, even though idle alone would trigger (rule 4:
# never compact a session that is actively processing) ----------------------
: > "$STUB_LOG"
{ _row busysweepsess remote 1 /nonexistent-cwd 90 2026-01-01T00:00:00 no no unknown clean; } > "$FIXTURE_DIR/rows.tsv"
STUB_CHECK_BUSY_SESSIONS="busysweepsess"
outbusy="$(_run sweep)"; rcbusy=$?
ok  "cli-sweep-busy-exit0"   "$rcbusy" "0"
has "cli-sweep-busy-verdict" "$(printf '%s' "$outbusy" | grep busysweepsess)" "skip: busy"
STUB_CHECK_BUSY_SESSIONS=""

# --- protected -> skip: protected, and the pane is never even checked (same
# short-circuit-before-live-call shape _evaluate_row already uses) ----------
: > "$STUB_LOG"
{ _row protsweepsess remote 1 /nonexistent-cwd 90 2026-01-01T00:00:00 yes no unknown clean; } > "$FIXTURE_DIR/rows.tsv"
outprot="$(_run sweep)"; rcprot=$?
ok    "cli-sweep-protected-exit0"       "$rcprot" "0"
has   "cli-sweep-protected-verdict"     "$(printf '%s' "$outprot" | grep protsweepsess)" "skip: protected"
lacks "cli-sweep-protected-no-pane-call" "$(cat "$STUB_LOG")" "protsweepsess"

# --- under thresholds: low idle, no context data available -> "skip: under
# thresholds" plus a printed degradation note, never a guessed percentage --
: > "$STUB_LOG"
{ _row freshsweepsess remote 1 /nonexistent-cwd 2 2026-01-01T00:00:00 no no unknown clean; } > "$FIXTURE_DIR/rows.tsv"
outfresh="$(_run sweep)"; rcfresh=$?
row_fresh="$(printf '%s' "$outfresh" | grep freshsweepsess)"
ok  "cli-sweep-under-thresholds-exit0"         "$rcfresh" "0"
has "cli-sweep-under-thresholds-verdict"       "$row_fresh" "skip: under thresholds"
has "cli-sweep-under-thresholds-degraded-note" "$row_fresh" "idle-only fallback"

# --- ragged/short TSV row through the real read-loop: no crash -------------
printf 'onlyname\n' > "$FIXTURE_DIR/rows.tsv"
outr="$(_run report 2>&1)"; rcr=$?
ok  "cli-report-ragged-row-exit0" "$rcr" "0"
has "cli-report-ragged-row-listed" "$outr" "onlyname"
has "cli-report-ragged-row-reason" "$(printf '%s' "$outr" | grep onlyname)" "bad-idle-field"

# --- Bug 2: TSV rows truncated AFTER idle_minutes (unlike the ragged-row
# case above, which truncates at column 1 and is caught early by
# bad-idle-field) must fail CLOSED as skip:malformed-row, not read the
# missing protected/compacted/landed/dirty columns as their PERMISSIVE
# default and come out "eligible". Real `read` -c 10 vars pads missing
# trailing columns with "", exactly like a genuinely short TSV line does.
printf 'trunc5sess\tremote\t1\t/cwd\t90\n' > "$FIXTURE_DIR/rows.tsv"
out5="$(_run report 2>&1)"; rc5=$?
ok  "cli-report-trunc5-exit0"  "$rc5" "0"
has "cli-report-trunc5-reason" "$(printf '%s' "$out5" | grep trunc5sess)" "malformed-row"

printf 'trunc6sess\tremote\t1\t/cwd\t90\t2026-01-01T00:00:00\n' > "$FIXTURE_DIR/rows.tsv"
out6="$(_run report 2>&1)"; rc6=$?
ok  "cli-report-trunc6-exit0"  "$rc6" "0"
has "cli-report-trunc6-reason" "$(printf '%s' "$out6" | grep trunc6sess)" "malformed-row"

printf 'trunc7sess\tremote\t1\t/cwd\t90\t2026-01-01T00:00:00\tno\n' > "$FIXTURE_DIR/rows.tsv"
out7="$(_run report 2>&1)"; rc7=$?
ok  "cli-report-trunc7-exit0"  "$rc7" "0"
has "cli-report-trunc7-reason" "$(printf '%s' "$out7" | grep trunc7sess)" "malformed-row"

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
# Bug 1 fix sibling: outside-window is a BENIGN skip reason (not a pane-
# safety verdict) and must still fall through to a plain relay — proves the
# skip:pane-* fail-closed fix below doesn't overcorrect into refusing every
# non-eligible decision.
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
# Bug 1: before-relay must FAIL CLOSED on skip:pane-* — the pane-safety check
# it just ran (`session-handoff.sh ready`) said the pane itself is unsafe to
# type into (busy / on an interactive menu / no prompt / holding an unsent
# draft). Before the fix this fell through to the generic "not stale/
# eligible — relaying without compacting" branch and sent anyway. The row
# here is otherwise fully in-window/eligible (idle=90, nothing else skips
# it) so the ONLY reason _evaluate_row returns skip:pane-<reason> is the
# `ready` stub reporting NOT-SAFE.
# ============================================================================
{ _row busysess remote 1 /cwd 90 2026-01-01T00:00:00 no no unknown clean; } > "$FIXTURE_DIR/rows.tsv"
: > "$STUB_LOG"
STUB_READY_SESSIONS=""
STUB_READY_REASON="busy"
outb="$(_run before-relay busysess "should never be sent" 2>&1)"; rcb=$?
ok    "cli-relay-pane-busy-exit-nonzero"     "$([ "$rcb" -ne 0 ] && echo yes || echo no)" "yes"
has   "cli-relay-pane-busy-refuses-msg"      "$outb" "not safe to inject into"
has   "cli-relay-pane-busy-reason-shown"     "$outb" "(busy)"
lacks "cli-relay-pane-busy-message-not-sent" "$(cat "$STUB_LOG")" "should never be sent"
lacks "cli-relay-pane-busy-no-compact-sent"  "$(cat "$STUB_LOG")" "/compact"

{ _row draftsess remote 1 /cwd 90 2026-01-01T00:00:00 no no unknown clean; } > "$FIXTURE_DIR/rows.tsv"
: > "$STUB_LOG"
STUB_READY_SESSIONS=""
STUB_READY_REASON="draft-in-input-box"
outd="$(_run before-relay draftsess "should also never be sent" 2>&1)"; rcd=$?
ok    "cli-relay-pane-draft-exit-nonzero"     "$([ "$rcd" -ne 0 ] && echo yes || echo no)" "yes"
has   "cli-relay-pane-draft-reason-shown"     "$outd" "draft-in-input-box"
lacks "cli-relay-pane-draft-message-not-sent" "$(cat "$STUB_LOG")" "should also never be sent"
STUB_READY_REASON="busy"

# ============================================================================
# Bug 1, the not-found-in-sensor branch: a session the sensor never reported
# on used to relay with ZERO pane-safety information. Must now consult
# `ready` directly (via the same _session_handoff indirection, so the stub
# still intercepts it) and refuse when it comes back NOT-SAFE — and,
# symmetrically, must still relay when the pane IS safe, so the fix doesn't
# overcorrect into refusing every unseen session outright.
# ============================================================================
: > "$FIXTURE_DIR/rows.tsv"   # sensor has no rows at all -> row_line is empty
: > "$STUB_LOG"
STUB_READY_SESSIONS=""
STUB_READY_REASON="menu"
outn="$(_run before-relay ghostsess "unsafe unseen message" 2>&1)"; rcn2=$?
ok    "cli-relay-notfound-unsafe-exit-nonzero"     "$([ "$rcn2" -ne 0 ] && echo yes || echo no)" "yes"
has   "cli-relay-notfound-unsafe-refuses-msg"      "$outn" "not safe to inject into"
has   "cli-relay-notfound-unsafe-reason-shown"     "$outn" "(menu)"
lacks "cli-relay-notfound-unsafe-message-not-sent" "$(cat "$STUB_LOG")" "unsafe unseen message"

: > "$STUB_LOG"
STUB_READY_SESSIONS="ghostsess2"
outn2="$(_run before-relay ghostsess2 "safe unseen message" 2>&1)"; rcn3=$?
ok  "cli-relay-notfound-safe-exit0"   "$rcn3" "0"
has "cli-relay-notfound-safe-says-pane-safe" "$outn2" "pane is safe"
has "cli-relay-notfound-safe-relayed" "$(cat "$STUB_LOG")" "send ghostsess2 safe unseen message"
STUB_READY_SESSIONS=""
STUB_READY_REASON="busy"

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
