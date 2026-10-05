#!/usr/bin/env bash
# Deterministic adapter only. Manual first-launch/control commands do not call
# this helper; unattended callers must identify themselves with CRSS_AUTONOMOUS=1.
set -uo pipefail
if [ -z "${AGENT_HOST_ADMISSION_CLI:-}" ] || [[ "$AGENT_HOST_ADMISSION_CLI" != /* ]]; then
  echo 'autonomous admission denied: authority unavailable' >&2
  exit 2
fi
exec python3 "$AGENT_HOST_ADMISSION_CLI" check "$@" --execution-mode interactive
