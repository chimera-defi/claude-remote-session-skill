#!/usr/bin/env bash
# gbrain-heal.sh — keep the gbrain brain draining and stamped fresh.
#
# Why this exists (2026-09-24, see SPEC-gbrain-heal.md, gbrain #4599):
#   1. The nightly embed drain was stalling every night: ollama's recipe batches up
#      to ~6k-char chunks with no cap, so a single sub-batch can take 42s+ on a
#      serial llama-server vs. the 60s default GBRAIN_AI_EMBED_TIMEOUT_MS. The
#      abort isn't honored, so gbrain's own stall watchdog kills the drain after
#      ~20 chunks and the cursor restarts at page_id 0 next run, hitting the same
#      huge page every time. VERIFIED FIX: cap batch tokens and raise the
#      per-batch timeout (gateway.ts:1968 reads GBRAIN_EMBED_MAX_BATCH_TOKENS,
#      gateway.ts:93 reads GBRAIN_AI_EMBED_TIMEOUT_MS) -- 233 chunks/10min, no stall.
#   1b. Capping the batch size fixes per-request latency but exposes a second,
#      distinct livelock (confirmed with a logging proxy): gbrain's stall
#      watchdog (src/core/embed-stall.ts) is progress-keyed on
#      `EmbedResult.embedded` -- i.e. it only resets on a PERSISTED CHUNK, and
#      chunks persist once per PAGE, not per sub-batch (see the module header's
#      "TRIGGER is SUCCESSFUL forward progress" note). Page 7551 has 1217
#      chunks -- at ~170 sub-batch requests to finish that one page, even a
#      healthy 5-19s/request adds up to ~27 minutes with ZERO watchdog-visible
#      progress, well past the watchdog's 900s default
#      (DEFAULT_EMBED_STALL_ABORT_SEC). So the watchdog fires mid-page, banks
#      nothing for that page, and the next run hits the same page again --
#      deterministic livelock, independent of the batch-size fix. VERIFIED FIX:
#      also raise GBRAIN_EMBED_STALL_ABORT_SECONDS (resolved in
#      resolveEmbedStallAbortSeconds()) well past the worst single-page time.
#   2. The nightly `gbrain-code-refresh.sh` cron syncs portfolio-ssot-live with
#      --no-embed by design, so hundreds of new unembedded code chunks land daily.
#      That backlog is expected; a script that treats "any backlog" as unhealthy
#      (see #4) chases its tail. This script tolerates a draining backlog and
#      only calls it unhealthy when doctor reports an actual FAIL.
#   3. cycle_freshness warns >6h and FAILs >24h; a once-daily timer sits at that
#      FAIL edge. Run this more than once a day (see systemd/gbrain-heal.timer).
#   4. A prior health script required stale==0 && missing==0 with no tolerance,
#      so any backlog at all read as "degraded" even while draining normally.
#
# Supersedes ~/.local/bin/gbrain-maintenance.sh. The sync/extract phases, the
# per-source `dream --source <id>` cycle-freshness trick, and their rationale
# comments below are ported from that script (never committed anywhere, hence
# this repo copy) rather than reinvented.
#
# Usage:
#   gbrain-heal [--check] [--json] [--strict]
#     Read-only (default mode). Runs `doctor --json` (counts FAIL checks) and
#     `migrate embeddings --status --json` (missing/stale/migration marker),
#     prints a one-line verdict, and exits 2 on a tool error. Otherwise, one
#     of three states, each with its own default exit code:
#       healthy    0 doctor FAILs AND missing==0 AND stale==0        -> exit 0
#       draining   0 doctor FAILs but an embedding backlog           -> exit 0
#                  (missing>0 or stale>0) -- expected, see #2           (1 with --strict)
#       unhealthy  a real doctor FAIL                                -> exit 1 (always)
#     --strict tightens "draining" to the same zero-tolerance rule
#     server-health-audit.sh used (marker=none && stale==0 && missing==0 &&
#     doctor fail==0): use it where a draining backlog really should page.
#
#   gbrain-heal --apply [--dry-run] [--embed-budget SECONDS] [--json]
#     sync --all -> embed --stale (tuned env, time-budgeted) -> extract --stale
#     -> per-source `dream --source <id>` cycle -> re-check (same as --check,
#     non-strict -- draining is an acceptable end state for --apply).
#     --dry-run prints the commands each phase would run and executes nothing.
#     Single-flight via flock: a concurrent --apply exits 0 as a no-op (a
#     concurrent --check is unaffected -- it is read-only and never locks).
#     Exit: non-zero if any phase hard-failed, the post-run doctor check has a
#     FAIL, or the embed phase stalled (backlog>0, zero progress in budget --
#     whether the process was killed by --embed-budget or gbrain's own stall
#     watchdog aborted it first). A timed-out/stalled-watchdog embed phase that
#     nonetheless made progress is NOT a failure -- it banks partial progress
#     and resumes next run, same as gbrain's own drain design.
#
# Options:
#   --embed-budget SECONDS   Wall-clock budget for the embed phase (default 7200;
#                            keep it comfortably above GBRAIN_EMBED_STALL_ABORT_SECONDS
#                            so gbrain's own watchdog, not our timeout, is what fires).
#   --strict                 --check only: exit 1 on a draining backlog too (see above).
#   --json                   Emit the machine-readable summary on stdout instead
#                            of the human one-line verdict (both are always
#                            logged to stderr).
# Env overrides:
#   GBRAIN_BIN               Path to the gbrain binary (default: /home/agents/.bun/bin/gbrain).
#   GBRAIN_HEAL_STATE_DIR    Per-run logs/lock live here (default: ~/.gbrain/heal).
#
# Never destructive: this script only calls sync, embed, extract, dream, doctor,
# and migrate embeddings --status. It never calls sources remove/purge/archive,
# delete, or migrate embeddings --to, and it never edits gbrain config.
set -uo pipefail

