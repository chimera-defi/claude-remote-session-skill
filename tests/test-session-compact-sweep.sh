#!/usr/bin/env bash
# Tests for session-compact.sh's `sweep` context-aware trigger, end-to-end
# through a REAL scripts/session-handoff.sh (not a stub of it) talking to a
# fake `tmux` on PATH. tests/test-session-compact.sh already covers sweep's
# CLI contract (flags, exit codes, the idle-trigger path) via a stubbed
# session-handoff — that harness has no way to produce a real token count
# (no transcript on disk) or drive session-handoff's ACTUAL busy detector
# (its own `tmux capture-pane` call). This file plugs both gaps: real
# fixture *.jsonl transcripts under a fake $HOME/.claude/projects/<cwd>/, and
# a real session-handoff.sh reading a stub tmux's capture-pane output — so
# the spinner/"esc to interrupt" pattern _is_working actually implements is
# what's under test, not a re-description of it in a mock.
#
# No real tmux, no real session, no real /compact anywhere in this file.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/session-compact.sh"
HANDOFF="$HERE/../scripts/session-handoff.sh"
# shellcheck disable=SC1090
source "$SCRIPT"   # for _encode_cwd only (source-guarded: must NOT run dispatch)
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }
has(){ if printf '%s' "$2" | grep -qF "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — pattern not found: $3 in: $2"; fi; }
lacks(){ if printf '%s' "$2" | grep -qF "$3"; then fail=$((fail+1)); echo "FAIL: $1 — pattern SHOULD NOT be present: $3 in: $2"; else pass=$((pass+1)); fi; }

# ============================================================================
# Fixture plumbing
# ============================================================================
ISO="$(mktemp -d)"
cp "$SCRIPT" "$ISO/session-compact.sh"
cp "$HANDOFF" "$ISO/session-handoff.sh"   # co-located: _find_helper picks this
                                            # REAL script over any PATH stub, so
                                            # busy-detection runs for real.

BIN="$(mktemp -d)"
# Fake tmux — the ONLY live-process boundary in this file. Driven by two env
# vars read at call time (so each `bash tmux ...` subprocess still sees them):
#   STUB_TMUX_SESSIONS       - space-separated names that "exist" (has-session)
#   STUB_TMUX_BUSY_SESSIONS  - subset of the above whose capture-pane shows the
#                              actively-generating spinner ("esc to interrupt")
# Every existing, non-busy session captures as a plain SAFE pane: a lone `❯ `
# prompt line immediately followed by a border line of only `─`, which is
# exactly the shape session-handoff.sh's _input_box_empty requires to read the
# input box as empty (see its own comment for the parse).
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

# _fixture_transcript <cwd> <tokens> <model> — writes ONE assistant message
# with a real usage object into the transcript dir _context_snapshot will
# scan for <cwd>, under $FAKE_HOME. All tokens go in input_tokens for
# simplicity — _context_snapshot sums input+cache_read+cache_creation, so
# where they land inside that sum doesn't matter for the total.
_fixture_transcript() {
  local cwd="$1" tokens="$2" model="$3" dir
  dir="$FAKE_HOME/.claude/projects/$(_encode_cwd "$cwd")"
  mkdir -p "$dir" "$cwd"
  printf '{"type":"assistant","timestamp":"2026-01-01T00:00:00.000Z","message":{"model":"%s","usage":{"input_tokens":%d,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":50}}}\n' \
    "$model" "$tokens" > "$dir/fixture.jsonl"
}

# _fixture_unparseable_transcript <cwd> — a transcript dir that EXISTS but
# contains no line _context_snapshot's parser can use as an assistant+usage
# entry (garbage JSON throughout) — the "cannot be found or parsed" case
# rule 6 requires degrading gracefully from, not crashing or guessing.
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

export STUB_TMUX_SESSIONS="ctxsess idlesess busysess protsess unparsesess"
export STUB_TMUX_BUSY_SESSIONS="busysess"

