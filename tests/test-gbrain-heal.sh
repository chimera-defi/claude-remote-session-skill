#!/usr/bin/env bash
# Plain-bash assertions for gbrain-heal.sh. No external test framework, no
# real gbrain binary or brain -- see tests/test-gbrain-sync-memory.sh for the
# repo's style this follows.
#
# The stub `gbrain` (installed via GBRAIN_BIN, per SPEC-gbrain-heal.md) records
# every invocation's argv AND the two tuned embed env vars to a capture file,
# then answers from scripted JSON fixtures / exit codes / sleep durations set
# via env vars. This is stricter than test-gbrain-sync-memory.sh's PATH-shadow
# stub because "tuned env exported and not overriding a pre-set value" can
# only be asserted if the stub actually records what env it received.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/gbrain-heal.sh"
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }
contains(){
  case "$2" in
    *"$3"*) pass=$((pass+1)) ;;
    *) fail=$((fail+1)); echo "FAIL: $1 — output did not contain '$3'"; echo "--- output ---"; echo "$2"; echo "--------------" ;;
  esac
}
not_contains(){
  case "$2" in
    *"$3"*) fail=$((fail+1)); echo "FAIL: $1 — output unexpectedly contained '$3'" ;;
    *) pass=$((pass+1)) ;;
  esac
}
before(){ # $1=haystack $2=needle_a $3=needle_b -- asserts a's first occurrence precedes b's
  local ia ib
  ia="${1%%"$2"*}"; ib="${1%%"$3"*}"
  if [ "${#ia}" -lt "${#ib}" ] && [ "$ia" != "$1" ] && [ "$ib" != "$1" ]; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); echo "FAIL: order — expected '$2' before '$3'"
  fi
}

STUBDIR="$(mktemp -d)"
cat > "$STUBDIR/gbrain" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
CAP="${GBRAIN_STUB_CAPTURE:?GBRAIN_STUB_CAPTURE not set}"
{
  printf 'CALL:'
  for a in "$@"; do printf ' %q' "$a"; done
  printf '\n'
  printf '  ENV_BATCH=%s\n' "${GBRAIN_EMBED_MAX_BATCH_TOKENS-<unset>}"
  printf '  ENV_TIMEOUT=%s\n' "${GBRAIN_AI_EMBED_TIMEOUT_MS-<unset>}"
} >> "$CAP"

emit_json() {
  local which="$1" seqfile=""
  case "$which" in
    doctor)  seqfile="${GBRAIN_STUB_DOCTOR_SEQ:-}" ;;
    status)  seqfile="${GBRAIN_STUB_STATUS_SEQ:-}" ;;
    sources) seqfile="${GBRAIN_STUB_SOURCES_SEQ:-}" ;;
  esac
  if [ -z "$seqfile" ]; then echo '{}'; return; fi
  local counter="$CAP.$which.count"
  local n=0
  [ -f "$counter" ] && n="$(cat "$counter")"
  local paths=()
  IFS=':' read -r -a paths <<< "$seqfile"
  local last=$(( ${#paths[@]} - 1 ))
  [ "$n" -gt "$last" ] && n="$last"
  echo "UPGRADE_AVAILABLE 0.50.0.0 0.54.1.1"
  echo "gbrain 0.50.0.0 -> 0.54.1.1 available. Run: gbrain self-upgrade"
  cat "${paths[$n]}"
  echo $((n+1)) > "$counter"
}

cmd="${1:-}"; sub="${2:-}"
case "$cmd" in
  doctor) emit_json doctor ;;
  migrate) [ "$sub" = "embeddings" ] && emit_json status ;;
  sources) [ "$sub" = "list" ] && emit_json sources ;;
  sync) exit "${GBRAIN_STUB_EXIT_SYNC:-0}" ;;
  embed) sleep "${GBRAIN_STUB_EMBED_SLEEP:-0}"; exit "${GBRAIN_STUB_EXIT_EMBED:-0}" ;;
  extract) exit "${GBRAIN_STUB_EXIT_EXTRACT:-0}" ;;
  dream) exit "${GBRAIN_STUB_EXIT_DREAM:-0}" ;;
  *) echo "gbrain-stub: unsupported command: $cmd $sub" >&2; exit 1 ;;
