#!/usr/bin/env bash
# session-compact.sh `sweep` context-aware trigger end-to-end through the REAL scripts/session-handoff.sh against a fake
# `tmux` on PATH. test-session-compact.sh covers the CLI contract with a stubbed handoff; this file adds real token counts
# (fixture *.jsonl transcripts under a fake $HOME/.claude/projects/<cwd>/) and session-handoff's actual busy detector
# (_is_working on a stub tmux's capture-pane output). No real tmux, session or /compact.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
SCRIPT="$HERE/../scripts/session-compact.sh"
HANDOFF="$HERE/../scripts/session-handoff.sh"
# shellcheck disable=SC1090
source "$SCRIPT"   # for _encode_cwd only (source-guarded: must NOT run dispatch)

# ============================================================================
# Fixture plumbing
# ============================================================================
ISO="$(mktemp -d)"
cp "$SCRIPT" "$ISO/session-compact.sh"
cp "$HANDOFF" "$ISO/session-handoff.sh"   # co-located: _find_helper picks this
                                            # REAL script over any PATH stub, so
                                            # busy-detection runs for real.

BIN="$(mktemp -d)"
# Fake tmux (the only live-process boundary), driven by env at call time: STUB_TMUX_SESSIONS (names that exist),
# STUB_TMUX_BUSY_SESSIONS (subset showing the spinner "esc to interrupt"). Other sessions capture as a SAFE pane: a lone
# `❯ ` line followed by a `─` border, the shape _input_box_empty needs.
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

# _fixture_transcript <cwd> <tokens> <model>: ONE assistant message with a usage object under $FAKE_HOME (all tokens in
# input_tokens; _context_snapshot sums input+cache_read+cache_creation).
_fixture_transcript() {
  local cwd="$1" tokens="$2" model="$3" dir
  dir="$FAKE_HOME/.claude/projects/$(_encode_cwd "$cwd")"
  mkdir -p "$dir" "$cwd"
  printf '{"type":"assistant","timestamp":"2026-01-01T00:00:00.000Z","message":{"model":"%s","usage":{"input_tokens":%d,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":50}}}\n' \
    "$model" "$tokens" > "$dir/fixture.jsonl"
}

# _fixture_unparseable_transcript <cwd>: dir exists but holds only garbage JSON (the "cannot be parsed" case, which must
# degrade gracefully, never crash or guess).
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
# Fixture rows: one session per scenario, all landed=no dirty=clean compacted=no so neither the landed-and-clean nor the
# already-compacted skip can mask the trigger under test.
# ============================================================================
CTX_CWD="$FAKE_HOME/proj-ctx"
IDLE_CWD="$FAKE_HOME/proj-idle"
BUSY_CWD="$FAKE_HOME/proj-busy"
PROT_CWD="$FAKE_HOME/proj-prot"
BAD_CWD="$FAKE_HOME/proj-bad"

_fixture_transcript "$CTX_CWD"  850000 claude-sonnet-4-6   # 85% of 1,000,000
# 45%: clears the idle trigger's context floor (_SWEEP_IDLE_CONTEXT_FLOOR_PCT=40) but stays under the 80% context trigger,
# isolating "idle trigger fires"
_fixture_transcript "$IDLE_CWD" 450000 claude-sonnet-4-6   # 45%
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

# --- 2. context=45% (clears the idle floor, under 80%), idle=90m -> idle ---
has "idle-trigger-fires"  "$(row idlesess)" "would-compact: idle"
has "idle-trigger-shows-pct" "$(row idlesess)" " 45 "

# --- 3. IMPORTANT: context=95% AND idle=90m both trigger, but the pane is BUSY (real spinner via the real
# session-handoff.sh) -> skip: busy, overriding BOTH triggers ---
has   "busy-overrides-both-triggers" "$(row busysess)" "skip: busy"
hasnt "busy-is-not-would-compact"    "$(row busysess)" "would-compact"

# --- 4. protected, idle=7200m, context=99% -> protected wins ---
has   "protected-wins" "$(row protsess)" "skip: protected"
hasnt "protected-is-not-would-compact" "$(row protsess)" "would-compact"

# --- 5. unparseable transcript, idle=10m (under the 60m idle trigger, over the 5m context floor) -> distinct loud
# skip:context-unknown (not an idle-only fallback, not "under thresholds"); never guesses a percentage ---
has "unparseable-shows-na"      "$(row unparsesess)" "n/a"
has "unparseable-verdict"       "$(row unparsesess)" "skip: context unknown"
has "unparseable-loud-note"     "$(row unparsesess)" "_model_window_for"

finish "session-compact-sweep"
