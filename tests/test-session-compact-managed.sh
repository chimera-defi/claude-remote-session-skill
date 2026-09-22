#!/usr/bin/env bash
# Tests for session-compact.sh's `sweep --managed-only` opt-in scope filter.
# Same harness shape as tests/test-session-compact-sweep.sh: an isolated copy
# of session-compact.sh, a REAL scripts/session-handoff.sh (not a stub of it)
# talking to a fake `tmux` on PATH for pane-safety, and $SESSION_COMPACT_SENSOR
# pointed at a fixture TSV. No real tmux, no real session, no real /compact
# anywhere in this file.
#
# The filter under test operates purely on the sensor's tmux_session column
# (c1), BEFORE _sweep_decide/_context_pct_for_row ever run, so context is not
# what these tests are about. It still has to be a KNOWN, sufficient value
# though: unknown context now makes the idle trigger skip (skip:context-
# unknown — see _sweep_decide's own comment), so a nonexistent-cwd row can no
# longer reach a deterministic "would-compact: idle" the way it used to. The
# four live sessions below all get a real fixture transcript at 45% — clears
# the idle trigger's context floor (_SWEEP_IDLE_CONTEXT_FLOOR_PCT) without
# approaching the separate 50% managed context-trigger threshold — purely so "did
# this session get evaluated at all" stays unambiguous from the verdict
# column; the context MATH itself is exercised in
# tests/test-session-compact-sweep.sh, not here.
#
# $SESSION_COMPACT_MANAGED_FILE is used for EVERY invocation below — this file
# never reads or writes the real $HOME/.claude/session-compact-managed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/session-compact.sh"
HANDOFF="$HERE/../scripts/session-handoff.sh"
# shellcheck disable=SC1090
source "$SCRIPT"   # for _encode_cwd only (source-guarded: must NOT run dispatch)
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }
has(){ if printf '%s' "$2" | grep -qF -- "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — pattern not found: $3 in: $2"; fi; }
lacks(){ if printf '%s' "$2" | grep -qF -- "$3"; then fail=$((fail+1)); echo "FAIL: $1 — pattern SHOULD NOT be present: $3 in: $2"; else pass=$((pass+1)); fi; }
row_in(){ printf '%s' "$1" | grep "^$2 "; }   # row_in <output> <session> -> that row's line

# ============================================================================
# Fixture plumbing (mirrors test-session-compact-sweep.sh)
# ============================================================================
ISO="$(mktemp -d)"
cp "$SCRIPT" "$ISO/session-compact.sh"
cp "$HANDOFF" "$ISO/session-handoff.sh"   # co-located: _find_helper picks this
                                            # REAL script over any PATH stub, so
                                            # busy-detection runs for real.

BIN="$(mktemp -d)"
cat > "$BIN/tmux" <<'EOF'
#!/usr/bin/env bash
_name_arg() {  # scan "$@" for the value following a literal -t
  local prev="" a
  for a in "$@"; do
    if [ "$prev" = "-t" ]; then printf '%s\n' "$a"; return; fi
    prev="$a"
  done
}
case "$1" in
  has-session)
    shift
    name="$(_name_arg "$@")"
    for s in ${STUB_TMUX_SESSIONS:-}; do
      [ "$s" = "$name" ] && exit 0
    done
    exit 1 ;;
  display-message)
    echo claude
    exit 0 ;;
  capture-pane)
    shift
    name="$(_name_arg "$@")"
    for s in ${STUB_TMUX_BUSY_SESSIONS:-}; do
      if [ "$s" = "$name" ]; then
        printf '%s\n' '✻ Combobulating… (12s · esc to interrupt)'
        exit 0
      fi
    done
    printf '%s\n' 'previous turn output here'
    printf '%s\n' '❯ '
    printf '%s\n' '──────────────────────────────'
    exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$BIN/tmux"

