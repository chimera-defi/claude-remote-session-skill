#!/usr/bin/env bash
# fleet-status.sh — one-shot composite view of "how's the fleet/server doing":
# sessions (tmux/systemd/registry), host resources + gbrain, and token-savings
# telemetry. Orchestrates existing tools rather than re-implementing any of
# them — session-doctor.sh owns sessions, server-health-audit.service already
# owns host+gbrain checks (this reads its latest JSON snapshot instead of
# re-running `gbrain doctor` live, which is the slow part), rtk owns token
# stats. Read-only; never reaps, never deletes, never starts/stops units.
#
# Usage:
#   fleet-status.sh              # everything: sessions + host/gbrain + rtk
#   fleet-status.sh --sessions   # sessions section only
#   fleet-status.sh --host       # host/gbrain section only
set -uo pipefail

# ── Host-local overlay config ────────────────────────────────────────────────
# See examples/crss-overlay/README.md. Parses (never sources) $CRSS_HOME/config.sh
# for CRSS_* vars; an env var already set wins over the file; a missing/unreadable
# file is fine (generic defaults below apply). Copied verbatim in every script
# that reads overlay config — see tests/test-crss-overlay-config.sh.
# CRSS-CONFIG-LOADER-START
_crss_load_config() {
  local _crss_home _crss_cfg _crss_line _crss_key _crss_val
  _crss_home="${CRSS_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/crss}"
  export CRSS_HOME="$_crss_home"
  _crss_cfg="$_crss_home/config.sh"
  [ -r "$_crss_cfg" ] || return 0
  while IFS= read -r _crss_line || [ -n "$_crss_line" ]; do
    [[ "$_crss_line" =~ ^(CRSS_[A-Z0-9_]+)=(.*)$ ]] || continue
    _crss_key="${BASH_REMATCH[1]}"
    _crss_val="${BASH_REMATCH[2]}"
    case "$_crss_val" in
      \"*\") _crss_val="${_crss_val#\"}"; _crss_val="${_crss_val%\"}" ;;
      \'*\') _crss_val="${_crss_val#\'}"; _crss_val="${_crss_val%\'}" ;;
    esac
    [ -z "${!_crss_key+x}" ] && export "${_crss_key}=${_crss_val}"
  done < "$_crss_cfg"
}
_crss_load_config
# CRSS-CONFIG-LOADER-END
: "${CRSS_HEALTH_SNAPSHOT_DIR:=}"  # unset = no host health snapshot section

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# Resolve session-doctor co-located first (repo/dev layout), then on PATH
# (deployed layout: flat copies in ~/.local/bin with the .sh dropped — see
# session-send.sh's header comment for why this two-step resolution exists).
_session_doctor() {
  if [ -f "$HERE/session-doctor.sh" ]; then
    bash "$HERE/session-doctor.sh" "$@"
  elif command -v session-doctor >/dev/null 2>&1; then
    bash "$(command -v session-doctor)" "$@"
  else
    echo "  (session-doctor not found — looked next to this script and on PATH)"
  fi
}

SECTION="${1:---all}"

print_sessions() {
  echo "########## SESSIONS ##########"
  _session_doctor report
  echo
  echo "=== Stale worktrees (no owning session) ==="
  _session_doctor worktree-stale
}

print_host() {
  echo "########## HOST / GBRAIN ##########"
  # server-health-audit.service writes a fresh JSON snapshot roughly every
  # 15min — read the latest one instead of re-running `gbrain doctor` and a
  # full df/free/systemctl sweep live on every call (the slow part of the old
  # hand-rolled routine). Falls back to a note if the audit has never run.
  local runs_dir="$CRSS_HEALTH_SNAPSHOT_DIR"
  if [ -z "$runs_dir" ]; then
    echo "  (no health snapshot configured — set CRSS_HEALTH_SNAPSHOT_DIR in \$CRSS_HOME/config.sh)"
    return 0
  fi
  local -a dirs
  local d latest=""
  # Directory names are UTC timestamps (YYYYMMDDTHHMMSSZ), so lexical sort
  # order == chronological order — sort descending via a plain glob (no `ls`
  # parsing) and pick the newest COMPLETE one. summary.json lands after the
  # dir itself, so the very-newest dir can transiently lack it while the
  # audit service is still writing it; skip that one rather than failing.
  mapfile -t dirs < <(printf '%s\n' "$runs_dir"/*/ | sort -r)
  for d in "${dirs[@]}"; do
    [ -f "${d}summary.json" ] && { latest="$d"; break; }
  done
  if [ -z "$latest" ]; then
    echo "  (no server-health-audit snapshot found under $runs_dir)"
  else
    local run_id iso run_epoch age_s
    run_id="$(basename "${latest%/}")"
    # run_id is a compact UTC timestamp like 20260919T194659Z; GNU date -d
    # rejects that form without separators, so re-punctuate to
    # 2026-09-19T19:46:59Z before parsing. Falls back to printing the raw id
    # if the host's date(1) still can't parse it.
    iso="${run_id:0:4}-${run_id:4:2}-${run_id:6:2}T${run_id:9:2}:${run_id:11:2}:${run_id:13:2}Z"
    run_epoch="$(date -u -d "$iso" +%s 2>/dev/null || echo "")"
    if [ -n "$run_epoch" ]; then
      age_s=$(( $(date -u +%s) - run_epoch ))
      echo "  snapshot: $run_id (${age_s}s / $((age_s/60))min old)"
    else
      echo "  snapshot: $run_id"
    fi
    jq -r '
      "  status: \(.status)",
      "  resources: disk=\(.resources.disk_used_pct)% mem=\(.resources.memory_used_pct)% load_1m=\(.resources.load_1m)",
      "  gbrain: doctor_status=\(.gbrain.doctor_status) failures=\(.gbrain.doctor_failures) stale_embeddings=\(.gbrain.stale_embeddings)",
      (if (.failed_units.observed_user // "") != "" then "  failed user units: \(.failed_units.observed_user)" else empty end),
      (if (.failed_units.observed_system // "") != "" then "  failed system units: \(.failed_units.observed_system)" else empty end),
      (if (.failed_units.persistent_user // "") != "" then "  PERSISTENT failed user units: \(.failed_units.persistent_user)" else empty end),
      (if (.failed_units.persistent_system // "") != "" then "  PERSISTENT failed system units: \(.failed_units.persistent_system)" else empty end)
    ' "${latest}summary.json" 2>/dev/null || echo "  (could not parse ${latest}summary.json)"
  fi
  echo
  echo "=== rtk (token-savings telemetry) ==="
  if command -v rtk >/dev/null 2>&1; then
    rtk gain
  else
    echo "  (rtk not on PATH)"
  fi
}

case "$SECTION" in
  --all)      print_sessions; echo; print_host ;;
  --sessions) print_sessions ;;
  --host)     print_host ;;
  *) echo "usage: fleet-status.sh [--all|--sessions|--host]" >&2; exit 2 ;;
esac
