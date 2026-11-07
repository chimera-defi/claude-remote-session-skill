#!/usr/bin/env bash
# new-session — generate a per-remote start script and systemd unit for a persistent
# Claude Code session in tmux with --remote-control. Usage: new-session <foldername> [workspace|sessions]
# workspace (default when $CRSS_WORKSPACE/<name> exists) = repo sessions; sessions = utility sessions.
set -e
_crss_codex_args_from_env=${CRSS_CODEX_ARGS+yes}

# Host overlay config: see crss-lib.sh.
_crss_lib="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/crss-lib.sh"
# shellcheck source=scripts/crss-lib.sh
. "$_crss_lib" || { echo "${0##*/}: missing $_crss_lib; install crss-lib.sh next to this script" >&2; exit 2; }
_crss_load_config
: "${CRSS_WORKSPACE:=$HOME/workspace}"
: "${CRSS_SESSIONS_DIR:=$HOME/.sessions}"
: "${CRSS_CLAUDE_HOME:=$HOME/.claude}"
if [ -z "${CRSS_CLAUDE_BIN:-}" ]; then
  if [ -x /usr/bin/claude ]; then
    CRSS_CLAUDE_BIN=/usr/bin/claude
  else
    CRSS_CLAUDE_BIN="$(command -v claude 2>/dev/null || echo claude)"
  fi
fi
# The one place new-session names "the Opus we pin to" (orchestrator default + default advisor);
# $CRSS_HOME/config.sh overrides it.
: "${CRSS_OPUS_MODEL:=claude-opus-5-5}"

if [ -z "${CRSS_CODEX_BIN:-}" ]; then
  CRSS_CODEX_BIN="$(command -v codex 2>/dev/null || echo codex)"
fi
: "${CRSS_CODEX_ARGS:=}"

# Session-name prefix: see crss-lib.sh.
_crss_prefix_init

# Overlay state line, shown in --dry-run and the spawn confirmation so a missing overlay is visible.
_crss_overlay_cfg_state=absent; [ -f "$CRSS_HOME/config.sh" ] && _crss_overlay_cfg_state=found
_crss_overlay_rules_state=absent; [ -f "$CRSS_CLAUDE_HOME/rules/crss-host.md" ] && _crss_overlay_rules_state=found
OVERLAY_LINE="overlay: ${CRSS_HOME} (config: ${_crss_overlay_cfg_state}, rules: ${_crss_overlay_rules_state})"

# Help
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<HELP_EOF
Usage: new-session <foldername> [workspace|sessions|auto] [--alias X] [--backend claude|codex] [--dry-run]

  foldername          Name for the session. Used in (prefix "$CRSS_SESSION_PREFIX" —
                      override with \$CRSS_SESSION_PREFIX in \$CRSS_HOME/config.sh):
                        tmux session:    ${CRSS_SESSION_PREFIX}_<alias>-<MMDD-HHMM>
                        remote-control:  ${CRSS_SESSION_PREFIX}-<alias>-<MMDD-HHMM>
                        start script:    ~/.local/bin/${CRSS_SESSION_PREFIX}-<alias>-<MMDD-HHMM>-start.sh
                        systemd service: ~/.config/systemd/user/${CRSS_SESSION_PREFIX}-<alias>-<MMDD-HHMM>.service

  workspace           Force workdir to \$CRSS_WORKSPACE/<foldername>
                      (repo sessions; CRSS_WORKSPACE default: \$HOME/workspace)
  sessions            Force workdir to \$CRSS_SESSIONS_DIR/<foldername>
                      (utility sessions: monitors, managers, etc.; default: \$HOME/.sessions)
  auto (default)      Use workspace/ if \$CRSS_WORKSPACE/<foldername>
                      exists, otherwise the sessions dir

Options:
  -h, --help          Print this help and exit.
  -a, --alias <x>     Short alias for THIS spawn only. It does NOT change the
                      folder's stored default -- pass --set-default-alias too if
                      you really mean to rename the folder for every future spawn.
  --set-default-alias Persist the --alias value as the folder's new default.
                      Use only when the name describes the FOLDER, not the task:
                      a task name here becomes the folder's name forever.
  --dry-run           Print the resolved names and exit without spawning.
  --backend <b>       Session backend for this spawn: claude or codex.
                      Default: \$CRSS_SESSION_BACKEND, then claude.
  --force             Spawn even when the preflight capacity gate refuses
                      (low RAM). Warnings are always advisory; only an
                      out-of-memory host blocks, and this overrides it.
  --tier <t>          Right-size: light = Haiku, standard = Sonnet builder, heavy = Sonnet owner
                      (full tools) + Opus advisor; auto uses brief keywords. A tier NEVER selects
                      Opus: for an Opus orchestrator omit --tier (bare spawn = Opus).
                      Orchestrator default effort medium; use CLAUDE_SESSION_EFFORT=high at risky forks.
  --task-type <t>     Auto routing: orchestrate|review|mechanical|research|build.
  --tier-reason <s>   One line on why; recorded in spawn telemetry.
  --launcher <n>      Record <n> as this spawn's launcher (auto: tmux session name
                      inside tmux; Claude session id when set). See telemetry-report.sh --kids
  --escalate-from <n> Respawn one tier above session <n>'s recorded tier (explicit --tier wins).
  --task <text>       After the session boots, poll until claude is ready in
                      the pane, then send this as the first message and
                      verify it landed (reuses session-handoff's send+verify
                      dance — never sent blind). Mutually exclusive with
                      --task-file.
  --task-file <path>  Same as --task, but read the message from a file. A
                      missing/unreadable path fails immediately, before
                      anything is spawned.

Environment:
  CRSS_SESSION_BACKEND=<b>      Generic default backend for new sessions
                                (claude|codex; default: claude).
  CRSS_CODEX_BIN=<path>         Codex CLI path for --backend codex.
                                Default: command -v codex.
  CRSS_CODEX_ARGS=<args>        Extra Codex CLI args for --backend codex.
                                Default: empty. Host overlays commonly set
                                model/sandbox/approval flags here.
  CRSS_CODEX_BUILDER_TIER=<t>   Codex service tier for --task-type build
                                lanes (default: priority, i.e. fast mode;
                                "default" for the normal tier, empty to omit).
  CRSS_CODEX_LANE_MODEL=<m>, CRSS_CODEX_LANE_EFFORT=<e>  Model/effort for non-build Codex lanes (default gpt-6.1-sol, high).
  CLAUDE_SESSION_MODEL=<model>  Claude backend model. Unset → the PROFILE's
                                per-role default (see below): claude-opus-5-5
                                (pinned) for orchestrator; sonnet/sonnet/sonnet/haiku
                                for owner/hub/builder/copywriter — bare aliases that
                                auto-track the latest release for their tier.
                                Set it to override: a bare alias tracks latest,
                                or pass an exact id (e.g. claude-opus-5-5) to
                                pin one spawn reproducibly.
  CLAUDE_SESSION_EFFORT=<lvl>   Claude --effort (low|medium|high|xhigh|max). Unset → no flag
                                (--tier standard sets low).
  CLAUDE_SESSION_COMPACT_WINDOW=<n|host>
                                Auto-compact window (tokens) exported to claude at launch.
                                Unset → the tier's CRSS_COMPACT_WINDOW_{LIGHT,STANDARD,HEAVY}
                                overlay value, else CRSS_COMPACT_WINDOW_DEFAULT (234000).
                                "host" exports nothing (host settings.json default).
CLAUDE_SESSION_ADVISOR=<m>    Advisor model for sessions that have the advisor tool.
                                Default: CRSS_OPUS_MODEL; "none" omits the flag.
CLAUDE_SESSION_PROFILE=<p>    Tool-schema footprint + default model (default:
                                orchestrator).
                                orchestrator — full built-in tool set; needed for
                                  multi-agent fan-out (Workflow/Agent/…).
                                  Default model: claude-opus-5-5 (pinned).
                                owner        — same full tool set as orchestrator,
                                  for a long-lived campaign/lane owner that fans
                                  out to builders. Default model: sonnet (Sonnet
                                  owners keep the native advisor and cost less per
                                  resident turn; use orchestrator, or an explicit
                                  CLAUDE_SESSION_MODEL, when Opus is approved).
                                hub          — same full tool set as owner, but
                                  with a short appended system contract for Sonnet
                                  to consult Opus one-shot at major forks. Default
                                  model: sonnet.
                                builder      — trimmed --tools allowlist; drops the
                                  orchestration-only schemas to reclaim ~10.3k of the
                                  ~19.5k System-tools context. Hands-on
                                  implementation that doesn't fan out. Default: sonnet.
                                copywriter   — same trimmed allowlist; lightweight
                                  doc/copy work. Default model: haiku.
                                All profiles add
                                --exclude-dynamic-system-prompt-sections (a
                                prompt-cache-reuse win). Unknown values fall back
                                to orchestrator with a warning.
                                builder/copywriter (and any profile under
                                CRSS_AUTONOMOUS=1) also launch with the Superpowers
                                plugin switched off (its SessionStart hook costs ~900
                                tokens per start/clear/compact); orchestrator, owner
                                and hub keep it.

Examples:
  new-session my-project                                                     # orchestrator + claude-opus-5-5 (pinned)
  CLAUDE_SESSION_PROFILE=owner new-session my-lane-owner sessions            # full tools + sonnet
  CLAUDE_SESSION_PROFILE=hub new-session my-review-hub sessions              # full tools + Sonnet hub + Opus consult contract
  new-session my-project workspace
  new-session my-long-project-name --alias mpn
  CLAUDE_SESSION_PROFILE=builder new-session my-impl-task workspace          # trimmed tools + sonnet
  CLAUDE_SESSION_PROFILE=copywriter new-session my-docs-pass sessions        # trimmed tools + haiku
  CLAUDE_SESSION_MODEL=claude-opus-5-5 new-session my-orchestrator sessions  # pin a specific spawn
HELP_EOF
  exit 0
fi

# Inputs
FOLDERNAME=""; TYPE="auto"; ALIAS_ARG=""; BACKEND_ARG=""; DRYRUN=no; FORCE=no; TASK_ARG=""; TASK_FILE_ARG=""; TASK_TYPE=""; TIER_AUTO=no; SETDEFAULT_ALIAS=no; NPOS=0
TIER_ARG=""; TIER_REASON=""; ESCALATE_FROM=""; LAUNCHER_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    -a|--alias)  ALIAS_ARG="${2:?--alias needs a value}"; shift 2 ;;
    --backend)   BACKEND_ARG="${2:?--backend needs a value}"; shift 2 ;;
    --set-default-alias) SETDEFAULT_ALIAS=yes; shift ;;
    --dry-run)   DRYRUN=yes; shift ;;
    --force)     FORCE=yes; shift ;;
    --tier)      TIER_ARG="${2:?--tier needs a value}"; [ "$TIER_ARG" = auto ] && TIER_AUTO=yes; shift 2 ;;
    --task-type) TASK_TYPE="${2:?--task-type needs a value}"; shift 2 ;;
    --launcher) LAUNCHER_ARG="${2:?--launcher needs a session name}"; shift 2 ;;
    --escalate-from) ESCALATE_FROM="${2:?--escalate-from needs a session name}"; shift 2 ;;
    --tier-reason) TIER_REASON="${2:?--tier-reason needs a value}"; shift 2 ;;
    --task)      TASK_ARG="${2:?--task needs a value}"; shift 2 ;;
    --task-file) TASK_FILE_ARG="${2:?--task-file needs a value}"; shift 2 ;;
    # workspace/sessions/auto are a TYPE only as the second positional; as the first, a folder named sessions would be unspawnable.
    -*) echo "new-session: unknown option '$1' (see --help)" >&2; exit 2 ;;
    *) if [ "$NPOS" -eq 0 ]; then FOLDERNAME="$1"; elif [ "$NPOS" -eq 1 ]; then TYPE="$1"
       else echo "new-session: too many positional arguments ('$1') — usage: new-session <foldername> [workspace|sessions|auto] [options]" >&2; exit 2; fi
       NPOS=$((NPOS + 1)); shift ;;
  esac