esac
STUB
chmod +x "$STUBDIR/gbrain"
export GBRAIN_BIN="$STUBDIR/gbrain"

FIXDIR="$(mktemp -d)"

doctor_healthy() {
  cat > "$FIXDIR/doctor-healthy.json" <<'JSON'
{"schema_version":2,"status":"ok","checks":[{"name":"sync_freshness","status":"ok"},{"name":"cycle_freshness","status":"ok"}]}
JSON
  echo "$FIXDIR/doctor-healthy.json"
}
doctor_unhealthy() {
  cat > "$FIXDIR/doctor-unhealthy.json" <<'JSON'
{"schema_version":2,"status":"warnings","checks":[{"name":"sync_freshness","status":"ok"},{"name":"cycle_freshness","status":"fail"},{"name":"other_check","status":"fail"}]}
JSON
  echo "$FIXDIR/doctor-unhealthy.json"
}
status_json() { # $1=path $2=missing
  cat > "$1" <<JSON
{"missing_embeddings":$2,"stale_vs_target":{"stale":$2}}
JSON
  echo "$1"
}
sources_json() { # $1=path -- one source with a local_path, one without
  cat > "$1" <<JSON
{"sources":[{"id":"src-a","local_path":"/tmp/does-not-need-to-exist-a"},{"id":"src-b","local_path":null}]}
JSON
  echo "$1"
}
sources_empty() {
  cat > "$FIXDIR/sources-empty.json" <<'JSON'
{"sources":[]}
JSON
  echo "$FIXDIR/sources-empty.json"
}

run() {
  local capfile="$1"; shift
  local statedir="$1"; shift
  GBRAIN_STUB_CAPTURE="$capfile" GBRAIN_HEAL_STATE_DIR="$statedir" bash "$SCRIPT" "$@"
}

# ── 1. check: healthy -> exit 0 ─────────────────────────────────────────────
CAP1="$(mktemp -u)"; : > "$CAP1"
STATE1="$(mktemp -d)"
GBRAIN_STUB_DOCTOR_SEQ="$(doctor_healthy)"
export GBRAIN_STUB_DOCTOR_SEQ
GBRAIN_STUB_STATUS_SEQ="$(status_json "$FIXDIR/status-0.json" 0)"
export GBRAIN_STUB_STATUS_SEQ
out1="$(run "$CAP1" "$STATE1" --check 2>&1)"; rc1=$?
ok "check-healthy-exit-code" "$rc1" "0"
contains "check-healthy-line" "$out1" "gbrain-heal: healthy"
unset GBRAIN_STUB_DOCTOR_SEQ GBRAIN_STUB_STATUS_SEQ
rm -rf "$STATE1"

# ── 2. check: unhealthy (doctor FAIL) -> exit 1 ─────────────────────────────
CAP2="$(mktemp -u)"; : > "$CAP2"
STATE2="$(mktemp -d)"
GBRAIN_STUB_DOCTOR_SEQ="$(doctor_unhealthy)"
export GBRAIN_STUB_DOCTOR_SEQ
GBRAIN_STUB_STATUS_SEQ="$(status_json "$FIXDIR/status-1.json" 500)"
export GBRAIN_STUB_STATUS_SEQ
out2="$(run "$CAP2" "$STATE2" --check --json 2>&1)"; rc2=$?
ok "check-unhealthy-exit-code" "$rc2" "1"
contains "check-unhealthy-json" "$out2" '"healthy": false'
contains "check-unhealthy-fail-count" "$out2" '"doctor_fail_count": 2'
unset GBRAIN_STUB_DOCTOR_SEQ GBRAIN_STUB_STATUS_SEQ
rm -rf "$STATE2"

# ── 3. apply: dry-run executes nothing ──────────────────────────────────────
CAP3="$(mktemp -u)"; : > "$CAP3"
STATE3="$(mktemp -d)"
out3="$(run "$CAP3" "$STATE3" --apply --dry-run 2>&1)"; rc3=$?
ok "dry-run-exit-code" "$rc3" "0"
ok "dry-run-no-gbrain-calls" "$(wc -l < "$CAP3" | tr -d ' ')" "0"
contains "dry-run-prints-plan" "$out3" "DRY-RUN"
rm -rf "$STATE3"