# `gbrain` is a bun script; cron/systemd PATHs don't include ~/.bun/bin.
PATH="/home/agents/.bun/bin:/home/agents/.local/bin:/home/agents/.npm-global/bin:${PATH:-/usr/bin:/bin}"
export PATH

GBRAIN="${GBRAIN_BIN:-/home/agents/.bun/bin/gbrain}"
STATE_DIR="${GBRAIN_HEAL_STATE_DIR:-/home/agents/.gbrain/heal}"
EMBED_BUDGET=7200
JSON_OUT=0
MODE=check
DRY_RUN=0
STRICT=0

usage() {
  sed -n '2,84p' "$0"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=check; shift ;;
    --apply) MODE=apply; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --json) JSON_OUT=1; shift ;;
    --strict) STRICT=1; shift ;;
    --embed-budget)
      [ $# -ge 2 ] || { echo "gbrain-heal: --embed-budget requires SECONDS" >&2; exit 2; }
      EMBED_BUDGET="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "gbrain-heal: unknown option: $1" >&2; exit 2 ;;
  esac
done

# The verified fix for root cause #1: cap the embed sub-batch size and raise
# the per-batch timeout. Exported globally (not just around the embed phase)
# because `gbrain sync` also embeds newly-imported content through the same
# gateway.ts path, and never override a value the caller already set.
: "${GBRAIN_EMBED_MAX_BATCH_TOKENS:=4096}"
export GBRAIN_EMBED_MAX_BATCH_TOKENS
: "${GBRAIN_AI_EMBED_TIMEOUT_MS:=180000}"
export GBRAIN_AI_EMBED_TIMEOUT_MS
# The verified fix for root cause #1b: gbrain's stall watchdog
# (src/core/embed-stall.ts) only resets on a PERSISTED chunk (EmbedResult.embedded),
# and chunks persist once per page -- so a single huge page (e.g. 7551, 1217
# chunks, ~170 sub-batch requests) can run ~27min with zero watchdog-visible
# progress even when every sub-batch is succeeding. Default
# GBRAIN_EMBED_STALL_ABORT_SECONDS is only 900s, well inside that window, so
# the watchdog fires mid-page every run and nothing ever banks for it. Raise
# it well past the worst single-page time; --embed-budget (default 7200) stays
# the outer bound so gbrain's own watchdog fires first, not our `timeout`.
: "${GBRAIN_EMBED_STALL_ABORT_SECONDS:=3600}"
export GBRAIN_EMBED_STALL_ABORT_SECONDS

log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }

# gbrain prints an "UPGRADE_AVAILABLE ..." banner before JSON; strip it (same
# technique as gbrain-maintenance.sh's json_only()).
json_only() { sed -n '/^[[:space:]]*{/,$p'; }

