#!/usr/bin/env bash
# session-compact.sh: sourced in-process tests (_decide, _evaluate_row, markers, _do_compact), then CLI tests
# against a COPY of the script in an isolated dir with a stub session-handoff and a fixture sensor.
# No tmux, no live session, no real /compact.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
SCRIPT="$HERE/../scripts/session-compact.sh"
# shellcheck disable=SC1090
source "$SCRIPT"   # source-guarded: must NOT run dispatch

# Layer 1: _decide (pure). d() spells only the varying fields; positional order: min max idle protected compacted landed dirty marker_hit.
d() { _decide "$1" "$2" sess remote pid cwd "$3" 2026-01-01T00:00:00 "$4" "$5" "$6" "$7" "$8"; }

ok "decide-never-touched"     "$(d 60 0 never no  no      unknown clean   na)" "skip:never-touched"
ok "decide-outside-window-lo" "$(d 60 0 30    no  no      unknown clean   na)" "skip:outside-window"
ok "decide-protected"         "$(d 60 0 90    yes no      unknown clean   na)" "skip:protected"
ok "decide-landed-and-clean"  "$(d 60 0 90    no  no      yes     clean   na)" "skip:landed-and-clean"
ok "decide-already-compacted" "$(d 60 0 90    no  yes     no      unknown na)" "skip:already-compacted"
# --- a fully-eligible row ----------------------------------------------------
ok "decide-fully-eligible" "$(d 60 0 90 no no unknown clean na)" "eligible"

# --- landed=yes + DIRTY is still eligible (only landed AND clean skips) -----
ok "decide-landed-dirty-still-eligible" "$(d 60 0 90 no no yes DIRTY na)" "eligible"

# --- compacted=unknown + matching marker -> skip; no marker -> eligible ----
ok "decide-unknown-marker-match"  "$(d 60 0 90 no unknown unknown unknown yes)" "skip:already-compacted"
ok "decide-unknown-no-marker"     "$(d 60 0 90 no unknown unknown unknown no)"  "eligible"

# --- --max-idle 0 means unbounded -------------------------------------------
# and max-idle IS enforced when non-zero
ok "decide-outside-window-hi" "$(d 60 120 200 no no unknown clean na)" "skip:outside-window"

# --- the documented escape hatch back to the original window ---------------
ok "decide-escape-hatch-30-60-too-old" "$(d 30 60 90 no no unknown clean na)" "skip:outside-window"

# protected/compacted/landed/dirty must fail CLOSED on any value outside the sensor vocabulary
# (including "" from a truncated TSV row), not read as the permissive default.
for v in "" maybe; do
  ok "decide-malformed-protected-${v:-empty}" "$(d 60 0 90 "$v" no unknown clean na)" "skip:malformed-row"
  ok "decide-malformed-compacted-${v:-empty}" "$(d 60 0 90 no "$v" unknown clean na)" "skip:malformed-row"
  ok "decide-malformed-landed-${v:-empty}"    "$(d 60 0 90 no no "$v" clean na)" "skip:malformed-row"
  ok "decide-malformed-dirty-${v:-empty}"     "$(d 60 0 90 no no unknown "$v" na)" "skip:malformed-row"
done
# and the legitimate no-worktree value for landed is NOT malformed


# _evaluate_row + marker + _do_compact. _SESSION_HANDOFF_BIN points at a stub, bypassing the co-located real script.
STUBDIR="$(mktemp -d)"
trap 'rm -rf "$STUBDIR"' EXIT

# Stub session-handoff driven by env: STUB_LOG (calls), STUB_READY_SESSIONS (ready=SAFE), STUB_READY_REASON,
# STUB_BUSY_POLLS (check busy N times then ready), STUB_STATE (counter dir), STUB_SEND_FAIL.
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
# a pure-check failure short-circuits before the live ready call
_reset_stub_env
row_protected=(protsess remote 1 /cwd 90 2026-01-01T00:00:00 yes no unknown clean)
decision="$(_evaluate_row 60 0 "${row_protected[@]}")"
ok "evalrow-protected-short-circuit-decision" "$decision" "skip:protected"
hasnt "evalrow-protected-short-circuit-no-pane-call" "$(cat "$STUB_LOG")" "protsess"

_REAL_HOME="$HOME"
HOME="$(mktemp -d)"

_write_marker markedsess 2026-01-01T00:00:00 2026-01-01T00:05:00 compacted
ok "marker-hit-match"    "$(_marker_hit markedsess 2026-01-01T00:00:00)" "yes"
ok "marker-hit-mismatch" "$(_marker_hit markedsess 2026-02-02T00:00:00)" "no"