FIXTURE_DIR="$(mktemp -d)"
cat > "$FIXTURE_DIR/sensor.sh" <<EOF
#!/usr/bin/env bash
cat "$FIXTURE_DIR/rows.tsv"
EOF
chmod +x "$FIXTURE_DIR/sensor.sh"

_row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }

FAKE_HOME="$(mktemp -d)"

# _fixture_transcript <cwd> <tokens> <model> — same helper as
# test-session-compact-sweep.sh. Needed now (previously wasn't) because the
# idle trigger requires a KNOWN context >= _SWEEP_IDLE_CONTEXT_FLOOR_PCT —
# see the header comment above.
_fixture_transcript() {
  local cwd="$1" tokens="$2" model="$3" dir
  dir="$FAKE_HOME/.claude/projects/$(_encode_cwd "$cwd")"
  mkdir -p "$dir" "$cwd"
  printf '{"type":"assistant","timestamp":"2026-01-01T00:00:00.000Z","message":{"model":"%s","usage":{"input_tokens":%d,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":50}}}\n' \
    "$model" "$tokens" > "$dir/fixture.jsonl"
}

_run() {  # _run <mode/args...> — invokes the isolated copy with fixtures wired up
  PATH="$BIN:$PATH" SESSION_COMPACT_SENSOR="$FIXTURE_DIR/sensor.sh" \
    HOME="$FAKE_HOME" bash "$ISO/session-compact.sh" "$@"
}

# Four LIVE sessions (all present in tmux AND in the sensor's TSV), all idle
# 90m (over the default 60m idle trigger), landed=no dirty=clean (never
# landed-and-clean), compacted=no (never already-compacted), context=45%
# (clears the idle trigger's context floor without approaching the separate
# 50% managed context-trigger threshold) — so an IN-SCOPE row always reaches a clean
# "would-compact: idle" verdict with nothing else masking it.
export STUB_TMUX_SESSIONS="sessa sessb sessc sessd"
export STUB_TMUX_BUSY_SESSIONS=""
# $FAKE_HOME-relative (not literal /nonexistent-cwd-*): _fixture_transcript's
# `mkdir -p ... "$cwd"` needs somewhere writable to create the cwd dir itself
# in, not a root-level path.
SESSA_CWD="$FAKE_HOME/proj-sessa"
SESSB_CWD="$FAKE_HOME/proj-sessb"
SESSC_CWD="$FAKE_HOME/proj-sessc"
SESSD_CWD="$FAKE_HOME/proj-sessd"
_fixture_transcript "$SESSA_CWD" 450000 claude-sonnet-4-6
_fixture_transcript "$SESSB_CWD" 450000 claude-sonnet-4-6
_fixture_transcript "$SESSC_CWD" 450000 claude-sonnet-4-6
_fixture_transcript "$SESSD_CWD" 450000 claude-sonnet-4-6
{
  _row sessa remote 1 "$SESSA_CWD" 90 2026-01-01T00:00:00 no no unknown clean
  _row sessb remote 1 "$SESSB_CWD" 90 2026-01-01T00:00:00 no no unknown clean
  _row sessc remote 1 "$SESSC_CWD" 90 2026-01-01T00:00:00 no no unknown clean
  _row sessd remote 1 "$SESSD_CWD" 90 2026-01-01T00:00:00 no no unknown clean
} > "$FIXTURE_DIR/rows.tsv"

# `deadsess` is deliberately NOT in STUB_TMUX_SESSIONS and NOT in rows.tsv —
# it stands in for "a session that used to be managed and has since exited"
# (item 4 in the brief: normal, not an error, just reported in the counts).

