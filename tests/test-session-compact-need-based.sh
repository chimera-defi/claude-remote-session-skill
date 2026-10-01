#!/usr/bin/env bash
# Need-based idle trigger: idle time alone is not need (a cold prompt cache makes compacting CHEAP, not WORTHWHILE).
# _sweep_decide's idle branch requires a MEASURED context_pct >= _SWEEP_IDLE_CONTEXT_FLOOR_PCT (40), and an UNMEASURABLE
# context_pct (unparseable transcript / model missing from _model_window_for) skips on EITHER trigger: "if we cannot
# measure need, we do not act".
# Harness: isolated copy of session-compact.sh, the REAL scripts/session-handoff.sh against a fake `tmux` on PATH,
# $SESSION_COMPACT_SENSOR pointed at a fixture TSV. No real tmux, session or /compact. Real fixture *.jsonl transcripts.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
SCRIPT="$HERE/../scripts/session-compact.sh"
HANDOFF="$HERE/../scripts/session-handoff.sh"
# shellcheck disable=SC1090
source "$SCRIPT"   # for _encode_cwd only (source-guarded: must NOT run dispatch)

# Fixture plumbing (mirrors test-session-compact-sweep.sh)
ISO="$(mktemp -d)"
cp "$SCRIPT" "$ISO/session-compact.sh"
cp "$HANDOFF" "$ISO/session-handoff.sh"   # co-located: _find_helper picks this
                                            # REAL script over any PATH stub, so
                                            # busy-detection runs for real.

BIN="$(mktemp -d)"
# Fake tmux: no row here is ever busy (covered in test-session-compact-sweep.sh); every session captures as a SAFE pane.
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

# _fixture_transcript <cwd> <tokens> <model>: as in test-session-compact-sweep.sh
_fixture_transcript() {
  local cwd="$1" tokens="$2" model="$3" dir
  dir="$FAKE_HOME/.claude/projects/$(_encode_cwd "$cwd")"
  mkdir -p "$dir" "$cwd"
  printf '{"type":"assistant","timestamp":"2026-01-01T00:00:00.000Z","message":{"model":"%s","usage":{"input_tokens":%d,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":50}}}\n' \
    "$model" "$tokens" > "$dir/fixture.jsonl"
}

# _fixture_unparseable_transcript <cwd>: as in test-session-compact-sweep.sh (dir exists, no parseable entry)
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

# Fixture rows: landed=no dirty=clean except compactedsess; model always claude-sonnet-4-6 (1M window) except
# ctxunknownsess/ctxunknownbsess (unparseable transcript). Six rows are the required scenarios (1-6); ctxb50/ctxb49/
# ctxbunknown fill trigger-B paths those don't reach (known sub-80% values and UNKNOWN context).
CTXSMALL_CWD="$FAKE_HOME/proj-ctxsmall"
IDLEOK_CWD="$FAKE_HOME/proj-idleok"
CTXTRIGGER_CWD="$FAKE_HOME/proj-ctxtrigger"
CTXUNKNOWN_CWD="$FAKE_HOME/proj-ctxunknown"
COMPACTED_CWD="$FAKE_HOME/proj-compacted"
ATFLOOR_CWD="$FAKE_HOME/proj-atfloor"
UNDERFLOOR_CWD="$FAKE_HOME/proj-underfloor"
CTXB50_CWD="$FAKE_HOME/proj-ctxb50"
CTXB49_CWD="$FAKE_HOME/proj-ctxb49"
CTXBUNKNOWN_CWD="$FAKE_HOME/proj-ctxbunknown"

_fixture_transcript "$CTXSMALL_CWD"   100000 claude-sonnet-4-6   # 10%
_fixture_transcript "$IDLEOK_CWD"     500000 claude-sonnet-4-6   # 50%
_fixture_transcript "$CTXTRIGGER_CWD" 900000 claude-sonnet-4-6   # 90%
_fixture_unparseable_transcript "$CTXUNKNOWN_CWD"
_fixture_transcript "$COMPACTED_CWD"  500000 claude-sonnet-4-6   # 50%
_fixture_transcript "$ATFLOOR_CWD"    400000 claude-sonnet-4-6   # exactly 40%
_fixture_transcript "$UNDERFLOOR_CWD" 390000 claude-sonnet-4-6   # exactly 39%
_fixture_transcript "$CTXB50_CWD"     500000 claude-sonnet-4-6   # exactly 50%
_fixture_transcript "$CTXB49_CWD"     490000 claude-sonnet-4-6   # exactly 49%
_fixture_unparseable_transcript "$CTXBUNKNOWN_CWD"

export STUB_TMUX_SESSIONS="ctxsmallsess idleoksess ctxtriggersess ctxunknownsess compactedsess atfloorsess underfloorsess ctxb50sess ctxb49sess ctxbunknownsess"
export STUB_TMUX_BUSY_SESSIONS=""

