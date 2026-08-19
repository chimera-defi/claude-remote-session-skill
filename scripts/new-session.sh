#!/usr/bin/env bash
# new-session.sh — generate a per-remote start script + systemd unit for a
# persistent Claude Code session running in a tmux window with --remote-control.
#
# Usage: new-session <foldername> [workspace|sessions]
#   workspace (default when /home/agents/workspace/<name> exists) — repo sessions
#   sessions  — utility sessions (monitors, managers, etc.)
set -e

# ── Help ─────────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'HELP_EOF'
Usage: new-session <foldername> [workspace|sessions|auto] [--alias X] [--dry-run]

  foldername          Name for the session. Used in:
                        tmux session:    ah_<alias>-<MMDD-HHMM>
                        remote-control:  ah-<alias>-<MMDD-HHMM>
                        start script:    ~/.local/bin/ah-<alias>-<MMDD-HHMM>-start.sh
                        systemd service: ~/.config/systemd/user/ah-<alias>-<MMDD-HHMM>.service

  workspace           Force workdir to /home/agents/workspace/<foldername>
                      (repo sessions)
  sessions            Force workdir to /home/agents/.sessions/<foldername>
                      (utility sessions: monitors, managers, etc.)
  auto (default)      Use workspace/ if /home/agents/workspace/<foldername>
                      exists, otherwise .sessions/

Options:
  -h, --help          Print this help and exit.
  -a, --alias <x>     Short alias for the session name (persisted per folder).
  --dry-run           Print the resolved names and exit without spawning.
  --force             Spawn even when the preflight capacity gate refuses
                      (low RAM). Warnings are always advisory; only an
                      out-of-memory host blocks, and this overrides it.

Environment:
  CLAUDE_SESSION_MODEL=<model>  Model for the session (default: sonnet). A bare
                                alias (opus/sonnet/haiku) tracks the latest release
                                and can drift between spawns; pass an exact id
                                (e.g. claude-opus-4-8) to pin it reproducibly.

Examples:
  new-session my-project
  new-session my-project workspace
  new-session my-project sessions
  new-session my-long-project-name --alias mpn
  CLAUDE_SESSION_MODEL=opus new-session my-orchestrator sessions
  CLAUDE_SESSION_MODEL=claude-opus-4-8 new-session my-orchestrator sessions  # pinned
HELP_EOF
  exit 0
fi

# ── Inputs ──────────────────────────────────────────────────────────────────
FOLDERNAME=""; TYPE="auto"; ALIAS_ARG=""; DRYRUN=no; FORCE=no
while [ $# -gt 0 ]; do
  case "$1" in
    -a|--alias) ALIAS_ARG="${2:?--alias needs a value}"; shift 2 ;;
    --dry-run)  DRYRUN=yes; shift ;;
    --force)    FORCE=yes; shift ;;
    # NB: workspace/sessions/auto are only a TYPE when they appear AS the second
    # positional (after the folder). Matching them as the first positional would
    # make a folder literally named `sessions`/`workspace`/`auto` unspawnable
    # (e.g. the live `sessions` management session).
    *) if [ -z "$FOLDERNAME" ]; then FOLDERNAME="$1"; else TYPE="$1"; fi; shift ;;
  esac
done
: "${FOLDERNAME:?Usage: new-session <foldername> [workspace|sessions] [--alias X]}"