# ============================================================================
# 1. Missing allowlist file + --managed-only -> ZERO sessions in scope, exit
#    0, and — the load-bearing property — NEVER falls back to the fleet-wide
#    4 sessions that ARE live and ARE in the sensor's TSV right now.
# ============================================================================
MISSING_FILE="$FAKE_HOME/.claude/session-compact-managed-does-not-exist"
out1="$(SESSION_COMPACT_MANAGED_FILE="$MISSING_FILE" _run sweep --dry-run --managed-only)"; rc1=$?
ok    "missing-file-exit0"                      "$rc1" "0"
has   "missing-file-zero-in-scope"              "$out1" "0 sessions in scope"
has   "missing-file-refuses-fleetwide-language" "$out1" "Refusing to fall back to fleet-wide"
lacks "missing-file-no-sessa"                   "$out1" "sessa"
lacks "missing-file-no-sessb"                   "$out1" "sessb"
lacks "missing-file-no-sessc"                   "$out1" "sessc"
lacks "missing-file-no-sessd"                   "$out1" "sessd"
lacks "missing-file-no-would-compact"           "$out1" "would-compact"

# ============================================================================
# 2. Empty / comments-only allowlist -> ZERO in scope, same as missing.
# ============================================================================
EMPTY_FILE="$(mktemp)"
printf '# just a comment\n\n   \n# another\n' > "$EMPTY_FILE"
out2="$(SESSION_COMPACT_MANAGED_FILE="$EMPTY_FILE" _run sweep --dry-run --managed-only)"; rc2=$?
ok    "empty-file-exit0"            "$rc2" "0"
has   "empty-file-zero-in-scope"    "$out2" "0 sessions in scope"
lacks "empty-file-no-sessa"         "$out2" "sessa"
lacks "empty-file-no-would-compact" "$out2" "would-compact"

# ============================================================================
# 3. 2 of 4 live sessions allowlisted -> only those 2 are evaluated; the
#    other 2 do NOT appear as skip: rows (they must not appear AT ALL — out
#    of scope, not skipped).
# ============================================================================
TWOOF4_FILE="$(mktemp)"
printf 'sessa\nsessb\n' > "$TWOOF4_FILE"
out3="$(SESSION_COMPACT_MANAGED_FILE="$TWOOF4_FILE" _run sweep --dry-run --managed-only)"; rc3=$?
ok    "twoof4-exit0"               "$rc3" "0"
has   "twoof4-sessa-would-compact" "$(row_in "$out3" sessa)" "would-compact: idle"
has   "twoof4-sessb-would-compact" "$(row_in "$out3" sessb)" "would-compact: idle"
lacks "twoof4-sessc-absent"        "$out3" "sessc"
lacks "twoof4-sessd-absent"        "$out3" "sessd"
has   "twoof4-counts-reported"     "$out3" "2 managed, 2 live"
has   "twoof4-scanned-count"       "$out3" "--- 2 session(s) scanned."

# ============================================================================
# 4. Stale entry naming a dead session (not live, not in tmux, not in the
#    sensor's TSV) -> ignored silently, but counted: 2 managed, 1 live.
# ============================================================================
STALE_FILE="$(mktemp)"
printf 'sessa\ndeadsess\n' > "$STALE_FILE"
out4="$(SESSION_COMPACT_MANAGED_FILE="$STALE_FILE" _run sweep --dry-run --managed-only)"; rc4=$?
ok    "stale-exit0"           "$rc4" "0"
has   "stale-sessa-present"   "$(row_in "$out4" sessa)" "would-compact: idle"
lacks "stale-deadsess-absent" "$out4" "deadsess"
has   "stale-counts-reported" "$out4" "2 managed, 1 live"
has   "stale-scanned-count"   "$out4" "--- 1 session(s) scanned."

