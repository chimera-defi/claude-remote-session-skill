#!/usr/bin/env bash
# Tests for TWO things that shipped together because the second is a display
# consequence of the same case statement the first one edits:
#
#   1. sweep's VERDICT column gives skip:already-compacted, skip:landed-and-
#      clean, skip:malformed-row, skip:never-touched, and skip:bad-idle-field
#      each their own distinct label, instead of collapsing all five (plus
#      the genuinely-outside-window case) into "skip: under thresholds".
#   2. sweep --managed-only overrides skip:landed-and-clean ONLY — via
#      _sweep_evaluate_row_managed, NOT by touching _decide/_evaluate_row —
#      because allowlist membership means the orchestrator WILL send this
#      session another mission, so "will never be resumed" (the guard's own
#      justification) does not hold for it. Every OTHER skip reason
#      (already-compacted, protected, busy pane) must still block, and the
#      override must be a complete no-op without --managed-only.
#
# Same harness shape as tests/test-session-compact-sweep.sh: an isolated copy
# of session-compact.sh, a REAL scripts/session-handoff.sh (not a stub of it)
# talking to a fake `tmux` on PATH, real fixture *.jsonl transcripts for the
# one scenario that needs an actual context percentage, and
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
row_in(){ printf '%s' "$1" | grep "^$2 "; }   # row_in <output> <session> -> that row's line

# ============================================================================
# Fixture plumbing (mirrors test-session-compact-sweep.sh / -managed.sh)
# ============================================================================
ISO="$(mktemp -d)"
cp "$SCRIPT" "$ISO/session-compact.sh"
cp "$HANDOFF" "$ISO/session-handoff.sh"   # co-located: _find_helper picks this
                                            # REAL script over any PATH stub, so
                                            # busy-detection runs for real.

BIN="$(mktemp -d)"
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
# test-session-compact-sweep.sh, needed only for the one scenario below that
# must clear the 80% CONTEXT trigger without clearing the 60m idle trigger.
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

# ============================================================================
# Group 1 (brief scenarios 1, 3, 4, 5 + discovered gap): managed-only
# override, all evaluated in ONE sweep invocation so the override, the
# already-compacted guard, the protected guard, and the busy-pane guard are
# all exercised side by side against the SAME allowlist/scope.
#
# All rows use landed=yes dirty=clean (the condition the override targets)
# EXCEPT where the row's own point is a DIFFERENT guard firing first
# (protected fires before landed-and-clean is even consulted — see _decide —
# so mo_landedclean isn't required there, but is included anyway to prove
# the override doesn't leak past a guard that legitimately outranks it).
# ============================================================================
CTX_CWD="$FAKE_HOME/proj-ctx-landedclean"
_fixture_transcript "$CTX_CWD" 900000 claude-sonnet-4-6   # 90%
# mo_landedclean now needs a KNOWN, sufficient context too: the idle trigger
# requires context >= _SWEEP_IDLE_CONTEXT_FLOOR_PCT (see _sweep_decide's own
# comment), so a nonexistent (context-unknown) cwd would now skip:context-
# unknown instead of demonstrating the override this row exists to prove.
LANDEDCLEAN_CWD="$FAKE_HOME/proj-mo-landedclean"
_fixture_transcript "$LANDEDCLEAN_CWD" 500000 claude-sonnet-4-6   # 50%

export STUB_TMUX_SESSIONS="mo_landedclean mo_compacted mo_protected mo_busy mo_ctxlandedclean"
export STUB_TMUX_BUSY_SESSIONS="mo_busy"
{
  # 1. plain landed+clean, over the 60m idle trigger, nothing else masking it
  #    -> THE bug this commit fixes: must flip to would-compact under
  #    --managed-only.
  _row mo_landedclean      remote 1 "$LANDEDCLEAN_CWD" 90 2026-01-01T00:00:00 no no  yes clean
  # 3. ALSO already-compacted (compacted=yes) -> the infinite-loop guard.
  #    Without it, --apply would re-issue /compact to this session on EVERY
  #    sweep run forever, because idle-report never resets idle_minutes
  #    across a compact (see _sweep_decide's own comment, #60/#61). This is
  #    the single most important assertion in this file.
  _row mo_compacted        remote 1 /nonexistent-cwd-b 90 2026-01-01T00:00:00 no yes yes clean
  # 4. ALSO protected -> protected is checked in _decide BEFORE landed-and-
  #    clean is ever consulted, so the override must never reach it.
  _row mo_protected        remote 1 /nonexistent-cwd-c 90 2026-01-01T00:00:00 yes no  yes clean
  # 5. ALSO a busy pane -> the retry the override performs re-runs the REAL
  #    _pane_ready_reason check (via _evaluate_row), so a busy pane must
  #    still block even once the landed-and-clean guard is bypassed.
  _row mo_busy             remote 1 /nonexistent-cwd-d 90 2026-01-01T00:00:00 no no  yes clean
  # Discovered gap (not in the brief's scenario list): landed+clean, but
  # UNDER the 60m idle trigger and relying ENTIRELY on the CONTEXT trigger
  # (idle=10m, context=90%). _sweep_decide's own comment says the override
  # is meant to apply "identically on BOTH triggers" — this is the only
  # scenario in this file that would catch an implementation which only
  # threaded managed_only through trigger A (idle) and forgot trigger B
  # (context).
  _row mo_ctxlandedclean   remote 1 "$CTX_CWD"         10 2026-01-01T00:00:00 no no  yes clean
} > "$FIXTURE_DIR/rows.tsv"