is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

if ! command -v "$GBRAIN" >/dev/null 2>&1; then
  echo "gbrain-heal: tool error - gbrain not found or not executable: $GBRAIN" >&2
  [ "$JSON_OUT" = 1 ] && echo "{\"error\":\"gbrain_not_found\",\"gbrain_bin\":\"$GBRAIN\"}"
  exit 2
fi

# ---------------------------------------------------------------- do_check
# Read-only health verdict. Sets CHECK_JSON / CHECK_LINE; returns 0 (exit-ok
# per the strict setting), 1 (not ok), 2 tool error. Used standalone (--check)
# and as --apply's final re-check (always called non-strict there -- draining
# is an acceptable end state for --apply), so the two never drift.
#
# Three states (independent of --strict):
#   healthy   : doctor_fail_count==0 AND missing==0 AND stale==0
#   draining  : doctor_fail_count==0 but an embedding backlog (missing>0 or stale>0)
#   unhealthy : doctor_fail_count>0 (a real doctor FAIL, e.g. cycle_freshness >24h)
# Default exit: 0 for healthy/draining, 1 for unhealthy. --strict (arg $1=1)
# additionally requires the server-health-audit.sh:97 zero-tolerance rule
# (marker.kind=="none" && stale==0 && missing==0 && doctor_fail_count==0), so
# a draining backlog (or an in-flight embedding migration) exits 1 under
# --strict even though its state is still reported as "draining".
CHECK_JSON=""
CHECK_LINE=""

do_check() {
  local strict="${1:-0}"
  local doctor_raw status_raw doctor_json status_json py_out
  doctor_raw="$("$GBRAIN" doctor --json 2>&1)"
  status_raw="$("$GBRAIN" migrate embeddings --status --json 2>&1)"
  doctor_json="$(printf '%s\n' "$doctor_raw" | json_only)"
  status_json="$(printf '%s\n' "$status_raw" | json_only)"
  if [ -z "$doctor_json" ] || [ -z "$status_json" ]; then
    CHECK_LINE="gbrain-heal: tool error - empty/unparsable JSON from gbrain"
    CHECK_JSON='{"error":"empty_json"}'
    return 2
  fi
  py_out="$(python3 - "$doctor_json" "$status_json" "$strict" <<'PY'
import json, sys
try:
    doc = json.loads(sys.argv[1])
    st = json.loads(sys.argv[2])
    strict = sys.argv[3] == "1"

    def is_zero(v):
        return isinstance(v, (int, float)) and v == 0

    checks = doc.get("checks", [])
    fail_count = sum(1 for c in checks if c.get("status") == "fail")
    named = {c.get("name"): c.get("status") for c in checks
             if c.get("name") in ("sync_freshness", "cycle_freshness")}
    missing = st.get("missing_embeddings")
    stale = (st.get("stale_vs_target") or {}).get("stale")
    marker_kind = (st.get("marker") or {}).get("kind")

    if fail_count > 0:
        state = "unhealthy"
    elif is_zero(missing) and is_zero(stale):
        state = "healthy"
    else:
        state = "draining"

    strict_ok = (marker_kind == "none") and is_zero(stale) and is_zero(missing) and fail_count == 0
    exit_ok = strict_ok if strict else (state != "unhealthy")

    summary = {
        "doctor_status": doc.get("status"),
        "doctor_fail_count": fail_count,
        "checks": named,
        "embeddings": {"missing": missing, "stale": stale},
        "marker_kind": marker_kind,
        "state": state,
        "strict": strict,
        "exit_ok": exit_ok,
    }
    note = ""
    if strict and not exit_ok and state != "unhealthy":
        note = " [--strict: draining backlog / migration marker counts as unhealthy]"
    line = "gbrain-heal: %s%s (doctor=%s fail=%d sync_freshness=%s cycle_freshness=%s embeddings missing=%s stale=%s marker=%s)" % (
        state, note, summary["doctor_status"], fail_count,
        named.get("sync_freshness", "?"), named.get("cycle_freshness", "?"),
        missing, stale, marker_kind,
    )
    print("OK")
    print("1" if exit_ok else "0")
    print(json.dumps(summary))
    print(line)
except Exception as e:
    print("ERR")
    print(str(e))
PY
)"
  mapfile -t _lines <<<"$py_out"
  if [ "${_lines[0]:-}" != "OK" ]; then
    CHECK_LINE="gbrain-heal: tool error - JSON parse failed: ${_lines[1]:-unknown}"
    CHECK_JSON='{"error":"parse_failed"}'
    return 2
  fi
  CHECK_JSON="${_lines[2]}"
  CHECK_LINE="${_lines[3]}"
  [ "${_lines[1]}" = "1" ] && return 0 || return 1
}