# ── Preflight capacity gate ──────────────────────────────────────────────────
# Sessions are long-lived and nothing reaps them automatically, so spawns
# accumulate until the box runs out of RAM and every session degrades together
# (observed 2026-08-16: 33 live sessions, 1.4G free of 64G, 18.5G in swap, load
# 8+ on 12 cores — turns taking 10-12min, `uv run` hanging with no output).
# A wedged fleet looks like a Claude bug but is really host exhaustion, so
# refuse to make it worse. Advisory by default; only a genuinely unsafe box
# hard-blocks, and --force always overrides.
preflight_capacity() {
  local avail_mb load1 cpus sess hard=no
  avail_mb=$(awk '/^MemAvailable:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 99999)
  load1=$(awk '{printf "%.0f", $1}' /proc/loadavg 2>/dev/null || echo 0)
  cpus=$(nproc 2>/dev/null || echo 1)
  sess=$(tmux ls -F '#{session_name}' 2>/dev/null | grep -cE '^(ah_|agenthost_)' || true)
  : "${sess:=0}"

  [ "$avail_mb" -lt "${NEW_SESSION_MIN_AVAIL_MB:-4096}" ] && { echo "warn: only ${avail_mb}MB RAM available — a new session needs ~400-600MB and will push the box into swap" >&2; hard=yes; }
  [ "$load1" -gt $(( cpus * 2 )) ] && echo "warn: load ${load1} on ${cpus} cpus — existing sessions are already CPU-starved" >&2
  [ "$sess" -ge 25 ] && echo "warn: ${sess} agenthost sessions already live — run 'session-doctor idle-report' and reap before adding more" >&2

  if [ "$hard" = yes ] && [ "$FORCE" != yes ]; then
    echo "" >&2
    echo "REFUSING to spawn: host is out of memory (${avail_mb}MB available)." >&2
    echo "  Free capacity first (reap idle sessions / stop a node), or re-run with --force." >&2
    return 1
  fi
  return 0
}
preflight_capacity || exit 1

# ── Model selection ─────────────────────────────────────────────────────────
# Override per-spawn with CLAUDE_SESSION_MODEL (e.g. for orchestrators).
MODEL="${CLAUDE_SESSION_MODEL:-sonnet}"
# A bare alias (opus/sonnet/haiku/...) tracks "the latest release" and can silently
# resolve to DIFFERENT models over time (observed: `opus` → claude-opus-5 one week,
# Opus 4.8 the next, with byte-identical flags). The CLI exposes no resolved-model
# readout and a model's self-report is unreliable, so the only reproducible fix is
# to pin an exact id. Warn and recommend pinning; MODEL is logged either way.
case "$MODEL" in
  opus|sonnet|haiku|fable|default|opusplan)
    echo "note: '$MODEL' is a moving model alias — it may resolve to different releases over time. For a reproducible pin set an exact id, e.g. CLAUDE_SESSION_MODEL=claude-opus-4-8" >&2 ;;
esac

# ── Resolve workdir ─────────────────────────────────────────────────────────
if [ "$TYPE" = "auto" ]; then
  [ -d "/home/agents/workspace/${FOLDERNAME}" ] && TYPE="workspace" || TYPE="sessions"
fi

if [ "$TYPE" = "workspace" ]; then
  WORKDIR="/home/agents/workspace/${FOLDERNAME}"
else
  WORKDIR="/home/agents/.sessions/${FOLDERNAME}"
fi

# ── Naming ──────────────────────────────────────────────────────────────────
# Name-first, date last: `ah-<alias>-<MMDD-HHMM>`. Aliases are short (capped /
# acronym'd), so the whole name fits the mobile window while reading naturally
# and grouping by project. Prefix `ah` (was `agenthost`); session-doctor
# understands both prefixes and does not parse the date, so order is opaque to it.
ID=$(date +%m%d-%H%M)
# In --dry-run, resolve read-only (--no-save) so a preview never mutates the store.
DRYFLAG=""; [ "$DRYRUN" = yes ] && DRYFLAG="--no-save"
if command -v session-alias >/dev/null 2>&1; then
  ALIAS=$(session-alias "$FOLDERNAME" ${ALIAS_ARG:+--alias "$ALIAS_ARG"} ${DRYFLAG:+$DRYFLAG} 2>/dev/null) || ALIAS=""