# ── 4. apply: order of phases (sync -> embed -> extract -> cycle -> recheck) ─
CAP4="$(mktemp -u)"; : > "$CAP4"
STATE4="$(mktemp -d)"
GBRAIN_STUB_DOCTOR_SEQ="$(doctor_healthy)"
export GBRAIN_STUB_DOCTOR_SEQ
GBRAIN_STUB_STATUS_SEQ="$(status_json "$FIXDIR/status-order.json" 0)"
export GBRAIN_STUB_STATUS_SEQ
GBRAIN_STUB_SOURCES_SEQ="$(sources_json "$FIXDIR/sources-order.json")"
export GBRAIN_STUB_SOURCES_SEQ
run "$CAP4" "$STATE4" --apply --embed-budget 30 >/dev/null 2>&1; rc4=$?
ok "apply-order-exit-code" "$rc4" "0"
cap4txt="$(cat "$CAP4")"
contains "apply-order-has-sync" "$cap4txt" "CALL: sync"
contains "apply-order-has-embed" "$cap4txt" "CALL: embed"
contains "apply-order-has-extract" "$cap4txt" "CALL: extract"
contains "apply-order-has-dream-src-a" "$cap4txt" "CALL: dream --source src-a"
not_contains "apply-order-skips-src-b" "$cap4txt" "--source src-b"
before "$cap4txt" "CALL: sync" "CALL: embed"
before "$cap4txt" "CALL: embed" "CALL: extract"
before "$cap4txt" "CALL: extract" "CALL: dream --source src-a"
before "$cap4txt" "CALL: dream --source src-a" "CALL: doctor"
unset GBRAIN_STUB_DOCTOR_SEQ GBRAIN_STUB_STATUS_SEQ GBRAIN_STUB_SOURCES_SEQ
rm -rf "$STATE4"

# ── 5. apply: tuned env exported, pre-set value NOT overridden ──────────────
CAP5="$(mktemp -u)"; : > "$CAP5"
STATE5="$(mktemp -d)"
GBRAIN_STUB_DOCTOR_SEQ="$(doctor_healthy)"
export GBRAIN_STUB_DOCTOR_SEQ
GBRAIN_STUB_STATUS_SEQ="$(status_json "$FIXDIR/status-env.json" 0)"
export GBRAIN_STUB_STATUS_SEQ
GBRAIN_STUB_SOURCES_SEQ="$(sources_empty)"
export GBRAIN_STUB_SOURCES_SEQ
export GBRAIN_EMBED_MAX_BATCH_TOKENS=9999
unset GBRAIN_AI_EMBED_TIMEOUT_MS 2>/dev/null || true
run "$CAP5" "$STATE5" --apply --embed-budget 30 >/dev/null 2>&1; rc5=$?
ok "apply-env-exit-code" "$rc5" "0"
cap5txt="$(cat "$CAP5")"
contains "apply-env-preserves-preset-batch" "$cap5txt" "ENV_BATCH=9999"
not_contains "apply-env-does-not-force-default-batch" "$cap5txt" "ENV_BATCH=4096"
contains "apply-env-applies-default-timeout" "$cap5txt" "ENV_TIMEOUT=180000"
unset GBRAIN_STUB_DOCTOR_SEQ GBRAIN_STUB_STATUS_SEQ GBRAIN_STUB_SOURCES_SEQ GBRAIN_EMBED_MAX_BATCH_TOKENS
rm -rf "$STATE5"

# ── 6. apply: lock held -> exit 0, no-op ────────────────────────────────────
CAP6="$(mktemp -u)"; : > "$CAP6"
STATE6="$(mktemp -d)"
mkdir -p "$STATE6"
exec 8>"$STATE6/.lock"
flock -n 8 || { echo "FAIL: test setup could not acquire its own lock"; fail=$((fail+1)); }
out6="$(run "$CAP6" "$STATE6" --apply 2>&1)"; rc6=$?
flock -u 8; exec 8>&-
ok "lock-held-exit-code" "$rc6" "0"
ok "lock-held-no-gbrain-calls" "$(wc -l < "$CAP6" | tr -d ' ')" "0"
contains "lock-held-message" "$out6" "another --apply run holds"
rm -rf "$STATE6"