done
if [ -n "$LAUNCHER_ARG" ] && { ! [[ "$LAUNCHER_ARG" =~ ^[A-Za-z0-9_.:-]{1,100}$ ]] || [[ "$LAUNCHER_ARG" = -* ]]; }; then
  echo "--launcher: invalid session name '$LAUNCHER_ARG'" >&2; exit 1
fi
if [ -n "$LAUNCHER_ARG" ] && ! tmux has-session -t "=$LAUNCHER_ARG" 2>/dev/null; then
  # Desktop launchers are not tmux sessions, so session-send cannot reach them.
  echo "new-session: note: launcher '$LAUNCHER_ARG' is not a live tmux session; session-send cannot reach it, so tell the lane to report via the host's bus/mailbox instead." >&2
fi
# Validate positionals before any side effect (pinned by tests/test-new-session-names.sh).
# FOLDERNAME is joined onto the workspace/sessions root, so it must be a bare name, not a path.
case "$FOLDERNAME" in
  ""|.|..|/*|*/*) echo "new-session: foldername '$FOLDERNAME' must be a bare name (no '/', not empty/./..) — it is joined onto \$CRSS_WORKSPACE or \$CRSS_SESSIONS_DIR. usage: new-session <foldername> [workspace|sessions|auto] [options]" >&2; exit 2 ;;
esac
case "$TYPE" in
  auto|workspace|sessions) ;;
  *) echo "new-session: unknown session type '$TYPE' (valid: workspace|sessions|auto) — usage: new-session <foldername> [workspace|sessions|auto] [options]" >&2; exit 2 ;;
esac
case "$TIER_ARG" in
  ""|light|standard|heavy|auto) ;;
  *) echo "new-session: unknown --tier '$TIER_ARG' (valid: light|standard|heavy|auto)" >&2; exit 2 ;;
esac
case "$TASK_TYPE" in ""|orchestrate|review|mechanical|research|build) ;; *) echo "new-session: invalid --task-type '$TASK_TYPE' (valid: orchestrate|review|mechanical|research|build)" >&2; exit 2 ;; esac
# --escalate-from: respawn one tier above the session's recorded tier; an explicit --tier wins. Never automatic.
if [ -n "$ESCALATE_FROM" ]; then
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
  if [ -z "$TIER_ARG" ]; then
    _prev_tier="$("$SELF_DIR/record-spawn-telemetry.sh" --tier-of "$ESCALATE_FROM" 2>/dev/null || true)"
    case "$_prev_tier" in
      light) TIER_ARG=standard ;;
      standard) TIER_ARG=heavy ;;
      heavy) echo "new-session: '$ESCALATE_FROM' already ran at tier heavy — escalating past it to Opus (orchestrator)" >&2
             TIER_ARG=heavy; CLAUDE_SESSION_PROFILE="${CLAUDE_SESSION_PROFILE:-orchestrator}"; export CLAUDE_SESSION_PROFILE ;;
      *) echo "new-session: no recorded tier for '$ESCALATE_FROM' — assuming standard, escalating to heavy" >&2; TIER_ARG=heavy ;;
    esac
    case "$TIER_REASON" in "") TIER_REASON="escalated from $ESCALATE_FROM ($_prev_tier)" ;; esac
  fi
