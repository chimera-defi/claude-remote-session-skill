---
name: gstack-session-spawn
slug: gstack-session-spawn
version: "1.2.0"
tagline: "Create a persistent Claude remote session on agenthost"
description: "Use when asked to create a remote session, schedule a persistent agent, spin up a Claude session for a project, or start a background Claude process. Creates a tmux+systemd session with --dangerously-skip-permissions, --continue auto-resume, and smart backoff."
allowed-tools:
  - Bash
---

# gstack-session-spawn

Use when asked to: "create a session for X", "create a remote session in X", "spin up an agent for X", or "start a background Claude process for X".

## Naming Convention

```
tmux session:    agenthost_<foldername>-<YYYYMMDD>
remote-control:  agenthost-<foldername>-<YYYYMMDD>
workdir (repo):  /home/agents/workspace/<foldername>
workdir (util):  /home/agents/.sessions/<foldername>
```

Use `workspace/` for repo sessions, `.sessions/` for utilities (managers, monitors, etc.).

## Key Rules

- `--dangerously-skip-permissions` always — sessions must never prompt
- Sentinel file `.sessions-init` prevents 0s exit on fresh workdirs triggering 300s backoff
- Auto-wire `using-superpowers` and all global skills into every session — do not wait for user to request it
- One Bash call for the entire recipe — do not split into multiple tool calls
- Scripts are local-only (`~/.local/bin/`, `~/.config/systemd/user/`) — no repo commits

## Recipe — run as ONE Bash call

Set `FOLDERNAME` and `WORKDIR` at the top, then paste the whole block:

```bash
FOLDERNAME="<foldername>"
DATE=$(date +%Y%m%d)
WORKDIR="/home/agents/workspace/${FOLDERNAME}"   # or /home/agents/.sessions/${FOLDERNAME}
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
log() { echo "[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] \$*"; }
log_start() {
  local _evt="\$1"
  local msg="[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] host=\$(hostname) session=\$SESSION remote=\$REMOTE_NAME workdir=\$WORKDIR event=\${_evt}"
  echo "\$msg" | tee -a "\$LOG_FILE"
}
if tmux has-session -t "${SESSION}" 2>/dev/null; then log_start "already-running"; exit 0; fi
log_start "starting"
mkdir -p "${WORKDIR}"
mkdir -p "${WORKDIR}/.claude/skills"
ln -sf /home/agents/.openclaw/skills/using-superpowers "${WORKDIR}/.claude/skills/using-superpowers" 2>/dev/null || true
for _skill in /home/agents/.claude/skills/*/; do
  _name=\$(basename "\$_skill")
  [ "\$_name" = "using-superpowers" ] && continue
  ln -sf "\$_skill" "${WORKDIR}/.claude/skills/\${_name}" 2>/dev/null || true
done
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
  [ "\$RUNTIME" -lt 30 ] && { echo "[${SESSION}] quick exit \${RUNTIME}s — backoff 300s"; sleep 300; } || { echo "[${SESSION}] exit \${RUNTIME}s — restart 10s"; sleep 10; }
done' Enter
log_start "started"
SCRIPT_EOF
chmod +x "$SCRIPT"

cat > "$SERVICE" << UNIT_EOF
[Unit]
Description=Claude Code Remote - ${REMOTE_NAME}
After=network-online.target openclaw-gateway.service
Wants=network-online.target
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

systemctl --user daemon-reload
systemctl --user enable --now "$(basename $SERVICE)"
python3 -c "
import json; p='/home/agents/.claude.json'; d=json.load(open(p))
d.setdefault('projects',{}).setdefault('${WORKDIR}',{})['hasTrustDialogAccepted']=True
json.dump(d,open(p,'w'),separators=(',',':'))
"
tmux list-sessions | grep "${SESSION}" && systemctl --user is-active "${REMOTE_NAME}.service"
```

## After Creating

Connect from Claude Code app: look for `agenthost-<foldername>-<YYYYMMDD>` in remote sessions.
Scripts are local-only (`~/.local/bin/`, `~/.config/systemd/user/`) — no repo commits.
