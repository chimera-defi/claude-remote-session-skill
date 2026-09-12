#!/usr/bin/env bash
# Tests for the need-based idle trigger: idle time alone is not need. A
# session idle 60+ minutes at single-digit context has nothing worth
# reclaiming from compaction — long idle only means the prompt cache has
# gone cold, which makes compacting CHEAP, not WORTHWHILE. _sweep_decide's
# decision_a (idle) branch now ALSO requires a MEASURED context_pct >=
# _SWEEP_IDLE_CONTEXT_FLOOR_PCT (40) before firing, and an UNMEASURABLE
# context_pct (unparseable transcript, or a model missing from
# _model_window_for's table) skips outright on EITHER trigger instead of
# silently compacting on idle alone — "if we cannot measure need, we do not
# act". See scripts/session-compact.sh's _sweep_decide comment for the full
# rationale.
#
# Same harness shape as tests/test-session-compact-sweep.sh: an isolated copy
# of session-compact.sh, a REAL scripts/session-handoff.sh (not a stub of it)
# talking to a fake `tmux` on PATH, real fixture *.jsonl transcripts, and
# $SESSION_COMPACT_SENSOR pointed at a fixture TSV. No real tmux, no real
# session, no real /compact anywhere in this file.
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

# ============================================================================
# Fixture plumbing (mirrors test-session-compact-sweep.sh)
# ============================================================================
ISO="$(mktemp -d)"
cp "$SCRIPT" "$ISO/session-compact.sh"
cp "$HANDOFF" "$ISO/session-handoff.sh"   # co-located: _find_helper picks this
                                            # REAL script over any PATH stub, so
                                            # busy-detection runs for real.

