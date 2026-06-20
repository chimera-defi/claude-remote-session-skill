#!/usr/bin/env bash
# Usage: new-session <foldername> [workspace|sessions]
set -e

FOLDERNAME="${1:?Usage: new-session <foldername> [workspace|sessions]}"
TYPE="${2:-auto}"

if [ "$TYPE" = "auto" ]; then
  [ -d "/home/agents/workspace/${FOLDERNAME}" ] && TYPE="workspace" || TYPE="sessions"
fi

if [ "$TYPE" = "workspace" ]; then
  WORKDIR="/home/agents/workspace/${FOLDERNAME}"
else
  WORKDIR="/home/agents/.sessions/${FOLDERNAME}"
fi

DATE=$(date +%Y%m%d-%H%M)
SESSION="agenthost_${FOLDERNAME}-${DATE}"
REMOTE_NAME="agenthost-${FOLDERNAME}-${DATE}"
SCRIPT="$HOME/.local/bin/${REMOTE_NAME}-start.sh"
SERVICE="$HOME/.config/systemd/user/${REMOTE_NAME}.service"

cat > "$SCRIPT" << SCRIPT_EOF
#!/usr/bin/env bash
SESSION="${SESSION}"
WORKDIR="${WORKDIR}"
REMOTE_NAME="${REMOTE_NAME}"
export PATH="/home/agents/.local/bin:/home/agents/.npm-global/bin:/home/agents/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export HOME="/home/agents"
LOG_FILE="\$HOME/.sessions/session-starts.log"
mkdir -p "\$(dirname "\$LOG_FILE")"
log_start() { echo "[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] host=\$(hostname) session=\$SESSION remote=\$REMOTE_NAME workdir=\$WORKDIR event=\$1" | tee -a "\$LOG_FILE"; }
if tmux has-session -t "${SESSION}" 2>/dev/null; then log_start "already-running"; exit 0; fi
log_start "starting"
# Decide where this session runs: the canonical tree on its default branch when
# it is free + clean, otherwise a fresh per-session worktree branched from the
# default branch (so parallel sessions on the same repo never collide). Falls
# back to \$WORKDIR if the helper is missing, preserving legacy behaviour.
RUNDIR="\$WORKDIR"
if command -v session-git-prep >/dev/null 2>&1; then
  PREP="\$(session-git-prep "\$WORKDIR" "\$SESSION" "\$REMOTE_NAME" 2>>"\$LOG_FILE")"
  [ -n "\$PREP" ] && RUNDIR="\$PREP"
fi
echo "[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] session=\$SESSION rundir=\$RUNDIR" | tee -a "\$LOG_FILE"
mkdir -p "\$RUNDIR/.claude"
rm -rf "\$RUNDIR/.claude/skills" && ln -sf /home/agents/.claude/skills "\$RUNDIR/.claude/skills"
if [ -f "\$RUNDIR/memory/MEMORY.md" ] && ! grep -q "Session Bootstrap" "\$RUNDIR/.claude/CLAUDE.md" 2>/dev/null; then
  printf '# Session Bootstrap\n\nOn your first response in any new session, read \`memory/MEMORY.md\` to load current project state, then summarize what needs to be done next and wait for instructions.\n' >> "\$RUNDIR/.claude/CLAUDE.md"
fi
tmux new-session -d -s "${SESSION}" -x 220 -y 50 -c "\$RUNDIR" -e "PATH=\$PATH" -e "HOME=\$HOME"
tmux send-keys -t "${SESSION}" 'SENTINEL="\$PWD/.sessions-init-${REMOTE_NAME}"
while true; do
  START=\$(date +%s)
  if [ -f "\$SENTINEL" ]; then
    /usr/bin/claude --dangerously-skip-permissions --remote-control ${REMOTE_NAME} --continue
  else
    /usr/bin/claude --dangerously-skip-permissions --remote-control ${REMOTE_NAME}
    touch "\$SENTINEL"
  fi
  RUNTIME=\$(( \$(date +%s) - START ))
  [ "\$RUNTIME" -lt 30 ] && { echo "[${SESSION}] quick exit \${RUNTIME}s — backoff 300s"; sleep 300; } || { echo "[${SESSION}] exit \${RUNTIME}s — restart 10s"; sleep 10; }
done' Enter
log_start "started"
SCRIPT_EOF
chmod +x "$SCRIPT"

cat > "$SERVICE" << UNIT_EOF
[Unit]
Description=Claude Code Remote - ${REMOTE_NAME}
After=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${SCRIPT}
ExecStop=/usr/bin/tmux kill-session -t ${SESSION}
Environment=HOME=/home/agents
Environment=PATH=/home/agents/.local/bin:/home/agents/.npm-global/bin:/home/agents/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=TMUX_TMPDIR=/tmp
[Install]
WantedBy=default.target
UNIT_EOF

systemctl --user daemon-reload && systemctl --user enable --now "$(basename $SERVICE)"
python3 -c "
import json; p='/home/agents/.claude.json'; d=json.load(open(p))
d.setdefault('projects',{}).setdefault('${WORKDIR}',{})['hasTrustDialogAccepted']=True
json.dump(d,open(p,'w'),separators=(',',':'))
"
tmux list-sessions | grep "${SESSION}" && echo "" && echo "remote: ${REMOTE_NAME}"
