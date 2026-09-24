#!/usr/bin/env bash
# Plain-bash assertions for gbrain-heal.sh. No external test framework, no
# real gbrain binary or brain -- see tests/test-gbrain-sync-memory.sh for the
# repo's style this follows.
#
# The stub `gbrain` (installed via GBRAIN_BIN, per SPEC-gbrain-heal.md) records
# every invocation's argv AND the three tuned embed env vars to a capture file,
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
  printf '  ENV_STALL=%s\n' "${GBRAIN_EMBED_STALL_ABORT_SECONDS-<unset>}"
  printf '  ENV_TIME_BUDGET=%s\n' "${GBRAIN_EMBED_TIME_BUDGET_MS-<unset>}"
  if [ "${GBRAIN_STUB_CHECK_FD9:-0}" = "1" ] && [ -n "${GBRAIN_STUB_FD9_MARKER:-}" ]; then
    if [ -e /proc/self/fd/9 ]; then
      echo "FD9_OPEN" > "$GBRAIN_STUB_FD9_MARKER"
    else
      echo "FD9_CLOSED" > "$GBRAIN_STUB_FD9_MARKER"
    fi
  fi
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
  doctor)
    emit_json doctor
    # Item 8 regression guard: prove capture_stdout_only() actually separates
    # streams -- this stray line (which itself looks like it could corrupt a
    # naive "everything after the first {" stdout+stderr merge) must never
    # reach the JSON parse; it may only ever show up in a logged stderr line.
    if [ -n "${GBRAIN_STUB_STDERR_TRAP:-}" ]; then
      echo "$GBRAIN_STUB_STDERR_TRAP" >&2
    fi
    ;;
  migrate) [ "$sub" = "embeddings" ] && emit_json status ;;
  sources) [ "$sub" = "list" ] && emit_json sources ;;
  sync)
    sleep "${GBRAIN_STUB_SYNC_SLEEP:-0}"
    if [ "${GBRAIN_STUB_SYNC_LOCKBUSY:-0}" = "1" ]; then
      # Verbatim substring from gbrain's own sync-lock.ts:formatLockBusyMessage,
      # as printed by sync.ts's per-source catch: "Error syncing <name>: <msg>".
      # `sync --all` classifies this as a per-source status:'error' (no special
      # case), so the whole invocation exits 1 -- same as any other error.
      echo 'Error syncing testsrc: Another sync is in progress (lock gbrain-sync:testsrc held by pid 999 on host, started 2m ago).'
      exit 1
    fi
    exit "${GBRAIN_STUB_EXIT_SYNC:-0}" ;;
  embed)
    sleep "${GBRAIN_STUB_EMBED_SLEEP:-0}"
    if [ "${GBRAIN_STUB_EMBED_STALL_MSG:-0}" = "1" ]; then
      # Verbatim substring from gbrain's own
      # src/commands/embed.ts:runEmbed on a stall-watchdog self-abort
      # (gbrain's internal watchdog firing, NOT killed by our `timeout`).
      echo "[embed] exiting non-zero: stall watchdog aborted the drain (reason: stall_timeout); partial progress banked -- re-run to resume."
    fi
    if [ "${GBRAIN_STUB_EMBED_WALLCLOCK_MSG:-0}" = "1" ]; then
      # Verbatim substring from src/commands/embed.ts's independent soft
      # wall-clock cap (GBRAIN_EMBED_TIME_BUDGET_MS), distinct from the stall
      # watchdog above -- also exits cleanly (rc depends on caller state).
      echo "  [embed] wall-clock budget (1800000ms) exceeded; exiting cleanly. Re-run picks up via partial index."
    fi
    if [ "${GBRAIN_STUB_EMBED_LOCKBUSY:-0}" = "1" ]; then
      # Verbatim substring from src/commands/embed.ts:~496 -- gbrain itself
      # returns this result normally (exit 0), never a stall/failure.
      echo '  [embed] another backfill is already running for source "testsrc"; skipping (single-flight).'
      exit 0
    fi
    if [ -n "${GBRAIN_STUB_EMBED_CHUNKFAIL_N:-}" ]; then
      # Verbatim substring from src/commands/embed.ts's runEmbed; cli.ts's
      # setCliExitVerdict(1) on EmbedResult.failures>0 drives the non-zero rc.
      echo "[embed] ${GBRAIN_STUB_EMBED_CHUNKFAIL_N} chunk(s) failed to embed. First error: boom"
    fi
    exit "${GBRAIN_STUB_EXIT_EMBED:-0}" ;;
  extract) sleep "${GBRAIN_STUB_EXTRACT_SLEEP:-0}"; exit "${GBRAIN_STUB_EXIT_EXTRACT:-0}" ;;
  dream)
    id="${3:-}"
    if [ -n "${GBRAIN_STUB_DREAM_SKIP_IDS:-}" ]; then
      case ":${GBRAIN_STUB_DREAM_SKIP_IDS}:" in
        *":$id:"*)
          # cycle.ts's {status:'skipped', reason:'cycle_already_running'} JSON
          # report shape (what --json actually prints) -- gbrain exits 0 for
          # any 'skipped' report; only status:'failed' exits 1.
          echo '{"status": "skipped", "reason": "cycle_already_running"}'
          exit 0 ;;
      esac
    fi
    exit "${GBRAIN_STUB_EXIT_DREAM:-0}" ;;
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
status_json() { # $1=path $2=missing $3=marker_kind (default "none")
  local marker="${3:-none}"
  cat > "$1" <<JSON
{"missing_embeddings":$2,"stale_vs_target":{"stale":$2},"marker":{"kind":"$marker"}}
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
contains "check-unhealthy-json" "$out2" '"state": "unhealthy"'
contains "check-unhealthy-exit-ok-false" "$out2" '"exit_ok": false'
contains "check-unhealthy-fail-count" "$out2" '"doctor_fail_count": 2'
unset GBRAIN_STUB_DOCTOR_SEQ GBRAIN_STUB_STATUS_SEQ
rm -rf "$STATE2"

# ── 2b. check: draining (0 doctor FAILs, but embedding backlog) -> exit 0 ───
CAP2B="$(mktemp -u)"; : > "$CAP2B"
STATE2B="$(mktemp -d)"
GBRAIN_STUB_DOCTOR_SEQ="$(doctor_healthy)"
export GBRAIN_STUB_DOCTOR_SEQ
GBRAIN_STUB_STATUS_SEQ="$(status_json "$FIXDIR/status-draining.json" 500)"
export GBRAIN_STUB_STATUS_SEQ
out2b="$(run "$CAP2B" "$STATE2B" --check --json 2>&1)"; rc2b=$?
ok "check-draining-exit-code" "$rc2b" "0"
contains "check-draining-state" "$out2b" '"state": "draining"'
contains "check-draining-exit-ok-true" "$out2b" '"exit_ok": true'
rm -rf "$STATE2B"

# ── 2c. check --strict: the SAME draining fixture now exits 1 ──────────────
CAP2C="$(mktemp -u)"; : > "$CAP2C"
STATE2C="$(mktemp -d)"
out2c="$(run "$CAP2C" "$STATE2C" --check --json --strict 2>&1)"; rc2c=$?
ok "check-draining-strict-exit-code" "$rc2c" "1"
contains "check-draining-strict-state-still-draining" "$out2c" '"state": "draining"'
contains "check-draining-strict-exit-ok-false" "$out2c" '"exit_ok": false'
contains "check-draining-strict-flag-recorded" "$out2c" '"strict": true'
unset GBRAIN_STUB_DOCTOR_SEQ GBRAIN_STUB_STATUS_SEQ
rm -rf "$STATE2C"

# ── 2d. check --strict: an in-flight migration marker also fails strict,
#       even with missing==0 && stale==0 (server-health-audit.sh:97 parity) ─
CAP2D="$(mktemp -u)"; : > "$CAP2D"
STATE2D="$(mktemp -d)"
GBRAIN_STUB_DOCTOR_SEQ="$(doctor_healthy)"
export GBRAIN_STUB_DOCTOR_SEQ
GBRAIN_STUB_STATUS_SEQ="$(status_json "$FIXDIR/status-marker.json" 0 in_progress)"
export GBRAIN_STUB_STATUS_SEQ
run "$CAP2D" "$STATE2D" --check --json >/dev/null 2>&1; rc2d_nonstrict=$?
ok "check-marker-nonstrict-still-healthy" "$rc2d_nonstrict" "0"
CAP2D2="$(mktemp -u)"; : > "$CAP2D2"
STATE2D2="$(mktemp -d)"
out2d_strict="$(run "$CAP2D2" "$STATE2D2" --check --json --strict 2>&1)"; rc2d_strict=$?
ok "check-marker-strict-exit-code" "$rc2d_strict" "1"
contains "check-marker-strict-state-still-healthy" "$out2d_strict" '"state": "healthy"'
contains "check-marker-strict-exit-ok-false" "$out2d_strict" '"exit_ok": false'
unset GBRAIN_STUB_DOCTOR_SEQ GBRAIN_STUB_STATUS_SEQ
rm -rf "$STATE2D" "$STATE2D2"

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
contains "apply-env-applies-default-stall" "$cap5txt" "ENV_STALL=3600"
unset GBRAIN_STUB_DOCTOR_SEQ GBRAIN_STUB_STATUS_SEQ GBRAIN_STUB_SOURCES_SEQ GBRAIN_EMBED_MAX_BATCH_TOKENS
rm -rf "$STATE5"

# ── 5b. apply: pre-set GBRAIN_EMBED_STALL_ABORT_SECONDS is NOT overridden ───
CAP5B="$(mktemp -u)"; : > "$CAP5B"
STATE5B="$(mktemp -d)"
GBRAIN_STUB_DOCTOR_SEQ="$(doctor_healthy)"
export GBRAIN_STUB_DOCTOR_SEQ
GBRAIN_STUB_STATUS_SEQ="$(status_json "$FIXDIR/status-env-stall.json" 0)"
export GBRAIN_STUB_STATUS_SEQ
GBRAIN_STUB_SOURCES_SEQ="$(sources_empty)"
export GBRAIN_STUB_SOURCES_SEQ
export GBRAIN_EMBED_STALL_ABORT_SECONDS=120
run "$CAP5B" "$STATE5B" --apply --embed-budget 30 >/dev/null 2>&1; rc5b=$?
ok "apply-env-stall-preset-exit-code" "$rc5b" "0"
cap5btxt="$(cat "$CAP5B")"
contains "apply-env-stall-preserves-preset" "$cap5btxt" "ENV_STALL=120"
not_contains "apply-env-stall-does-not-force-default" "$cap5btxt" "ENV_STALL=3600"
unset GBRAIN_STUB_DOCTOR_SEQ GBRAIN_STUB_STATUS_SEQ GBRAIN_STUB_SOURCES_SEQ GBRAIN_EMBED_STALL_ABORT_SECONDS
rm -rf "$STATE5B"

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
# Item 5 (adversarial review): name the holder's PID via fuser when available
# -- this test's own shell holds the lock (exec 8>...), so fuser should find
# this process's PID. Skip gracefully (still a pass) where fuser isn't
# installed, matching the script's own `command -v fuser` degrade path.
if command -v fuser >/dev/null 2>&1; then
  contains "lock-held-names-holder-pid" "$out6" "pid(s):"
else
  pass=$((pass+1))
fi
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

# ── 7c. apply: gbrain's OWN stall watchdog self-aborts (non-zero rc, NOT our
#       `timeout`'s rc=124) with ZERO progress -> stalled, non-zero. This is
#       the exact new-root-cause case: a stall-shaped exit that isn't rc=124
#       must not be misread as an unconditional hard failure. ────────────────
CAP7C="$(mktemp -u)"; : > "$CAP7C"
STATE7C="$(mktemp -d)"
GBRAIN_STUB_DOCTOR_SEQ="$(doctor_healthy)"
export GBRAIN_STUB_DOCTOR_SEQ
status_json "$FIXDIR/status-wd-1.json" 200 >/dev/null
status_json "$FIXDIR/status-wd-2.json" 200 >/dev/null
export GBRAIN_STUB_STATUS_SEQ="$FIXDIR/status-wd-1.json:$FIXDIR/status-wd-2.json:$FIXDIR/status-wd-2.json"
GBRAIN_STUB_SOURCES_SEQ="$(sources_empty)"
export GBRAIN_STUB_SOURCES_SEQ
export GBRAIN_STUB_EXIT_EMBED=1
export GBRAIN_STUB_EMBED_STALL_MSG=1
out7c="$(run "$CAP7C" "$STATE7C" --apply --embed-budget 30 2>&1)"; rc7c=$?
ok "watchdog-stall-exit-code-nonzero" "$([ "$rc7c" -ne 0 ] && echo yes || echo no)" "yes"
contains "watchdog-stall-message" "$out7c" "STALLED"
unset GBRAIN_STUB_DOCTOR_SEQ GBRAIN_STUB_STATUS_SEQ GBRAIN_STUB_SOURCES_SEQ GBRAIN_STUB_EXIT_EMBED GBRAIN_STUB_EMBED_STALL_MSG
rm -rf "$STATE7C"

# ── 7d. apply: gbrain's own stall watchdog self-aborts but DID make progress
#       -> partial, exit 0 (not a failure) ──────────────────────────────────
CAP7D="$(mktemp -u)"; : > "$CAP7D"
STATE7D="$(mktemp -d)"
GBRAIN_STUB_DOCTOR_SEQ="$(doctor_healthy)"
export GBRAIN_STUB_DOCTOR_SEQ
status_json "$FIXDIR/status-wd-progress-1.json" 1000 >/dev/null
status_json "$FIXDIR/status-wd-progress-2.json" 300 >/dev/null
export GBRAIN_STUB_STATUS_SEQ="$FIXDIR/status-wd-progress-1.json:$FIXDIR/status-wd-progress-2.json:$FIXDIR/status-wd-progress-2.json"
GBRAIN_STUB_SOURCES_SEQ="$(sources_empty)"
export GBRAIN_STUB_SOURCES_SEQ
export GBRAIN_STUB_EXIT_EMBED=1
export GBRAIN_STUB_EMBED_STALL_MSG=1
out7d="$(run "$CAP7D" "$STATE7D" --apply --embed-budget 30 --json 2>&1)"; rc7d=$?
ok "watchdog-stall-progress-exit-code" "$rc7d" "0"
not_contains "watchdog-stall-progress-no-stalled-message" "$out7d" "STALLED"
contains "watchdog-stall-progress-status" "$out7d" '"embed": {"status": "timeout-partial"'
unset GBRAIN_STUB_DOCTOR_SEQ GBRAIN_STUB_STATUS_SEQ GBRAIN_STUB_SOURCES_SEQ GBRAIN_STUB_EXIT_EMBED GBRAIN_STUB_EMBED_STALL_MSG
rm -rf "$STATE7D"

# ── 7e. apply: a GENUINE embed hard failure (non-zero rc, no stall message)
#       is still reported as a real failure, not silently downgraded ───────
CAP7E="$(mktemp -u)"; : > "$CAP7E"
STATE7E="$(mktemp -d)"
GBRAIN_STUB_DOCTOR_SEQ="$(doctor_healthy)"
export GBRAIN_STUB_DOCTOR_SEQ
GBRAIN_STUB_STATUS_SEQ="$(status_json "$FIXDIR/status-hardfail.json" 50)"
export GBRAIN_STUB_STATUS_SEQ
GBRAIN_STUB_SOURCES_SEQ="$(sources_empty)"
export GBRAIN_STUB_SOURCES_SEQ
export GBRAIN_STUB_EXIT_EMBED=1
out7e="$(run "$CAP7E" "$STATE7E" --apply --embed-budget 30 --json 2>&1)"; rc7e=$?
ok "genuine-embed-failure-exit-code-nonzero" "$([ "$rc7e" -ne 0 ] && echo yes || echo no)" "yes"
contains "genuine-embed-failure-status" "$out7e" '"embed": {"status": "failed(rc=1)"'
not_contains "genuine-embed-failure-not-mislabeled-stalled" "$out7e" '"status": "stalled"'
unset GBRAIN_STUB_DOCTOR_SEQ GBRAIN_STUB_STATUS_SEQ GBRAIN_STUB_SOURCES_SEQ GBRAIN_STUB_EXIT_EMBED
rm -rf "$STATE7E"

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

# ── 9. apply: embed single-flight lock held by another process -> skipped
#       (lock-held), non-fatal, exit 0 (item 1, BLOCKER). NOTE: this is the
#       exact path a real long transient drain (e.g.
#       gbrain-backlog-drain-0924b) hits on the timer's first fire. ─────────
CAP9="$(mktemp -u)"; : > "$CAP9"
STATE9="$(mktemp -d)"
GBRAIN_STUB_DOCTOR_SEQ="$(doctor_healthy)"
export GBRAIN_STUB_DOCTOR_SEQ
GBRAIN_STUB_STATUS_SEQ="$(status_json "$FIXDIR/status-embed-lockbusy.json" 500)"
export GBRAIN_STUB_STATUS_SEQ
GBRAIN_STUB_SOURCES_SEQ="$(sources_empty)"
export GBRAIN_STUB_SOURCES_SEQ
export GBRAIN_STUB_EMBED_LOCKBUSY=1
out9="$(run "$CAP9" "$STATE9" --apply --embed-budget 30 --json 2>&1)"; rc9=$?
ok "embed-lockbusy-exit-code" "$rc9" "0"
contains "embed-lockbusy-status" "$out9" '"embed": {"status": "skipped(lock-held)"'
not_contains "embed-lockbusy-not-stalled" "$out9" '"status": "stalled"'
unset GBRAIN_STUB_DOCTOR_SEQ GBRAIN_STUB_STATUS_SEQ GBRAIN_STUB_SOURCES_SEQ GBRAIN_STUB_EMBED_LOCKBUSY
rm -rf "$STATE9"

# ── 10. apply: sync lock busy (SyncLockBusyError) -> skipped(lock-held),
#        non-fatal, exit 0 (item 4). gbrain's own `sync --all` has no special
#        case for this -- it's a generic per-source error (rc=1) -- so this
#        reclassification happens entirely in gbrain-heal. ─────────────────
CAP10="$(mktemp -u)"; : > "$CAP10"
STATE10="$(mktemp -d)"
GBRAIN_STUB_DOCTOR_SEQ="$(doctor_healthy)"
export GBRAIN_STUB_DOCTOR_SEQ
GBRAIN_STUB_STATUS_SEQ="$(status_json "$FIXDIR/status-sync-lockbusy.json" 0)"
export GBRAIN_STUB_STATUS_SEQ
GBRAIN_STUB_SOURCES_SEQ="$(sources_empty)"
export GBRAIN_STUB_SOURCES_SEQ
export GBRAIN_STUB_SYNC_LOCKBUSY=1
out10="$(run "$CAP10" "$STATE10" --apply --embed-budget 30 --json 2>&1)"; rc10=$?
ok "sync-lockbusy-exit-code" "$rc10" "0"
contains "sync-lockbusy-status" "$out10" '"sync": {"status": "skipped(lock-held)"'
unset GBRAIN_STUB_DOCTOR_SEQ GBRAIN_STUB_STATUS_SEQ GBRAIN_STUB_SOURCES_SEQ GBRAIN_STUB_SYNC_LOCKBUSY
rm -rf "$STATE10"

# ── 11. apply: extract budget exhausted (real rc=124 via a real `timeout`,
#        real SIGTERM) -> timeout-partial, non-fatal, exit 0 (item 2: extract
#        stamps progress per batch via stampExtracted()/
#        markPagesExtractedBatch(), so a kill mid-run only loses the current
#        small batch and resumes from the watermark). Sync's OWN timeout
#        stays fatal ("timeout", counted against APPLY_RC) -- unchanged --
#        proving the two phases are genuinely independently configured, not
#        both accidentally flipped non-fatal.
#        GBRAIN_HEAL_EXTRACT_TIMEOUT_S / _SYNC_TIMEOUT_S are test-only
#        internal overrides (see the script's call-site comment) so this
#        stays fast and deterministic instead of waiting out the real 1800s. ─
CAP11="$(mktemp -u)"; : > "$CAP11"
STATE11="$(mktemp -d)"
GBRAIN_STUB_DOCTOR_SEQ="$(doctor_healthy)"
export GBRAIN_STUB_DOCTOR_SEQ
GBRAIN_STUB_STATUS_SEQ="$(status_json "$FIXDIR/status-extract-timeout.json" 0)"
export GBRAIN_STUB_STATUS_SEQ
GBRAIN_STUB_SOURCES_SEQ="$(sources_empty)"
export GBRAIN_STUB_SOURCES_SEQ
export GBRAIN_HEAL_EXTRACT_TIMEOUT_S=1
export GBRAIN_STUB_EXTRACT_SLEEP=3
out11="$(run "$CAP11" "$STATE11" --apply --embed-budget 30 --json 2>&1)"; rc11=$?
ok "extract-timeout-partial-exit-code" "$rc11" "0"
contains "extract-timeout-partial-status" "$out11" '"extract": {"status": "timeout-partial"'
unset GBRAIN_HEAL_EXTRACT_TIMEOUT_S GBRAIN_STUB_EXTRACT_SLEEP
rm -rf "$STATE11"

# ── 11b. apply: sync's rc=124 timeout is still FATAL ("timeout", counted
#         against APPLY_RC) -- unchanged from before this round, confirming
#         extract's new non-fatal timeout is genuinely per-phase, not global. ─
CAP11B="$(mktemp -u)"; : > "$CAP11B"
STATE11B="$(mktemp -d)"
export GBRAIN_HEAL_SYNC_TIMEOUT_S=1
export GBRAIN_STUB_SYNC_SLEEP=3
out11b="$(run "$CAP11B" "$STATE11B" --apply --embed-budget 30 --json 2>&1)"; rc11b=$?
ok "sync-timeout-fatal-exit-code-nonzero" "$([ "$rc11b" -ne 0 ] && echo yes || echo no)" "yes"
contains "sync-timeout-fatal-status" "$out11b" '"sync": {"status": "timeout"'
unset GBRAIN_HEAL_SYNC_TIMEOUT_S GBRAIN_STUB_SYNC_SLEEP
unset GBRAIN_STUB_DOCTOR_SEQ GBRAIN_STUB_STATUS_SEQ GBRAIN_STUB_SOURCES_SEQ
rm -rf "$STATE11B"

# ── 12. apply: embed chunk-level failures WITH progress -> partial
#        (chunk-failures=N), non-fatal, exit 0; failure count surfaced in the
#        summary (item 3). ──────────────────────────────────────────────────
CAP12="$(mktemp -u)"; : > "$CAP12"
STATE12="$(mktemp -d)"
GBRAIN_STUB_DOCTOR_SEQ="$(doctor_healthy)"
export GBRAIN_STUB_DOCTOR_SEQ
status_json "$FIXDIR/status-cf-1.json" 1000 >/dev/null
status_json "$FIXDIR/status-cf-2.json" 700 >/dev/null
export GBRAIN_STUB_STATUS_SEQ="$FIXDIR/status-cf-1.json:$FIXDIR/status-cf-2.json:$FIXDIR/status-cf-2.json"
GBRAIN_STUB_SOURCES_SEQ="$(sources_empty)"
export GBRAIN_STUB_SOURCES_SEQ
export GBRAIN_STUB_EXIT_EMBED=1
export GBRAIN_STUB_EMBED_CHUNKFAIL_N=7
out12="$(run "$CAP12" "$STATE12" --apply --embed-budget 30 --json 2>&1)"; rc12=$?
ok "chunk-failures-progress-exit-code" "$rc12" "0"
contains "chunk-failures-progress-status" "$out12" '"embed": {"status": "partial(chunk-failures=7)"'
unset GBRAIN_STUB_STATUS_SEQ
# Perturbation: same chunk-failure count, but ZERO progress -- item 3 says
# "fail only on zero progress"; must now report stalled and exit non-zero.
status_json "$FIXDIR/status-cf-3.json" 1000 >/dev/null
export GBRAIN_STUB_STATUS_SEQ="$FIXDIR/status-cf-1.json:$FIXDIR/status-cf-3.json:$FIXDIR/status-cf-3.json"
CAP12B="$(mktemp -u)"; : > "$CAP12B"
STATE12B="$(mktemp -d)"
out12b="$(run "$CAP12B" "$STATE12B" --apply --embed-budget 30 --json 2>&1)"; rc12b=$?
ok "chunk-failures-no-progress-exit-code-nonzero" "$([ "$rc12b" -ne 0 ] && echo yes || echo no)" "yes"
contains "chunk-failures-no-progress-stalled" "$out12b" '"embed": {"status": "stalled"'
unset GBRAIN_STUB_DOCTOR_SEQ GBRAIN_STUB_STATUS_SEQ GBRAIN_STUB_SOURCES_SEQ GBRAIN_STUB_EXIT_EMBED GBRAIN_STUB_EMBED_CHUNKFAIL_N
rm -rf "$STATE12" "$STATE12B"

# ── 13. apply: the single-flight lock fd is closed in phase subprocesses
#        (item 5) -- otherwise an orphaned straggler child inherits it and
#        can hold the heal lock open indefinitely. ──────────────────────────
CAP13="$(mktemp -u)"; : > "$CAP13"
STATE13="$(mktemp -d)"
FD9MARKER="$(mktemp -u)"
GBRAIN_STUB_DOCTOR_SEQ="$(doctor_healthy)"
export GBRAIN_STUB_DOCTOR_SEQ
GBRAIN_STUB_STATUS_SEQ="$(status_json "$FIXDIR/status-fd9.json" 0)"
export GBRAIN_STUB_STATUS_SEQ
GBRAIN_STUB_SOURCES_SEQ="$(sources_empty)"
export GBRAIN_STUB_SOURCES_SEQ
export GBRAIN_STUB_CHECK_FD9=1
export GBRAIN_STUB_FD9_MARKER="$FD9MARKER"
run "$CAP13" "$STATE13" --apply --embed-budget 30 >/dev/null 2>&1
ok "fd9-closed-in-child" "$(cat "$FD9MARKER" 2>/dev/null)" "FD9_CLOSED"
unset GBRAIN_STUB_DOCTOR_SEQ GBRAIN_STUB_STATUS_SEQ GBRAIN_STUB_SOURCES_SEQ GBRAIN_STUB_CHECK_FD9 GBRAIN_STUB_FD9_MARKER
rm -rf "$STATE13" "$FD9MARKER"

# ── 14. gbrain-http (item 6): --check probes and reports, never restarts;
#        --apply self-heals (restarts) when not responding, and the run is
#        never blocked by it either way. curl/systemctl are PATH-shadowed
#        (they aren't gbrain, so GBRAIN_BIN can't intercept them). ─────────
HTTPSTUBDIR="$(mktemp -d)"
cat > "$HTTPSTUBDIR/curl" <<'STUB'
#!/usr/bin/env bash
exit "${FAKE_CURL_EXIT:-0}"
STUB
cat > "$HTTPSTUBDIR/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "SYSTEMCTL_CALL: $*" >> "${FAKE_SYSTEMCTL_LOG:?}"
exit "${FAKE_SYSTEMCTL_EXIT:-0}"
STUB
chmod +x "$HTTPSTUBDIR/curl" "$HTTPSTUBDIR/systemctl"
OLDPATH="$PATH"
export PATH="$HTTPSTUBDIR:$PATH"

# 14a. --check, http down: reports not_responding, never calls systemctl.
SYSLOG14A="$(mktemp)"
CAP14A="$(mktemp -u)"; : > "$CAP14A"
STATE14A="$(mktemp -d)"
GBRAIN_STUB_DOCTOR_SEQ="$(doctor_healthy)"
export GBRAIN_STUB_DOCTOR_SEQ
GBRAIN_STUB_STATUS_SEQ="$(status_json "$FIXDIR/status-http-a.json" 0)"
export GBRAIN_STUB_STATUS_SEQ
FAKE_CURL_EXIT=1 FAKE_SYSTEMCTL_LOG="$SYSLOG14A" run "$CAP14A" "$STATE14A" --check --json > /tmp/gbrain-heal-test-out14a 2>&1
out14a="$(cat /tmp/gbrain-heal-test-out14a)"; rm -f /tmp/gbrain-heal-test-out14a
contains "http-check-down-reported" "$out14a" '"gbrain_http": "not_responding"'
ok "http-check-never-restarts" "$([ -s "$SYSLOG14A" ] && echo called || echo not-called)" "not-called"
rm -rf "$STATE14A" "$SYSLOG14A"

# 14b. --check, http up: reports ok, never calls systemctl.
SYSLOG14B="$(mktemp)"
CAP14B="$(mktemp -u)"; : > "$CAP14B"
STATE14B="$(mktemp -d)"
FAKE_CURL_EXIT=0 FAKE_SYSTEMCTL_LOG="$SYSLOG14B" run "$CAP14B" "$STATE14B" --check --json > /tmp/gbrain-heal-test-out14b 2>&1
out14b="$(cat /tmp/gbrain-heal-test-out14b)"; rm -f /tmp/gbrain-heal-test-out14b
contains "http-check-up-reported" "$out14b" '"gbrain_http": "ok"'
ok "http-check-up-never-restarts" "$([ -s "$SYSLOG14B" ] && echo called || echo not-called)" "not-called"
rm -rf "$STATE14B" "$SYSLOG14B"

# 14c. --apply, http down throughout: self-heal restart IS attempted, and the
#      run still completes normally -- the preflight never blocks phases.
SYSLOG14C="$(mktemp)"
CAP14C="$(mktemp -u)"; : > "$CAP14C"
STATE14C="$(mktemp -d)"
GBRAIN_STUB_SOURCES_SEQ="$(sources_empty)"
export GBRAIN_STUB_SOURCES_SEQ
FAKE_CURL_EXIT=1 FAKE_SYSTEMCTL_LOG="$SYSLOG14C" run "$CAP14C" "$STATE14C" --apply --embed-budget 30 --json > /tmp/gbrain-heal-test-out14c 2>&1
rc14c=$?
out14c="$(cat /tmp/gbrain-heal-test-out14c)"; rm -f /tmp/gbrain-heal-test-out14c
ok "http-apply-exit-code" "$rc14c" "0"
contains "http-apply-restart-attempted" "$(cat "$SYSLOG14C")" "restart gbrain-http.service"
contains "http-apply-phases-still-ran" "$out14c" '"sync": {"status": "ok"'
rm -rf "$STATE14C" "$SYSLOG14C"

# 14d. --apply --dry-run, http down: preflight itself must NOT run for real
#      (no restart attempted) -- dry-run means execute nothing, including this.
SYSLOG14D="$(mktemp)"
CAP14D="$(mktemp -u)"; : > "$CAP14D"
STATE14D="$(mktemp -d)"
FAKE_CURL_EXIT=1 FAKE_SYSTEMCTL_LOG="$SYSLOG14D" run "$CAP14D" "$STATE14D" --apply --dry-run > /tmp/gbrain-heal-test-out14d 2>&1
rm -f /tmp/gbrain-heal-test-out14d
ok "http-dryrun-never-restarts" "$([ -s "$SYSLOG14D" ] && echo called || echo not-called)" "not-called"
rm -rf "$STATE14D" "$SYSLOG14D"

unset GBRAIN_STUB_DOCTOR_SEQ GBRAIN_STUB_STATUS_SEQ GBRAIN_STUB_SOURCES_SEQ
export PATH="$OLDPATH"
rm -rf "$HTTPSTUBDIR"

# ── 15. apply: a per-source dream cycle hitting cycle_already_running is
#        counted as skipped, not ok (item 7). ───────────────────────────────
CAP15="$(mktemp -u)"; : > "$CAP15"
STATE15="$(mktemp -d)"
GBRAIN_STUB_DOCTOR_SEQ="$(doctor_healthy)"
export GBRAIN_STUB_DOCTOR_SEQ
GBRAIN_STUB_STATUS_SEQ="$(status_json "$FIXDIR/status-cycle-skip.json" 0)"
export GBRAIN_STUB_STATUS_SEQ
GBRAIN_STUB_SOURCES_SEQ="$(sources_json "$FIXDIR/sources-cycle-skip.json")"
export GBRAIN_STUB_SOURCES_SEQ
export GBRAIN_STUB_DREAM_SKIP_IDS="src-a"
out15="$(run "$CAP15" "$STATE15" --apply --embed-budget 30 --json 2>&1)"; rc15=$?
ok "cycle-skip-exit-code" "$rc15" "0"
contains "cycle-skip-status" "$out15" '"cycle": {"status": "ok(0 ok/1 skip)"'
unset GBRAIN_STUB_DOCTOR_SEQ GBRAIN_STUB_STATUS_SEQ GBRAIN_STUB_SOURCES_SEQ GBRAIN_STUB_DREAM_SKIP_IDS
rm -rf "$STATE15"

# ── 16. check: JSON parsing captures stdout only -- a stray stderr line
#        (even one shaped like JSON) never reaches the parse and is logged
#        separately instead of silently merged or lost (item 8). ──────────
CAP16="$(mktemp -u)"; : > "$CAP16"
STATE16="$(mktemp -d)"
GBRAIN_STUB_DOCTOR_SEQ="$(doctor_healthy)"
export GBRAIN_STUB_DOCTOR_SEQ
GBRAIN_STUB_STATUS_SEQ="$(status_json "$FIXDIR/status-trap.json" 0)"
export GBRAIN_STUB_STATUS_SEQ
export GBRAIN_STUB_STDERR_TRAP='{"trap": "would corrupt a naive stdout+stderr merge"}'
out16="$(run "$CAP16" "$STATE16" --check --json 2>&1)"; rc16=$?
ok "stderr-trap-does-not-break-parse-exit-code" "$rc16" "0"
contains "stderr-trap-clean-json" "$out16" '"state": "healthy"'
contains "stderr-trap-logged-separately" "$out16" "stderr from gbrain doctor --json"
contains "stderr-trap-content-in-log-not-json" "$out16" "would corrupt a naive stdout+stderr merge"
unset GBRAIN_STUB_DOCTOR_SEQ GBRAIN_STUB_STATUS_SEQ GBRAIN_STUB_STDERR_TRAP
rm -rf "$STATE16"

# ── 17. source guard: every real `timeout` invocation carries -k 60 (item 9)
#        -- also SIGKILL a wedged child 60s after the initial signal so it
#        can never outlive `timeout` itself. ────────────────────────────────
missing_kill_flag="$(grep -n 'timeout ' "$SCRIPT" | grep -v -- '-k 60' | grep -v '^[0-9]*:[[:space:]]*#')"
ok "every-timeout-has-kill-flag" "$missing_kill_flag" ""

# ── 18. systemd timer documents the skipped-tick behavior (item 10) ────────
TIMER_FILE="$HERE/../systemd/gbrain-heal.timer"
if [ -f "$TIMER_FILE" ]; then
  contains "timer-documents-skipped-tick" "$(cat "$TIMER_FILE")" "skip"
else
  fail=$((fail+1)); echo "FAIL: timer-file-exists — $TIMER_FILE not found"
fi

# ── 19. apply: GBRAIN_EMBED_TIME_BUDGET_MS default sizing + floor + preset
#        preservation (item 11). ────────────────────────────────────────────
CAP19="$(mktemp -u)"; : > "$CAP19"
STATE19="$(mktemp -d)"
GBRAIN_STUB_DOCTOR_SEQ="$(doctor_healthy)"
export GBRAIN_STUB_DOCTOR_SEQ
GBRAIN_STUB_STATUS_SEQ="$(status_json "$FIXDIR/status-tb-default.json" 0)"
export GBRAIN_STUB_STATUS_SEQ
GBRAIN_STUB_SOURCES_SEQ="$(sources_empty)"
export GBRAIN_STUB_SOURCES_SEQ
run "$CAP19" "$STATE19" --apply --embed-budget 7200 >/dev/null 2>&1
cap19txt="$(cat "$CAP19")"
contains "time-budget-default-7200" "$cap19txt" "ENV_TIME_BUDGET=4800000"
rm -rf "$STATE19"

# Floor: a tiny --embed-budget must not compute a negative/near-zero budget.
CAP19B="$(mktemp -u)"; : > "$CAP19B"
STATE19B="$(mktemp -d)"
run "$CAP19B" "$STATE19B" --apply --embed-budget 30 >/dev/null 2>&1
cap19btxt="$(cat "$CAP19B")"
contains "time-budget-floor-applied" "$cap19btxt" "ENV_TIME_BUDGET=600000"
rm -rf "$STATE19B"

# Pre-set value preserved, not overridden.
CAP19C="$(mktemp -u)"; : > "$CAP19C"
STATE19C="$(mktemp -d)"
export GBRAIN_EMBED_TIME_BUDGET_MS=999000
run "$CAP19C" "$STATE19C" --apply --embed-budget 7200 >/dev/null 2>&1
cap19ctxt="$(cat "$CAP19C")"
contains "time-budget-preset-preserved" "$cap19ctxt" "ENV_TIME_BUDGET=999000"
not_contains "time-budget-preset-not-defaulted" "$cap19ctxt" "ENV_TIME_BUDGET=4800000"
unset GBRAIN_EMBED_TIME_BUDGET_MS
rm -rf "$STATE19C"
unset GBRAIN_STUB_DOCTOR_SEQ GBRAIN_STUB_STATUS_SEQ GBRAIN_STUB_SOURCES_SEQ

# ── 20. apply: embed's independent wall-clock-budget exit, classified the
#        same as any other stall-shaped exit (item 11) -- progress -> partial
#        (ok); zero progress against a backlog -> stalled (fail). ──────────
CAP20="$(mktemp -u)"; : > "$CAP20"
STATE20="$(mktemp -d)"
GBRAIN_STUB_DOCTOR_SEQ="$(doctor_healthy)"
export GBRAIN_STUB_DOCTOR_SEQ
status_json "$FIXDIR/status-wc-1.json" 1000 >/dev/null
status_json "$FIXDIR/status-wc-2.json" 300 >/dev/null
export GBRAIN_STUB_STATUS_SEQ="$FIXDIR/status-wc-1.json:$FIXDIR/status-wc-2.json:$FIXDIR/status-wc-2.json"
GBRAIN_STUB_SOURCES_SEQ="$(sources_empty)"
export GBRAIN_STUB_SOURCES_SEQ
export GBRAIN_STUB_EMBED_WALLCLOCK_MSG=1
out20="$(run "$CAP20" "$STATE20" --apply --embed-budget 30 --json 2>&1)"; rc20=$?
ok "wallclock-progress-exit-code" "$rc20" "0"
contains "wallclock-progress-status" "$out20" '"embed": {"status": "timeout-partial"'
unset GBRAIN_STUB_STATUS_SEQ
# Perturbation: same wall-clock message, but zero progress -- must stall.
status_json "$FIXDIR/status-wc-3.json" 1000 >/dev/null
export GBRAIN_STUB_STATUS_SEQ="$FIXDIR/status-wc-1.json:$FIXDIR/status-wc-3.json:$FIXDIR/status-wc-3.json"
CAP20B="$(mktemp -u)"; : > "$CAP20B"
STATE20B="$(mktemp -d)"
out20b="$(run "$CAP20B" "$STATE20B" --apply --embed-budget 30 --json 2>&1)"; rc20b=$?
ok "wallclock-no-progress-exit-code-nonzero" "$([ "$rc20b" -ne 0 ] && echo yes || echo no)" "yes"
contains "wallclock-no-progress-stalled" "$out20b" '"embed": {"status": "stalled"'
unset GBRAIN_STUB_DOCTOR_SEQ GBRAIN_STUB_STATUS_SEQ GBRAIN_STUB_SOURCES_SEQ GBRAIN_STUB_EMBED_WALLCLOCK_MSG
rm -rf "$STATE20" "$STATE20B"

rm -rf "$STUBDIR" "$FIXDIR"

echo "gbrain-heal: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