fi
# Fallback if the helper is missing (mirrors fallback-recipe): sanitized folder.
[ -n "$ALIAS" ] || ALIAS=$(printf '%s' "$FOLDERNAME" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//')
BODY="${ALIAS}-${ID}"
SESSION="ah_${BODY}"
REMOTE_NAME="ah-${BODY}"
# MMDD-HHMM is minute-granularity, so spawning the same folder twice inside one
# clock-minute would otherwise collide on SESSION. That's not just a cosmetic
# dupe: the generated script's own already-running guard (line ~130) would then
# silently exit on the second spawn, discarding whatever --alias/
# CLAUDE_SESSION_MODEL that call passed while still printing "Session created"
# below. Disambiguate against a live tmux session of the same name so every
# spawn really does get its own session, matching the documented guarantee.
#
# A plain "check tmux, then act" has a TOCTOU race: two invocations for the
# same folder started concurrently could both pass the has-session check
# before either has actually created its tmux session, and would then both
# settle on the same name (caught in review). Close that window with an
# mkdir-based lock — mkdir is atomic on POSIX filesystems, so only one
# concurrent invocation can ever hold a given name's lock — held only for the
# duration of this process (released on exit via the trap below) once the
# name is confirmed free. --dry-run never reserves anything (mirrors
# session-alias's --no-save: a preview must not mutate shared state), so it
# only does the plain liveness check.
if command -v tmux >/dev/null 2>&1; then
  if [ "$DRYRUN" = yes ]; then
    n=2
    while tmux has-session -t "$SESSION" 2>/dev/null; do
      BODY="${ALIAS}-${ID}-${n}"; SESSION="ah_${BODY}"; REMOTE_NAME="ah-${BODY}"; n=$((n+1))
    done
  else
    LOCKROOT="$HOME/.claude/session-spawn-locks"
    mkdir -p "$LOCKROOT" 2>/dev/null || true
    n=2
    while :; do
      if mkdir "$LOCKROOT/${SESSION}.lock" 2>/dev/null; then
        if tmux has-session -t "$SESSION" 2>/dev/null; then
          # Name was already live (a prior, non-racing spawn) — free the lock
          # we just took and move on to the next candidate name.
          rmdir "$LOCKROOT/${SESSION}.lock" 2>/dev/null
        else
          # A lock dir surviving past this process's exit is a crashed/killed
          # prior attempt (the trap below did not run) — a benign leak: it
          # just makes this exact name unavailable until removed by hand,
          # future spawns still get a working (suffixed) name.
          trap 'rmdir "$LOCKROOT/${SESSION}.lock" 2>/dev/null' EXIT
          break
        fi
      fi
      BODY="${ALIAS}-${ID}-${n}"; SESSION="ah_${BODY}"; REMOTE_NAME="ah-${BODY}"; n=$((n+1))
    done
  fi
fi
SCRIPT="$HOME/.local/bin/${REMOTE_NAME}-start.sh"
SERVICE="$HOME/.config/systemd/user/${REMOTE_NAME}.service"

if [ "$DRYRUN" = yes ]; then
  printf 'SESSION=%s\nREMOTE_NAME=%s\nSCRIPT=%s\nSERVICE=%s\n' "$SESSION" "$REMOTE_NAME" "$SCRIPT" "$SERVICE"
  exit 0
fi

mkdir -p "$(dirname "$SCRIPT")" "$(dirname "$SERVICE")"

# ── Generate start script ────────────────────────────────────────────────────
# Variables without backslash expand NOW (baked into generated script).
# Variables with backslash (\$) expand at runtime in the generated script.
cat > "$SCRIPT" << SCRIPT_EOF
#!/usr/bin/env bash
# Generated by new-session.sh — do not edit by hand.
SESSION="${SESSION}"
WORKDIR="${WORKDIR}"
REMOTE_NAME="${REMOTE_NAME}"
MODEL="${MODEL}"
export PATH="/home/agents/.local/bin:/home/agents/.npm-global/bin:/home/agents/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export HOME="/home/agents"
LOG_FILE="\$HOME/.sessions/session-starts.log"
mkdir -p "\$(dirname "\$LOG_FILE")"
log_start() { echo "[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] host=\$(hostname) session=\$SESSION remote=\$REMOTE_NAME workdir=\$WORKDIR model=\$MODEL event=\$1" | tee -a "\$LOG_FILE"; }
if tmux has-session -t "${SESSION}" 2>/dev/null; then log_start "already-running"; exit 0; fi
log_start "starting"
# Resolve the run directory: canonical tree (clean+free) or a fresh worktree.
RUNDIR="\$WORKDIR"
if command -v session-git-prep >/dev/null 2>&1; then
  PREP="\$(session-git-prep "\$WORKDIR" "\$SESSION" "\$REMOTE_NAME" 2>>"\$LOG_FILE")"
  [ -n "\$PREP" ] && RUNDIR="\$PREP"
fi
echo "[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] session=\$SESSION rundir=\$RUNDIR" | tee -a "\$LOG_FILE"
mkdir -p "\$RUNDIR/.claude"
rm -rf "\$RUNDIR/.claude/skills" && ln -sf /home/agents/.claude/skills "\$RUNDIR/.claude/skills"
# Remote-control bridge requires a first-party ANTHROPIC_BASE_URL (CLI >= 2026-07-07);
# a headroom/proxy base URL (e.g. 127.0.0.1) silently disables session registration so
# the session never appears on the phone. Force first-party via a dedicated --settings
# layer, which merges over the user settings.json (keeping hooks/MCP/plugins).
# Self-heal: (re)write if MISSING or not valid JSON. A truncated/corrupt file would
# otherwise make claude silently ignore it, fall back to the proxy base URL, and
# re-break registration with no error — so validate, don't just check existence.
python3 -c "import json;json.load(open('/home/agents/.claude/rc-firstparty.settings.json'))" 2>/dev/null || printf '{"env":{"ANTHROPIC_BASE_URL":"https://api.anthropic.com","DISABLE_AUTOUPDATER":"1"}}\n' > /home/agents/.claude/rc-firstparty.settings.json
if [ -f "\$RUNDIR/memory/MEMORY.md" ] && ! grep -q "Session Bootstrap" "\$RUNDIR/.claude/CLAUDE.md" 2>/dev/null; then
  printf '# Session Bootstrap\n\nOn your first response in any new session, read \`memory/MEMORY.md\` to load current project state, then summarize what needs to be done next and wait for instructions.\n' >> "\$RUNDIR/.claude/CLAUDE.md"
fi
tmux new-session -d -s "${SESSION}" -x 220 -y 50 -c "\$RUNDIR" -e "PATH=\$PATH" -e "HOME=\$HOME"
# Wait for the pane's interactive shell to be ready before typing into it, so
# the kickoff keystrokes are not swallowed by a still-initializing pane.
for _i in \$(seq 1 20); do
  case "\$(tmux display-message -p -t "${SESSION}" '#{pane_current_command}' 2>/dev/null)" in
    bash|zsh|sh) break ;;
  esac
  sleep 0.25
