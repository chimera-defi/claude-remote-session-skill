#!/usr/bin/env bash
# fleet-status.sh: one-shot view of sessions, host health and token savings. Read-only; never
# reaps, deletes or starts/stops units. session-doctor owns sessions; host health is read from the
# latest snapshot in CRSS_HEALTH_SNAPSHOT_DIR (optional); token stats come from rtk.
#
# Usage:
#   fleet-status.sh              # everything: sessions + host health + token stats
#   fleet-status.sh --sessions   # sessions section only
#   fleet-status.sh --host       # host health section only
set -uo pipefail

# Parses (never sources) $CRSS_HOME/config.sh; env vars win. Copied verbatim into every script
# that reads it (tests/test-crss-overlay-config.sh).
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
    _crss_val="${_crss_val%$'\r'}"
    case "$_crss_val" in
      \"*\") _crss_val="${_crss_val#\"}"; _crss_val="${_crss_val%\"}" ;;
      \'*\') _crss_val="${_crss_val#\'}"; _crss_val="${_crss_val%\'}" ;;
    esac
    if [ -z "${!_crss_key+x}" ]; then export "${_crss_key}=${_crss_val}"; fi
  done < "$_crss_cfg"
  return 0
}
_crss_load_config
# CRSS-CONFIG-LOADER-END
: "${CRSS_HEALTH_SNAPSHOT_DIR:=}"  # unset = no host health snapshot section

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# session-doctor: repo layout first, then PATH (deployed copies drop the .sh).
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
  echo "########## HOST HEALTH ##########"
# Read the latest snapshot instead of a live df/free/systemctl sweep on every call.
  local runs_dir="$CRSS_HEALTH_SNAPSHOT_DIR"
  if [ -z "$runs_dir" ]; then
    echo "  (no health snapshot configured — set CRSS_HEALTH_SNAPSHOT_DIR in \$CRSS_HOME/config.sh)"
    return 0
  fi
  local -a dirs
  local d latest=""
# Dir names are UTC timestamps, so reverse lexical order is newest first. Skip a newest dir
# that is still missing summary.json (the audit is writing it).
  mapfile -t dirs < <(printf '%s\n' "$runs_dir"/*/ | sort -r)
  for d in "${dirs[@]}"; do
    [ -f "${d}summary.json" ] && { latest="$d"; break; }
  done
  if [ -z "$latest" ]; then
    echo "  (no health-audit snapshot found under $runs_dir)"
  else
    local run_id iso run_epoch age_s
    run_id="$(basename "${latest%/}")"
# GNU date rejects the compact run id, so re-punctuate it; print the raw id if parsing fails.
    iso="${run_id:0:4}-${run_id:4:2}-${run_id:6:2}T${run_id:9:2}:${run_id:11:2}:${run_id:13:2}Z"
    run_epoch="$(date -u -d "$iso" +%s 2>/dev/null || echo "")"
    if [ -n "$run_epoch" ]; then
      age_s=$(( $(date -u +%s) - run_epoch ))
      echo "  snapshot: $run_id (${age_s}s / $((age_s/60))min old)"
    else
      echo "  snapshot: $run_id"
    fi
# The .gbrain key is a data contract with the snapshot writer; keep it as-is.
    jq -r '
      "  status: \(.status)",
      "  resources: disk=\(.resources.disk_used_pct)% mem=\(.resources.memory_used_pct)% load_1m=\(.resources.load_1m)",
      "  index: doctor_status=\(.gbrain.doctor_status) failures=\(.gbrain.doctor_failures) stale_embeddings=\(.gbrain.stale_embeddings)",
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
