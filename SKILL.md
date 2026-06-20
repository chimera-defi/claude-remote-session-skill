---
name: gstack-session-spawn
slug: gstack-session-spawn
version: "1.6.0"
tagline: "Create a persistent Claude remote session on agenthost"
description: "Use when asked to create a remote session, schedule a persistent agent, spin up a Claude session for a project, or start a background Claude process. Creates a tmux+systemd session with --dangerously-skip-permissions, --continue auto-resume, and smart backoff."
allowed-tools:
  - Bash
---

# gstack-session-spawn

Use when asked to: "create a session for X", "create a remote session in X", "spin up an agent for X", or "start a background Claude process for X".

## Naming Convention

```
tmux session:    agenthost_<foldername>-<YYYYMMDD-HHMM>
remote-control:  agenthost-<foldername>-<YYYYMMDD-HHMM>
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
- Git-aware run dir: when the workdir is a git repo, sessions start from the **default branch** — never a stale feature branch — and parallel sessions never collide (see below)

## Git-aware run directory (RUNDIR)

When the workdir is a git repo, the start script resolves where to run via the
`session-git-prep` helper (`~/.local/bin/session-git-prep`) instead of using the
checked-out branch as-is:

- **canonical tree is free + clean** → check it out on the default branch
  (`origin/HEAD` → `main` → `master`), pull latest when an `origin` exists, and
  claim it with an owner-lock under `~/.claude/session-locks/`
- **canonical tree is dirty or already owned by a live session** → create a
  fresh per-session worktree under `~/.claude/worktrees/<remote_name>` on a new
  `session/<remote_name>` branch cut from the default branch

This means a session never inherits a random current branch, and N agents can
work the same repo in parallel without stepping on each other. The helper never
fails a spawn — if anything goes wrong (or it's not on PATH) the start script
falls back to launching in `$WORKDIR` as-is. Non-git workdirs are unaffected.

## Recipe — use the script (preferred)

A standalone script handles the full recipe. Use it directly:

```bash
new-session <foldername>              # auto-detects workspace/ vs .sessions/
new-session <foldername> workspace    # force workspace/
new-session <foldername> sessions     # force .sessions/
```

Script lives at `~/.local/bin/new-session`. If it's missing, recreate it from the fallback recipe below.

## Recipe — fallback (manual, ONE Bash call)

Set `FOLDERNAME` and `WORKDIR` at the top, then paste the whole block:

```bash
FOLDERNAME="<foldername>"
DATE=$(date +%Y%m%d-%H%M)
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
RUNDIR="\$WORKDIR"
if command -v session-git-prep >/dev/null 2>&1; then
  PREP="\$(session-git-prep "\$WORKDIR" "\$SESSION" "\$REMOTE_NAME" 2>>"\$LOG_FILE")"
  [ -n "\$PREP" ] && RUNDIR="\$PREP"
fi
echo "[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] session=\$SESSION rundir=\$RUNDIR" | tee -a "\$LOG_FILE"
mkdir -p "\$RUNDIR/.claude"
rm -rf "\$RUNDIR/.claude/skills" && ln -sf /home/agents/.claude/skills "\$RUNDIR/.claude/skills"
if [ -f "\$RUNDIR/memory/MEMORY.md" ] && ! grep -q "Session Bootstrap" "\$RUNDIR/.claude/CLAUDE.md" 2>/dev/null; then
  printf '# Session Bootstrap\n\nOn your first response in any new session, read `memory/MEMORY.md` to load current project state, then summarize what needs to be done next and wait for instructions.\n' >> "\$RUNDIR/.claude/CLAUDE.md"
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

Connect from Claude Code app: look for `agenthost-<foldername>-<YYYYMMDD-HHMM>` in remote sessions.
Each spawn gets a unique name — never collides with same-day sessions.
Scripts are local-only (`~/.local/bin/`, `~/.config/systemd/user/`) — no repo commits.

## Sessions Agent Scope

A sessions management agent (workdir `/home/agents/.sessions/agenthost-sessions`) has a **bounded scope**:

- **Allowed**: create sessions, write handoffs to `memory/` in target repos, relay context, monitor session status
- **NOT allowed**: run scripts, execute optimizers, make code changes, or do project work for another repo

If project-specific work arrives in a sessions agent's context (e.g. a handoff describing optimizer runs):
1. Write a handoff to that repo's `memory/` folder with the pending work
2. Spawn or connect to the appropriate project session
3. Tell the user what session to use — do NOT execute the work yourself

The sessions agent's `CLAUDE.md` at `/home/agents/.sessions/agenthost-sessions/.claude/CLAUDE.md` enforces these rules.