fi
# Overlay roots are read literally (no $HOME or ~ expansion): a relative root would land the run dir in the cwd.
for _root_var in CRSS_WORKSPACE CRSS_SESSIONS_DIR; do
  case "${!_root_var}" in
    /*) ;;
    *) echo "new-session: ${_root_var}='${!_root_var}' must be an absolute path (the overlay is read literally: no \$HOME or ~ expansion)" >&2; exit 2 ;;
  esac
done

# Backend selection
BACKEND="${BACKEND_ARG:-${CRSS_SESSION_BACKEND:-claude}}"
case "$BACKEND" in
  claude|codex) ;;
  *) echo "new-session: unknown backend '$BACKEND' (valid: claude|codex)" >&2; exit 2 ;;
esac

_codex_model_from_args() {
  local prev="" tok
  for tok in ${CRSS_CODEX_ARGS:-}; do
    if [ "$prev" = "-m" ] || [ "$prev" = "--model" ]; then
      printf '%s\n' "$tok"
      return
    fi
    case "$tok" in
      -m?*) printf '%s\n' "${tok#-m}"; return ;;
      --model=*) printf '%s\n' "${tok#--model=}"; return ;;
    esac
    prev="$tok"
  done
}

# Split an overlay arg string like a shell would (quotes group), without evaluating it, then %q-escape each word.
# Unbalanced quotes fall back to a whitespace split.
_shell_words_literal() {
  local tok
  while IFS= read -r -d '' tok; do
    printf '%q ' "$tok"
  done < <(python3 - "${1:-}" <<'PY'
import shlex, sys
s = sys.argv[1]
try:
    words = shlex.split(s, comments=False, posix=True)
except ValueError:
    words = s.split()
sys.stdout.write(''.join(w + '\0' for w in words))
PY
)
}

_shell_quote() {
  printf '%q' "$1"
}

# Validate --task/--task-file before spawning: a spawned-but-unkicked session looks like it worked.
if [ -n "$TASK_ARG" ] && [ -n "$TASK_FILE_ARG" ]; then
  echo "new-session: --task and --task-file are mutually exclusive" >&2
  exit 2
fi
TASK=""
if [ -n "$TASK_FILE_ARG" ]; then
  if [ ! -r "$TASK_FILE_ARG" ]; then
    echo "new-session: --task-file '$TASK_FILE_ARG' is missing or unreadable" >&2
    exit 2
  fi
  TASK="$(cat "$TASK_FILE_ARG")"
elif [ -n "$TASK_ARG" ]; then
  TASK="$TASK_ARG"
fi

# Auto tier routing and quota checks
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# quota-check: co-located (repo layout) first, then PATH (deployed layout, .sh dropped).
QUOTA_CHECK=""
if [ -x "$SELF_DIR/quota-check.sh" ]; then QUOTA_CHECK="$SELF_DIR/quota-check.sh"
elif command -v quota-check >/dev/null 2>&1; then QUOTA_CHECK="$(command -v quota-check)"; fi
if [ "$TIER_AUTO" = yes ]; then
  _brief="${TASK,,}"; [ -n "$_brief" ] || _brief="${FOLDERNAME,,}"
  _tt="$TASK_TYPE"; _why_src=no\ match; _kw=""
  if [ -z "$_tt" ]; then
    # First rule with a whole-word keyword wins; stems spell out endings ([a-z]*), so add never matches address.
    for _rule in 'orchestrate:orchestrat[a-z]*|coordinat[a-z]*|plan the|lead the' 'review:reviews?|audits?|check|verify|lint' \
                 'mechanical:inventory|grep|triage|rename|move docs|mechanical' 'research:research|investigat[a-z]*|debug|design|root cause|why' \
                 'build:implement[a-z]*|build|fix|add|refactor|migrat[a-z]*|tests?|write'; do
      if [[ "$_brief" =~ (^|[^a-z0-9])(${_rule#*:})([^a-z0-9]|$) ]]; then _tt=${_rule%%:*}; _kw=${BASH_REMATCH[2]}; break; fi
    done
    [ -z "$_kw" ] || _why_src="keyword '$_kw'"
  else _why_src=--task-type; fi
  [ -n "$_tt" ] || _tt=none
  case "$_tt" in
    orchestrate) TIER_ARG=""; _auto_backend=claude; CLAUDE_SESSION_PROFILE=${CLAUDE_SESSION_PROFILE:-orchestrator} ;;
    review|mechanical) TIER_ARG=light; _auto_backend=claude; CLAUDE_SESSION_PROFILE=${CLAUDE_SESSION_PROFILE:-copywriter}; CLAUDE_SESSION_MODEL=${CLAUDE_SESSION_MODEL:-haiku}; CLAUDE_SESSION_EFFORT=${CLAUDE_SESSION_EFFORT:-low} ;;
    research) TIER_ARG=heavy; _auto_backend=claude; CLAUDE_SESSION_PROFILE=${CLAUDE_SESSION_PROFILE:-owner}; CLAUDE_SESSION_MODEL=${CLAUDE_SESSION_MODEL:-sonnet} ;;
    build) TIER_ARG=standard; _auto_backend=codex ;;
    *) TIER_ARG=standard; _tt=none; _auto_backend=claude; CLAUDE_SESSION_PROFILE=${CLAUDE_SESSION_PROFILE:-builder}; CLAUDE_SESSION_MODEL=${CLAUDE_SESSION_MODEL:-sonnet}; CLAUDE_SESSION_EFFORT=${CLAUDE_SESSION_EFFORT:-low} ;;
  esac
  if [ -z "$BACKEND_ARG" ] && [ -z "${CRSS_SESSION_BACKEND+x}" ]; then BACKEND="$_auto_backend"; fi
  TIER_AUTO_TYPE=$_tt; [ -n "$TIER_REASON" ] || TIER_REASON="auto: $_tt via $_why_src"
else TIER_AUTO_TYPE=""; fi
_apply_codex_builder_args() {
  [ "${_crss_codex_args_from_env:-}" = yes ] && return 0
  # Rewrite in Python; shlex.join output is the quoting _shell_words_literal parses back.
  CRSS_CODEX_ARGS="$(python3 - "${CRSS_CODEX_ARGS:-}" "${CRSS_CODEX_BUILDER_MODEL:-gpt-6.1-terra}" "${CRSS_CODEX_BUILDER_EFFORT:-low}" "${CRSS_CODEX_BUILDER_TIER-priority}" <<'PY'
import shlex,sys
args,model,effort,tier=sys.argv[1:]
try: w=shlex.split(args)
except ValueError: w=args.split()
out=[]; i=0; found=False
while i<len(w):
  t=w[i]
  if t in ('-m','--model'): out+=[t,model]; i+=2; found=True; continue
  if t.startswith('--model='): out.append('--model='+model); found=True
  elif t.startswith('-m') and len(t)>2 and not t.startswith('--'): out.append('-m'+model); found=True
  else: out.append(t)
  i+=1
if not found: out=['-m',model]+out
if not any('model_reasoning_effort' in t for t in out): out+=['-c','model_reasoning_effort='+effort]
if tier and not any('service_tier' in t for t in out): out+=['-c','service_tier='+tier]
print(shlex.join(out))
PY
)"
}
[ "${TIER_AUTO_TYPE:-}" = build ] && [ "$BACKEND" = codex ] && _apply_codex_builder_args
# Non-build Codex lanes keep gpt-6.1-sol high: the ~/.codex default is terra-low, which the bench did not cover for reviews.
_apply_codex_lane_args() { CRSS_CODEX_BUILDER_MODEL=${CRSS_CODEX_LANE_MODEL:-gpt-6.1-sol} CRSS_CODEX_BUILDER_EFFORT=${CRSS_CODEX_LANE_EFFORT:-high} _apply_codex_builder_args; }
[ "$BACKEND" = codex ] && [ "${TIER_AUTO_TYPE:-}" != build ] && _apply_codex_lane_args
QUOTA_RESULT=none; QUOTA_FROM=""; QUOTA_EVIDENCE=""
if [ "${CRSS_QUOTA_FAILOVER:-1}" != 0 ]; then
  if [ -z "$QUOTA_CHECK" ]; then echo 'new-session: quota-check.sh missing; quota failover skipped' >&2
  elif [ "$BACKEND" = codex ] || [ "$BACKEND" = claude ]; then
    _from=$BACKEND; if _out=$("$QUOTA_CHECK" "$BACKEND-status"); then _orc=0; else _orc=$?; fi
    if { [ "$BACKEND" = codex ] && [ "$_orc" = 10 ]; } || { [ "$BACKEND" = claude ] && [ "$_orc" = 11 ]; }; then
      _other=claude; [ "$BACKEND" = claude ] && _other=codex
      if _other_out=$("$QUOTA_CHECK" "$_other-status"); then _other_rc=0; else _other_rc=$?; fi
      if { [ "$_other" = claude ] && [ "$_other_rc" = 11 ]; } || { [ "$_other" = codex ] && [ "$_other_rc" = 10 ]; }; then
        QUOTA_RESULT=both-out; echo "$_out" >&2; echo "$_other_out" >&2; echo 'both quotas out: pausing — report the exact text above to the launcher' >&2; [ "$DRYRUN" = yes ] && echo QUOTA=both-out; exit 3
      fi
      if [ "$BACKEND" = codex ]; then
        QUOTA_RESULT=codex-out; QUOTA_FROM=codex; QUOTA_EVIDENCE=$_out; BACKEND=claude; CLAUDE_SESSION_PROFILE=${CLAUDE_SESSION_PROFILE:-builder}; CLAUDE_SESSION_MODEL=${CLAUDE_SESSION_MODEL:-sonnet}; CLAUDE_SESSION_EFFORT=${CLAUDE_SESSION_EFFORT:-low}; [ -n "$TIER_ARG" ] || TIER_ARG=standard; TIER_REASON="${TIER_REASON:+$TIER_REASON; }quota failover codex->claude"; echo "quota failover: Codex out ($_out) -> Claude builder sonnet low" >&2
      else
        QUOTA_RESULT=claude-out; QUOTA_FROM=claude; QUOTA_EVIDENCE=$_out; BACKEND=codex; if [ "${TIER_AUTO_TYPE:-}" = build ]; then _apply_codex_builder_args; else _apply_codex_lane_args; fi; echo 'quota failover: Claude out ('"$_out"') -> Codex-only (gpt-6.1-terra low builds and gpt-6.1-sol reviews; PR must say "single-family review (Claude quota-out)")' >&2
      fi
    fi
  fi
fi

# Preflight capacity gate. Nothing reaps sessions, so spawns pile up until RAM runs out and the whole
# fleet degrades (host exhaustion looks like a Claude bug). Advisory by default; only an unsafe box
# hard-blocks, and --force overrides.
preflight_capacity() {
  # --dry-run must stay a side-effect-free preview, so it skips the gate even on a low-memory host.
  [ "$DRYRUN" = yes ] && return 0
  local avail_mb load1 cpus sess hard=no
  avail_mb=$(awk '/^MemAvailable:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 99999)
  load1=$(awk '{printf "%.0f", $1}' /proc/loadavg 2>/dev/null || echo 0)
  cpus=$(nproc 2>/dev/null || echo 1)
  sess=$(tmux ls -F '#{session_name}' 2>/dev/null | grep -cE "^(${_crss_prefix_re})_" || true)
  : "${sess:=0}"

  [ "$avail_mb" -lt "${NEW_SESSION_MIN_AVAIL_MB:-4096}" ] && { echo "warn: only ${avail_mb}MB RAM available — a new session needs ~400-600MB and will push the box into swap" >&2; hard=yes; }
  [ "$load1" -gt $(( cpus * 2 )) ] && echo "warn: load ${load1} on ${cpus} cpus — existing sessions are already CPU-starved" >&2
  [ "$sess" -ge 25 ] && echo "warn: ${sess} sessions (prefix: ${_crss_prefix_re}) already live — run 'session-doctor idle-report' and reap before adding more" >&2

  if [ "$hard" = yes ] && [ "$FORCE" != yes ]; then
    echo "" >&2
    echo "REFUSING to spawn: host is out of memory (${avail_mb}MB available)." >&2
    echo "  Free capacity first (reap idle sessions / stop a node), or re-run with --force." >&2
    return 1
  fi
  return 0
}
preflight_capacity || exit 1

# Profile/model selection
if [ "$BACKEND" = claude ]; then
  # CLAUDE_SESSION_PROFILE sets both the tool-schema footprint and the default model.
  # --tier sets defaults only (explicit env vars win). A tier never selects Opus (pinned by tests/test-new-session-tier.sh).
  [[ "$CRSS_OPUS_MODEL" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || { echo "new-session: CRSS_OPUS_MODEL='$CRSS_OPUS_MODEL' must match ^[a-z0-9][a-z0-9.-]*\$" >&2; exit 2; }
  case "$TIER_ARG" in light) T_PROFILE=copywriter; T_EFFORT=low ;; standard) T_PROFILE=builder; T_EFFORT=low ;;
    heavy) T_PROFILE=owner; T_EFFORT="" ;; *) T_PROFILE=orchestrator; T_EFFORT="" ;; esac
  PROFILE="${CLAUDE_SESSION_PROFILE:-$T_PROFILE}"
  case "$PROFILE" in
    orchestrator|owner|hub|builder|copywriter) ;;
    *) if [ -n "$TIER_ARG" ]; then echo "new-session: unknown CLAUDE_SESSION_PROFILE='$PROFILE' (valid: orchestrator|owner|hub|builder|copywriter)" >&2; exit 2; fi
       echo "note: unknown CLAUDE_SESSION_PROFILE='$PROFILE' — defaulting to 'orchestrator' (full tool set). Valid: orchestrator|owner|hub|builder|copywriter" >&2
       PROFILE="orchestrator" ;;
  esac
  if [ "$PROFILE" = orchestrator ]; then _default_effort=${CRSS_ORCHESTRATOR_EFFORT:-medium}; else _default_effort=$T_EFFORT; fi
  EFFORT="${CLAUDE_SESSION_EFFORT:-$_default_effort}"; [ "$EFFORT" = none ] && EFFORT=""
  case "$EFFORT" in ""|none|low|medium|high|xhigh|max) ;; *) echo "new-session: CLAUDE_SESSION_EFFORT='$EFFORT' invalid (low|medium|high|xhigh|max)" >&2; exit 2 ;; esac

  if [ -n "${CLAUDE_SESSION_MODEL:-}" ]; then
    # Same shape as CRSS_OPUS_MODEL: a model in the "..." launch line must not break out with " $ ` or backslash.
    # [1m] (1M context) is the one bracket form allowed; brackets are inert inside those quotes.
    _model_re='^[a-z0-9][a-z0-9.-]*(\[1m\])?$'
    [[ "$CLAUDE_SESSION_MODEL" =~ $_model_re ]] || { echo "new-session: CLAUDE_SESSION_MODEL='$CLAUDE_SESSION_MODEL' must match $_model_re" >&2; exit 2; }
    MODEL="$CLAUDE_SESSION_MODEL"; MODEL_SRC=explicit
    [[ "$MODEL" == *'[1m]' ]] && echo "note: CLAUDE_SESSION_MODEL='$MODEL' accepted: 1M context comes only from the [1m] suffix (without it, ${MODEL%'[1m]'} runs at standard context)" >&2
  else
    case "$PROFILE" in
      orchestrator) MODEL="$CRSS_OPUS_MODEL" ;;
      owner)        MODEL=sonnet ;;
      hub)          MODEL=sonnet ;;
      builder)      MODEL=sonnet ;;
      copywriter)   MODEL=haiku ;;
    esac
    MODEL_SRC=profile-default
  fi
  if [ "$MODEL_SRC" = explicit ]; then
    case "$MODEL" in
      opus|sonnet|haiku|fable|default|opusplan)
        echo "note: '$MODEL' is a moving model alias — it may resolve to different releases over time. For a reproducible pin set an exact id, e.g. CLAUDE_SESSION_MODEL=claude-opus-5-5" >&2 ;;
    esac
  fi
else
  PROFILE=codex; EFFORT=""
  MODEL="$(_codex_model_from_args)"
  if [ -n "$MODEL" ]; then
    MODEL_SRC=codex-args
  else
    MODEL=codex
    MODEL_SRC=backend-default
  fi
fi

# Builder/copywriter built-in allowlist, comma-separated with no spaces (one shell word in the claude command).
# --tools is exhaustive over built-ins, deferred ones too: an omitted built-in is unreachable even via ToolSearch.
# Dropping Workflow, Artifact, SendUserFile, ReportFindings and ScheduleWakeup saves ~10k of upfront schema.
# advisor stays: builders reach for a second opinion, and it is gated on the agent's own model (sonnet has it).
# AskUserQuestion is omitted: an unwatched lane must never ask.
BUILDER_TOOLS="Bash,Read,Edit,Write,Glob,Grep,Agent,Skill,ToolSearch,WebFetch,WebSearch,TaskCreate,TaskGet,TaskList,TaskUpdate,TaskStop,TaskOutput,EnterPlanMode,ExitPlanMode,NotebookEdit,Monitor,advisor"
HUB_CONSULT_PROMPT='You are a Sonnet hub. At forks consult Opus one-shot via Agent(model:"opus") after first writing a frozen packet to .claude/hub-opus-frozen-packet.md. Packet only: state, options, your recommendation, UNVERIFIED list, file paths; never transcripts. Forks: before destructive/irreversible actions, design under real ambiguity, and before declaring a multi-step task done. Never use Opus/Fable as polling or waiting sessions. Builders default Codex-first (new-session --backend codex, codex exec), then Sonnet fallback. Record models_ran with actual models.'
# Unattended lanes escalate rather than wait.
BUILDER_ESCALATION_PROMPT='Unattended lane: nobody reads this pane and AskUserQuestion is off. Never end a turn on a plain-text question and wait. When you need a decision or input, or a denied tool or permission blocks you: send the exact need to your launcher with session-send <launcher> --file <file> (if the launcher is not a tmux session, post on the coordination bus per ~/.config/crss/local.md Escalation), then print one final line starting BLOCKED: with that need, and keep doing any work that does not depend on it.'
ORCHESTRATOR_DELEGATION_PROMPT='Delegation (operator 2026-10-25, keep quota): you orchestrate and write no code yourself. Every build, fix, script, test or doc edit goes to Codex: codex exec -m gpt-6.1-terra -c model_reasoning_effort=low -c service_tier=priority -c skills.include_instructions=false --disable multi_agent -c project_doc_max_bytes=0 "<bounded task, files, test command>" </dev/null, or a kid via new-session --backend codex. Fan out: run independent slices as parallel background codex exec jobs. Run each slice'\''s test; only on failure: Haiku low repair (claude -p --model haiku --effort low --tools ""), then gpt-6-astra medium, then a Sonnet builder. Read-only research: Haiku high or gpt-6.1-sol low, never an Opus subagent. Fable reads are paused (operator 2026-10-28): review with one gpt-6.1-sol call per bundle. Codex quota-out only on the exact error text. End each Codex brief with: commit only on this branch, no merge or push; propose, do not do: list other changes under PROPOSED. Name a done-check it cannot game, and diff-check renames and allowlist or skip edits before accepting. At most 3 parallel builders per repo, on disjoint files. Read-only scans and prose drafts: Haiku high, written to a file. Re-run each builder'\''s cited check yourself before reporting done. See references/orchestration-flow.md.'

# Moves cwd/env/git-status out of the cached system prompt: a prompt-cache win that relocates tokens, not shrinks them.
CLAUDE_EXTRA_FLAGS="--exclude-dynamic-system-prompt-sections"
# Superpowers SessionStart costs ~900 tokens per start/clear/compact and pushes brainstorming before any reply,
# so builder, copywriter and autonomous spawns run without it. Repeated --settings flags replace each other
# (last wins), so the lane file is derived from rc-firstparty, which keeps ANTHROPIC_BASE_URL for remote-control.
# CRSS_LANE_DENY (empty disables) is unioned into permissions.deny; the token-reduce MCP is unused (lanes use the CLI).
SUPERPOWERS=on
SUPERPOWERS_PLUGIN="superpowers@claude-plugins-official"
if [ -z "${CRSS_LANE_DENY+x}" ]; then
  CRSS_LANE_DENY="mcp__gbrain,mcp__plugin_token-reduce_token-reduce-mcp,SendFeedback,ReportFindings"
fi
SETTINGS_FILE="${CRSS_CLAUDE_HOME}/rc-firstparty.settings.json"
if [ "${CRSS_AUTONOMOUS:-0}" = 1 ]; then
  HUB_CONSULT_PROMPT='Autonomous bounded session: no child agents, advisor fanout, compaction, polling or self-restarts. Finish one finite task, record its result and stop. Operator judgment requires a separately admitted frozen packet.'
  CLAUDE_EXTRA_FLAGS="$CLAUDE_EXTRA_FLAGS --disallowedTools Agent"
fi
COMPACT_WINDOW=""
if [ "$BACKEND" = claude ]; then
  # Auto-compact window: per-spawn CLAUDE_SESSION_COMPACT_WINDOW, then the tier's CRSS_COMPACT_WINDOW_<TIER>,
  # then the default (234000, about 150k with CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=70). "host" exports nothing.
  # Only a launch-environment export reaches claude (references/troubleshooting.md).
  _cw_var=""
  [ -z "$TIER_ARG" ] || _cw_var="CRSS_COMPACT_WINDOW_$(printf '%s' "$TIER_ARG" | tr '[:lower:]' '[:upper:]')"
  if [ -n "${CLAUDE_SESSION_COMPACT_WINDOW:-}" ]; then
    COMPACT_WINDOW="$CLAUDE_SESSION_COMPACT_WINDOW"
  elif [ -n "$_cw_var" ] && [ -n "${!_cw_var:-}" ]; then
    COMPACT_WINDOW="${!_cw_var}"
  else
    COMPACT_WINDOW="${CRSS_COMPACT_WINDOW_DEFAULT:-234000}"
  fi
  [ "$COMPACT_WINDOW" != host ] || COMPACT_WINDOW=""
  case "$COMPACT_WINDOW" in
    "") ;;
    *[!0-9]*) echo "new-session: compact window '$COMPACT_WINDOW' invalid (an integer token count in 100000..2000000, or 'host')" >&2; exit 2 ;;
    *) if [ "$COMPACT_WINDOW" -lt 100000 ] || [ "$COMPACT_WINDOW" -gt 2000000 ]; then
         echo "new-session: compact window '$COMPACT_WINDOW' out of range (100000..2000000, or 'host')" >&2; exit 2; fi ;;
  esac
  case "$PROFILE" in builder|copywriter) SUPERPOWERS=off ;; esac
  [ "${CRSS_AUTONOMOUS:-0}" != 1 ] || SUPERPOWERS=off
  [ "$SUPERPOWERS" = on ] || SETTINGS_FILE="${CRSS_CLAUDE_HOME}/rc-firstparty-no-superpowers.settings.json"
  # Keep the lane file name a suffix of the plain path: the hostile-path test rewrites that prefix.
  if [ "$SUPERPOWERS" = on ] && [ -n "$CRSS_LANE_DENY" ]; then
    SETTINGS_FILE="${SETTINGS_FILE%.settings.json}-lane.settings.json"
  fi
  case "$PROFILE" in
    hub) CLAUDE_EXTRA_FLAGS="$CLAUDE_EXTRA_FLAGS --append-system-prompt $(_shell_quote "$HUB_CONSULT_PROMPT")" ;;
    orchestrator|owner)
      if [ "${CRSS_AUTONOMOUS:-0}" != 1 ] && [ "${CRSS_ORCHESTRATOR_PROMPT:-}" != off ]; then
        CLAUDE_EXTRA_FLAGS="$CLAUDE_EXTRA_FLAGS --append-system-prompt $(_shell_quote "$ORCHESTRATOR_DELEGATION_PROMPT")"
      fi ;;
    builder|copywriter)
      _builder_prompt="$BUILDER_ESCALATION_PROMPT"
      [ -z "$LAUNCHER_ARG" ] || _builder_prompt="${_builder_prompt} Your launcher is ${LAUNCHER_ARG}."
      CLAUDE_EXTRA_FLAGS="$CLAUDE_EXTRA_FLAGS --tools $BUILDER_TOOLS --append-system-prompt $(_shell_quote "$_builder_prompt")"
      ;;
  esac
  [ -z "$EFFORT" ] || CLAUDE_EXTRA_FLAGS="$CLAUDE_EXTRA_FLAGS --effort $EFFORT"
  # Default advisor is the pinned Opus, except on Opus/Fable sessions (self-advice). The advisor reads the
  # whole transcript, so it is Opus spend; CLAUDE_SESSION_ADVISOR overrides it (an explicit id is honoured).
  ADVISOR="${CLAUDE_SESSION_ADVISOR:-$CRSS_OPUS_MODEL}"
  [ -n "${CLAUDE_SESSION_ADVISOR:-}" ] || case "$MODEL" in *opus*|*fable*) ADVISOR=none ;; esac
  [[ "$ADVISOR" == none || "$ADVISOR" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || { echo "new-session: CLAUDE_SESSION_ADVISOR='$ADVISOR' invalid (model id or none)" >&2; exit 2; }
  [ "$ADVISOR" = none ] || CLAUDE_EXTRA_FLAGS="$CLAUDE_EXTRA_FLAGS --advisor $ADVISOR"
else
  CLAUDE_EXTRA_FLAGS=""; ADVISOR=none; SUPERPOWERS=n/a
fi

# Resolve workdir
# TYPE was validated with the other positionals above.
if [ "$TYPE" = "auto" ]; then
  [ -d "${CRSS_WORKSPACE}/${FOLDERNAME}" ] && TYPE="workspace" || TYPE="sessions"
fi

if [ "$TYPE" = "workspace" ]; then
  WORKDIR="${CRSS_WORKSPACE}/${FOLDERNAME}"
else
  WORKDIR="${CRSS_SESSIONS_DIR}/${FOLDERNAME}"
fi

# Naming
# Name is <prefix>-<alias>-<MMDD-HHMM>. Prefix is $CRSS_SESSION_PREFIX (see crss-lib.sh).
# session-doctor does not parse the date, so the order is free.
ID=$(date +%m%d-%H%M)
# In --dry-run, resolve read-only (--no-save) so a preview never mutates the store.
DRYFLAG=""; [ "$DRYRUN" = yes ] && DRYFLAG="--no-save"
# --alias alone is per-spawn; only --set-default-alias makes it the folder default.
SETDEFFLAG=""; [ "$SETDEFAULT_ALIAS" = yes ] && SETDEFFLAG="--set-default"
if command -v session-alias >/dev/null 2>&1; then
  ALIAS=$(session-alias "$FOLDERNAME" ${ALIAS_ARG:+--alias "$ALIAS_ARG"} ${SETDEFFLAG:+$SETDEFFLAG} ${DRYFLAG:+$DRYFLAG} 2>/dev/null) || ALIAS=""
fi
# Fallback when session-alias is missing: sanitized folder name.
[ -n "$ALIAS" ] || ALIAS=$(printf '%s' "$FOLDERNAME" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//')
BODY="${ALIAS}-${ID}"
SESSION="${CRSS_SESSION_PREFIX}_${BODY}"
REMOTE_NAME="${CRSS_SESSION_PREFIX}-${BODY}"
# MMDD-HHMM is minute-granular, so a same-minute respawn would collide. The start script's already-running
# guard would then exit silently. Pick a free name under an mkdir lock (atomic, so concurrent spawns cannot
# both take it). Dry-run reserves nothing and only checks liveness.
# name_taken: a live tmux session, or a worktree still at ~/.claude/worktrees/<name>, makes a name unavailable.
# Reap leaves worktree dirs behind, and session-git-prep reuses a same-name worktree as a restart, so a
# reused name would hand a new session leftover dirty state.
name_taken() {
  tmux has-session -t "$1" 2>/dev/null && return 0
  [ -e "$HOME/.claude/worktrees/$2" ] && return 0
  return 1
}
if command -v tmux >/dev/null 2>&1; then
  if [ "$DRYRUN" = yes ]; then
    n=2
    while name_taken "$SESSION" "$REMOTE_NAME"; do
      BODY="${ALIAS}-${ID}-${n}"; SESSION="${CRSS_SESSION_PREFIX}_${BODY}"; REMOTE_NAME="${CRSS_SESSION_PREFIX}-${BODY}"; n=$((n+1))
    done
  else
    LOCKROOT="$HOME/.claude/session-spawn-locks"
    mkdir -p "$LOCKROOT" 2>/dev/null || true
    n=2
    # Bounded: a persistent mkdir failure (read-only or full filesystem) would otherwise spin forever silently.
    while :; do
      if mkdir "$LOCKROOT/${SESSION}.lock" 2>/dev/null; then
        if name_taken "$SESSION" "$REMOTE_NAME"; then
          # Taken: free the lock and try the next candidate.
          rmdir "$LOCKROOT/${SESSION}.lock" 2>/dev/null
        else
          # A lock dir left by a killed prior attempt only blocks this exact name until removed by hand.
          trap 'rmdir "$LOCKROOT/${SESSION}.lock" 2>/dev/null' EXIT
          break
        fi
      fi
      # Build from the current n, then increment, so the first retry is -2 (as the dry-run branch and tests expect).
      BODY="${ALIAS}-${ID}-${n}"; SESSION="${CRSS_SESSION_PREFIX}_${BODY}"; REMOTE_NAME="${CRSS_SESSION_PREFIX}-${BODY}"
      n=$((n+1))
      if [ "$n" -gt 1000 ]; then
        echo "new-session: could not claim a session-name lock under '$LOCKROOT' after 1000 attempts — likely a persistent filesystem problem (read-only/full), not a race. Check '$LOCKROOT' by hand." >&2
        exit 1
      fi
    done
  fi
fi
# Admission config is written into the generated loops, so it survives reboot.
ADMISSION_SUBJECT="${CRSS_ADMISSION_SUBJECT:-$SESSION}"
ADMISSION_CONFIG_INVALID=0
[[ "$ADMISSION_SUBJECT" =~ ^[a-zA-Z0-9_./:-]+$ ]] || ADMISSION_CONFIG_INVALID=1
ADMISSION_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/autonomous-admission.sh"
if [ ! -f "$ADMISSION_HELPER" ]; then ADMISSION_HELPER="$(command -v autonomous-admission 2>/dev/null || true)"; fi
for admission_path in "$ADMISSION_HELPER" "${AGENT_HOST_ADMISSION_CLI:-}" "${AGENT_HOST_ADMISSION_DB:-}" "${AGENT_HOST_ADMISSION_EVIDENCE:-}"; do
  if [ -n "$admission_path" ] && [[ ! "$admission_path" =~ ^/[a-zA-Z0-9_./-]+$ ]]; then
    ADMISSION_CONFIG_INVALID=1
  fi
done
if [ "$ADMISSION_CONFIG_INVALID" = 1 ]; then
  if [ "${CRSS_AUTONOMOUS:-0}" = 1 ] && [ "$DRYRUN" != yes ]; then
    echo "new-session: invalid admission configuration" >&2; exit 2
  fi
  # A bad config must not block a human launch or preview; autonomous passes still fail closed.
  ADMISSION_SUBJECT=manual
  ADMISSION_HELPER=""
  AGENT_HOST_ADMISSION_CLI=""; AGENT_HOST_ADMISSION_DB=""; AGENT_HOST_ADMISSION_EVIDENCE=""
fi
# Restarts consult admission only when something can answer (autonomous, a configured authority, or a broken
# config, which fails closed). A manual session with no authority restarts freely.
ADMISSION_GATED=0
if [ "${CRSS_AUTONOMOUS:-0}" = 1 ] || [ "$ADMISSION_CONFIG_INVALID" = 1 ] || [ -n "${AGENT_HOST_ADMISSION_CLI:-}" ]; then
  ADMISSION_GATED=1
fi
SCRIPT="$HOME/.local/bin/${REMOTE_NAME}-start.sh"
HUB_CONSULT_PROMPT_FILE=""
[ "$BACKEND" = claude ] && [ "$PROFILE" = hub ] && HUB_CONSULT_PROMPT_FILE="${SCRIPT%.sh}-hub-consult-prompt.txt"
SERVICE="$HOME/.config/systemd/user/${REMOTE_NAME}.service"
SESSION_LITERAL="$(_shell_quote "$SESSION")"
WORKDIR_LITERAL="$(_shell_quote "$WORKDIR")"
TYPE_LITERAL="$(_shell_quote "$TYPE")"
REMOTE_NAME_LITERAL="$(_shell_quote "$REMOTE_NAME")"
BACKEND_LITERAL="$(_shell_quote "$BACKEND")"
MODEL_LITERAL="$(_shell_quote "$MODEL")"
SETTINGS_FILE_LITERAL="$(_shell_quote "$SETTINGS_FILE")"
LANE_DENY_LITERAL="$(_shell_quote "$CRSS_LANE_DENY")"
PROFILE_LITERAL="$(_shell_quote "$PROFILE")"
CODEX_BIN_LITERAL="$(_shell_quote "$CRSS_CODEX_BIN")"
CODEX_ARGS_LITERAL="$(_shell_words_literal "$CRSS_CODEX_ARGS")"

if [ "$QUOTA_RESULT" != none ] && [ "$DRYRUN" != yes ]; then "$QUOTA_CHECK" log event=quota-failover from="$QUOTA_FROM" to="$BACKEND" evidence="$QUOTA_EVIDENCE" session="$SESSION" || true; fi
_shown_effort="${EFFORT:-default}"
if [ "$BACKEND" = codex ] && [[ "$CRSS_CODEX_ARGS" =~ model_reasoning_effort=([a-z]+) ]]; then _shown_effort=${BASH_REMATCH[1]}; fi
if [ "$TIER_AUTO" = yes ]; then printf 'tier auto: %s -> tier=%s backend=%s model=%s effort=%s (why: %s)\n' "$TIER_AUTO_TYPE" "${TIER_ARG:-none}" "$BACKEND" "$MODEL" "$_shown_effort" "$TIER_REASON" >&2; [ "$DRYRUN" = yes ] || "$QUOTA_CHECK" log event=tier-auto session="$SESSION" task_type="$TIER_AUTO_TYPE" tier="${TIER_ARG:-}" backend="$BACKEND" model="$MODEL" effort="$_shown_effort" why="$TIER_REASON" || true; fi
# Always show what this spawn runs, so a tier name is not misread as a model.
_shown_adv="${ADVISOR:-}"; [ "$BACKEND" = claude ] || _shown_adv=n/a
printf 'resolved: backend=%s profile=%s model=%s effort=%s advisor=%s tier=%s\n' "$BACKEND" "${PROFILE:-codex}" "$MODEL" "$_shown_effort" "${_shown_adv:-none}" "${TIER_ARG:-none}" >&2
if [ "$BACKEND" = claude ] && [ -n "$TIER_ARG" ] && [[ "$MODEL" != *opus* && "$MODEL" != *fable* ]]; then
  echo "note: --tier ${TIER_ARG} is a Sonnet/Haiku session (a tier never selects Opus); for an Opus orchestrator omit --tier" >&2
fi
if [ "$DRYRUN" = yes ]; then
  printf 'SESSION=%s\nREMOTE_NAME=%s\nSCRIPT=%s\nSERVICE=%s\nBACKEND=%s\nPROFILE=%s\nMODEL=%s\nMODEL_SRC=%s\nCLAUDE_EXTRA_FLAGS=%s\nTIER=%s\nEFFORT=%s\nCOMPACT_WINDOW=%s\nADVISOR=%s\nCODEX_ARGS=%s\n%s\n' \
    "$SESSION" "$REMOTE_NAME" "$SCRIPT" "$SERVICE" "$BACKEND" "$PROFILE" "$MODEL" "$MODEL_SRC" "$CLAUDE_EXTRA_FLAGS" "${TIER_ARG:-none}" "${EFFORT:-default}" "${COMPACT_WINDOW:-host}" "$ADVISOR" "$CRSS_CODEX_ARGS" "$OVERLAY_LINE"
  [ -z "$TIER_AUTO_TYPE" ] || printf 'TIER_AUTO=%s\n' "$TIER_AUTO_TYPE"
  printf 'SUPERPOWERS=%s\nSETTINGS_FILE=%s\nLANE_DENY=%s\n' "$SUPERPOWERS" "$SETTINGS_FILE" "$CRSS_LANE_DENY"
  printf 'QUOTA=%s\n' "$QUOTA_RESULT"
  exit 0
fi

if [ "${CRSS_AUTONOMOUS:-0}" = 1 ]; then
  _crss_admit launch "$ADMISSION_SUBJECT" --packet-chars "${#TASK}" >&2 || exit 2
fi

# Per-attempt start id, logged on every start-script line and checked by the Codex start verdict,
# so a stale line cannot stand in for this spawn. od's own status is checked, not tr's.
START_ID="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null)" || START_ID=""
START_ID="${START_ID//[$' \n']/}"
[[ "$START_ID" =~ ^[0-9a-f]{32}$ ]] || { echo "new-session: could not generate a start id from /dev/urandom" >&2; exit 1; }

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# Folder-trust seed helper, baked into the start script; empty when neither copy exists.
TRUST_SEED=""
if [ -f "$SELF_DIR/session-trust-seed.sh" ]; then TRUST_SEED="$SELF_DIR/session-trust-seed.sh"
elif command -v session-trust-seed >/dev/null 2>&1; then TRUST_SEED="$(command -v session-trust-seed)"; fi
TRUST_SEED_LITERAL="$(_shell_quote "$TRUST_SEED")"
mkdir -p "$(dirname "$SCRIPT")" "$(dirname "$SERVICE")"
if [ -n "$HUB_CONSULT_PROMPT_FILE" ]; then
  printf '%s\n' "$HUB_CONSULT_PROMPT" > "$HUB_CONSULT_PROMPT_FILE"
fi

# Generate start script
# Variables without backslash expand NOW (baked into generated script).
# Variables with backslash (\$) expand at runtime in the generated script.
cat > "$SCRIPT" << SCRIPT_EOF
#!/usr/bin/env bash
# Generated by new-session.sh — do not edit by hand.
SESSION=${SESSION_LITERAL}
WORKDIR=${WORKDIR_LITERAL}
LANE_TYPE=${TYPE_LITERAL}
REMOTE_NAME=${REMOTE_NAME_LITERAL}
BACKEND=${BACKEND_LITERAL}
MODEL=${MODEL_LITERAL}
PROFILE=${PROFILE_LITERAL}
START_ID=${START_ID}
CODEX_ARGS=(${CODEX_ARGS_LITERAL})
export PATH="${HOME}/.local/bin:${HOME}/.npm-global/bin:${HOME}/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export HOME="${HOME}"
LOG_FILE="\$HOME/.sessions/session-starts.log"
mkdir -p "\$(dirname "\$LOG_FILE")"
log_start() { echo "[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] host=\$(hostname) session=\$SESSION remote=\$REMOTE_NAME backend=\$BACKEND workdir=\$WORKDIR model=\$MODEL profile=\$PROFILE start_id=\$START_ID event=\$1" | tee -a "\$LOG_FILE"; }
if tmux has-session -t "${SESSION}" 2>/dev/null; then log_start "already-running"; exit 0; fi
log_start "starting"
# Resolve the run directory: canonical tree (clean+free) or a fresh worktree.
RUNDIR="\$WORKDIR"
if command -v session-git-prep >/dev/null 2>&1; then
  PREP="\$(session-git-prep "\$WORKDIR" "\$SESSION" "\$REMOTE_NAME" 2>>"\$LOG_FILE")"
  [ -n "\$PREP" ] && RUNDIR="\$PREP"
fi
echo "[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] session=\$SESSION rundir=\$RUNDIR" | tee -a "\$LOG_FILE"
# A relative run directory (from session-git-prep or an env override) would resolve against the cwd.
case "\$RUNDIR" in
  /*) ;;
  *) echo "[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] session=\$SESSION event=rundir-not-absolute rundir=\$RUNDIR" | tee -a "\$LOG_FILE"; exit 1 ;;
esac
# A workspace lane is an existing repo directory; never invent one (an empty dir would also make
# auto-detect pick \`workspace\` for this name from then on).
if [ "\$LANE_TYPE" = workspace ] && [ ! -d "\$RUNDIR" ]; then
  echo "[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] session=\$SESSION event=rundir-missing rundir=\$RUNDIR" | tee -a "\$LOG_FILE"
  exit 1
fi
# tmux silently starts the pane in \$HOME when \`-c\` names a missing dir, and only the claude
# backend created it (\`mkdir -p \$RUNDIR/.claude\`), so a fresh codex \`sessions\` lane ran in \$HOME.
# Fail closed: no run directory means no lane, and tmux must not be asked to start in \$HOME.
if ! mkdir -p "\$RUNDIR"; then
  echo "[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] session=\$SESSION event=rundir-mkdir-FAILED rundir=\$RUNDIR" | tee -a "\$LOG_FILE"
  exit 1
fi
# An existing directory is not enough: tmux would start the pane in \$HOME if it cannot enter it
# (chmod 000, or another user's 0700 dir). Entering it proves tmux can start the pane there.
if ! cd "\$RUNDIR"; then
  echo "[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] session=\$SESSION event=rundir-unusable rundir=\$RUNDIR" | tee -a "\$LOG_FILE"
  exit 1
fi
# An enterable but read-only directory is no lane either: the agent could not write its own files there.
if [ ! -w "\$RUNDIR" ]; then
  echo "[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] session=\$SESSION event=rundir-unwritable rundir=\$RUNDIR" | tee -a "\$LOG_FILE"
  exit 1
fi
SCRIPT_EOF

if [ "$BACKEND" = claude ]; then
  cat >> "$SCRIPT" << SCRIPT_EOF
mkdir -p "\$RUNDIR/.claude"
# Make the global skill catalog available at \$RUNDIR/.claude/skills WITHOUT
# clobbering a repo that ships its OWN committed project skills. Only (re)point
# the link when it is missing or is a symlink we own (incl. a dangling one from a
# prior spawn) — \`rm -f\` on a symlink removes just the link, never its target.
# A real directory there is the project's own project-scoped skills: leave it.
# (Previously an unconditional \`rm -rf … && ln -sf\` silently destroyed any
# committed .claude/skills/ on every spawn.)
if [ -L "\$RUNDIR/.claude/skills" ] || [ ! -e "\$RUNDIR/.claude/skills" ]; then
  rm -f "\$RUNDIR/.claude/skills"
  ln -sfn ${CRSS_CLAUDE_HOME}/skills "\$RUNDIR/.claude/skills"
else
  echo "[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] session=\$SESSION note=preserving project .claude/skills (real dir; not clobbering global catalog over it)" | tee -a "\$LOG_FILE"
fi
# Remote-control bridge requires a first-party ANTHROPIC_BASE_URL (CLI >= 2026-07-07);
# a proxy base URL (e.g. 127.0.0.1) silently disables session registration so
# the session never appears on the phone. Force first-party via a dedicated --settings
# layer, which merges over the user settings.json (keeping hooks/MCP/plugins).
# Self-heal: (re)write if MISSING or not valid JSON. A truncated/corrupt file would
# otherwise make claude silently ignore it, fall back to the proxy base URL, and
# re-break registration with no error — so validate, don't just check existence.
python3 -c "import json;json.load(open('${CRSS_CLAUDE_HOME}/rc-firstparty.settings.json'))" 2>/dev/null || printf '{"env":{"ANTHROPIC_BASE_URL":"https://api.anthropic.com","DISABLE_AUTOUPDATER":"1"}}\n' > ${CRSS_CLAUDE_HOME}/rc-firstparty.settings.json
# Unattended sessions never accept a prompt suggestion, and every unused one bumps the host-wide
# promptSuggestionUnusedStreak in ~/.claude.json (20 in a row puts the operator's app sessions into
# back-off). Add the off switch if the key is absent; an explicit value already there is kept.
python3 -c "
import json,sys
f=sys.argv[1];d=json.load(open(f));e=d.setdefault('env',{})
if 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION' not in e:
    e['CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION']='0';json.dump(d,open(f,'w'));open(f,'a').write('\\n')
" ${CRSS_CLAUDE_HOME}/rc-firstparty.settings.json 2>/dev/null || true
SCRIPT_EOF
# Derive runs in the start script on every start. Only one --settings flag: repeated flags replace each other and drop this layer's env.
_DERIVE_COMMENT='# Derive ONE file from healed rc-firstparty (every other key kept, env especially; tmp + os.replace; mode copied). Off lanes set the plugin false; permissions.deny is the existing list UNION the lane deny (order kept, no duplicates).
# gbrain MCP ~2.6k tokens/start (110 deferred names + instructions; 6 MCP calls vs 1,087 gbrain CLI calls in 4 weeks), token-reduce MCP (0 MCP calls in 30 days vs 288 token-reduce CLI calls), SendFeedback ~9KB and ReportFindings ~3KB (0 uses); deny removes them even under --dangerously-skip-permissions. CRSS_LANE_DENY= opts out. Derive failure: plain rc-firstparty copy.'
_DERIVE_PY=$(cat << 'PY'
import json,os,sys
src,dst,plugin,switch_off,deny_csv=sys.argv[1:6]
d=json.load(open(src))
if switch_off=='1':
    d.setdefault('enabledPlugins',{})[plugin]=False
if deny_csv:
    extra=[x for x in deny_csv.split(',') if x!='']
    perms=d.setdefault('permissions',{})
    if not isinstance(perms, dict):
        raise SystemExit(1)
    existing=perms.get('deny')
    if existing is None:
        existing=[]
    if not isinstance(existing, list):
        raise SystemExit(1)
    seen=set()
    merged=[]
    for item in list(existing)+extra:
        if item in seen:
            continue
        seen.add(item)
        merged.append(item)
    perms['deny']=merged
tmp=dst+'.'+str(os.getpid())+'.tmp'
fd=os.open(tmp, os.O_WRONLY|os.O_CREAT|os.O_EXCL, 0o600)
os.fchmod(fd, os.stat(src).st_mode & 0o777)
f=os.fdopen(fd, 'w')
print(json.dumps(d), file=f)
f.close()
os.replace(tmp, dst)
PY
)
_crss_emit_derive() {
  local first="$1" switch_flag="$2" event_name="$3"
  cat >> "$SCRIPT" << SCRIPT_EOF
${_DERIVE_COMMENT}
${first}
  python3 -c "
${_DERIVE_PY}
" ${CRSS_CLAUDE_HOME}/rc-firstparty.settings.json ${SETTINGS_FILE_LITERAL} ${SUPERPOWERS_PLUGIN} ${switch_flag} ${LANE_DENY_LITERAL} 2>/dev/null || {
    cp -p ${CRSS_CLAUDE_HOME}/rc-firstparty.settings.json ${SETTINGS_FILE_LITERAL}
    echo "[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] session=\$SESSION event=${event_name} (launching with the plain rc-firstparty copy; plugin stays on)" | tee -a "\$LOG_FILE"
  }
fi
SCRIPT_EOF
}
if [ "$SUPERPOWERS" = off ]; then
  _crss_emit_derive "if [ \"${SUPERPOWERS}\" = off ]; then" 1 no-superpowers-settings-FAILED
elif [ -n "$CRSS_LANE_DENY" ]; then
  _crss_emit_derive "# crss-lane-deny-derive
if [ -n ${LANE_DENY_LITERAL} ]; then" 0 settings-derive-FAILED
fi
cat >> "$SCRIPT" << SCRIPT_EOF
if [ -f "\$RUNDIR/memory/MEMORY.md" ] && ! grep -q "Session Bootstrap" "\$RUNDIR/.claude/CLAUDE.md" 2>/dev/null; then
  printf '# Session Bootstrap\n\nOn your first response in any new session, read \`memory/MEMORY.md\` to load current project state, then summarize what needs to be done next and wait for instructions.\n' >> "\$RUNDIR/.claude/CLAUDE.md"
fi
# Pre-accept the folder-trust dialog for the dir claude will actually run in (RUNDIR is
# often a fresh worktree, which prompts on first launch and parks an unattended spawn).
# See scripts/session-trust-seed.sh for what key it writes and why. Never blocks the
# start: a failure is logged and new-session's kickoff reports a still-open dialog.
TRUST_SEED=${TRUST_SEED_LITERAL}
if [ -n "\$TRUST_SEED" ] && [ -f "\$TRUST_SEED" ]; then
  bash "\$TRUST_SEED" "\$RUNDIR" 2>&1 | sed "s|^|[trust-seed] |" >> "\$LOG_FILE"
  [ "\${PIPESTATUS[0]}" -eq 0 ] || echo "[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] session=\$SESSION event=trust-seed-FAILED rundir=\$RUNDIR (claude may park on the folder-trust dialog)" | tee -a "\$LOG_FILE"
else
  echo "[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] session=\$SESSION note=session-trust-seed-not-found (claude may park on the folder-trust dialog)" | tee -a "\$LOG_FILE"
fi
SCRIPT_EOF
fi

cat >> "$SCRIPT" << SCRIPT_EOF
# Launch tmux in its own transient scope, never in this unit's cgroup: if this call forks the
# shared server, a later stop/restart of THIS unit (KillMode=control-group) would otherwise kill
# the server and every session on it (2026-10-24, 29 sessions). With a server already up, the
# scope holds only the short-lived client. Bare tmux only when systemd-run cannot run at all.
# Older scripts: crss-tmux-scope migrate-scripts / adopt.
_crss_tmux() {
  if command -v systemd-run >/dev/null 2>&1 && [ -S "\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}/bus" ]; then
    systemd-run --user --scope --quiet --collect -- tmux "\$@"
  else
    tmux "\$@"
  fi
}
_crss_tmux new-session -d -s "${SESSION}" -x 220 -y 50 -c "\$RUNDIR" -e "PATH=\$PATH" -e "HOME=\$HOME"
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
SCRIPT_EOF

# Claude supervisor loop, first match wins: resume pin (--resume <uuid>, cleared only after 30s+ so a bad
# uuid is retried, never downgraded to --continue), sentinel (--continue), else fresh. The sentinel is
# touched before the first launch so a session killed from outside still restarts its conversation.
if [ "$BACKEND" = claude ]; then
  # The loop is typed with send-keys, so a literal ' in the flags would end that quote early. Close the
  # quote, emit a quoted ', reopen. Model, settings and remote name get the same escape. The launch line
  # keeps --model "..." because session-resume rewrites that exact shape.
  _sq="'"; _sq_esc="'\\''"
  _sq_escape() { printf '%s' "${1//"$_sq"/$_sq_esc}"; }
  _pane_word() { _sq_escape "$(_shell_quote "$1")"; }
  CLAUDE_EXTRA_FLAGS_SQ="${CLAUDE_EXTRA_FLAGS//"$_sq"/$_sq_esc}"
  MODEL_DQ="$(_sq_escape "$MODEL")"
  SETTINGS_FILE_SQ="$(_pane_word "$SETTINGS_FILE")"
  REMOTE_NAME_SQ="$(_pane_word "$REMOTE_NAME")"
  REMOTE_NAME_DQ="$(_sq_escape "$REMOTE_NAME")"
  cat >> "$SCRIPT" << SCRIPT_EOF
${COMPACT_WINDOW:+tmux send-keys -t "${SESSION}" 'export CLAUDE_CODE_AUTO_COMPACT_WINDOW=$COMPACT_WINDOW' Enter
}tmux send-keys -t "${SESSION}" 'LOG_FILE="$HOME/.sessions/session-starts.log"
SESSION="${SESSION}"
SENTINEL="\$PWD/.sessions-init-${REMOTE_NAME_DQ}"
RESUME_PIN="$HOME/.sessions/resume/${REMOTE_NAME_DQ}.uuid"
MANUAL_LAUNCH="$HOME/.sessions/resume/${REMOTE_NAME_DQ}.manual-launch"
ADMISSION_FIRST=1
while true; do
  MANUAL_ONCE=0
  if [ "\$ADMISSION_FIRST" = 1 ] && [ -s "\$MANUAL_LAUNCH" ] && [ -s "\$RESUME_PIN" ] && [ "\$(cat "\$MANUAL_LAUNCH")" = "\$(cat "\$RESUME_PIN")" ]; then
    rm -f "\$MANUAL_LAUNCH" && MANUAL_ONCE=1
  fi
  if [ "${ADMISSION_GATED}" = 1 ] && [ "\$MANUAL_ONCE" != 1 ] && { [ "\$ADMISSION_FIRST" = 0 ] || [ "${CRSS_AUTONOMOUS:-0}" = 1 ] || [ -f "\$SENTINEL" ]; }; then
    ADMISSION_ACTION=restart
    [ "\$ADMISSION_FIRST" = 1 ] && [ ! -f "\$SENTINEL" ] && ADMISSION_ACTION=launch
    CRSS_AUTONOMOUS="${CRSS_AUTONOMOUS:-0}" AGENT_HOST_ADMISSION_CLI="${AGENT_HOST_ADMISSION_CLI:-}" AGENT_HOST_ADMISSION_DB="${AGENT_HOST_ADMISSION_DB:-}" AGENT_HOST_ADMISSION_EVIDENCE="${AGENT_HOST_ADMISSION_EVIDENCE:-}" bash "${ADMISSION_HELPER}" "\$ADMISSION_ACTION" "${ADMISSION_SUBJECT}" || { echo "autonomous admission denied"; break; }
  fi
  ADMISSION_FIRST=0
  START=\$(date +%s)
  PINNED=0
  if [ -s "\$RESUME_PIN" ]; then
    RESUME_ID=\$(cat "\$RESUME_PIN"); PINNED=1; touch "\$SENTINEL" || break
    ${CRSS_CLAUDE_BIN} --dangerously-skip-permissions --model "${MODEL_DQ}" ${CLAUDE_EXTRA_FLAGS_SQ} --settings ${SETTINGS_FILE_SQ} --remote-control ${REMOTE_NAME_SQ} --resume "\$RESUME_ID"
  elif [ -f "\$SENTINEL" ]; then
    ${CRSS_CLAUDE_BIN} --dangerously-skip-permissions --model "${MODEL_DQ}" ${CLAUDE_EXTRA_FLAGS_SQ} --settings ${SETTINGS_FILE_SQ} --remote-control ${REMOTE_NAME_SQ} --continue
  else
    touch "\$SENTINEL" || break
    ${CRSS_CLAUDE_BIN} --dangerously-skip-permissions --model "${MODEL_DQ}" ${CLAUDE_EXTRA_FLAGS_SQ} --settings ${SETTINGS_FILE_SQ} --remote-control ${REMOTE_NAME_SQ}
  fi
  RUNTIME=\$(( \$(date +%s) - START ))
  if [ "\$PINNED" = 1 ] && [ "\$RUNTIME" -ge 30 ]; then rm -f "\$RESUME_PIN"; fi
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
SCRIPT_EOF
  KICKED_CMDS="claude|node|sleep"
else
  cat >> "$SCRIPT" << SCRIPT_EOF
CODEX_LOOP=\$(cat <<'CODEX_LOOP_EOF'
LOG_FILE="\$HOME/.sessions/session-starts.log"
SESSION=${SESSION_LITERAL}
CODEX_BIN=${CODEX_BIN_LITERAL}
CODEX_ARGS=(${CODEX_ARGS_LITERAL})
CODEX_PIN="\$HOME/.sessions/resume/${REMOTE_NAME}.codex-thread"
SENTINEL="\$PWD/.sessions-init-${REMOTE_NAME}"
ADMISSION_FIRST=1
while true; do
  if [ "${ADMISSION_GATED}" = 1 ] && { [ "\$ADMISSION_FIRST" = 0 ] || [ "${CRSS_AUTONOMOUS:-0}" = 1 ] || [ -f "\$SENTINEL" ]; }; then
    ADMISSION_ACTION=restart
    [ "\$ADMISSION_FIRST" = 1 ] && [ ! -f "\$SENTINEL" ] && ADMISSION_ACTION=launch
    CRSS_AUTONOMOUS="${CRSS_AUTONOMOUS:-0}" AGENT_HOST_ADMISSION_CLI="${AGENT_HOST_ADMISSION_CLI:-}" AGENT_HOST_ADMISSION_DB="${AGENT_HOST_ADMISSION_DB:-}" AGENT_HOST_ADMISSION_EVIDENCE="${AGENT_HOST_ADMISSION_EVIDENCE:-}" bash "${ADMISSION_HELPER}" "\$ADMISSION_ACTION" "${ADMISSION_SUBJECT}" || { echo "autonomous admission denied"; break; }
  fi
  ADMISSION_FIRST=0
  touch "\$SENTINEL" || break
  START=\$(date +%s)
  _codex_trust_dir="\${PWD//\\\\/\\\\\\\\}"
  _codex_trust_dir="\${_codex_trust_dir//\"/\\\\\"}"
  CODEX_TRUST_CONFIG="projects.\"\${_codex_trust_dir}\".trust_level=\"trusted\""
  # Resume the lane's EXPLICITLY pinned thread (a UUID a person/agent wrote to
  # CODEX_PIN; nothing here writes or guesses it) so a reboot does not lose it.
  # A resume does NOT inherit the thread's sandbox, so EVERY attempt passes
  # exactly one explicit sandbox. The helper is mandatory and every read fails
  # closed (reason logged, no launch, the backoff below retries); only a PROVEN
  # absence of the pinned rollout leads to a fresh launch. argv is a bash array,
  # never newline-delimited text.
  FAIL=""; PIN_ID=""; SB=""; SB_FLAG=""; SB_ARGV=(); LAUNCH_ARGV=()
  # A logging failure must never change a decision or its reason: open the log ONCE per pass,
  # on fd 9, and send helper stderr there (the pane when the log cannot be opened). A redirect
  # reopened per call could fail mid-pass and make a helper call return 1 for the wrong reason.
  mkdir -p "\$(dirname "\$LOG_FILE")" 2>/dev/null
  if { exec 9>>"\$LOG_FILE"; } 2>/dev/null; then LOG_OK=1; else
    exec 9>&2; LOG_OK=""; echo "[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] session=\$SESSION event=log-unavailable"
  fi
  _h() { "\$@" 2>&9; }
  if ! command -v codex-resume-pin >/dev/null 2>&1; then
    FAIL=helper-missing
  elif ! SB=\$(_h codex-resume-pin sandbox-of "\${CODEX_ARGS[@]}") || ! SB_FLAG=\$(_h codex-resume-pin sandbox-of --flag "\${CODEX_ARGS[@]}"); then
    FAIL=sandbox-invalid
  else
    # a -s/--sandbox FLAG beats a profile and config.toml; -c sits below them, so only a flag
    # suppresses the appended -s
    [ -n "\$SB_FLAG" ] || SB_ARGV=(-s "\$SB")
    PIN_ID=\$(_h codex-resume-pin read-pin "\$CODEX_PIN"); _rc=\$?
    if [ "\$_rc" -eq 10 ]; then
      PIN_ID=""
    elif [ "\$_rc" -ne 0 ]; then
      FAIL=pin-invalid; PIN_ID=""
    else
      _h codex-resume-pin exists "\$PIN_ID" >/dev/null; _rc=\$?
      if [ "\$_rc" -eq 0 ]; then
        _h codex-resume-pin verify-lane "\$PIN_ID" "\$PWD"; _rc=\$?
        if [ "\$_rc" -eq 1 ]; then FAIL=pin-foreign; elif [ "\$_rc" -ne 0 ]; then FAIL=pin-unverifiable; fi
      elif [ "\$_rc" -eq 11 ]; then
        _p2=\$(_h codex-resume-pin read-pin "\$CODEX_PIN") || _p2=""
        if [ "\$_p2" != "\$PIN_ID" ]; then FAIL=pin-changed; else
          echo "[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] session=\$SESSION event=pin-stale thread=\$PIN_ID" | tee -a "\$LOG_FILE"
          # archive only to a name that does not exist yet, then VERIFY (mv -n exit codes differ)
          _arc="\$CODEX_PIN.stale.\$(date +%s)"
          if [ -e "\$_arc" ] || [ -L "\$_arc" ]; then FAIL=pin-archive-failed; else
            mv -n -T -- "\$CODEX_PIN" "\$_arc" 2>/dev/null
            if [ -e "\$CODEX_PIN" ] || [ -L "\$CODEX_PIN" ] || [ ! -f "\$_arc" ] || [ "\$(cat -- "\$_arc" 2>/dev/null)" != "\$PIN_ID" ]; then
              FAIL=pin-archive-failed
              # the pin changed under the archive: put the moved file back (only a regular,
              # non-link archive, and only onto an empty pin path); report if that fails too
              if ! { [ -e "\$CODEX_PIN" ] || [ -L "\$CODEX_PIN" ]; } && [ -f "\$_arc" ] && [ ! -L "\$_arc" ]; then
                mv -n -T -- "\$_arc" "\$CODEX_PIN" 2>/dev/null
              fi
              { [ -e "\$CODEX_PIN" ] || [ -L "\$CODEX_PIN" ]; } || echo "[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] session=\$SESSION event=pin-restore-failed archive=\$_arc" | tee -a "\$LOG_FILE"
            else PIN_ID=""; fi
          fi
        fi
      else
        FAIL=pin-lookup-error
      fi
      if [ -z "\$FAIL" ] && [ -n "\$PIN_ID" ]; then
        _p2=\$(_h codex-resume-pin read-pin "\$CODEX_PIN") || _p2=""
        [ "\$_p2" = "\$PIN_ID" ] || FAIL=pin-changed
      fi
    fi
  fi
  if [ -n "\$FAIL" ]; then
    echo "[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] session=\$SESSION event=resume-pin-fail-closed reason=\$FAIL" | tee -a "\$LOG_FILE"
  elif [ -n "\$PIN_ID" ]; then
    LAUNCH_ARGV=(resume "\$PIN_ID" "\${CODEX_ARGS[@]}" "\${SB_ARGV[@]}")
    echo "[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] session=\$SESSION event=resume thread=\$PIN_ID sandbox=\$SB" | tee -a "\$LOG_FILE"
    "\$CODEX_BIN" -c "\$CODEX_TRUST_CONFIG" "\${LAUNCH_ARGV[@]}" 9>&-
  else
    LAUNCH_ARGV=("\${CODEX_ARGS[@]}" "\${SB_ARGV[@]}")
    "\$CODEX_BIN" -c "\$CODEX_TRUST_CONFIG" "\${LAUNCH_ARGV[@]}" 9>&-
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
done
CODEX_LOOP_EOF
)
tmux send-keys -t "${SESSION}" "\$CODEX_LOOP"
SCRIPT_EOF
  KICKED_CMDS="codex|node|sleep"
fi

cat >> "$SCRIPT" << SCRIPT_EOF
# A fail-closed Codex first pass (helper missing, bad args, bad pin) ends in \`sleep 300\`, which
# the kickoff below counts as launched. For codex, \`started\` is reported only from explicit
# evidence: the pane command is codex/node, or (sleep) the pane shows the loop's OWN expanded
# fail-closed line for THIS session. Anything else is UNVERIFIED, never a plain \`started\`.
kicked=no
_kcmd=""
for _try in 1 2 3; do
  tmux send-keys -t "${SESSION}" Enter
  for _j in \$(seq 1 12); do
    _kc="\$(tmux display-message -p -t "${SESSION}" '#{pane_current_command}' 2>/dev/null)"
    case "\$_kc" in
      ${KICKED_CMDS}) kicked=yes; _kcmd="\$_kc"; break ;;
    esac
    sleep 0.5
  done
  [ "\$kicked" = yes ] && break
  echo "[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] session=\$SESSION event=kickoff-retry attempt=\$_try" | tee -a "\$LOG_FILE"
done
if [ "\$kicked" != yes ]; then
  log_start "started-UNVERIFIED-kickoff-may-have-failed"
elif [ "\$BACKEND" = codex ] && [ "\$_kcmd" = sleep ]; then
  _fc=""; _cap_ok=no
  for _t in 1 2 3 4 5 6 7 8 9 10; do
    if _pane="\$(tmux capture-pane -p -J -S - -t "${SESSION}" 2>/dev/null)"; then
      _cap_ok=yes
      _fc="\$(printf '%s\\n' "\$_pane" | sed 's/[[:space:]]*\$//' \\
        | grep -aE '^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\] session=[^ ]+ event=resume-pin-fail-closed reason=[a-z][a-z-]*\$' \\
        | grep -aF "] session=${SESSION} event=" | tail -1)"
      [ -z "\$_fc" ] || break
    fi
    sleep 0.5
  done
  if [ -n "\$_fc" ]; then
    log_start "started-FAIL-CLOSED reason=\${_fc##*reason=}"
  elif [ "\$_cap_ok" = yes ]; then
    log_start "started-UNVERIFIED-codex-not-running"
  else
    log_start "started-UNVERIFIED-pane-unreadable"
  fi
else
  log_start "started"
fi
SCRIPT_EOF
chmod +x "$SCRIPT"

# Generate systemd unit
cat > "$SERVICE" << UNIT_EOF
[Unit]
Description=CRSS ${BACKEND} Session - ${REMOTE_NAME}
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${SCRIPT}
ExecStop=/usr/bin/tmux kill-session -t ${SESSION}
Environment=HOME=${HOME}
Environment=PATH=${HOME}/.local/bin:${HOME}/.npm-global/bin:${HOME}/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=TMUX_TMPDIR=/tmp
[Install]
WantedBy=default.target
UNIT_EOF

# Enable and start
# bash's own clock (no `date` fork): several test harnesses put a recursing `date` stub on PATH
t0="$(TZ=UTC printf '%(%Y-%m-%dT%H:%M:%SZ)T' -1)"
if ! { systemctl --user daemon-reload && systemctl --user enable --now "$(basename "$SERVICE")"; }; then
  # An enabled, failed unit would re-run and refuse at boot: disable it and clear the failed state (file stays).
  _unit="$(basename "$SERVICE")"
  if systemctl --user disable "$_unit" >/dev/null 2>&1; then
    _after="The unit was disabled, so a reboot will not re-run it."
  else
    _after="The unit could NOT be disabled; run by hand: systemctl --user disable $_unit; systemctl --user reset-failed $_unit"
  fi
  systemctl --user reset-failed "$_unit" >/dev/null 2>&1 || true
  echo "new-session: systemd failed to start $_unit — the session was NOT started. $_after Inspect: journalctl --user -u $_unit -n 30; start script: $SCRIPT" >&2
  exit 1
fi

# A Codex lane counts as started only on the last log line for this session and start id, at or after t0,
# ending in event=started. Anything else exits 3.
START_FAIL_CLOSED=""; START_UNVERIFIED=""; START_VERDICT=""
if [ "$BACKEND" = codex ]; then
  _sl="$HOME/.sessions/session-starts.log"; _last=""
  if [ -f "$_sl" ]; then
    _last="$(grep -aF "session=${SESSION} " "$_sl" | grep -aE '^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\] ' \
      | grep -aF " start_id=${START_ID} event=started" | awk -v t0="$t0" '{ ts = substr($1, 2, 20); if ((ts "") >= (t0 "")) last = $0 } END { print last }')" || _last=""
  fi
  case "$_last" in
    *" event=started") ;;
    *" event=started-FAIL-CLOSED reason="*) START_FAIL_CLOSED="${_last##*reason=}"; START_VERDICT="fail-closed reason=${START_FAIL_CLOSED}" ;;
    *) START_UNVERIFIED=1; START_VERDICT="start not verified" ;;
  esac
fi

# Telemetry (best-effort, never fails the spawn)
# Prefer the launch dir over WORKDIR: session-git-prep may redirect into a fresh worktree, which gets the
# CLAUDE.md fragment. The start script logs rundir= before enable --now returns; fall back to WORKDIR.
TELEMETRY_DIR="$WORKDIR"
SPAWN_LOG="$HOME/.sessions/session-starts.log"
if [ -f "$SPAWN_LOG" ]; then
  LOGLINE="$(grep "session=${SESSION} rundir=" "$SPAWN_LOG" | tail -1)"
  # ${#*pat} strips the shortest prefix; a greedy sed would cut at the last rundir= and break paths containing it.
  RD="${LOGLINE#*session="${SESSION}" rundir=}"
  [ -n "$RD" ] && TELEMETRY_DIR="$RD"
fi
if [ -x "$SELF_DIR/record-spawn-telemetry.sh" ]; then
  CRSS_ESCALATED_FROM="$ESCALATE_FROM" CRSS_LAUNCHER="$LAUNCHER_ARG" CRSS_SPAWN_BACKEND="$BACKEND" "$SELF_DIR/record-spawn-telemetry.sh" "$FOLDERNAME" "$ALIAS" "$REMOTE_NAME" "$SESSION" "$TYPE" "$MODEL" "$TELEMETRY_DIR" "${TIER_ARG:-}" "${EFFORT:-}" "$TIER_REASON" "$COMPACT_WINDOW" || true
fi

# Kickoff task (--task/--task-file)
# Reuses session-handoff's poll-then-verify send (no second copy). Helper: co-located, then PATH; run via bash.
# TASK_FAILED collects why delivery failed; any value makes the spawn exit 3, so a launcher never reads it as success.
# Codex has no output hook: keep this advisory and local to kickoff (no rtk, no CLI config change).
if [ "$BACKEND" = codex ] && [ -n "$TASK" ]; then
  TASK=$'Shell output: use rtk for supported noisy commands (e.g. rtk git log -20, rtk ls, rtk test <command>) when installed; use the original command if rtk is unavailable or unfiltered output is needed.\n\n'"$TASK"
fi
TASK_FAILED=""
if [ -n "$TASK" ] && [ -n "$START_VERDICT" ]; then
  TASK_FAILED="task NOT sent: the lane's start was not verified (${START_VERDICT})"
elif [ -n "$TASK" ]; then
  HANDOFF=""
  if [ -f "$SELF_DIR/session-handoff.sh" ]; then
    HANDOFF="$SELF_DIR/session-handoff.sh"
  elif command -v session-handoff >/dev/null 2>&1; then
    HANDOFF="$(command -v session-handoff)"
  fi
  if [ -z "$HANDOFF" ]; then
    TASK_FAILED="could not locate session-handoff (looked next to this script and on PATH) — task NOT sent; send it by hand: session-handoff send ${SESSION} ..."
  else
    # Need NEW_SESSION_TASK_SETTLE (default 3) consecutive ready polls: a fresh TUI can drop the first paste.
    # session-handoff's send recovers any paste that still slips through.
    ready=no
    trust_dialog=no
    gone=no
    settle_need="${NEW_SESSION_TASK_SETTLE:-3}"
    settle_have=0
    for _i in $(seq 1 "${NEW_SESSION_TASK_READY_TRIES:-90}"); do
      # check exits non-zero when not ready: capture the status without tripping set -e, or the spawn dies silently.
      check_rc=0; check_out="$(bash "$HANDOFF" check "$SESSION" 2>&1)" || check_rc=$?
      # A dialog (typically folder trust) needs a human: stop polling now. The start script pre-seeds trust, so seeing it means seeding failed.
      if printf '%s' "$check_out" | grep -q 'state=menu'; then
        trust_dialog=yes
        break
      fi
      if [ "$check_rc" -eq 2 ]; then gone=yes; break; fi
      if [ "$check_rc" -eq 0 ]; then
        settle_have=$((settle_have + 1))
        [ "$settle_have" -ge "$settle_need" ] && { ready=yes; break; }
      else
        settle_have=0
      fi
      sleep 1
    done
    if [ "$trust_dialog" = yes ] && tmux capture-pane -p -t "$SESSION" 2>/dev/null | grep -qiE 'retires on|Try new model|Use existing model'; then
      # Codex's model-retirement menu is a model choice, not a trust grant: never pick for the operator.
      TASK_FAILED="'${SESSION}' is parked on the Codex model-retirement menu ('Try new model' / 'Use existing model') — task NOT sent. Attach and choose deliberately (not an auto-pick; 'Use existing model' keeps the configured model, 'Try new model' switches it), then: session-handoff send ${SESSION} ${TASK_FILE_ARG:+--file $(_shell_quote "$TASK_FILE_ARG")}"
    elif [ "$trust_dialog" = yes ]; then
      TASK_FAILED="'${SESSION}' is parked on a menu/trust dialog — task NOT sent (pre-seeding trust failed: see $HOME/.sessions/session-starts.log). Attach and choose 'Yes, I trust this folder' (the highlighted default is 'No, exit', so do not press Enter blindly), then: session-handoff send ${SESSION} ${TASK_FILE_ARG:+--file $(_shell_quote "$TASK_FILE_ARG")}"
    elif [ "$gone" = yes ]; then
      TASK_FAILED="tmux session '${SESSION}' vanished while waiting for ${BACKEND} — task NOT sent; see $HOME/.sessions/session-starts.log"
    elif [ "$ready" != yes ]; then
      TASK_FAILED="'${SESSION}' never reached ready state (last: ${check_out}) — task NOT sent; send it by hand: session-handoff send ${SESSION} ..."
    elif bash "$HANDOFF" send "$SESSION" "$TASK"; then
      echo "Task sent to ${REMOTE_NAME} and verified landed."
    else
      TASK_FAILED="task send UNVERIFIED on ${REMOTE_NAME} — check the session before assuming it received the task"
    fi
  fi
fi

# Confirm
if [ -n "$START_FAIL_CLOSED" ]; then
  echo "" >&2
  echo "new-session: session ${REMOTE_NAME} (tmux ${SESSION}) started FAIL-CLOSED (reason=${START_FAIL_CLOSED}): codex was NOT launched and the loop retries after its backoff. ${TASK_FAILED:+${TASK_FAILED}. }Inspect: grep -a 'session=${SESSION} ' $HOME/.sessions/session-starts.log | tail" >&2
  exit 3
fi
if [ -n "$START_UNVERIFIED" ]; then
  echo "" >&2
  echo "new-session: start NOT verified for ${REMOTE_NAME} (tmux ${SESSION}): codex is not confirmed running. ${TASK_FAILED:+${TASK_FAILED}. }Inspect: journalctl --user -u $(basename "$SERVICE") -n 30; grep -a 'session=${SESSION} ' ~/.sessions/session-starts.log | tail" >&2
  exit 3
fi
if [ -n "$TASK_FAILED" ]; then
  echo "" >&2
  echo "new-session: session ${REMOTE_NAME} (tmux ${SESSION}) was spawned, but the task was NOT delivered: ${TASK_FAILED}" >&2
  exit 3
fi
echo ""
echo "Session created: ${REMOTE_NAME}"
echo "Connect: Claude Code app → Remote sessions → ${REMOTE_NAME}"
echo "$OVERLAY_LINE"
tmux list-sessions | grep "${SESSION}" || true
