#!/usr/bin/env bash
# session-compact.sh `sweep` end to end: an isolated copy of the script, the REAL session-handoff.sh (busy detector),
# a fake `tmux` on PATH, a fixture sensor TSV and real fixture *.jsonl transcripts under a fake $HOME. No real tmux,
# session or /compact. One fleet of rows, three sweeps:
#   1. plain: the context trigger (80%), the idle trigger (needs a MEASURED context >= 40%), unknown context skips on
#      either trigger, and busy / protected / already-compacted / landed+clean / malformed rows each get their own verdict.
#   2. --managed-only scope: a missing/empty/stale allowlist is zero in scope (never a fleet-wide fallback), a subset
#      is the only thing evaluated, and the flag is ignored when absent.
#   3. --managed-only overrides skip:landed+clean ONLY (already-compacted, protected and busy still block; the lower
#      50% context trigger applies).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
SCRIPT="$HERE/../scripts/session-compact.sh"
HANDOFF="$HERE/../scripts/session-handoff.sh"
# shellcheck disable=SC1090
source "$SCRIPT"   # for _encode_cwd / _managed_task_state_for_cwd (source-guarded: must NOT run dispatch)

ISO="$(mktemp -d)"; BIN="$(mktemp -d)"; FIXTURE_DIR="$(mktemp -d)"; FAKE_HOME="$(mktemp -d)"
trap 'rm -rf "$ISO" "$BIN" "$FIXTURE_DIR" "$FAKE_HOME"' EXIT
cp "$SCRIPT" "$ISO/session-compact.sh"
cp "$HANDOFF" "$ISO/session-handoff.sh"   # co-located: busy detection runs for real

# fake tmux: STUB_TMUX_SESSIONS exist; STUB_TMUX_BUSY_SESSIONS show the spinner; the rest capture as a SAFE pane
cat > "$BIN/tmux" <<'EOF'
#!/usr/bin/env bash
_name_arg() { local prev="" a; for a in "$@"; do [ "$prev" = "-t" ] && { printf '%s\n' "$a"; return; }; prev="$a"; done; }
case "$1" in
  has-session) shift; name="$(_name_arg "$@")"; for s in ${STUB_TMUX_SESSIONS:-}; do [ "$s" = "$name" ] && exit 0; done; exit 1 ;;
  display-message) echo claude ;;
  capture-pane)
    shift; name="$(_name_arg "$@")"
    for s in ${STUB_TMUX_BUSY_SESSIONS:-}; do
      [ "$s" = "$name" ] && { printf '%s\n' '✻ Combobulating… (12s · esc to interrupt)'; exit 0; }
    done
    printf '%s\n' 'previous turn output here' '❯ ' '──────────────────────────────' ;;
esac
exit 0
EOF
chmod +x "$BIN/tmux"
printf '#!/usr/bin/env bash\ncat "%s/rows.tsv"\n' "$FIXTURE_DIR" > "$FIXTURE_DIR/sensor.sh"; chmod +x "$FIXTURE_DIR/sensor.sh"

_row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }   # name kind n cwd idle ts protected compacted landed dirty
# tx <name> <tokens>: a one-message transcript for the session's cwd ($FAKE_HOME/p-<name>); tx_bad: unparseable
cwd_of() { echo "$FAKE_HOME/p-$1"; }
tx() {
  local d; d="$FAKE_HOME/.claude/projects/$(_encode_cwd "$(cwd_of "$1")")"; mkdir -p "$d" "$(cwd_of "$1")"
  printf '{"type":"assistant","timestamp":"2026-01-01T00:00:00.000Z","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":%d,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":50}}}\n' "$2" > "$d/fixture.jsonl"
}
tx_bad() {
  local d; d="$FAKE_HOME/.claude/projects/$(_encode_cwd "$(cwd_of "$1")")"; mkdir -p "$d" "$(cwd_of "$1")"
  printf 'this is not json at all\n{"broken\n\n' > "$d/fixture.jsonl"
}
_run() { PATH="$BIN:$PATH" SESSION_COMPACT_SENSOR="$FIXTURE_DIR/sensor.sh" HOME="$FAKE_HOME" bash "$ISO/session-compact.sh" "$@"; }
row_in() { printf '%s' "$1" | grep "^$2 "; }

