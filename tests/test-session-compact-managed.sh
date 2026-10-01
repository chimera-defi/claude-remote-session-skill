#!/usr/bin/env bash
# session-compact.sh `sweep --managed-only` opt-in scope filter.
# Harness: isolated copy of session-compact.sh, the REAL scripts/session-handoff.sh against a fake `tmux` on PATH,
# $SESSION_COMPACT_SENSOR pointed at a fixture TSV. No real tmux, session or /compact. The filter works purely on the sensor's tmux_session
# column BEFORE _sweep_decide runs, so context isn't the point, but it must be KNOWN and sufficient (unknown context
# makes the idle trigger skip): the four live sessions get a 45% fixture transcript (over the idle floor, under the
# 50% managed context trigger) so "was it evaluated" is unambiguous from the verdict column. Context math itself is in
# test-session-compact-sweep.sh. $SESSION_COMPACT_MANAGED_FILE is set on EVERY invocation (never the real file).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
SCRIPT="$HERE/../scripts/session-compact.sh"
HANDOFF="$HERE/../scripts/session-handoff.sh"
# shellcheck disable=SC1090
source "$SCRIPT"   # for _encode_cwd only (source-guarded: must NOT run dispatch)
row_in(){ printf '%s' "$1" | grep "^$2 "; }   # row_in <output> <session> -> that row's line

# Fixture plumbing (mirrors test-session-compact-sweep.sh)
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

# _fixture_transcript <cwd> <tokens> <model>: as in test-session-compact-sweep.sh (needed for the known-context requirement above)
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

# Four LIVE sessions (in tmux AND the sensor TSV), idle 90m, landed=no dirty=clean, compacted=no, context=45%, so an
# IN-SCOPE row always reaches a clean "would-compact: idle".
export STUB_TMUX_SESSIONS="sessa sessb sessc sessd"
export STUB_TMUX_BUSY_SESSIONS=""
# $FAKE_HOME-relative cwds (not /nonexistent-cwd-*): _fixture_transcript needs a writable place to mkdir the cwd
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

# `deadsess` is NOT in STUB_TMUX_SESSIONS or rows.tsv: a once-managed session that exited (normal, counted not errored)

# 1. Missing allowlist + --managed-only -> ZERO in scope, exit 0, and (load-bearing) NEVER a fallback to the fleet-wide 4 live sessions.
MISSING_FILE="$FAKE_HOME/.claude/session-compact-managed-does-not-exist"
out1="$(SESSION_COMPACT_MANAGED_FILE="$MISSING_FILE" _run sweep --dry-run --managed-only)"; rc1=$?
ok    "missing-file-exit0"                      "$rc1" "0"
has   "missing-file-zero-in-scope"              "$out1" "0 sessions in scope"
has   "missing-file-refuses-fleetwide-language" "$out1" "Refusing to fall back to fleet-wide"
hasnt "missing-file-no-sessa"                   "$out1" "sessa"
hasnt "missing-file-no-sessb"                   "$out1" "sessb"
hasnt "missing-file-no-sessc"                   "$out1" "sessc"
hasnt "missing-file-no-sessd"                   "$out1" "sessd"
hasnt "missing-file-no-would-compact"           "$out1" "would-compact"

# 2. Empty / comments-only allowlist -> ZERO in scope, same as missing.
EMPTY_FILE="$(mktemp)"
printf '# just a comment\n\n   \n# another\n' > "$EMPTY_FILE"
out2="$(SESSION_COMPACT_MANAGED_FILE="$EMPTY_FILE" _run sweep --dry-run --managed-only)"; rc2=$?
ok    "empty-file-exit0"            "$rc2" "0"
has   "empty-file-zero-in-scope"    "$out2" "0 sessions in scope"
hasnt "empty-file-no-sessa"         "$out2" "sessa"
hasnt "empty-file-no-would-compact" "$out2" "would-compact"

# 3. 2 of 4 live sessions allowlisted -> only those 2 evaluated; the other 2 must not appear AT ALL (out of scope, not skipped).
TWOOF4_FILE="$(mktemp)"
printf 'sessa\nsessb\n' > "$TWOOF4_FILE"
out3="$(SESSION_COMPACT_MANAGED_FILE="$TWOOF4_FILE" _run sweep --dry-run --managed-only)"; rc3=$?
ok    "twoof4-exit0"               "$rc3" "0"
has   "twoof4-sessa-would-compact" "$(row_in "$out3" sessa)" "would-compact: idle"
has   "twoof4-sessb-would-compact" "$(row_in "$out3" sessb)" "would-compact: idle"
hasnt "twoof4-sessc-absent"        "$out3" "sessc"
hasnt "twoof4-sessd-absent"        "$out3" "sessd"
has   "twoof4-counts-reported"     "$out3" "2 managed, 2 live"
has   "twoof4-scanned-count"       "$out3" "--- 2 session(s) scanned."

# 4. Stale entry naming a dead session -> ignored silently but counted: 2 managed, 1 live.
STALE_FILE="$(mktemp)"
printf 'sessa\ndeadsess\n' > "$STALE_FILE"
out4="$(SESSION_COMPACT_MANAGED_FILE="$STALE_FILE" _run sweep --dry-run --managed-only)"; rc4=$?
ok    "stale-exit0"           "$rc4" "0"
has   "stale-sessa-present"   "$(row_in "$out4" sessa)" "would-compact: idle"
hasnt "stale-deadsess-absent" "$out4" "deadsess"
has   "stale-counts-reported" "$out4" "2 managed, 1 live"
has   "stale-scanned-count"   "$out4" "--- 1 session(s) scanned."

# 5. ALL managed entries stale (n_managed > 0, so the case 1/2 early exit doesn't fire): the filtered TSV must still end
# up EMPTY, not revert to the unfiltered fleet-wide fetch (the bug a `TSV="${TSV_FILTERED:-$TSV}"` coalescing fallback
# would reintroduce, since `:-` treats an empty-but-set string as unset).
ALLSTALE_FILE="$(mktemp)"
printf 'deadsess\nanotherdeadsess\n' > "$ALLSTALE_FILE"
out5s="$(SESSION_COMPACT_MANAGED_FILE="$ALLSTALE_FILE" _run sweep --dry-run --managed-only)"; rc5s=$?
ok    "allstale-exit0"            "$rc5s" "0"
has   "allstale-counts-reported"  "$out5s" "2 managed, 0 live"
hasnt "allstale-no-sessa"         "$out5s" "sessa"
hasnt "allstale-no-sessb"         "$out5s" "sessb"
hasnt "allstale-no-sessc"         "$out5s" "sessc"
hasnt "allstale-no-sessd"         "$out5s" "sessd"
hasnt "allstale-no-would-compact" "$out5s" "would-compact"
has   "allstale-scanned-count"    "$out5s" "--- 0 session(s) scanned."

# 6. Backward-compat: no --managed-only -> ALL 4 evaluated, no "scope:" text; the managed file (2-of-4 from test 3) is
# set to prove it is IGNORED without the flag.
out5="$(SESSION_COMPACT_MANAGED_FILE="$TWOOF4_FILE" _run sweep --dry-run)"; rc5=$?
ok    "nomanaged-exit0"         "$rc5" "0"
has   "nomanaged-sessa"         "$out5" "sessa"
has   "nomanaged-sessb"         "$out5" "sessb"
has   "nomanaged-sessc"         "$out5" "sessc"
has   "nomanaged-sessd"         "$out5" "sessd"
hasnt "nomanaged-no-scope-text" "$out5" "scope:"
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

finish "session-compact-managed"
