#!/usr/bin/env bash
# Deterministic adapter only. Manual first-launch/control commands do not call
# this helper; unattended callers must identify themselves with CRSS_AUTONOMOUS=1.
# With no authority configured, only those autonomous callers are denied.
# A denial is also appended to the starts log (one line) so it is visible outside
# the denied session's own pane; the helper's stdout/stderr and exit code are unchanged.
set -uo pipefail
_log_denial() {
  local log="${CRSS_STARTS_LOG:-$HOME/.sessions/session-starts.log}"
  mkdir -p "$(dirname "$log")" 2>/dev/null || return 0
  printf '%s event=admission-denied action=%s subject=%s rc=%s\n' \
    "$(date -u +%FT%TZ)" "${1:-?}" "${2:-?}" "$3" >> "$log" 2>/dev/null || true
}
# No authority configured and the caller is not autonomous: nothing can answer, so there is
# nothing to deny. Start loops generated before #189 call this on every restart, and the loop
# already running in a pane never re-reads its start script, so this is the only fix that
# reaches them: without it a reboot or crash leaves a manual session at a bare shell.
# Autonomous callers (CRSS_AUTONOMOUS=1) still fail closed below.
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