tx ctxsess 850000; tx idlesess 450000; tx busysess 950000; tx protsess 990000; tx_bad unparsesess; tx_bad unparse90
tx ctxsmall 100000; tx atfloor 400000; tx underfloor 390000; tx ctxb50 500000; tx ctxb49 490000
tx compacted 500000; tx mo_landed 450000; tx mo_ctxlanded 900000
mkdir -p "$(cwd_of malformed)" "$(cwd_of nevertouched)" "$(cwd_of badidle)" "$(cwd_of landed)"
export STUB_TMUX_SESSIONS="ctxsess idlesess busysess protsess unparsesess unparse90 ctxsmall atfloor underfloor ctxb50 ctxb49 compacted mo_landed mo_ctxlanded malformed nevertouched badidle landed"
export STUB_TMUX_BUSY_SESSIONS="busysess"
{
  #     name         kind   n cwd                       idle  ts                   prot  comp  landed  dirty
  _row ctxsess      remote 1 "$(cwd_of ctxsess)"      10    2026-01-01T00:00:00 no    no    unknown clean
  _row idlesess     remote 1 "$(cwd_of idlesess)"     90    2026-01-01T00:00:00 no    no    unknown clean
  _row busysess     remote 1 "$(cwd_of busysess)"     90    2026-01-01T00:00:00 no    no    unknown clean
  _row protsess     remote 1 "$(cwd_of protsess)"     7200  2026-01-01T00:00:00 yes   no    unknown clean
  _row unparsesess  remote 1 "$(cwd_of unparsesess)"  10    2026-01-01T00:00:00 no    no    unknown clean
  _row unparse90    remote 1 "$(cwd_of unparse90)"    90    2026-01-01T00:00:00 no    no    unknown clean
  _row ctxsmall     remote 1 "$(cwd_of ctxsmall)"     90    2026-01-01T00:00:00 no    no    unknown clean
  _row atfloor      remote 1 "$(cwd_of atfloor)"      90    2026-01-01T00:00:00 no    no    unknown clean
  _row underfloor   remote 1 "$(cwd_of underfloor)"   90    2026-01-01T00:00:00 no    no    unknown clean
  _row ctxb50       remote 1 "$(cwd_of ctxb50)"       10    2026-01-01T00:00:00 no    no    unknown clean
  _row ctxb49       remote 1 "$(cwd_of ctxb49)"       10    2026-01-01T00:00:00 no    no    unknown clean
  _row compacted    remote 1 "$(cwd_of compacted)"    90    2026-01-01T00:00:00 no    yes   unknown clean
  _row mo_landed    remote 1 "$(cwd_of mo_landed)"    90    2026-01-01T00:00:00 no    no    yes     clean
  _row mo_ctxlanded remote 1 "$(cwd_of mo_ctxlanded)" 10    2026-01-01T00:00:00 no    no    yes     clean
  _row malformed    remote 1 "$(cwd_of malformed)"    90    2026-01-01T00:00:00 maybe no    unknown clean
  _row nevertouched remote 1 "$(cwd_of nevertouched)" never 2026-01-01T00:00:00 no    no    unknown clean
  _row badidle      remote 1 "$(cwd_of badidle)"      abc   2026-01-01T00:00:00 no    no    unknown clean
  _row landed       remote 1 "$(cwd_of landed)"       90    2026-01-01T00:00:00 no    no    yes     clean
} > "$FIXTURE_DIR/rows.tsv"

# ---- 1. plain sweep
out="$(_run sweep --dry-run)"; rc=$?
ok "sweep exit 0" "$rc" "0"
r() { row_in "$out" "$1"; }
has   "context >= 80% fires (idle only 10m), with pct and tokens" "$(r ctxsess)" "would-compact: context"
has   "...pct shown" "$(r ctxsess)" " 85 "; has "...tokens shown" "$(r ctxsess)" "850000"
has   "idle trigger fires once context clears the floor" "$(r idlesess)" "would-compact: idle"
has   "context 10% + idle 90m is not need" "$(r ctxsmall)" "skip: context too small"
has   "exactly 40% (inclusive floor) compacts" "$(r atfloor)" "would-compact: idle"
has   "39% skips" "$(r underfloor)" "skip: context too small"
has   "trigger B under 80%: 50% stays below" "$(r ctxb50)" "skip: under thresholds"
has   "trigger B under 80%: 49% stays below" "$(r ctxb49)" "skip: under thresholds"
has   "busy pane beats both triggers" "$(r busysess)" "skip: busy"
has   "protected wins at 99% and 7200m idle" "$(r protsess)" "skip: protected"
has   "unparseable transcript: n/a, context unknown, names the model table" "$(r unparsesess)" "skip: context unknown"
has   "...loud note" "$(r unparsesess)" "_model_window_for"; has "...shows n/a" "$(r unparsesess)" "n/a"
has   "unknown context also skips on the idle trigger" "$(r unparse90)" "skip: context unknown"
has   "already-compacted blocks first (loop guard)" "$(r compacted)" "skip: compacted"
has   "landed+clean has its own verdict" "$(r landed)" "skip: landed+clean"
has   "malformed row" "$(r malformed)" "skip: malformed row"
has   "never touched" "$(r nevertouched)" "skip: never touched"
has   "bad idle field" "$(r badidle)" "skip: bad idle field"
for s in busysess protsess ctxsmall underfloor ctxb50 compacted landed malformed; do hasnt "$s never would-compact" "$(r $s)" "would-compact"; done
_verdict_of() { row_in "$out" "$1" | cut -c62-83 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }   # VERDICT column
ok "skip causes are pairwise distinct in the real VERDICT column" \
  "$(for s in compacted landed malformed nevertouched badidle; do _verdict_of $s; done | sort -u | wc -l)" "5"