HOME="$_REAL_HOME"

_reset_stub_env
STUB_BUSY_POLLS=2   # busy for 2 polls, ready on the 3rd -> success before timeout
out="$(_do_compact compactok 30)"; rc=$?
ok "docompact-success-exit"   "$rc" "0"
ok "docompact-success-output" "$out" "compacted"


_reset_stub_env
STUB_SEND_FAIL=yes
out="$(_do_compact compactsendfail 5)"; rc=$?
ok "docompact-send-failed-exit"   "$rc" "1"
ok "docompact-send-failed-output" "$out" "send-failed"

# never issue /compact twice to the same session
_reset_stub_env
STUB_BUSY_POLLS=0
_do_compact compacttwice 5 >/dev/null
out2="$(_do_compact compacttwice 5 2>&1)"; rc2=$?
ok "docompact-no-double-issue-exit" "$rc2" "1"
has "docompact-no-double-issue-msg" "$out2" "refusing to send /compact"
sendcount="$(grep -c 'CALL send compacttwice /compact' "$STUB_LOG")"
ok "docompact-no-double-issue-single-send" "$sendcount" "1"

# Completion must be detected from the TRANSCRIPT (ground truth) too: with the pane never reporting busy
# (STUB_BUSY_POLLS=999) only a fresh compact_boundary newer than the pre-send baseline can yield "compacted".
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
# stale marker: must be a baseline, not a match
cat > "$DOTB_PROJDIR/old.jsonl" <<'EOF'
{"type":"system","subtype":"compact_boundary","timestamp":"2020-01-01T00:00:00.000Z"}
EOF
HOME="$DOTB_HOME"
# fresh compact_boundary appended 1s after send, while _do_compact polls
( sleep 1; printf '{"type":"system","subtype":"compact_boundary","timestamp":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" >> "$DOTB_PROJDIR/live.jsonl" ) &
BGPID=$!
out="$(_do_compact transcriptok 30 "$DOTB_CWD")"; rc=$?
wait "$BGPID" 2>/dev/null
HOME="$_REAL_HOME"
ok "docompact-transcript-success-exit"   "$rc" "0"
ok "docompact-transcript-success-output" "$out" "compacted"
rm -rf "$DOTB_HOME"

# fail closed: nothing postdates the baseline and the pane never resolves -> timeout
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

# Layer 3: CLI. Copy session-compact.sh ALONE into an isolated dir (PATH-only helper resolution), stub session-handoff and systemctl.
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

# _fixture_transcript CWD TOKENS MODEL: one assistant turn so a row clears the idle trigger context floor
# (real context-trigger coverage is in test-session-compact-sweep.sh).
_fixture_transcript() {
  local cwd="$1" tokens="$2" model="$3" dir
  dir="$CLI_HOME/.claude/projects/$(_encode_cwd "$cwd")"
  mkdir -p "$dir" "$cwd"
  printf '{"type":"assistant","timestamp":"2026-01-01T00:00:00.000Z","message":{"model":"%s","usage":{"input_tokens":%d,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":50}}}\n' \
    "$model" "$tokens" > "$dir/fixture.jsonl"
}

# --- report: basic eligible/skip rows, defaults are 60 / unbounded ---------
{
  _row readysess   remote 1 /cwd 90 2026-01-01T00:00:00 no no unknown clean
  _row notreadysess remote 1 /cwd 90 2026-01-01T00:00:00 no no unknown clean
} > "$FIXTURE_DIR/rows.tsv"
STUB_READY_SESSIONS="readysess"
out="$(_run report)"; rc=$?
ok   "cli-report-exit0"          "$rc" "0"
has  "cli-report-header-default-window" "$out" "idle >= 60m"
has  "cli-report-eligible-row"   "$out" "readysess"
has  "cli-report-reason-pane-busy" "$(printf '%s' "$out" | grep notreadysess)" "pane-busy"


# sweep: CLI contract (flags, exit codes, verdict text). Rows use /nonexistent-cwd (context unavailable) except
# readysess, which gets a 50% transcript so the idle trigger is reachable.
READY_CWD="$CLI_HOME/proj-ready"
_fixture_transcript "$READY_CWD" 500000 claude-sonnet-4-6   # 50%

# neither flag: defaults to dry-run (exit 0, no send, but pane checked)
: > "$STUB_LOG"
{ _row readysess remote 1 "$READY_CWD" 90 2026-01-01T00:00:00 no no unknown clean; } > "$FIXTURE_DIR/rows.tsv"
STUB_READY_SESSIONS="readysess"
outn="$(_run sweep)"; rcn=$?
ok  "cli-sweep-bare-defaults-to-dryrun-exit0" "$rcn" "0"
has "cli-sweep-bare-would-compact"            "$outn" "would-compact: readysess"
has "cli-sweep-bare-pane-check-happened"      "$(cat "$STUB_LOG")" "ready readysess"
hasnt "cli-sweep-bare-no-send"                "$(cat "$STUB_LOG")" "send"


# --- autonomous sweep --apply refuses before paste without admission -----
: > "$STUB_LOG"
STUB_BUSY_POLLS=1
outa="$(_run sweep --apply --timeout 20 2>&1)"; rca=$?
ok  "cli-sweep-apply-exit0" "$rca" "0"
has "cli-sweep-apply-admission-denied" "$outa" "admission-denied"
hasnt "cli-sweep-apply-no-compact" "$(cat "$STUB_LOG")" "send readysess /compact"
nofile "cli-sweep-apply-no-marker" "$CLI_HOME/.sessions/compact-markers/readysess.json"
STUB_BUSY_POLLS=0

# --- both flags at once: still rejected --------------------------------------
: > "$STUB_LOG"
_run sweep --dry-run --apply >/dev/null 2>&1; rcboth=$?
ok "cli-sweep-both-flags-exit2" "$rcboth" "2"


# protected: skipped without any pane check
: > "$STUB_LOG"
{ _row protsweepsess remote 1 /nonexistent-cwd 90 2026-01-01T00:00:00 yes no unknown clean; } > "$FIXTURE_DIR/rows.tsv"
outprot="$(_run sweep)"; rcprot=$?
ok    "cli-sweep-protected-exit0"       "$rcprot" "0"
has   "cli-sweep-protected-verdict"     "$(printf '%s' "$outprot" | grep protsweepsess)" "skip: protected"
hasnt "cli-sweep-protected-no-pane-call" "$(cat "$STUB_LOG")" "protsweepsess"


# low idle + no context data -> skip: under thresholds with a degradation note, never a guessed percentage
: > "$STUB_LOG"
{ _row freshsweepsess remote 1 /nonexistent-cwd 2 2026-01-01T00:00:00 no no unknown clean; } > "$FIXTURE_DIR/rows.tsv"
outfresh="$(_run sweep)"; rcfresh=$?
row_fresh="$(printf '%s' "$outfresh" | grep freshsweepsess)"
ok  "cli-sweep-under-thresholds-exit0"         "$rcfresh" "0"
has "cli-sweep-under-thresholds-verdict"       "$row_fresh" "skip: under thresholds"
has "cli-sweep-under-thresholds-degraded-note" "$row_fresh" "context unavailable"
STUB_READY_SESSIONS=""
STUB_READY_REASON="busy"

# --- ragged/short TSV row through the real read-loop: no crash -------------
printf 'onlyname\n' > "$FIXTURE_DIR/rows.tsv"
outr="$(_run report 2>&1)"; rcr=$?
ok  "cli-report-ragged-row-exit0" "$rcr" "0"
has "cli-report-ragged-row-listed" "$outr" "onlyname"
has "cli-report-ragged-row-reason" "$(printf '%s' "$outr" | grep onlyname)" "bad-idle-field"

# TSV rows truncated after idle_minutes must fail closed (malformed-row), not read as eligible.
{
  printf 'trunc5sess\tremote\t1\t/cwd\t90\n'
  printf 'trunc6sess\tremote\t1\t/cwd\t90\t2026-01-01T00:00:00\n'
  printf 'trunc7sess\tremote\t1\t/cwd\t90\t2026-01-01T00:00:00\tno\n'
} > "$FIXTURE_DIR/rows.tsv"
outt="$(_run report 2>&1)"; rct=$?
ok "cli-report-trunc-exit0" "$rct" "0"
for n in 5 6 7; do has "cli-report-trunc$n-reason" "$(grep "trunc${n}sess" <<<"$outt")" "malformed-row"; done


# before-relay fail-closed: compact never verifies -> real message must not be sent
{ _row failsess remote 1 /cwd 90 2026-01-01T00:00:00 no no unknown clean; } > "$FIXTURE_DIR/rows.tsv"
: > "$STUB_LOG"
STUB_READY_SESSIONS="failsess"
STUB_BUSY_POLLS=999   # never verifies -> before-relay must not send the real message
# --timeout must precede the session name
outf="$(_run before-relay --timeout 2 failsess "THE REAL MESSAGE" 2>&1)"; rcf=$?
ok    "cli-relay-unverified-exit-nonzero" "$(yn test "$rcf" -ne 0)" "yes"
has   "cli-relay-unverified-says-fail-closed" "$outf" "FAILING CLOSED"
hasnt "cli-relay-unverified-message-not-sent" "$(cat "$STUB_LOG")" "THE REAL MESSAGE"
has   "cli-relay-unverified-compact-was-sent" "$(cat "$STUB_LOG")" "send failsess /compact"
[ -f "$CLI_HOME/.sessions/compact-markers/failsess.json" ] && { fail=$((fail+1)); echo "FAIL: cli-relay-unverified-no-marker — marker file exists but must not"; } || { pass=$((pass+1)); }
STUB_BUSY_POLLS=0

# before-relay happy path: compact, verify, THEN relay. STUB_BUSY_POLLS=1 because _do_compact needs one busy poll first.
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

# before-relay: benign skip (outside window) still relays plainly
{ _row freshsess remote 1 /cwd 5 2026-01-01T00:00:00 no no unknown clean; } > "$FIXTURE_DIR/rows.tsv"
: > "$STUB_LOG"
outk="$(_run before-relay freshsess "hello there")"; rck=$?
ok  "cli-relay-not-stale-exit0"    "$rck" "0"
has "cli-relay-not-stale-says-so"  "$outk" "not stale/eligible"
has "cli-relay-not-stale-relayed"  "$(cat "$STUB_LOG")" "send freshsess hello there"
hasnt "cli-relay-not-stale-no-compact-sent" "$(cat "$STUB_LOG")" "/compact"


# before-relay must FAIL CLOSED on skip:pane-* (otherwise-eligible row; only the ready stub says NOT-SAFE)
{ _row busysess remote 1 /cwd 90 2026-01-01T00:00:00 no no unknown clean; } > "$FIXTURE_DIR/rows.tsv"
: > "$STUB_LOG"
STUB_READY_SESSIONS=""
STUB_READY_REASON="busy"
outb="$(_run before-relay busysess "should never be sent" 2>&1)"; rcb=$?
ok    "cli-relay-pane-busy-exit-nonzero"     "$(yn test "$rcb" -ne 0)" "yes"
has   "cli-relay-pane-busy-refuses-msg"      "$outb" "not safe to inject into"
has   "cli-relay-pane-busy-reason-shown"     "$outb" "(busy)"
hasnt "cli-relay-pane-busy-message-not-sent" "$(cat "$STUB_LOG")" "should never be sent"
hasnt "cli-relay-pane-busy-no-compact-sent"  "$(cat "$STUB_LOG")" "/compact"


# session absent from the sensor: consult ready directly; refuse when NOT-SAFE, relay when safe
: > "$FIXTURE_DIR/rows.tsv"   # sensor has no rows at all -> row_line is empty
: > "$STUB_LOG"
STUB_READY_SESSIONS=""
STUB_READY_REASON="menu"
outn="$(_run before-relay ghostsess "unsafe unseen message" 2>&1)"; rcn2=$?
ok    "cli-relay-notfound-unsafe-exit-nonzero"     "$(yn test "$rcn2" -ne 0)" "yes"
has   "cli-relay-notfound-unsafe-refuses-msg"      "$outn" "not safe to inject into"
has   "cli-relay-notfound-unsafe-reason-shown"     "$outn" "(menu)"
hasnt "cli-relay-notfound-unsafe-message-not-sent" "$(cat "$STUB_LOG")" "unsafe unseen message"

: > "$STUB_LOG"
STUB_READY_SESSIONS="ghostsess2"
outn2="$(_run before-relay ghostsess2 "safe unseen message" 2>&1)"; rcn3=$?
ok  "cli-relay-notfound-safe-exit0"   "$rcn3" "0"
has "cli-relay-notfound-safe-says-pane-safe" "$outn2" "pane is safe"
has "cli-relay-notfound-safe-relayed" "$(cat "$STUB_LOG")" "send ghostsess2 safe unseen message"
STUB_READY_SESSIONS=""
STUB_READY_REASON="busy"

# install-timer: writes units, enables nothing, refuses to clobber
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
ok  "cli-installtimer-no-systemctl-calls" "$(cat "$SYSTEMCTL_LOG")" ""

out2="$(run_it install-timer 2>&1)"; rc2=$?
ok  "cli-installtimer-refuse-without-force-exit2" "$rc2" "2"
has "cli-installtimer-refuse-without-force-msg" "$out2" "refusing to overwrite"


finish "session-compact"