# ── 7. apply: stall (backlog>0, zero progress) -> non-zero ──────────────────
CAP7="$(mktemp -u)"; : > "$CAP7"
STATE7="$(mktemp -d)"
GBRAIN_STUB_DOCTOR_SEQ="$(doctor_healthy)"
export GBRAIN_STUB_DOCTOR_SEQ
status_json "$FIXDIR/status-stall-1.json" 100 >/dev/null
status_json "$FIXDIR/status-stall-2.json" 100 >/dev/null
status_json "$FIXDIR/status-stall-3.json" 100 >/dev/null
export GBRAIN_STUB_STATUS_SEQ="$FIXDIR/status-stall-1.json:$FIXDIR/status-stall-2.json:$FIXDIR/status-stall-3.json"
GBRAIN_STUB_SOURCES_SEQ="$(sources_empty)"
export GBRAIN_STUB_SOURCES_SEQ
export GBRAIN_STUB_EXIT_EMBED=0
out7="$(run "$CAP7" "$STATE7" --apply --embed-budget 30 2>&1)"; rc7=$?
ok "stall-exit-code-nonzero" "$([ "$rc7" -ne 0 ] && echo yes || echo no)" "yes"
contains "stall-message" "$out7" "STALLED"
# Perturbation: same fixture but status shows progress -- must now report ok.
export GBRAIN_STUB_STATUS_SEQ="$FIXDIR/status-stall-1.json:$FIXDIR/status-stall-3.json:$FIXDIR/status-stall-3.json"
status_json "$FIXDIR/status-stall-3.json" 10 >/dev/null
CAP7B="$(mktemp -u)"; : > "$CAP7B"
STATE7B="$(mktemp -d)"
out7b="$(run "$CAP7B" "$STATE7B" --apply --embed-budget 30 2>&1)"; rc7b=$?
ok "stall-perturbation-exit-code" "$rc7b" "0"
not_contains "stall-perturbation-no-stall-message" "$out7b" "STALLED"
unset GBRAIN_STUB_DOCTOR_SEQ GBRAIN_STUB_STATUS_SEQ GBRAIN_STUB_SOURCES_SEQ GBRAIN_STUB_EXIT_EMBED
rm -rf "$STATE7" "$STATE7B"

# ── 8. apply: embed timeout WITH progress -> 0 (not a failure) ──────────────
CAP8="$(mktemp -u)"; : > "$CAP8"
STATE8="$(mktemp -d)"
GBRAIN_STUB_DOCTOR_SEQ="$(doctor_healthy)"
export GBRAIN_STUB_DOCTOR_SEQ
status_json "$FIXDIR/status-to-1.json" 1000 >/dev/null
status_json "$FIXDIR/status-to-2.json" 400 >/dev/null
export GBRAIN_STUB_STATUS_SEQ="$FIXDIR/status-to-1.json:$FIXDIR/status-to-2.json:$FIXDIR/status-to-2.json"
GBRAIN_STUB_SOURCES_SEQ="$(sources_empty)"
export GBRAIN_STUB_SOURCES_SEQ
export GBRAIN_STUB_EMBED_SLEEP=3
out8="$(run "$CAP8" "$STATE8" --apply --embed-budget 1 --json 2>&1)"; rc8=$?
ok "embed-timeout-progress-exit-code" "$rc8" "0"
contains "embed-timeout-progress-status" "$out8" '"embed": {"status": "timeout-partial"'
unset GBRAIN_STUB_DOCTOR_SEQ GBRAIN_STUB_STATUS_SEQ GBRAIN_STUB_SOURCES_SEQ GBRAIN_STUB_EMBED_SLEEP
rm -rf "$STATE8"

rm -rf "$STUBDIR" "$FIXDIR"

echo "gbrain-heal: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