# ---- 2. --managed-only scope
ALLOW="$(mktemp)"; trap 'rm -rf "$ISO" "$BIN" "$FIXTURE_DIR" "$FAKE_HOME" "$ALLOW"' EXIT
msweep() { SESSION_COMPACT_MANAGED_FILE="$1" _run sweep --dry-run "${@:2}"; }
o="$(msweep "$FAKE_HOME/does-not-exist" --managed-only)"; rc=$?
ok "missing allowlist: exit 0" "$rc" "0"; has "missing allowlist: zero in scope" "$o" "0 sessions in scope"
has "missing allowlist: refuses a fleet-wide fallback" "$o" "Refusing to fall back to fleet-wide"
hasnt "missing allowlist: evaluates nothing" "$o" "would-compact"
printf '# just a comment\n\n   \n' > "$ALLOW"
o="$(msweep "$ALLOW" --managed-only)"; has "comments-only allowlist: zero in scope" "$o" "0 sessions in scope"; hasnt "comments-only: nothing evaluated" "$o" "idlesess"
printf 'idlesess\nctxsess\n' > "$ALLOW"
o="$(msweep "$ALLOW" --managed-only)"
has "subset: only the allowlisted rows are evaluated" "$(row_in "$o" idlesess)" "would-compact: idle"
hasnt "subset: others absent entirely" "$o" "busysess"; has "subset: counts" "$o" "2 managed, 2 live"; has "subset: scanned" "$o" "--- 2 session(s) scanned."
printf 'idlesess\ndeadsess\n' > "$ALLOW"
o="$(msweep "$ALLOW" --managed-only)"
has "stale entry ignored but counted" "$o" "2 managed, 1 live"; hasnt "stale entry never listed" "$o" "deadsess"
printf 'deadsess\nanotherdead\n' > "$ALLOW"
o="$(msweep "$ALLOW" --managed-only)"
has "all-stale: 0 live" "$o" "2 managed, 0 live"; has "all-stale: 0 scanned (no unfiltered fallback)" "$o" "--- 0 session(s) scanned."; hasnt "all-stale: nothing evaluated" "$o" "would-compact"
o="$(msweep "$ALLOW")"
has "without the flag the allowlist is ignored: whole fleet scanned" "$o" "--- 18 session(s) scanned."; hasnt "...no scope text" "$o" "scope:"

# ---- 3. --managed-only overrides landed+clean only
printf 'mo_landed\nmo_ctxlanded\ncompacted\nprotsess\nbusysess\nctxb50\nctxb49\ndeadsess\n' > "$ALLOW"
mo="$(msweep "$ALLOW" --managed-only)"
has "landed+clean flips on the idle trigger" "$(row_in "$mo" mo_landed)" "would-compact: idle"
has "landed+clean flips on the context trigger" "$(row_in "$mo" mo_ctxlanded)" "would-compact: context"
has "already-compacted still blocks (infinite-loop guard)" "$(row_in "$mo" compacted)" "skip: compacted"
has "protected still blocks" "$(row_in "$mo" protsess)" "skip: protected"
has "busy still blocks" "$(row_in "$mo" busysess)" "skip: busy"
has "managed context trigger is 50%" "$(row_in "$mo" ctxb50)" "would-compact: context"
has "49% still skips" "$(row_in "$mo" ctxb49)" "skip: under thresholds"
has "banner states the managed threshold" "$mo" "context >= 50%"
has "without the flag landed+clean still skips" "$(row_in "$(msweep "$ALLOW")" mo_landed)" "skip: landed+clean"

# ---- managed task-state guard
TCWD="$FAKE_HOME/proj-active-task"; TENC="$(_encode_cwd "$TCWD")"
mkdir -p "$FAKE_HOME/.claude/projects/$TENC" "$FAKE_HOME/tasks-root/sid-active"
echo '{"type":"assistant","timestamp":"2026-09-22T10:00:00Z","message":{"model":"claude-fable-5","usage":{"input_tokens":10,"cache_read_input_tokens":500000,"cache_creation_input_tokens":0,"output_tokens":1}}}' > "$FAKE_HOME/.claude/projects/$TENC/sid-active.jsonl"
tstate() { HOME="$FAKE_HOME" SESSION_COMPACT_TASKS_ROOT="$FAKE_HOME/tasks-root" _managed_task_state_for_cwd "$TCWD"; }
echo '{"id":"1","status":"in_progress"}' > "$FAKE_HOME/tasks-root/sid-active/1.json"; ok "task in progress => active:1" "$(tstate)" "active:1"
echo '{"id":"1","status":"completed"}' > "$FAKE_HOME/tasks-root/sid-active/1.json"; ok "task completed => clear" "$(tstate)" "clear"
echo '{broken' > "$FAKE_HOME/tasks-root/sid-active/bad.json"; ok "malformed task file fails closed" "$(tstate)" "unknown"

finish "session-compact-sweep"
