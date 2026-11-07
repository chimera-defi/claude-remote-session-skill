#!/usr/bin/env bash
# Deterministic admission adapter. Unattended callers set CRSS_AUTONOMOUS=1 and fail closed
# without authority. Every denial is also appended to the starts log.
set -uo pipefail
_log_denial() {
  local log="${CRSS_STARTS_LOG:-$HOME/.sessions/session-starts.log}"
  mkdir -p "$(dirname "$log")" 2>/dev/null || return 0
  printf '%s event=admission-denied action=%s subject=%s rc=%s\n' \
    "$(date -u +%FT%TZ)" "${1:-?}" "${2:-?}" "$3" >> "$log" 2>/dev/null || true
}
# No authority and not autonomous: nothing can answer, so allow (log only). Old start loops
# call this on every restart and never re-read their script; denying would strand a manual
# session at a bare shell. Autonomous callers still fail closed below.
if [ -z "${AGENT_HOST_ADMISSION_CLI:-}" ] && [ "${CRSS_AUTONOMOUS:-0}" != 1 ]; then
  log="${CRSS_STARTS_LOG:-$HOME/.sessions/session-starts.log}"
  mkdir -p "$(dirname "$log")" 2>/dev/null &&
    printf '%s event=admission-skipped reason=no-authority-manual action=%s subject=%s\n' \
      "$(date -u +%FT%TZ)" "${1:-?}" "${2:-?}" >> "$log" 2>/dev/null
  exit 0
fi
if [ -z "${AGENT_HOST_ADMISSION_CLI:-}" ] || [[ "$AGENT_HOST_ADMISSION_CLI" != /* ]]; then
  echo 'autonomous admission denied: authority unavailable' >&2
  _log_denial "${1:-}" "${2:-}" 2
  exit 2
fi
python3 "$AGENT_HOST_ADMISSION_CLI" check "$@" --execution-mode interactive
rc=$?
[ "$rc" -eq 0 ] || _log_denial "${1:-}" "${2:-}" "$rc"
exit "$rc"