embed_missing_count() {
  local raw json
  raw="$("$GBRAIN" migrate embeddings --status --json 2>&1)"
  json="$(printf '%s\n' "$raw" | json_only)"
  python3 -c '
import json, sys
try:
    print(json.loads(sys.argv[1]).get("missing_embeddings", "NA"))
except Exception:
    print("NA")
' "$json" 2>/dev/null || echo NA
}

if [ "$MODE" = check ]; then
  do_check "$STRICT"
  rc=$?
  log "$CHECK_LINE"
  if [ "$JSON_OUT" = 1 ]; then
    echo "$CHECK_JSON"
  else
    echo "$CHECK_LINE"
  fi
  exit "$rc"
fi

# ---------------------------------------------------------------- apply
mkdir -p "$STATE_DIR"
LOCK="$STATE_DIR/.lock"

# Single-flight: a concurrent --apply must never overlap another (ported from
# gbrain-maintenance.sh). --check never takes this lock -- it's read-only and
# its exit code (0/1/2) needs to stay meaningful even while --apply is running.
exec 9>"$LOCK"
if ! flock -n 9; then
  log "gbrain-heal: another --apply run holds $LOCK; exiting"
  exit 0
fi

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$STATE_DIR/runs/$RUN_ID"
mkdir -p "$RUN_DIR"
LOG="$RUN_DIR/run.log"
log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$LOG" >&2; }

log "gbrain-heal apply run $RUN_ID (dry_run=$DRY_RUN embed_budget=${EMBED_BUDGET}s)"

declare -a PHASE_NAMES=() PHASE_STATUS=() PHASE_SECS=()
EMBED_STALLED=0

# Generic phase runner, ported from gbrain-maintenance.sh's run_phase(): ok /
# timeout / failed, with the same stall-watchdog tolerance (gbrain's own
# documented backpressure banks partial progress and resumes next run --
# treating it as a hard failure just makes the systemd unit "failed" for no
# reason, which is itself an independent trigger for degraded-health alerts).
run_phase() {
  local name="$1" timeout_s="$2"; shift 2
  local t0 t1 rc out
  log "── phase: $name"
  t0=$(date +%s)
  out="$RUN_DIR/$name.out"
  if [ "$DRY_RUN" = 1 ]; then
    log "   DRY-RUN, would run: $*"
    PHASE_NAMES+=("$name"); PHASE_STATUS+=("skipped-dry-run"); PHASE_SECS+=(0)
    return 0
  fi
  timeout "$timeout_s" "$@" >"$out" 2>&1
  rc=$?
  t1=$(date +%s)
  PHASE_NAMES+=("$name"); PHASE_SECS+=($((t1 - t0)))
  if [ "$rc" -eq 0 ]; then
    PHASE_STATUS+=("ok"); log "   ok ($((t1 - t0))s)"
  elif [ "$rc" -eq 124 ]; then
    PHASE_STATUS+=("timeout"); log "   TIMEOUT after ${timeout_s}s"
  elif grep -q 'stall watchdog aborted the drain' "$out" 2>/dev/null; then
    PHASE_STATUS+=("partial(stall-watchdog)")
    log "   partial ($((t1 - t0))s): stall watchdog aborted the drain, partial progress banked -- will resume next run"
  else
    PHASE_STATUS+=("failed(rc=$rc)")
    log "   FAILED rc=$rc — last lines:"
    tail -5 "$out" | sed 's/^/     /' | tee -a "$LOG" >&2
  fi
}