# ============================================================================
# Fixture rows — one session per required scenario (see brief's Commit 3
# list). All use landed=no dirty=clean (valid vocabulary, and specifically
# NOT landed=yes+dirty=clean, so the landed-and-clean skip never masks the
# trigger this test is actually checking) and compacted=no (so the already-
# compacted skip doesn't mask it either).
# ============================================================================
CTX_CWD="$FAKE_HOME/proj-ctx"
IDLE_CWD="$FAKE_HOME/proj-idle"
BUSY_CWD="$FAKE_HOME/proj-busy"
PROT_CWD="$FAKE_HOME/proj-prot"
BAD_CWD="$FAKE_HOME/proj-bad"

_fixture_transcript "$CTX_CWD"  850000 claude-sonnet-4-6   # 85% of 1,000,000
# 50%: clears the idle trigger's own context floor (_SWEEP_IDLE_CONTEXT_FLOOR_PCT
# = 40 — idle alone is not need) while staying well under the DIFFERENT 80%
# context-trigger threshold, so this row still isolates "idle trigger fires",
# not "context trigger also would have fired".
_fixture_transcript "$IDLE_CWD" 500000 claude-sonnet-4-6   # 50%
_fixture_transcript "$BUSY_CWD" 950000 claude-sonnet-4-6   # 95%
_fixture_transcript "$PROT_CWD" 990000 claude-sonnet-4-6   # 99%
_fixture_unparseable_transcript "$BAD_CWD"

{
  _row ctxsess     remote 1 "$CTX_CWD"  10   2026-01-01T00:00:00 no  no unknown clean
  _row idlesess    remote 1 "$IDLE_CWD" 90   2026-01-01T00:00:00 no  no unknown clean
  _row busysess    remote 1 "$BUSY_CWD" 90   2026-01-01T00:00:00 no  no unknown clean
  _row protsess    remote 1 "$PROT_CWD" 7200 2026-01-01T00:00:00 yes no unknown clean
  _row unparsesess remote 1 "$BAD_CWD"  10   2026-01-01T00:00:00 no  no unknown clean
} > "$FIXTURE_DIR/rows.tsv"

out="$(_run sweep)"; rc=$?
ok "sweep-exit0" "$rc" "0"

row() { printf '%s' "$out" | grep "^$1 "; }

# --- 1. context >= 80%, idle=10m (well under the idle trigger) -> context --
has "context-trigger-fires"     "$(row ctxsess)" "would-compact: context"
has "context-trigger-shows-pct" "$(row ctxsess)" " 85 "
has "context-trigger-shows-tokens" "$(row ctxsess)" "850000"

# --- 2. context=50% (clears the idle trigger's context floor but not the
# separate 80% context-trigger threshold), idle=90m (over the idle trigger)
# -> idle ---------------------------------------------------------------
has "idle-trigger-fires"  "$(row idlesess)" "would-compact: idle"
has "idle-trigger-shows-pct" "$(row idlesess)" " 50 "

# --- 3. THE IMPORTANT CASE: context=95% (would ALSO trigger) AND idle=90m
# (would ALSO trigger via idle) but the pane is BUSY (real spinner text, read
# through the REAL session-handoff.sh -> real tmux capture-pane stub) ->
# skip: busy, overriding BOTH triggers ---------------------------------------
has   "busy-overrides-both-triggers" "$(row busysess)" "skip: busy"
lacks "busy-is-not-would-compact"    "$(row busysess)" "would-compact"

# --- 4. protected, idle=7200m (5 days), context=99% -> protected wins,
# regardless of how hard both triggers would otherwise fire ------------------
has   "protected-wins" "$(row protsess)" "skip: protected"
lacks "protected-is-not-would-compact" "$(row protsess)" "would-compact"

# --- 5. unparseable transcript, idle=10m: under the 60m idle trigger but
# over the context trigger's 5m floor, so this reaches the context-path
# eligibility check with an unmeasurable percentage -> distinct, loud
# skip:context-unknown (NOT a silent idle-only fallback, and NOT collapsed
# into "skip: under thresholds") — never guesses a percentage (rule 6) ------
has "unparseable-shows-na"      "$(row unparsesess)" "n/a"
has "unparseable-verdict"       "$(row unparsesess)" "skip: context unknown"
has "unparseable-loud-note"     "$(row unparsesess)" "_model_window_for"

echo "session-compact-sweep: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
