#!/usr/bin/env bash
# create-session.sh — non-interactive helper; fill in FOLDERNAME and run.
# Usage: FOLDERNAME=my-project bash create-session.sh

set -euo pipefail

: "${FOLDERNAME:?Set FOLDERNAME to the project folder name, e.g. SharedStake-ui}"
: "${AGENTS_HOME:=/home/agents}"

DATE=$(date +%Y%m%d)
SESSION="agenthost_${FOLDERNAME}-${DATE}"
REMOTE_NAME="agenthost-${FOLDERNAME}-${DATE}"
WORKDIR="${AGENTS_HOME}/workspace/${FOLDERNAME}"
SCRIPT="${AGENTS_HOME}/.local/bin/${REMOTE_NAME}-start.sh"
SERVICE="${AGENTS_HOME}/.config/systemd/user/${REMOTE_NAME}.service"

mkdir -p "$(dirname "$SCRIPT")" "$(dirname "$SERVICE")"

cat > "$SCRIPT" << SCRIPT_EOF
#!/usr/bin/env bash
SESSION="${SESSION}"
WORKDIR="${WORKDIR}"
export PATH="${AGENTS_HOME}/.local/bin:${AGENTS_HOME}/.npm-global/bin:${AGENTS_HOME}/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export HOME="${AGENTS_HOME}"
log() { echo "[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] \$*"; }
if tmux has-session -t "${SESSION}" 2>/dev/null; then log "Session already running."; exit 0; fi
log "Starting ${SESSION}..."
tmux new-session -d -s "${SESSION}" -x 220 -y 50 -c "${WORKDIR}" -e "PATH=\$PATH" -e "HOME=\$HOME"
tmux send-keys -t "${SESSION}" 'SENTINEL="${WORKDIR}/.sessions-init"
while true; do
  START=\$(date +%s)
  if [ -f "\$SENTINEL" ]; then
    /usr/bin/claude --dangerously-skip-permissions --remote-control ${REMOTE_NAME} --continue
  else
    /usr/bin/claude --dangerously-skip-permissions --remote-control ${REMOTE_NAME}
    touch "\$SENTINEL"
  fi
  RUNTIME=\$(( \$(date +%s) - START ))
  if [ "\$RUNTIME" -lt 30 ]; then
    echo "[${SESSION}] Quick exit (\${RUNTIME}s) — backing off 300s"; sleep 300
  else
    echo "[${SESSION}] Exited after \${RUNTIME}s — restarting in 10s"; sleep 10
  fi
done' Enter
log "Session started. Attach: tmux attach -t ${SESSION}"
SCRIPT_EOF
chmod +x "$SCRIPT"

cat > "$SERVICE" << UNIT_EOF
[Unit]
Description=Claude Code Remote - ${REMOTE_NAME}
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${SCRIPT}
ExecStop=/usr/bin/tmux kill-session -t ${SESSION}
Environment=HOME=${AGENTS_HOME}
Environment=PATH=${AGENTS_HOME}/.local/bin:${AGENTS_HOME}/.npm-global/bin:${AGENTS_HOME}/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=TMUX_TMPDIR=/tmp
[Install]
WantedBy=default.target
UNIT_EOF

systemctl --user daemon-reload
systemctl --user enable --now "$(basename "$SERVICE")"

python3 -c "
import json, os
p=os.path.expanduser('~/.claude.json')
d=json.load(open(p)) if os.path.exists(p) else {}
d.setdefault('projects',{}).setdefault('${WORKDIR}',{})['hasTrustDialogAccepted']=True
json.dump(d,open(p,'w'),separators=(',',':'))
"

echo ""
echo "Session created: ${REMOTE_NAME}"
echo "Connect via Claude Code app → Remote sessions → ${REMOTE_NAME}"
tmux list-sessions | grep "${SESSION}" || true