BIN="$(mktemp -d)"
# Fake tmux — the ONLY live-process boundary in this file. No row here is
# ever busy (that interaction is already covered in
# tests/test-session-compact-sweep.sh); every session captures as a plain
# SAFE pane.
cat > "$BIN/tmux" <<'EOF'
#!/usr/bin/env bash
_name_arg() {
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
# test-session-compact-sweep.sh.
_fixture_transcript() {
  local cwd="$1" tokens="$2" model="$3" dir
  dir="$FAKE_HOME/.claude/projects/$(_encode_cwd "$cwd")"
  mkdir -p "$dir" "$cwd"
  printf '{"type":"assistant","timestamp":"2026-01-01T00:00:00.000Z","message":{"model":"%s","usage":{"input_tokens":%d,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":50}}}\n' \
    "$model" "$tokens" > "$dir/fixture.jsonl"
}

# _fixture_unparseable_transcript <cwd> — same helper as
# test-session-compact-sweep.sh: a transcript dir that EXISTS but has no
# parseable assistant+usage entry.
_fixture_unparseable_transcript() {
  local cwd="$1" dir
  dir="$FAKE_HOME/.claude/projects/$(_encode_cwd "$cwd")"
  mkdir -p "$dir" "$cwd"
  printf 'this is not json at all\n{"broken\n\n' > "$dir/fixture.jsonl"
}

_run() {  # _run <mode/args...> — invokes the isolated copy with fixtures wired up
  PATH="$BIN:$PATH" SESSION_COMPACT_SENSOR="$FIXTURE_DIR/sensor.sh" \
    HOME="$FAKE_HOME" bash "$ISO/session-compact.sh" "$@"
}

# ============================================================================
# Fixture rows. All use landed=no dirty=clean (never landed-and-clean) unless
# a row's own point is a different guard (compactedsess). Model is always a
# recognized one (claude-sonnet-4-6, 1,000,000-token window) except
# ctxunknownsess/ctxunknownbsess, which use an unparseable transcript.
#
# Six rows below are the brief's own required scenarios (1-6). Two more
# (ctxb50sess, ctxbunknownsess) fill code paths those six do not reach:
# trigger B (the context path, idle < 60m) with a KNOWN-but-under-80% context
# and trigger B with an UNKNOWN context, respectively — the given six only
# exercise trigger A (idle >= 60m) for both the too-small and the unknown
# case. See scenario notes 7 and 8 below.
# ============================================================================
CTXSMALL_CWD="$FAKE_HOME/proj-ctxsmall"
IDLEOK_CWD="$FAKE_HOME/proj-idleok"
CTXTRIGGER_CWD="$FAKE_HOME/proj-ctxtrigger"
CTXUNKNOWN_CWD="$FAKE_HOME/proj-ctxunknown"
COMPACTED_CWD="$FAKE_HOME/proj-compacted"
ATFLOOR_CWD="$FAKE_HOME/proj-atfloor"
UNDERFLOOR_CWD="$FAKE_HOME/proj-underfloor"
CTXB50_CWD="$FAKE_HOME/proj-ctxb50"
CTXBUNKNOWN_CWD="$FAKE_HOME/proj-ctxbunknown"

_fixture_transcript "$CTXSMALL_CWD"   100000 claude-sonnet-4-6   # 10%
_fixture_transcript "$IDLEOK_CWD"     500000 claude-sonnet-4-6   # 50%
_fixture_transcript "$CTXTRIGGER_CWD" 900000 claude-sonnet-4-6   # 90%
_fixture_unparseable_transcript "$CTXUNKNOWN_CWD"
_fixture_transcript "$COMPACTED_CWD"  500000 claude-sonnet-4-6   # 50%
_fixture_transcript "$ATFLOOR_CWD"    400000 claude-sonnet-4-6   # exactly 40%
_fixture_transcript "$UNDERFLOOR_CWD" 390000 claude-sonnet-4-6   # exactly 39%
_fixture_transcript "$CTXB50_CWD"     500000 claude-sonnet-4-6   # 50%
_fixture_unparseable_transcript "$CTXBUNKNOWN_CWD"

export STUB_TMUX_SESSIONS="ctxsmallsess idleoksess ctxtriggersess ctxunknownsess compactedsess atfloorsess underfloorsess ctxb50sess ctxbunknownsess"
export STUB_TMUX_BUSY_SESSIONS=""

{
  # 1. idle=90m, context=10% -> the whole point of this task: idle alone is
  #    not need, and 10% clears neither the idle trigger's 40% floor nor the
  #    context trigger's 80% threshold.
  _row ctxsmallsess    remote 1 "$CTXSMALL_CWD"   90 2026-01-01T00:00:00 no no unknown clean
  # 2. idle=90m, context=50% -> clears the idle trigger's 40% floor (and is
  #    irrelevant to the separate 80% context-trigger threshold, since idle
  #    already qualifies trigger A first) -> would-compact: idle.
  _row idleoksess       remote 1 "$IDLEOK_CWD"     90 2026-01-01T00:00:00 no no unknown clean
  # 3. idle=10m (under the 60m idle trigger), context=90% (clears the 80%
  #    context trigger, and 10m clears its own 5m floor) -> would-compact:
  #    context.
  _row ctxtriggersess   remote 1 "$CTXTRIGGER_CWD" 10 2026-01-01T00:00:00 no no unknown clean
  # 4. idle=90m, context UNKNOWN (unparseable transcript) -> skip: context
  #    unknown, with a loud note naming _model_window_for — NOT a silent
  #    fall-through to would-compact: idle just because idle alone qualifies.
  _row ctxunknownsess   remote 1 "$CTXUNKNOWN_CWD" 90 2026-01-01T00:00:00 no no unknown clean
  # 5. idle=90m, context=50% (would clear the idle trigger's floor), but
  #    ALSO already-compacted -> the infinite-loop guard (#60/#61) still
  #    blocks FIRST, before the context floor is ever consulted. Without
  #    this, --apply would re-issue /compact to an idle, already-compacted
  #    session on every sweep run forever.
  _row compactedsess    remote 1 "$COMPACTED_CWD"  90 2026-01-01T00:00:00 no yes unknown clean
  # 6a. boundary: context EXACTLY 40% (the floor itself, inclusive) with
  #     idle=90m -> compacts (would-compact: idle).
  _row atfloorsess      remote 1 "$ATFLOOR_CWD"    90 2026-01-01T00:00:00 no no unknown clean
  # 6b. boundary: context EXACTLY 39% (one point under the floor) with
  #     idle=90m -> skips (skip: context too small).
  _row underfloorsess   remote 1 "$UNDERFLOOR_CWD" 90 2026-01-01T00:00:00 no no unknown clean
  # 7. discovered gap: trigger B (context path) with a KNOWN context under
  #    its own 80% threshold, idle=10m (clears trigger B's 5m floor, not
  #    trigger A's 60m min) -> skip: under thresholds, UNCHANGED from before
  #    this task. None of scenarios 1-6 exercise trigger B with a KNOWN,
  #    merely-insufficient context — only trigger A's floor (1, 2, 6) or
  #    trigger B's already-covered >=80% case (3). Confirms the idle-trigger
  #    floor didn't accidentally loosen or otherwise touch trigger B's own
  #    threshold check for a context value that IS measurable.
  _row ctxb50sess       remote 1 "$CTXB50_CWD"     10 2026-01-01T00:00:00 no no unknown clean
  # 8. discovered gap: trigger B (context path) with an UNKNOWN context,
  #    idle=10m -> skip: context unknown. Scenario 4 only exercises the
  #    unknown-context path through trigger A (idle=90m, i.e. decision_a).
  #    Trigger B's OWN unknown-context branch is a separate code path in
  #    _sweep_decide (decision_b) that needed its own fix (see the commit
  #    that added this) and needs its own coverage here, independent of
  #    tests/test-session-compact-sweep.sh's unparsesess (which exists for a
  #    different reason: proving degrade-gracefully generally, not this
  #    specific floor/label pairing).
  _row ctxbunknownsess  remote 1 "$CTXBUNKNOWN_CWD" 10 2026-01-01T00:00:00 no no unknown clean
} > "$FIXTURE_DIR/rows.tsv"

out="$(_run sweep)"; rc=$?
ok "sweep-exit0" "$rc" "0"

row() { printf '%s' "$out" | grep "^$1 "; }

# --- 1. idle 90min + context 10% -> skip: context too small -----------------
has "ctxsmall-verdict" "$(row ctxsmallsess)" "skip: context too small"
has "ctxsmall-shows-pct" "$(row ctxsmallsess)" " 10 "
lacks "ctxsmall-not-would-compact" "$(row ctxsmallsess)" "would-compact"

# --- 2. idle 90min + context 50% -> would-compact: idle ---------------------
has "idleok-verdict" "$(row idleoksess)" "would-compact: idle"
has "idleok-shows-pct" "$(row idleoksess)" " 50 "

# --- 3. idle 10min + context 90% -> would-compact: context ------------------
has "ctxtrigger-verdict" "$(row ctxtriggersess)" "would-compact: context"
has "ctxtrigger-shows-pct" "$(row ctxtriggersess)" " 90 "

# --- 4. idle 90min + context UNKNOWN -> skip: context unknown, note names
# the model/table --------------------------------------------------------
has "ctxunknown-verdict"   "$(row ctxunknownsess)" "skip: context unknown"
has "ctxunknown-loud-note" "$(row ctxunknownsess)" "_model_window_for"
lacks "ctxunknown-not-would-compact" "$(row ctxunknownsess)" "would-compact"

# --- 5. idle 90min + context 50% + already-compacted -> still skips (loop
# guard intact, fires before the context floor is even consulted) ----------
has   "compacted-still-skips"       "$(row compactedsess)" "skip: compacted"
lacks "compacted-not-would-compact" "$(row compactedsess)" "would-compact"

# --- 6. boundary: exactly 40% compacts, exactly 39% skips --------------------
has   "atfloor-compacts"        "$(row atfloorsess)"    "would-compact: idle"
has   "underfloor-skips"        "$(row underfloorsess)" "skip: context too small"
lacks "underfloor-not-compact"  "$(row underfloorsess)" "would-compact"

# --- 7. discovered gap: trigger B, known context under 80%, idle under 60m
# -> skip: under thresholds, unchanged -----------------------------------
has   "ctxb50-under-thresholds" "$(row ctxb50sess)" "skip: under thresholds"
lacks "ctxb50-not-compact"      "$(row ctxb50sess)" "would-compact"
lacks "ctxb50-not-context-unknown" "$(row ctxb50sess)" "context unknown"

# --- 8. discovered gap: trigger B, unknown context, idle under 60m ---------
has   "ctxbunknown-verdict"   "$(row ctxbunknownsess)" "skip: context unknown"
has   "ctxbunknown-loud-note" "$(row ctxbunknownsess)" "_model_window_for"
lacks "ctxbunknown-not-compact" "$(row ctxbunknownsess)" "would-compact"

echo "session-compact-need-based: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