# Dedicated embed phase (root causes #1/#1b): tuned env is already exported
# globally above. Record missing-before/after so a stalled-out run (whether
# killed by our own --embed-budget `timeout`, rc=124, or by gbrain's own
# stall watchdog self-aborting with rc=1 and the message asserted in
# src/core/embed-stall.ts:assertEmbedNotStalled -- "stall watchdog aborted
# the drain") is distinguished from a genuine stall (backlog>0, zero
# progress) vs. a stall-shaped exit that still banked partial progress.
run_embed_phase() {
  local t0 t1 rc out missing_before missing_after progress backlog stall_exit
  log "── phase: embed"
  if [ "$DRY_RUN" = 1 ]; then
    log "   DRY-RUN, would run: GBRAIN_EMBED_MAX_BATCH_TOKENS=$GBRAIN_EMBED_MAX_BATCH_TOKENS GBRAIN_AI_EMBED_TIMEOUT_MS=$GBRAIN_AI_EMBED_TIMEOUT_MS GBRAIN_EMBED_STALL_ABORT_SECONDS=$GBRAIN_EMBED_STALL_ABORT_SECONDS timeout ${EMBED_BUDGET}s $GBRAIN embed --stale --include-null-signature"
    PHASE_NAMES+=("embed"); PHASE_STATUS+=("skipped-dry-run"); PHASE_SECS+=(0)
    return 0
  fi
  missing_before="$(embed_missing_count)"
  t0=$(date +%s)
  out="$RUN_DIR/embed.out"
  timeout "$EMBED_BUDGET" "$GBRAIN" embed --stale --include-null-signature >"$out" 2>&1
  rc=$?
  t1=$(date +%s)
  missing_after="$(embed_missing_count)"
  log "   missing_embeddings before=$missing_before after=$missing_after"
  PHASE_NAMES+=("embed"); PHASE_SECS+=($((t1 - t0)))

  # A stall-shaped exit is either our own `timeout` killing it (rc=124) or
  # gbrain's own watchdog self-aborting first (any rc, but its process exits
  # via `process.exit(1)` after printing this exact substring -- see
  # src/commands/embed.ts:runEmbed). Either way, don't treat it as an
  # unconditional hard failure -- check whether it still made progress first.
  stall_exit=0
  if [ "$rc" -eq 124 ] || grep -q 'stall watchdog aborted the drain' "$out" 2>/dev/null; then
    stall_exit=1
  fi

  if [ "$rc" -ne 0 ] && [ "$stall_exit" -ne 1 ]; then
    PHASE_STATUS+=("failed(rc=$rc)")
    log "   FAILED rc=$rc — last lines:"
    tail -5 "$out" | sed 's/^/     /' | tee -a "$LOG" >&2
    return
  fi

  progress=0
  if is_num "$missing_before" && is_num "$missing_after" && [ "$missing_after" -lt "$missing_before" ]; then
    progress=1
  fi
  backlog=0
  if is_num "$missing_before" && [ "$missing_before" -gt 0 ]; then
    backlog=1
  fi

  if [ "$backlog" -eq 1 ] && [ "$progress" -eq 0 ]; then
    PHASE_STATUS+=("stalled")
    EMBED_STALLED=1
    log "   STALLED: no progress (missing stuck at $missing_before) -- rc=$rc, stall_exit=$stall_exit"
  elif [ "$stall_exit" -eq 1 ]; then
    PHASE_STATUS+=("timeout-partial")
    log "   partial ($((t1 - t0))s): embed budget/stall-watchdog exhausted, made progress -- NOT a failure, resumes next run"
  else
    PHASE_STATUS+=("ok")
    log "   ok ($((t1 - t0))s)"
  fi
}