done
# Type the supervisor loop WITHOUT a trailing Enter, then submit + verify
# separately: a raced final Enter can be dropped, leaving the loop buffered in
# readline but never executed (the session then churns idle). Resend Enter until
# pane_current_command shows the loop actually launched.
tmux send-keys -t "${SESSION}" 'LOG_FILE="$HOME/.sessions/session-starts.log"
SESSION="${SESSION}"
SENTINEL="\$PWD/.sessions-init-${REMOTE_NAME}"
while true; do
  START=\$(date +%s)
  if [ -f "\$SENTINEL" ]; then
    /usr/bin/claude --dangerously-skip-permissions --model "${MODEL}" --settings /home/agents/.claude/rc-firstparty.settings.json --remote-control ${REMOTE_NAME} --continue
  else
    /usr/bin/claude --dangerously-skip-permissions --model "${MODEL}" --settings /home/agents/.claude/rc-firstparty.settings.json --remote-control ${REMOTE_NAME}
    touch "\$SENTINEL"
  fi
  RUNTIME=\$(( \$(date +%s) - START ))
  echo "[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] session=\$SESSION event=exit runtime=\${RUNTIME}s" | tee -a "\$LOG_FILE"
  if [ "\$RUNTIME" -lt 30 ]; then
    echo "[${SESSION}] quick exit \${RUNTIME}s — backoff 300s" | tee -a "\$LOG_FILE"
    echo "[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] session=\$SESSION event=backoff wait=300s" | tee -a "\$LOG_FILE"
    sleep 300
  else
    echo "[${SESSION}] exit \${RUNTIME}s — restart 10s" | tee -a "\$LOG_FILE"
    echo "[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] session=\$SESSION event=restart wait=10s" | tee -a "\$LOG_FILE"
    sleep 10
  fi