{
  # 1. idle=90m, context=10%: idle alone is not need; clears neither the 40% idle floor nor the 50% context trigger
  _row ctxsmallsess    remote 1 "$CTXSMALL_CWD"   90 2026-01-01T00:00:00 no no unknown clean
  # 2. idle=90m, context=50%: clears the 40% idle floor -> would-compact: idle
  _row idleoksess       remote 1 "$IDLEOK_CWD"     90 2026-01-01T00:00:00 no no unknown clean
  # 3. idle=10m, context=90%: clears the 50% context trigger and its 5m floor -> would-compact: context
  _row ctxtriggersess   remote 1 "$CTXTRIGGER_CWD" 10 2026-01-01T00:00:00 no no unknown clean
  # 4. idle=90m, context UNKNOWN -> skip: context unknown, note naming _model_window_for (no silent idle fall-through)
  _row ctxunknownsess   remote 1 "$CTXUNKNOWN_CWD" 90 2026-01-01T00:00:00 no no unknown clean
  # 5. idle=90m, context=50%, ALSO already-compacted: the loop guard (#60/#61) blocks FIRST, before the floor is consulted
  _row compactedsess    remote 1 "$COMPACTED_CWD"  90 2026-01-01T00:00:00 no yes unknown clean
  # 6a. boundary: context EXACTLY 40% (inclusive floor), idle=90m -> would-compact: idle
  _row atfloorsess      remote 1 "$ATFLOOR_CWD"    90 2026-01-01T00:00:00 no no unknown clean
  # 6b. boundary: 39%, idle=90m -> skip: context too small
  _row underfloorsess   remote 1 "$UNDERFLOOR_CWD" 90 2026-01-01T00:00:00 no no unknown clean
  # 7. gap: trigger B with a KNOWN context under its 50% threshold, idle=10m -> skip: under thresholds, unchanged;
  #    confirms the idle-floor change didn't touch trigger B's threshold check for measurable context
  _row ctxb50sess       remote 1 "$CTXB50_CWD"     10 2026-01-01T00:00:00 no no unknown clean
  # 7b. boundary: 49%, idle=10m -> skip
  _row ctxb49sess       remote 1 "$CTXB49_CWD"     10 2026-01-01T00:00:00 no no unknown clean
  # 8. gap: trigger B with UNKNOWN context, idle=10m -> skip: context unknown. Trigger B's unknown branch (decision_b)
  #    is a separate code path from scenario 4's (decision_a) and needs its own coverage.
  _row ctxbunknownsess  remote 1 "$CTXBUNKNOWN_CWD" 10 2026-01-01T00:00:00 no no unknown clean
} > "$FIXTURE_DIR/rows.tsv"

out="$(_run sweep)"; rc=$?
ok "sweep-exit0" "$rc" "0"

row() { printf '%s' "$out" | grep "^$1 "; }

# --- 1. idle 90min + context 10% -> skip: context too small -----------------
has "ctxsmall-verdict" "$(row ctxsmallsess)" "skip: context too small"
has "ctxsmall-shows-pct" "$(row ctxsmallsess)" " 10 "
hasnt "ctxsmall-not-would-compact" "$(row ctxsmallsess)" "would-compact"

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
hasnt "ctxunknown-not-would-compact" "$(row ctxunknownsess)" "would-compact"

# --- 5. idle 90min + context 50% + already-compacted -> still skips (loop
# guard intact, fires before the context floor is even consulted) ----------
has   "compacted-still-skips"       "$(row compactedsess)" "skip: compacted"
hasnt "compacted-not-would-compact" "$(row compactedsess)" "would-compact"

# --- 6. boundary: exactly 40% compacts, exactly 39% skips --------------------
has   "atfloor-compacts"        "$(row atfloorsess)"    "would-compact: idle"
has   "underfloor-skips"        "$(row underfloorsess)" "skip: context too small"
hasnt "underfloor-not-compact"  "$(row underfloorsess)" "would-compact"

# --- 7. fleet trigger remains 80%: 50% and 49% both stay below it ----------
has   "ctxb50-under-thresholds" "$(row ctxb50sess)" "skip: under thresholds"
has   "ctxb50-shows-pct" "$(row ctxb50sess)" " 50 "
has   "ctxb49-under-thresholds" "$(row ctxb49sess)" "skip: under thresholds"
has   "ctxb49-shows-pct" "$(row ctxb49sess)" " 49 "
hasnt "ctxb50-not-compact"      "$(row ctxb50sess)" "would-compact"
hasnt "ctxb49-not-compact"      "$(row ctxb49sess)" "would-compact"

# --- 8. discovered gap: trigger B, unknown context, idle under 60m ---------
has   "ctxbunknown-verdict"   "$(row ctxbunknownsess)" "skip: context unknown"
has   "ctxbunknown-loud-note" "$(row ctxbunknownsess)" "_model_window_for"
hasnt "ctxbunknown-not-compact" "$(row ctxbunknownsess)" "would-compact"
# --- 9. managed-only trigger is lower: 50% fires, 49% skips ----------------
ALLOW_FILE="$(mktemp)"
printf 'ctxb50sess
ctxb49sess
' > "$ALLOW_FILE"
out_mo="$(SESSION_COMPACT_MANAGED_FILE="$ALLOW_FILE" _run sweep --dry-run --managed-only)"; rc_mo=$?
ok "managed-boundary-exit0" "$rc_mo" "0"
row_mo(){ printf '%s' "$out_mo" | grep "^$1 "; }
has "managed-50-compacts" "$(row_mo ctxb50sess)" "would-compact: context"
has "managed-49-skips" "$(row_mo ctxb49sess)" "skip: under thresholds"
has "managed-banner-50" "$out_mo" "context >= 50%"

finish "session-compact-need-based"
