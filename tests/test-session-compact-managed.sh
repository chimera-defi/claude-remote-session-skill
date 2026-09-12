#!/usr/bin/env bash
# Tests for session-compact.sh's `sweep --managed-only` opt-in scope filter.
# Same harness shape as tests/test-session-compact-sweep.sh: an isolated copy
# of session-compact.sh, a REAL scripts/session-handoff.sh (not a stub of it)
# talking to a fake `tmux` on PATH for pane-safety, and $SESSION_COMPACT_SENSOR
# pointed at a fixture TSV. No real tmux, no real session, no real /compact
# anywhere in this file.
#
# Unlike that file, these tests don't need fixture transcripts: the filter
# under test operates purely on the sensor's tmux_session column (c1), BEFORE
# _sweep_decide/_context_pct_for_row ever run — so every fixture row here uses
# a nonexistent cwd (same idiom test-session-compact.sh's CLI layer already
# uses for its sweep tests) and degrades to the idle-only trigger, which is
# all that's needed to get a deterministic, non-masking verdict
# ("would-compact: idle") for any IN-SCOPE, ready, non-protected row — so "did
# this session get evaluated at all" is unambiguous from the verdict column.
#
# $SESSION_COMPACT_MANAGED_FILE is used for EVERY invocation below — this file
# never reads or writes the real $HOME/.claude/session-compact-managed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/session-compact.sh"
HANDOFF="$HERE/../scripts/session-handoff.sh"
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

_run() {  # _run <mode/args...> — invokes the isolated copy with fixtures wired up
  PATH="$BIN:$PATH" SESSION_COMPACT_SENSOR="$FIXTURE_DIR/sensor.sh" \
    HOME="$FAKE_HOME" bash "$ISO/session-compact.sh" "$@"
}

# Four LIVE sessions (all present in tmux AND in the sensor's TSV), all idle
# 90m (over the default 60m idle trigger), landed=no dirty=clean (never
# landed-and-clean), compacted=no (never already-compacted) — so an IN-SCOPE
# row always reaches a clean "would-compact: idle" verdict with nothing else
# masking it.
export STUB_TMUX_SESSIONS="sessa sessb sessc sessd"
export STUB_TMUX_BUSY_SESSIONS=""
{
  _row sessa remote 1 /nonexistent-cwd-a 90 2026-01-01T00:00:00 no no unknown clean
  _row sessb remote 1 /nonexistent-cwd-b 90 2026-01-01T00:00:00 no no unknown clean
  _row sessc remote 1 /nonexistent-cwd-c 90 2026-01-01T00:00:00 no no unknown clean
  _row sessd remote 1 /nonexistent-cwd-d 90 2026-01-01T00:00:00 no no unknown clean
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

echo "session-compact-managed: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