ALLOW_FILE="$(mktemp)"
printf 'mo_landedclean\nmo_compacted\nmo_protected\nmo_busy\nmo_ctxlandedclean\n' > "$ALLOW_FILE"

out_mo="$(SESSION_COMPACT_MANAGED_FILE="$ALLOW_FILE" _run sweep --dry-run --managed-only)"; rc_mo=$?
ok  "managed-override-exit0" "$rc_mo" "0"

has "landedclean-would-compact"   "$(row_in "$out_mo" mo_landedclean)"    "would-compact: idle"
has "ctxlandedclean-would-compact" "$(row_in "$out_mo" mo_ctxlandedclean)" "would-compact: context"

has   "compacted-still-skips"       "$(row_in "$out_mo" mo_compacted)" "skip: compacted"
lacks "compacted-not-would-compact" "$(row_in "$out_mo" mo_compacted)" "would-compact"

has   "protected-still-skips"       "$(row_in "$out_mo" mo_protected)" "skip: protected"
lacks "protected-not-would-compact" "$(row_in "$out_mo" mo_protected)" "would-compact"

has   "busy-still-skips"       "$(row_in "$out_mo" mo_busy)" "skip: busy"
lacks "busy-not-would-compact" "$(row_in "$out_mo" mo_busy)" "would-compact"

# ============================================================================
# Group 2 (brief scenario 2): backward-compat guard. SAME rows.tsv, SAME
# $SESSION_COMPACT_MANAGED_FILE (proving it's ignored, same idiom
# test-session-compact-managed.sh uses), but WITHOUT --managed-only ->
# mo_landedclean must revert to skip:landed+clean, not would-compact.
# ============================================================================
out_plain="$(SESSION_COMPACT_MANAGED_FILE="$ALLOW_FILE" _run sweep --dry-run)"; rc_plain=$?
ok    "noflag-exit0"                   "$rc_plain" "0"
has   "noflag-landedclean-still-skips" "$(row_in "$out_plain" mo_landedclean)" "skip: landed+clean"
lacks "noflag-landedclean-not-would-compact" "$(row_in "$out_plain" mo_landedclean)" "would-compact"
lacks "noflag-no-scope-text"           "$out_plain" "scope:"

# ============================================================================
# Group 3 (brief scenario 6): the five relabelled skip causes each report
# their own distinct VERDICT — plain sweep, no --managed-only involved, all
# using /nonexistent-cwd (all five guards fire before context is ever
# consulted, so the context-unknown path never applies here — no transcript
# needed).
# ============================================================================
export STUB_TMUX_SESSIONS="lb_compacted lb_landedclean lb_malformed lb_nevertouched lb_badidle"
export STUB_TMUX_BUSY_SESSIONS=""
{
  _row lb_compacted     remote 1 /nonexistent-cwd-e 90    2026-01-01T00:00:00 no    yes unknown clean
  _row lb_landedclean   remote 1 /nonexistent-cwd-f 90    2026-01-01T00:00:00 no    no  yes     clean
  _row lb_malformed     remote 1 /nonexistent-cwd-g 90    2026-01-01T00:00:00 maybe no  unknown clean
  _row lb_nevertouched  remote 1 /nonexistent-cwd-h never 2026-01-01T00:00:00 no    no  unknown clean
  _row lb_badidle       remote 1 /nonexistent-cwd-i abc   2026-01-01T00:00:00 no    no  unknown clean
} > "$FIXTURE_DIR/rows.tsv"

out_lb="$(_run sweep --dry-run)"; rc_lb=$?
ok "label-exit0" "$rc_lb" "0"

has "label-already-compacted"  "$(row_in "$out_lb" lb_compacted)"    "skip: compacted"
has "label-landed-and-clean"   "$(row_in "$out_lb" lb_landedclean)"  "skip: landed+clean"
has "label-malformed-row"      "$(row_in "$out_lb" lb_malformed)"    "skip: malformed row"
has "label-never-touched"      "$(row_in "$out_lb" lb_nevertouched)" "skip: never touched"
has "label-bad-idle-field"     "$(row_in "$out_lb" lb_badidle)"      "skip: bad idle field"

# All five labels must be pairwise DISTINCT IN THE ACTUAL OUTPUT — not just
# as hardcoded strings above (a test asserting five different constants
# against five different rows would pass even if the real VERDICT column
# collapsed all five to "skip: under thresholds", since each `has` call only
# checks its own row). VERDICT is the fixed-width column at 1-indexed
# characters 62-83 in "%-32s %-8s %-11s %-6s %-22s %s" (SESSION 1-32, IDLE
# 34-41, CTX_TOKENS 43-53, CTX% 55-60, VERDICT 62-83, NOTE 85+).
_verdict_of() { row_in "$1" "$2" | cut -c62-83 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }
v_compacted="$(_verdict_of "$out_lb" lb_compacted)"
v_landedclean="$(_verdict_of "$out_lb" lb_landedclean)"
v_malformed="$(_verdict_of "$out_lb" lb_malformed)"
v_nevertouched="$(_verdict_of "$out_lb" lb_nevertouched)"
v_badidle="$(_verdict_of "$out_lb" lb_badidle)"
n_distinct="$(printf '%s\n%s\n%s\n%s\n%s\n' "$v_compacted" "$v_landedclean" "$v_malformed" "$v_nevertouched" "$v_badidle" | sort -u | wc -l)"
ok "labels-distinct-in-real-output" "$n_distinct" "5"

echo "session-compact-managed-override: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