# Per-source freshness-stamp cycle, ported verbatim from gbrain-maintenance.sh:
# `dream --source <id>` runs only gbrain's deterministic freshness phases for a
# named non-default source (per its own --help), which is what makes doctor's
# cycle_freshness check see a fresh stamp -- this brain is postgres-backed with
# no local checkout, so a bare `gbrain dream` skips its filesystem phases
# entirely and cycle_freshness never advances. Measured ~0.2s/source, no LLM
# calls -- safe to run every cycle, unlike --full's dream synthesize/patterns.
cycle_sources() {
  local ids id rc ok=0 bad=0 t0 t1
  log "── phase: cycle (per-source freshness stamps)"
  if [ "$DRY_RUN" = 1 ]; then
    log "   DRY-RUN, would run: gbrain dream --source <id> for each source with a local_path"
    PHASE_NAMES+=("cycle"); PHASE_STATUS+=("skipped-dry-run"); PHASE_SECS+=(0)
    return 0
  fi
  t0=$(date +%s)
  ids="$("$GBRAIN" sources list --json 2>/dev/null | json_only \
        | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
for s in d.get("sources", []):
    if s.get("local_path"):
        print(s["id"])
' 2>/dev/null)"
  if [ -z "$ids" ]; then
    log "   no sources with a local_path; nothing to cycle"
    PHASE_NAMES+=("cycle"); PHASE_STATUS+=("no-op"); PHASE_SECS+=(0)
    return 0
  fi
  for id in $ids; do
    timeout 300 "$GBRAIN" dream --source "$id" --json >"$RUN_DIR/cycle-$id.out" 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then ok=$((ok + 1)); else bad=$((bad + 1)); log "   cycle FAILED for $id (rc=$rc)"; fi
  done
  t1=$(date +%s)
  log "   cycled $ok source(s), $bad failure(s) ($((t1 - t0))s)"
  PHASE_NAMES+=("cycle"); PHASE_SECS+=($((t1 - t0)))
  if [ "$bad" -gt 0 ]; then
    PHASE_STATUS+=("partial($ok ok/$bad fail)")
  else
    PHASE_STATUS+=("ok($ok sources)")
  fi
}

run_phase sync 1800 "$GBRAIN" sync --all --missing-path skip
run_embed_phase
run_phase extract 900 "$GBRAIN" extract --stale --catch-up
cycle_sources

if [ "$DRY_RUN" = 1 ]; then
  log "── DRY-RUN, would re-check: $GBRAIN doctor --json && $GBRAIN migrate embeddings --status --json"
  CHECK_LINE="gbrain-heal: dry-run -- re-check not executed"
  CHECK_JSON='{"dry_run":true}'
  check_rc=0
else
  # Always non-strict here: --apply's own exit contract already treats a
  # draining backlog as an acceptable end state (see header comment); --strict
  # is a --check-only concern and is intentionally ignored for this re-check.
  do_check 0
  check_rc=$?
  log "$CHECK_LINE"
fi

APPLY_RC=0
for st in "${PHASE_STATUS[@]}"; do
  case "$st" in
    failed\(*|timeout|stalled) APPLY_RC=1 ;;
    partial\(*fail\)) APPLY_RC=1 ;;
  esac
done
[ "$EMBED_STALLED" -eq 1 ] && APPLY_RC=1
[ "$check_rc" -ne 0 ] && [ "$DRY_RUN" -eq 0 ] && APPLY_RC=1

SUMMARY="$RUN_DIR/summary.json"
{
  printf '{\n'
  printf '  "run_id": "%s",\n' "$RUN_ID"
  printf '  "dry_run": %s,\n' "$([ "$DRY_RUN" = 1 ] && echo true || echo false)"
  printf '  "embed_budget_seconds": %s,\n' "$EMBED_BUDGET"
  printf '  "phases": {'
  for i in "${!PHASE_NAMES[@]}"; do
    [ "$i" -gt 0 ] && printf ','
    printf '\n    "%s": {"status": "%s", "seconds": %s}' \
      "${PHASE_NAMES[$i]}" "${PHASE_STATUS[$i]}" "${PHASE_SECS[$i]}"
  done
  printf '\n  },\n'
  printf '  "recheck": %s,\n' "${CHECK_JSON:-null}"
  printf '  "exit_code": %s,\n' "$APPLY_RC"
  printf '  "run_dir": "%s"\n' "$RUN_DIR"
  printf '}\n'
} >"$SUMMARY"

ln -sfn "$RUN_DIR" "$STATE_DIR/latest"

# Keep the last 30 run dirs.
mapfile -t OLD_RUNS < <(find "$STATE_DIR/runs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
KEEP=30
if [ "${#OLD_RUNS[@]}" -gt "$KEEP" ]; then
  EXCESS=$((${#OLD_RUNS[@]} - KEEP))
  for ((i = 0; i < EXCESS; i++)); do
    rm -rf -- "${OLD_RUNS[$i]}"
  done
fi

log "summary: $SUMMARY"
log "done rc=$APPLY_RC"
if [ "$JSON_OUT" = 1 ]; then
  cat "$SUMMARY"
else
  echo "$CHECK_LINE"
fi
exit "$APPLY_RC"
