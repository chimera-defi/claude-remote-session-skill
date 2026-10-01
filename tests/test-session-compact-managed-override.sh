#!/usr/bin/env bash
# Two things that shipped together: (1) sweep's VERDICT column gives skip:already-compacted, skip:landed-and-clean,
# skip:malformed-row, skip:never-touched and skip:bad-idle-field each a distinct label (not "skip: under thresholds");
# (2) sweep --managed-only overrides skip:landed-and-clean ONLY (via _sweep_evaluate_row_managed, not _decide/
# _evaluate_row), because an allowlisted session WILL get another mission. Every other skip (already-compacted,
# protected, busy) must still block, and the override is a no-op without --managed-only.
# Harness: isolated copy of session-compact.sh, the REAL scripts/session-handoff.sh against a fake `tmux` on PATH,
# $SESSION_COMPACT_SENSOR pointed at a fixture TSV. No real tmux, session or /compact. Real fixture
# *.jsonl transcripts for the one scenario needing a context percentage.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
SCRIPT="$HERE/../scripts/session-compact.sh"
HANDOFF="$HERE/../scripts/session-handoff.sh"
# shellcheck disable=SC1090
source "$SCRIPT"   # for _encode_cwd only (source-guarded: must NOT run dispatch)
row_in(){ printf '%s' "$1" | grep "^$2 "; }   # row_in <output> <session> -> that row's line

# Fixture plumbing (mirrors test-session-compact-sweep.sh / -managed.sh)
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

# _fixture_transcript <cwd> <tokens> <model>: as in test-session-compact-sweep.sh; needed for the one scenario that must
# clear the 50% managed CONTEXT trigger without clearing the 60m idle trigger.
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

# Group 1: managed-only override, all in ONE sweep so the override, already-compacted, protected and busy-pane guards are
# exercised side by side. Rows are landed=yes dirty=clean (what the override targets) except where a different guard
# should fire first (protected outranks landed-and-clean; mo_landedclean proves the override doesn't leak past it).
CTX_CWD="$FAKE_HOME/proj-ctx-landedclean"
_fixture_transcript "$CTX_CWD" 900000 claude-sonnet-4-6   # 90%
# mo_landedclean needs a KNOWN sufficient context: the idle trigger requires context >= _SWEEP_IDLE_CONTEXT_FLOOR_PCT
LANDEDCLEAN_CWD="$FAKE_HOME/proj-mo-landedclean"
_fixture_transcript "$LANDEDCLEAN_CWD" 450000 claude-sonnet-4-6   # 45%

export STUB_TMUX_SESSIONS="mo_landedclean mo_compacted mo_protected mo_busy mo_ctxlandedclean"
export STUB_TMUX_BUSY_SESSIONS="mo_busy"
{
  # 1. plain landed+clean over the 60m idle trigger: THE bug; must flip to would-compact under --managed-only
  _row mo_landedclean      remote 1 "$LANDEDCLEAN_CWD" 90 2026-01-01T00:00:00 no no  yes clean
  # 3. ALSO already-compacted: the infinite-loop guard (idle_minutes never resets across a compact, so --apply would
  #    re-/compact this session every sweep, #60/#61). The most important assertion in this file.
  _row mo_compacted        remote 1 /nonexistent-cwd-b 90 2026-01-01T00:00:00 no yes yes clean
  # 4. ALSO protected: checked in _decide before landed-and-clean, so the override must never reach it
  _row mo_protected        remote 1 /nonexistent-cwd-c 90 2026-01-01T00:00:00 yes no  yes clean
  # 5. ALSO a busy pane: the override's retry re-runs the real pane check, so busy must still block
  _row mo_busy             remote 1 /nonexistent-cwd-d 90 2026-01-01T00:00:00 no no  yes clean
  # Gap: landed+clean, UNDER the 60m idle trigger, relying ENTIRELY on the CONTEXT trigger (idle=10m, context=90%):
  # the override must apply on BOTH triggers; only this row catches an implementation that threaded managed_only
  # through trigger A and forgot trigger B.
  _row mo_ctxlandedclean   remote 1 "$CTX_CWD"         10 2026-01-01T00:00:00 no no  yes clean
} > "$FIXTURE_DIR/rows.tsv"

ALLOW_FILE="$(mktemp)"
printf 'mo_landedclean\nmo_compacted\nmo_protected\nmo_busy\nmo_ctxlandedclean\n' > "$ALLOW_FILE"

out_mo="$(SESSION_COMPACT_MANAGED_FILE="$ALLOW_FILE" _run sweep --dry-run --managed-only)"; rc_mo=$?
ok  "managed-override-exit0" "$rc_mo" "0"

has "landedclean-would-compact"   "$(row_in "$out_mo" mo_landedclean)"    "would-compact: idle"
has "ctxlandedclean-would-compact" "$(row_in "$out_mo" mo_ctxlandedclean)" "would-compact: context"

has   "compacted-still-skips"       "$(row_in "$out_mo" mo_compacted)" "skip: compacted"
hasnt "compacted-not-would-compact" "$(row_in "$out_mo" mo_compacted)" "would-compact"

has   "protected-still-skips"       "$(row_in "$out_mo" mo_protected)" "skip: protected"
hasnt "protected-not-would-compact" "$(row_in "$out_mo" mo_protected)" "would-compact"

has   "busy-still-skips"       "$(row_in "$out_mo" mo_busy)" "skip: busy"
hasnt "busy-not-would-compact" "$(row_in "$out_mo" mo_busy)" "would-compact"

# Group 2: backward-compat. SAME rows.tsv and $SESSION_COMPACT_MANAGED_FILE (proving it's ignored), but WITHOUT
# --managed-only -> mo_landedclean reverts to skip:landed+clean.
out_plain="$(SESSION_COMPACT_MANAGED_FILE="$ALLOW_FILE" _run sweep --dry-run)"; rc_plain=$?
ok    "noflag-exit0"                   "$rc_plain" "0"
has   "noflag-landedclean-still-skips" "$(row_in "$out_plain" mo_landedclean)" "skip: landed+clean"
hasnt "noflag-landedclean-not-would-compact" "$(row_in "$out_plain" mo_landedclean)" "would-compact"
hasnt "noflag-no-scope-text"           "$out_plain" "scope:"

# Group 3: the five relabelled skip causes each report their own VERDICT (plain sweep; /nonexistent-cwd is fine since
# all five guards fire before context is consulted).
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

# All five labels must be pairwise DISTINCT IN THE ACTUAL OUTPUT (five constants against five rows would pass even if
# the real column collapsed them all to "skip: under thresholds"). VERDICT is chars 62-83 of "%-32s %-8s %-11s %-6s %-22s %s"
# (SESSION 1-32, IDLE 34-41, CTX_TOKENS 43-53, CTX% 55-60, VERDICT 62-83, NOTE 85+).
_verdict_of() { row_in "$1" "$2" | cut -c62-83 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }
v_compacted="$(_verdict_of "$out_lb" lb_compacted)"
v_landedclean="$(_verdict_of "$out_lb" lb_landedclean)"
v_malformed="$(_verdict_of "$out_lb" lb_malformed)"
v_nevertouched="$(_verdict_of "$out_lb" lb_nevertouched)"
v_badidle="$(_verdict_of "$out_lb" lb_badidle)"
n_distinct="$(printf '%s\n%s\n%s\n%s\n%s\n' "$v_compacted" "$v_landedclean" "$v_malformed" "$v_nevertouched" "$v_badidle" | sort -u | wc -l)"
ok "labels-distinct-in-real-output" "$n_distinct" "5"

finish "session-compact-managed-override"