# ============================================================================
# 5. ALL managed entries stale (n_managed > 0, so the missing/empty early-exit
#    from case 1/2 does NOT fire — this reaches the TSV-filtering step below
#    with a non-empty allowlist whose every entry is dead) -> the filtered
#    TSV must still end up EMPTY, not silently revert to the unfiltered
#    fleet-wide fetch. This is the specific shape of bug a
#    `TSV="${TSV_FILTERED:-$TSV}"`-style coalescing fallback would reintroduce
#    (bash treats an empty-but-set string as "unset" for `:-` only when using
#    that exact operator) — see the tamper-verification in this commit's
#    message for proof this assertion is load-bearing.
# ============================================================================
ALLSTALE_FILE="$(mktemp)"
printf 'deadsess\nanotherdeadsess\n' > "$ALLSTALE_FILE"
out5s="$(SESSION_COMPACT_MANAGED_FILE="$ALLSTALE_FILE" _run sweep --dry-run --managed-only)"; rc5s=$?
ok    "allstale-exit0"            "$rc5s" "0"
has   "allstale-counts-reported"  "$out5s" "2 managed, 0 live"
lacks "allstale-no-sessa"         "$out5s" "sessa"
lacks "allstale-no-sessb"         "$out5s" "sessb"
lacks "allstale-no-sessc"         "$out5s" "sessc"
lacks "allstale-no-sessd"         "$out5s" "sessd"
lacks "allstale-no-would-compact" "$out5s" "would-compact"
has   "allstale-scanned-count"    "$out5s" "--- 0 session(s) scanned."

# ============================================================================
# 6. Backward-compat guard: no --managed-only at all -> ALL 4 live sessions
#    evaluated exactly as before, no "scope:" text anywhere in the header.
#    $SESSION_COMPACT_MANAGED_FILE is set to the 2-of-4 file from test 3 to
#    prove it is IGNORED entirely absent the flag — if the filter ever fired
#    without --managed-only, this is what would catch it.
# ============================================================================
out5="$(SESSION_COMPACT_MANAGED_FILE="$TWOOF4_FILE" _run sweep --dry-run)"; rc5=$?
ok    "nomanaged-exit0"         "$rc5" "0"
has   "nomanaged-sessa"         "$out5" "sessa"
has   "nomanaged-sessb"         "$out5" "sessb"
has   "nomanaged-sessc"         "$out5" "sessc"
has   "nomanaged-sessd"         "$out5" "sessd"
lacks "nomanaged-no-scope-text" "$out5" "scope:"
has   "nomanaged-scanned-count" "$out5" "--- 4 session(s) scanned."


# managed task-state guard
TASK_CWD="$FAKE_HOME/proj-active-task"
TASK_ENC="$(_encode_cwd "$TASK_CWD")"
mkdir -p "$FAKE_HOME/.claude/projects/$TASK_ENC" "$FAKE_HOME/tasks-root/sid-active"
cat > "$FAKE_HOME/.claude/projects/$TASK_ENC/sid-active.jsonl" <<'JSONL'
{"type":"assistant","timestamp":"2026-09-22T10:00:00Z","message":{"model":"claude-fable-5","usage":{"input_tokens":10,"cache_read_input_tokens":500000,"cache_creation_input_tokens":0,"output_tokens":1}}}
JSONL
cat > "$FAKE_HOME/tasks-root/sid-active/1.json" <<'JSON'
{"id":"1","status":"in_progress"}
JSON
state="$(HOME="$FAKE_HOME" SESSION_COMPACT_TASKS_ROOT="$FAKE_HOME/tasks-root" _managed_task_state_for_cwd "$TASK_CWD")"
ok "managed-task-active-state" "$state" "active:1"
cat > "$FAKE_HOME/tasks-root/sid-active/1.json" <<'JSON'
{"id":"1","status":"completed"}
JSON
state="$(HOME="$FAKE_HOME" SESSION_COMPACT_TASKS_ROOT="$FAKE_HOME/tasks-root" _managed_task_state_for_cwd "$TASK_CWD")"
ok "managed-task-clear-state" "$state" "clear"
echo '{broken' > "$FAKE_HOME/tasks-root/sid-active/bad.json"
state="$(HOME="$FAKE_HOME" SESSION_COMPACT_TASKS_ROOT="$FAKE_HOME/tasks-root" _managed_task_state_for_cwd "$TASK_CWD")"
ok "managed-task-malformed-fails-closed" "$state" "unknown"

echo "session-compact-managed: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