done'
kicked=no
for _try in 1 2 3; do
  tmux send-keys -t "${SESSION}" Enter
  for _j in \$(seq 1 12); do
    case "\$(tmux display-message -p -t "${SESSION}" '#{pane_current_command}' 2>/dev/null)" in
      claude|node|sleep) kicked=yes; break ;;
    esac
    sleep 0.5
  done
  [ "\$kicked" = yes ] && break
  echo "[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] session=\$SESSION event=kickoff-retry attempt=\$_try" | tee -a "\$LOG_FILE"
done
if [ "\$kicked" = yes ]; then
  log_start "started"
else
  log_start "started-UNVERIFIED-kickoff-may-have-failed"
fi
SCRIPT_EOF
chmod +x "$SCRIPT"

# ── Generate systemd unit ────────────────────────────────────────────────────
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
Environment=HOME=/home/agents
Environment=PATH=/home/agents/.local/bin:/home/agents/.npm-global/bin:/home/agents/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=TMUX_TMPDIR=/tmp
[Install]
WantedBy=default.target
UNIT_EOF

# ── Enable and start ─────────────────────────────────────────────────────────
systemctl --user daemon-reload && systemctl --user enable --now "$(basename $SERVICE)"

# ── Telemetry (best-effort, never fails the spawn) ──────────────────────────
# Prefer the directory the session actually launched in over WORKDIR:
# session-git-prep redirects into a fresh worktree whenever the canonical tree
# is dirty or already owned, and the bootstrap CLAUDE.md fragment (line ~197
# above) is appended there — not in WORKDIR — so WORKDIR's CLAUDE.md would be
# stale/wrong for worktree spawns. `systemctl --user enable --now` above
# blocks until ExecStart (the generated script) completes, and that script
# logs "session=$SESSION rundir=..." before returning, so the line is already
# there to read back. Falls back to WORKDIR if the log line isn't found.
TELEMETRY_DIR="$WORKDIR"
SPAWN_LOG="$HOME/.sessions/session-starts.log"
if [ -f "$SPAWN_LOG" ]; then
  LOGLINE="$(grep "session=${SESSION} rundir=" "$SPAWN_LOG" | tail -1)"
  # Bash's ${#*pat} removes the SHORTEST match from the front — unlike a
  # greedy sed s/.*rundir=//, which would strip up through the LAST
  # occurrence of "rundir=" in the line. A run directory whose path itself
  # contains the literal substring "rundir=" (e.g. .../repo-rundir=trial)
  # would otherwise get truncated to whatever follows its own last match.
  RD="${LOGLINE#*session=${SESSION} rundir=}"
  [ -n "$RD" ] && TELEMETRY_DIR="$RD"
fi
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
if [ -x "$SELF_DIR/record-spawn-telemetry.sh" ]; then
  "$SELF_DIR/record-spawn-telemetry.sh" "$FOLDERNAME" "$ALIAS" "$REMOTE_NAME" "$SESSION" "$TYPE" "$MODEL" "$TELEMETRY_DIR" || true
fi

# ── Confirm ──────────────────────────────────────────────────────────────────
echo ""
echo "Session created: ${REMOTE_NAME}"
echo "Connect: Claude Code app → Remote sessions → ${REMOTE_NAME}"
tmux list-sessions | grep "${SESSION}" || true
