#!/usr/bin/env bash
# new-session.sh — generate a per-remote start script + systemd unit for a
# persistent Claude Code session running in a tmux window with --remote-control.
#
# Usage: new-session <foldername> [workspace|sessions]
#   workspace (default when $CRSS_WORKSPACE/<name> exists) — repo sessions
#   sessions  — utility sessions (monitors, managers, etc.)
set -e

# ── Host-local overlay config ────────────────────────────────────────────────
# See examples/crss-overlay/README.md. Parses (never sources) $CRSS_HOME/config.sh
# for CRSS_* vars; an env var already set wins over the file; a missing/unreadable
# file is fine (generic defaults below apply). Copied verbatim in every script
# that reads overlay config — see tests/test-crss-overlay-config.sh.
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
# Single source of truth for "the Opus we pin to": bump it here (or in $CRSS_HOME/config.sh,
# which wins) when a newer Opus ships. The orchestrator default model and the default advisor
# both read it. Validated because the advisor id lands unquoted in the start script.
: "${CRSS_OPUS_MODEL:=claude-opus-5-5}"
: "${CRSS_ADVISOR_MODEL:=$CRSS_OPUS_MODEL}"
for _m_var in CRSS_OPUS_MODEL CRSS_ADVISOR_MODEL; do
  [[ "${!_m_var}" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || { echo "new-session: ${_m_var}='${!_m_var}' must match ^[a-z0-9][a-z0-9.-]*\$" >&2; exit 2; }
done

if [ -z "${CRSS_CODEX_BIN:-}" ]; then
  CRSS_CODEX_BIN="$(command -v codex 2>/dev/null || echo codex)"
fi
: "${CRSS_CODEX_ARGS:=}"

# ── Session-name prefix recognition ─────────────────────────────────────────
# CRSS_SESSION_PREFIX is what NEW sessions get (generic default: "cs", short
# for "claude session" — lowercase, short, memorable, and distinct from any
# prefix a given host used before). CRSS_LEGACY_PREFIXES is a `|`-separated
# list of EXTRA prefixes still RECOGNISED when parsing an existing name but
# NEVER used to generate one (a host migrating off an old prefix sets
# CRSS_SESSION_PREFIX=<new> and CRSS_LEGACY_PREFIXES=<old>, e.g. oldhost — see
# examples/crss-overlay/). Both feed one
# validated alternation, _crss_prefix_re, that every parse/generate site below
# uses instead of a hardcoded prefix. Each element must match
# ^[a-z][a-z0-9]{0,15}$ — that charset can't contain ERE metacharacters, so
# validating IS escaping here. An invalid CRSS_SESSION_PREFIX falls back to
# the generic default; ANY invalid element in CRSS_LEGACY_PREFIXES drops the
# WHOLE legacy list (not just that element) rather than guessing which of
# several bad values was meant — never to an empty pattern, which would make
# the alternation match everything (the dangerous direction in a reap path).
# Copied verbatim in every script that needs it — see
# tests/test-crss-overlay-config.sh.
# CRSS-PREFIX-RE-START
_crss_valid_prefix_tok() { [[ "$1" =~ ^[a-z][a-z0-9]{0,15}$ ]]; }
if [ -z "${CRSS_SESSION_PREFIX+x}" ]; then
  CRSS_SESSION_PREFIX=cs
fi
if ! _crss_valid_prefix_tok "$CRSS_SESSION_PREFIX"; then
  echo "crss: CRSS_SESSION_PREFIX '$CRSS_SESSION_PREFIX' is invalid (want ^[a-z][a-z0-9]{0,15}\$) — falling back to 'cs'" >&2
  CRSS_SESSION_PREFIX=cs
fi
_crss_prefix_re="$CRSS_SESSION_PREFIX"
if [ -n "${CRSS_LEGACY_PREFIXES:-}" ]; then
  _crss_legacy_re=""
  _crss_legacy_ok=yes
  while IFS= read -r _crss_legacy_tok; do
    [ -n "$_crss_legacy_tok" ] || continue
    if _crss_valid_prefix_tok "$_crss_legacy_tok"; then
      _crss_legacy_re="${_crss_legacy_re}|${_crss_legacy_tok}"
    else
      _crss_legacy_ok=no
    fi
  done < <(printf '%s\n' "$CRSS_LEGACY_PREFIXES" | tr '|' '\n')
  if [ "$_crss_legacy_ok" = yes ]; then
    _crss_prefix_re="${_crss_prefix_re}${_crss_legacy_re}"
  else
    echo "crss: CRSS_LEGACY_PREFIXES '$CRSS_LEGACY_PREFIXES' has an invalid element (want each ^[a-z][a-z0-9]{0,15}\$) — ignoring ALL legacy prefixes" >&2
  fi
fi
# CRSS-PREFIX-RE-END

# Overlay visibility line, printed in --dry-run output and in the final
# spawn confirmation below — a missing overlay should be visible, not silent.
_crss_overlay_cfg_state=absent; [ -f "$CRSS_HOME/config.sh" ] && _crss_overlay_cfg_state=found
_crss_overlay_rules_state=absent; [ -f "$CRSS_CLAUDE_HOME/rules/crss-host.md" ] && _crss_overlay_rules_state=found
OVERLAY_LINE="overlay: ${CRSS_HOME} (config: ${_crss_overlay_cfg_state}, rules: ${_crss_overlay_rules_state})"

# ── Help ─────────────────────────────────────────────────────────────────────
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
  --tier <t>          Right-size the spawn: light|standard|heavy -> profile + model +
                      effort (see SKILL.md "Choosing a tier"). Explicit
                      CLAUDE_SESSION_PROFILE/_MODEL/_EFFORT win piecewise.
  --tier-reason <s>   One line on why; recorded in spawn telemetry.
  --needs-fanout      Task must call Workflow (builder/copywriter drop it; they keep Agent
                      + advisor): lifts them to owner.
  --approve-opus      Lets --tier heavy use the Opus orchestrator profile.
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
  CLAUDE_SESSION_MODEL=<model>  Claude backend model. Unset → the PROFILE's
                                per-role default (see below): claude-opus-5-5
                                (pinned) for orchestrator; sonnet/sonnet/sonnet/haiku
                                for owner/hub/builder/copywriter — bare aliases that
                                auto-track the latest release for their tier.
                                Set it to override: a bare alias tracks latest,
                                or pass an exact id (e.g. claude-opus-4-8) to
                                pin one spawn reproducibly.
  CLAUDE_SESSION_EFFORT=<lvl>   Claude --effort level (low|medium|high|xhigh|max).
                                Unset → no flag (CLI/settings baseline), except
                                --tier light which sets low.
CRSS_TIER_CODEX_TIERS=<list>  Space-separated tiers routed to the codex backend
                                (default: none; --needs-fanout stays on claude).
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

Examples:
  new-session my-project                                                     # orchestrator + claude-opus-5-5 (pinned)
  CLAUDE_SESSION_PROFILE=owner new-session my-lane-owner sessions            # full tools + sonnet
  CLAUDE_SESSION_PROFILE=hub new-session my-review-hub sessions              # full tools + Sonnet hub + Opus consult contract
  new-session my-project workspace
  new-session my-long-project-name --alias mpn
  CLAUDE_SESSION_PROFILE=builder new-session my-impl-task workspace          # trimmed tools + sonnet
  CLAUDE_SESSION_PROFILE=copywriter new-session my-docs-pass sessions        # trimmed tools + haiku
  CLAUDE_SESSION_MODEL=claude-opus-4-8 new-session my-orchestrator sessions  # pin a specific spawn
HELP_EOF
  exit 0
fi

# ── Inputs ──────────────────────────────────────────────────────────────────
FOLDERNAME=""; TYPE="auto"; ALIAS_ARG=""; BACKEND_ARG=""; DRYRUN=no; FORCE=no; TASK_ARG=""; TASK_FILE_ARG=""; SETDEFAULT_ALIAS=no; NPOS=0
TIER_ARG=""; TIER_REASON=""; NEEDS_FANOUT=no; APPROVE_OPUS=no
while [ $# -gt 0 ]; do
  case "$1" in
    -a|--alias)  ALIAS_ARG="${2:?--alias needs a value}"; shift 2 ;;
    --backend)   BACKEND_ARG="${2:?--backend needs a value}"; shift 2 ;;
    --set-default-alias) SETDEFAULT_ALIAS=yes; shift ;;
    --dry-run)   DRYRUN=yes; shift ;;
    --force)     FORCE=yes; shift ;;
    --tier)      TIER_ARG="${2:?--tier needs a value}"; shift 2 ;;
    --tier-reason) TIER_REASON="${2:?--tier-reason needs a value}"; shift 2 ;;
    --needs-fanout) NEEDS_FANOUT=yes; shift ;;
    --approve-opus) APPROVE_OPUS=yes; shift ;;
    --task)      TASK_ARG="${2:?--task needs a value}"; shift 2 ;;
    --task-file) TASK_FILE_ARG="${2:?--task-file needs a value}"; shift 2 ;;
    # NB: workspace/sessions/auto are only a TYPE when they appear AS the second
    # positional (after the folder). Matching them as the first positional would
    # make a folder literally named `sessions`/`workspace`/`auto` unspawnable
    # (e.g. the live `sessions` management session).
    -*) echo "new-session: unknown option '$1' (see --help)" >&2; exit 2 ;;
    *) if [ "$NPOS" -eq 0 ]; then FOLDERNAME="$1"; elif [ "$NPOS" -eq 1 ]; then TYPE="$1"
       else echo "new-session: too many positional arguments ('$1') — usage: new-session <foldername> [workspace|sessions|auto] [options]" >&2; exit 2; fi
       NPOS=$((NPOS + 1)); shift ;;
  esac
done
# Validate the positionals BEFORE any side effect (pinned by tests/test-new-session-names.sh).
# FOLDERNAME is a bare name that gets joined onto the workspace/sessions root, never a
# path: `new-session ~/.sessions fleet-v2` once made WORKDIR=<root>/<root> (the first
# positional was a directory, the second was taken as TYPE).
case "$FOLDERNAME" in
  ""|.|..|/*|*/*) echo "new-session: foldername '$FOLDERNAME' must be a bare name (no '/', not empty/./..) — it is joined onto \$CRSS_WORKSPACE or \$CRSS_SESSIONS_DIR. usage: new-session <foldername> [workspace|sessions|auto] [options]" >&2; exit 2 ;;
esac
case "$TYPE" in
  auto|workspace|sessions) ;;
  *) echo "new-session: unknown session type '$TYPE' (valid: workspace|sessions|auto) — usage: new-session <foldername> [workspace|sessions|auto] [options]" >&2; exit 2 ;;
esac
case "$TIER_ARG" in
  ""|light|standard|heavy) ;;
  *) echo "new-session: unknown --tier '$TIER_ARG' (valid: light|standard|heavy)" >&2; exit 2 ;;
esac
[ -z "$TIER_REASON" ] || [ -n "$TIER_ARG" ] || { echo "new-session: --tier-reason needs --tier" >&2; exit 2; }
# The overlay is read literally (no $HOME or ~ expansion), so a relative root would put the run
# directory under whatever cwd the start script has. Refuse before any side effect.
for _root_var in CRSS_WORKSPACE CRSS_SESSIONS_DIR; do
  case "${!_root_var}" in
    /*) ;;
    *) echo "new-session: ${_root_var}='${!_root_var}' must be an absolute path (the overlay is read literally: no \$HOME or ~ expansion)" >&2; exit 2 ;;
  esac
done

# ── Backend selection ────────────────────────────────────────────────────────
# --tier may route a tier to the codex backend (CRSS_TIER_CODEX_TIERS, a space-separated list
# of tiers, default empty) -- unless the task needs fan-out, which needs the Workflow tool (Claude full-tool profiles only). An explicit --backend or CRSS_SESSION_BACKEND always wins.
TIER_RULES=""
BACKEND="${BACKEND_ARG:-${CRSS_SESSION_BACKEND:-}}"
if [ -z "$BACKEND" ]; then
  BACKEND=claude
  if [ -n "$TIER_ARG" ] && [ "$NEEDS_FANOUT" != yes ]; then
    case " ${CRSS_TIER_CODEX_TIERS:-} " in *" $TIER_ARG "*) BACKEND=codex; TIER_RULES="backend=codex(CRSS_TIER_CODEX_TIERS)" ;; esac
  fi
fi
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

# _shell_words_literal — split an overlay arg string into words the way a shell
# would (quotes group, e.g. -c 'k="a b"'), without executing anything, then
# %q-escape each word. The value is parsed as data, never evaluated. If quoting
# is unbalanced it falls back to a plain whitespace split.
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

# --task/--task-file: validate up front so a bad kickoff argument fails loudly
# BEFORE anything spawns, not after (a spawned-but-unkicked session is a worse
# failure mode than no session at all — it looks like it worked).
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

# ── Preflight capacity gate ──────────────────────────────────────────────────
# Sessions are long-lived and nothing reaps them automatically, so spawns
# accumulate until the box runs out of RAM and every session degrades together
# (observed on a loaded box: dozens of live sessions, little free RAM, heavy
# swap, high load — turns taking 10+ minutes, commands hanging with no output).
# A wedged fleet looks like a Claude bug but is really host exhaustion, so
# refuse to make it worse. Advisory by default; only a genuinely unsafe box
# hard-blocks, and --force always overrides.
preflight_capacity() {
  # --dry-run is documented as a pure, side-effect-free preview ("print the
  # resolved names and exit — no session spawned, store untouched"), but this
  # gate ran unconditionally BEFORE $DRYRUN is consulted (it isn't checked
  # again until the naming section below), so a --dry-run on a genuinely
  # low-memory host hard-refused with no name output at all unless --force
  # was also passed — defeating the exact "check what this would resolve to"
  # use case --dry-run exists for (e.g. debugging a memory-pressure incident).
  # A dry-run spawns nothing and consumes no RAM, so it never needs this gate.
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

# ── Profile/model selection ─────────────────────────────────────────────────
if [ "$BACKEND" = claude ]; then
  # CLAUDE_SESSION_PROFILE selects BOTH the built-in tool-schema footprint AND
  # the default model for the spawned Claude session.
  # --tier fills only what CLAUDE_SESSION_PROFILE / _MODEL / _EFFORT leave unset (explicit wins):
  #   light -> copywriter (haiku, effort low)   standard -> builder (sonnet)   heavy -> owner (sonnet)
  # Floors/ceilings: --needs-fanout lifts a trimmed profile to owner (builder/copywriter drop the
  # Workflow tool but keep Agent + advisor); Opus (orchestrator) only via heavy + --approve-opus or an explicit
  # CLAUDE_SESSION_MODEL. Effort only moves DOWN from the CLI baseline (light=low); raise it
  # explicitly with CLAUDE_SESSION_EFFORT. Pinned by tests/test-new-session-tier.sh.
  PROFILE="${CLAUDE_SESSION_PROFILE:-}"
  if [ -z "$PROFILE" ]; then
    PROFILE=orchestrator
    case "$TIER_ARG" in
      light) PROFILE=copywriter ;;
      standard) PROFILE=builder ;;
      heavy) if [ "$APPROVE_OPUS" = yes ]; then PROFILE=orchestrator; else PROFILE=owner; fi ;;
    esac
    [ -z "$TIER_ARG" ] || TIER_RULES="${TIER_RULES:+$TIER_RULES,}profile=$PROFILE"
    if [ "$NEEDS_FANOUT" = yes ] && { [ "$PROFILE" = builder ] || [ "$PROFILE" = copywriter ]; }; then
      PROFILE=owner; TIER_RULES="${TIER_RULES:+$TIER_RULES,}fanout-floor=owner"
    fi
    # A tier that reaches Opus must be a bounded job: Opus is expensive per resident turn, so it
    # is only born with a task, and the launcher reaps it when done (nothing here enforces that).
    if [ -n "$TIER_ARG" ] && [ "$PROFILE" = orchestrator ] && [ -z "$TASK_ARG$TASK_FILE_ARG" ]; then
      echo "new-session: --tier $TIER_ARG --approve-opus resolves to Opus; pass --task/--task-file so it is a bounded job (or set CLAUDE_SESSION_PROFILE explicitly)" >&2; exit 2
    fi
  elif [ "$NEEDS_FANOUT" = yes ] && { [ "$PROFILE" = builder ] || [ "$PROFILE" = copywriter ]; }; then
    echo "note: --needs-fanout but CLAUDE_SESSION_PROFILE=$PROFILE has no Workflow tool" >&2
  fi
  # Cheap pre-classifier: flag a SHORT task that looks mechanical but was given a heavier tier. (A heavy-direction
  # keyword check was dropped: it fired on guardrail wording in ordinary kickoff text.) It FLAGS
  # (note + telemetry rule); it never overrides the launcher. Disagreement rate is the signal for
  # tuning the rubric.
  if [ -n "$TIER_ARG" ]; then
    _task_text="$TASK_ARG"
    [ -z "$TASK_FILE_ARG" ] || [ ! -r "$TASK_FILE_ARG" ] || _task_text="$_task_text $(head -c 4000 "$TASK_FILE_ARG")"
    _hint=""
    if [ "$TIER_ARG" != light ] && [ "${#_task_text}" -gt 0 ] && [ "${#_task_text}" -lt 200 ] && grep -qiE '\b(typo|rename|reformat|docs?[- ]only|comment)\b' <<<"$_task_text"; then _hint=light; fi
    if [ -n "$_hint" ]; then
      echo "note: task text looks '$_hint' but --tier $TIER_ARG was declared (kept; recorded as heuristic=$_hint)" >&2
      TIER_RULES="${TIER_RULES:+$TIER_RULES,}heuristic=$_hint"
    fi
  fi
  case "$PROFILE" in
    orchestrator|owner|hub|builder|copywriter) ;;
    *) echo "note: unknown CLAUDE_SESSION_PROFILE='$PROFILE' — defaulting to 'orchestrator' (full tool set). Valid: orchestrator|owner|hub|builder|copywriter" >&2
       PROFILE="orchestrator" ;;
  esac

  if [ -n "${CLAUDE_SESSION_MODEL:-}" ]; then
    MODEL="$CLAUDE_SESSION_MODEL"; MODEL_SRC=explicit
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
  EFFORT=""; EFFORT_SRC=""
  if [ -n "${CLAUDE_SESSION_EFFORT:-}" ]; then
    EFFORT="$CLAUDE_SESSION_EFFORT"; EFFORT_SRC=explicit
  elif [ "$TIER_ARG" = light ]; then
    EFFORT=low; EFFORT_SRC=tier
  fi
  case "$EFFORT" in
    ""|low|medium|high|xhigh|max) ;;
    *) echo "new-session: CLAUDE_SESSION_EFFORT='$EFFORT' invalid (valid: low|medium|high|xhigh|max)" >&2; exit 2 ;;
  esac
  [ "$EFFORT_SRC" != tier ] || TIER_RULES="${TIER_RULES:+$TIER_RULES,}effort=low"
  if [ "$MODEL_SRC" = explicit ]; then
    case "$MODEL" in
      opus|sonnet|haiku|fable|default|opusplan)
        echo "note: '$MODEL' is a moving model alias — it may resolve to different releases over time. For a reproducible pin set an exact id, e.g. CLAUDE_SESSION_MODEL=claude-opus-4-8" >&2 ;;
    esac
  fi
else
  PROFILE=codex; EFFORT=""; EFFORT_SRC=""; ADVISOR=none
  MODEL="$(_codex_model_from_args)"
  if [ -n "$MODEL" ]; then
    MODEL_SRC=codex-args
  else
    MODEL=codex
    MODEL_SRC=backend-default
  fi
fi

# Builder keep-list: the built-ins a hands-on-implementation session needs.
# Shared by the `builder` and `copywriter` profiles (both are trimmed, non-fan-out
# roles). Comma-separated, NO spaces, so it stays a single shell word when baked
# into the generated claude command line.
#
# IMPORTANT: --tools is an EXHAUSTIVE allowlist over the BUILT-IN set — it gates
# the *deferred* built-ins (WebFetch, WebSearch, Task*, plan-mode, …) too, not
# just the upfront-schema ones. Verified empirically: a built-in omitted here is
# unreachable even via ToolSearch. (MCP-server tools are a separate namespace and
# stay reachable regardless of this list.) Deferred built-ins cost 0 upfront
# tokens, so re-listing them is FREE (measured: System tools = 8.2k with OR
# without them) — we keep the useful ones so a builder stays fully capable:
# web fetch/search, task tracking, plan mode, notebook edits, background monitor.
#
# The ~10.3k saving comes from DROPPING 5 upfront-schema tools: Workflow (~7.8k
# — multi-agent fan-out, THE orchestrator-defining tool) plus Artifact,
# SendUserFile, ReportFindings, ScheduleWakeup (~2.5k combined — the
# reporting/scheduling surface). A builder that genuinely needs one of those
# should add it here (~1k each) or just use the orchestrator profile.
#
# `advisor` is KEPT (~1k), unlike its reporting-surface neighbours: the builder
# role is the one that actually reaches for a second opinion, and --tools gates
# deferred built-ins too, so omitting it here made it unreachable ENTIRELY —
# which presents as "advisor is broken" rather than "never allowlisted".
# NB it is ALSO gated on the agent's own model, independent of this list
# (verified against the installed CLI: the sonnet line has it, the opus 5.x
# line does not).
# This allowlist is necessary but not sufficient — keep builder on sonnet.
BUILDER_TOOLS="Bash,Read,Edit,Write,Glob,Grep,Agent,AskUserQuestion,Skill,ToolSearch,WebFetch,WebSearch,TaskCreate,TaskGet,TaskList,TaskUpdate,TaskStop,TaskOutput,EnterPlanMode,ExitPlanMode,NotebookEdit,Monitor,advisor"
HUB_CONSULT_PROMPT='You are a Sonnet hub. At forks consult Opus one-shot via Agent(model:"opus") after first writing a frozen packet to .claude/hub-opus-frozen-packet.md. Packet only: state, options, your recommendation, UNVERIFIED list, file paths; never transcripts. Forks: before destructive/irreversible actions, design under real ambiguity, and before declaring a multi-step task done. Never use Opus/Fable as polling or waiting sessions. Builders default Codex-first (new-session --backend codex, codex exec), then Sonnet fallback. Record models_ran with actual models.'

# --exclude-dynamic-system-prompt-sections (BOTH profiles, unconditional): moves
# cwd/env/memory-path/git-status out of the cached system prompt into the first
# user message — a prompt-cache-reuse win across spawns. NB: this RELOCATES those
# sections, it does not shrink the raw token total.
CLAUDE_EXTRA_FLAGS="--exclude-dynamic-system-prompt-sections"
if [ "$BACKEND" = claude ]; then
  case "$PROFILE" in
    hub) CLAUDE_EXTRA_FLAGS="$CLAUDE_EXTRA_FLAGS --append-system-prompt $(_shell_quote "$HUB_CONSULT_PROMPT")" ;;
    builder|copywriter) CLAUDE_EXTRA_FLAGS="$CLAUDE_EXTRA_FLAGS --tools $BUILDER_TOOLS" ;;
  esac
  [ -z "$EFFORT" ] || CLAUDE_EXTRA_FLAGS="$CLAUDE_EXTRA_FLAGS --effort $EFFORT"
  # Advisor: Opus first (CRSS_ADVISOR_MODEL, default = CRSS_OPUS_MODEL). Fable is the last rung and
  # is called one-shot by the parent, not set here. Only sessions that HAVE the advisor tool (not
  # Opus/Fable themselves) get the flag. CLAUDE_SESSION_ADVISOR overrides; "none" omits the flag.
  ADVISOR="${CLAUDE_SESSION_ADVISOR:-$CRSS_ADVISOR_MODEL}"
  [ -n "${CLAUDE_SESSION_ADVISOR:-}" ] || [ "$TIER_ARG" != light ] || ADVISOR=none   # light = cheap tier: no Opus advisor unless asked
  case "$MODEL" in *opus*|*fable*) ADVISOR=none ;; esac
  [[ "$ADVISOR" == none || "$ADVISOR" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || { echo "new-session: CLAUDE_SESSION_ADVISOR='$ADVISOR' invalid (model id/alias or none)" >&2; exit 2; }
  [ "$ADVISOR" = none ] || CLAUDE_EXTRA_FLAGS="$CLAUDE_EXTRA_FLAGS --advisor $ADVISOR"
else
  CLAUDE_EXTRA_FLAGS=""
fi

# ── Resolve workdir ─────────────────────────────────────────────────────────
# TYPE was validated with the other positionals above.
if [ "$TYPE" = "auto" ]; then
  [ -d "${CRSS_WORKSPACE}/${FOLDERNAME}" ] && TYPE="workspace" || TYPE="sessions"
fi

if [ "$TYPE" = "workspace" ]; then
  WORKDIR="${CRSS_WORKSPACE}/${FOLDERNAME}"
else
  WORKDIR="${CRSS_SESSIONS_DIR}/${FOLDERNAME}"
fi

# ── Naming ──────────────────────────────────────────────────────────────────
# Name-first, date last: `<prefix>-<alias>-<MMDD-HHMM>`. Aliases are short
# (capped / acronym'd), so the whole name fits the mobile window while reading
# naturally and grouping by project. Prefix is $CRSS_SESSION_PREFIX (generic
# default "cs"; a host migrating off an old hardcoded prefix sets it to that
# value instead — see the CRSS-PREFIX-RE block above); session-doctor
# understands the configured prefix plus $CRSS_LEGACY_PREFIXES and does not
# parse the date, so order is opaque to it.
ID=$(date +%m%d-%H%M)
# In --dry-run, resolve read-only (--no-save) so a preview never mutates the store.
DRYFLAG=""; [ "$DRYRUN" = yes ] && DRYFLAG="--no-save"
# --alias alone is per-spawn; only --set-default-alias makes it the folder default.
SETDEFFLAG=""; [ "$SETDEFAULT_ALIAS" = yes ] && SETDEFFLAG="--set-default"
if command -v session-alias >/dev/null 2>&1; then
  ALIAS=$(session-alias "$FOLDERNAME" ${ALIAS_ARG:+--alias "$ALIAS_ARG"} ${SETDEFFLAG:+$SETDEFFLAG} ${DRYFLAG:+$DRYFLAG} 2>/dev/null) || ALIAS=""
fi
# Fallback if the helper is missing (mirrors fallback-recipe): sanitized folder.
[ -n "$ALIAS" ] || ALIAS=$(printf '%s' "$FOLDERNAME" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//')
BODY="${ALIAS}-${ID}"
SESSION="${CRSS_SESSION_PREFIX}_${BODY}"
REMOTE_NAME="${CRSS_SESSION_PREFIX}-${BODY}"
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
# name_taken <session> <remote_name> — is this candidate name unavailable?
# Live tmux session -> yes. Also yes when a worktree is still registered at
# ~/.claude/worktrees/<remote_name>: reap-local never removes worktree files
# (see session-doctor.sh reap), so a reaped session's worktree can outlive
# its tmux session and its systemd unit. Respawning the SAME folder+alias
# within the same clock-minute (ID is minute-granularity) would otherwise
# reissue that reaped session's exact REMOTE_NAME, and session-git-prep.sh
# treats a REMOTE_NAME's own registered worktree as safe to reuse across a
# restart (by design, so a live session's restart doesn't orphan itself) —
# which would silently hand this brand-new session someone else's leftover,
# possibly-dirty worktree (found in review, chatgpt-codex-connector, PR #72).
# Reserving the name until a human runs worktree-stale keeps that reuse path
# limited to genuine restarts of the SAME session.
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
    # Bounded, not `while :`: this loop only ever needs to advance past names a
    # CONCURRENT spawn is actively racing for, which is inherently self-limiting.
    # A persistent (non-transient) `mkdir` failure — LOCKROOT on a read-only/full
    # filesystem, or a plain file occupying that path — makes every iteration
    # fail identically forever; an unbounded loop then spins with no sleep, no
    # cap, and no diagnostic, hanging the whole spawn with no sign of why. Fail
    # loudly instead once a persistent failure is implausibly still "just a race".
    while :; do
      if mkdir "$LOCKROOT/${SESSION}.lock" 2>/dev/null; then
        if name_taken "$SESSION" "$REMOTE_NAME"; then
          # Name was already live or worktree-retained (a prior, non-racing
          # spawn or a reaped-but-uncleaned session) — free the lock we just
          # took and move on to the next candidate name.
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
      # Build the next candidate from the CURRENT n before incrementing — not
      # after — so the first retry after the bare base name is "-2" (matching
      # the dry-run branch above and the collision-suffix numbering the tests
      # assert), not "-3" (found by Codex review on this PR: incrementing
      # first skipped "-2" on every real, non-dry-run collision).
      BODY="${ALIAS}-${ID}-${n}"; SESSION="${CRSS_SESSION_PREFIX}_${BODY}"; REMOTE_NAME="${CRSS_SESSION_PREFIX}-${BODY}"
      n=$((n+1))
      if [ "$n" -gt 1000 ]; then
        echo "new-session: could not claim a session-name lock under '$LOCKROOT' after 1000 attempts — likely a persistent filesystem problem (read-only/full), not a race. Check '$LOCKROOT' by hand." >&2
        exit 1
      fi
    done
  fi
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
PROFILE_LITERAL="$(_shell_quote "$PROFILE")"
CODEX_BIN_LITERAL="$(_shell_quote "$CRSS_CODEX_BIN")"
CODEX_ARGS_LITERAL="$(_shell_words_literal "$CRSS_CODEX_ARGS")"

if [ "$DRYRUN" = yes ]; then
  printf 'SESSION=%s\nREMOTE_NAME=%s\nSCRIPT=%s\nSERVICE=%s\nBACKEND=%s\nPROFILE=%s\nMODEL=%s\nMODEL_SRC=%s\nCLAUDE_EXTRA_FLAGS=%s\nTIER=%s\nTIER_RULES=%s\nEFFORT=%s\nADVISOR=%s\nCODEX_ARGS=%s\n%s\n' \
    "$SESSION" "$REMOTE_NAME" "$SCRIPT" "$SERVICE" "$BACKEND" "$PROFILE" "$MODEL" "$MODEL_SRC" "$CLAUDE_EXTRA_FLAGS" "${TIER_ARG:-none}" "${TIER_RULES:-none}" "${EFFORT:-default}" "$ADVISOR" "$CRSS_CODEX_ARGS" "$OVERLAY_LINE"
  exit 0
fi

# One id per start attempt, logged on every start-script line and required by the Codex start
# verdict below, so a stale or concurrent line can never stand in for THIS spawn. Generated after
# the dry-run exit (a dry run needs no RNG) and before any start script or unit is written. od's own status is
# checked, not tr's: an od that prints 32 hex characters and then fails is refused.
START_ID="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null)" || START_ID=""
START_ID="${START_ID//[$' \n']/}"
[[ "$START_ID" =~ ^[0-9a-f]{32}$ ]] || { echo "new-session: could not generate a start id from /dev/urandom" >&2; exit 1; }

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# Folder-trust pre-seed helper, baked into the start script: co-located (repo layout)
# first, then PATH (deployed layout, .sh dropped). Empty when neither exists.
TRUST_SEED=""
if [ -f "$SELF_DIR/session-trust-seed.sh" ]; then TRUST_SEED="$SELF_DIR/session-trust-seed.sh"
elif command -v session-trust-seed >/dev/null 2>&1; then TRUST_SEED="$(command -v session-trust-seed)"; fi
TRUST_SEED_LITERAL="$(_shell_quote "$TRUST_SEED")"
mkdir -p "$(dirname "$SCRIPT")" "$(dirname "$SERVICE")"
if [ -n "$HUB_CONSULT_PROMPT_FILE" ]; then
  printf '%s\n' "$HUB_CONSULT_PROMPT" > "$HUB_CONSULT_PROMPT_FILE"
fi

# ── Generate start script ────────────────────────────────────────────────────
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
  ln -sf ${CRSS_CLAUDE_HOME}/skills "\$RUNDIR/.claude/skills"
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
SCRIPT_EOF

# Claude supervisor loop, first match wins each iteration:
#   resume pin  -> `--resume <uuid>` (written by `session-resume`). The pin is
#                  cleared only after claude has run 30s+ (or by session-resume
#                  once the registry confirms it): a bad uuid that exits at once
#                  is retried after the backoff, never silently downgraded to
#                  `--continue` (which could open the wrong conversation).
#   sentinel    -> `--continue` (a restart of this session)
#   neither     -> fresh session. The sentinel is touched BEFORE that first launch:
#                  touching it after claude exits meant a session killed from outside
#                  (tmux kill-session, unit stop) never got one, and its next unit
#                  start was a fresh conversation.
#                  `--continue` with no prior conversation just starts fresh (checked
#                  on 2.1.285), so touching early costs nothing.
if [ "$BACKEND" = claude ]; then
  cat >> "$SCRIPT" << SCRIPT_EOF
tmux send-keys -t "${SESSION}" 'LOG_FILE="$HOME/.sessions/session-starts.log"
SESSION="${SESSION}"
SENTINEL="\$PWD/.sessions-init-${REMOTE_NAME}"
RESUME_PIN="$HOME/.sessions/resume/${REMOTE_NAME}.uuid"
while true; do
  START=\$(date +%s)
  PINNED=0
  if [ -s "\$RESUME_PIN" ]; then
    RESUME_ID=\$(cat "\$RESUME_PIN"); PINNED=1; touch "\$SENTINEL"
    ${CRSS_CLAUDE_BIN} --dangerously-skip-permissions --model "${MODEL}" ${CLAUDE_EXTRA_FLAGS} --settings ${CRSS_CLAUDE_HOME}/rc-firstparty.settings.json --remote-control ${REMOTE_NAME} --resume "\$RESUME_ID"
  elif [ -f "\$SENTINEL" ]; then
    ${CRSS_CLAUDE_BIN} --dangerously-skip-permissions --model "${MODEL}" ${CLAUDE_EXTRA_FLAGS} --settings ${CRSS_CLAUDE_HOME}/rc-firstparty.settings.json --remote-control ${REMOTE_NAME} --continue
  else
    touch "\$SENTINEL"
    ${CRSS_CLAUDE_BIN} --dangerously-skip-permissions --model "${MODEL}" ${CLAUDE_EXTRA_FLAGS} --settings ${CRSS_CLAUDE_HOME}/rc-firstparty.settings.json --remote-control ${REMOTE_NAME}
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
while true; do
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

# ── Generate systemd unit ────────────────────────────────────────────────────
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

# ── Enable and start ─────────────────────────────────────────────────────────
# bash's own clock (no `date` fork): several test harnesses put a recursing `date` stub on PATH
t0="$(TZ=UTC printf '%(%Y-%m-%dT%H:%M:%SZ)T' -1)"
if ! { systemctl --user daemon-reload && systemctl --user enable --now "$(basename "$SERVICE")"; }; then
  # The unit may now be enabled and failed: a later boot would re-run the start script and refuse
  # again. Best effort, output discarded: disable it and clear the failed state. The unit file stays.
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

# A Codex lane is reported started only from explicit evidence: the LAST well-formed log line for
# this session written at or after t0 AND carrying THIS start attempt's start_id (so a stale or
# concurrent same-second line cannot count) must end exactly in ` event=started`. A fresh
# fail-closed line, any UNVERIFIED line, a stale line, a line from another attempt, a malformed
# timestamp, or no line at all exits 3.
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
  RD="${LOGLINE#*session="${SESSION}" rundir=}"
  [ -n "$RD" ] && TELEMETRY_DIR="$RD"
fi
if [ -x "$SELF_DIR/record-spawn-telemetry.sh" ]; then
  "$SELF_DIR/record-spawn-telemetry.sh" "$FOLDERNAME" "$ALIAS" "$REMOTE_NAME" "$SESSION" "$TYPE" "$MODEL" "$TELEMETRY_DIR" "${TIER_ARG:-}" "${EFFORT:-}" "${TIER_RULES:-}" "$TIER_REASON" || true
fi

# ── Kickoff task (--task/--task-file) ───────────────────────────────────────
# Replaces the fragile manual dance (spawn, hand-type the prompt, eyeball it
# landed, hit Enter) with the SAME poll-then-verify path session-handoff.sh
# already uses for a live session's follow-ups — not a second copy of that
# logic. Resolve the helper co-located first (repo/dev layout: session-
# handoff.sh next to this script) then on PATH (deployed layout: flat copies
# in ~/.local/bin with the .sh dropped, see session-git-prep.sh's header) so
# this works in both. Invoked via `bash` so the helper's exec bit (664 in-repo)
# never matters.
# TASK_FAILED collects why the task was not (verifiably) delivered; any value makes the
# spawn exit 3 below, after naming the session, so a launcher never mistakes it for success.
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
    # Require `check` to report ready for NEW_SESSION_TASK_SETTLE (default 3)
    # CONSECUTIVE 1s-apart polls, not just once, before the first send: on a freshly
    # booted TUI the first paste right after the prompt renders can be silently
    # dropped. This only cuts how often that race is hit; session-handoff.sh's
    # `send` ("dropped-first-paste recovery") is what catches one that slips past.
    ready=no
    trust_dialog=no
    gone=no
    settle_need="${NEW_SESSION_TASK_SETTLE:-3}"
    settle_have=0
    for _i in $(seq 1 "${NEW_SESSION_TASK_READY_TRIES:-90}"); do
      # `check` exits non-zero for every not-ready state, so the status must be
      # captured WITHOUT tripping `set -e` (a bare `x="$(cmd)"` exits the whole
      # script silently — the first not-ready poll killed the spawn after the
      # systemd symlink line, with no "Session created" and no warning).
      check_rc=0; check_out="$(bash "$HANDOFF" check "$SESSION" 2>&1)" || check_rc=$?
      # A menu/dialog (typically the folder-trust prompt) waits on a human and
      # cannot resolve by itself: stop polling at once. The start script pre-seeds
      # trust (session-trust-seed), so seeing it here means seeding failed.
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
      # Codex's model-retirement notice is a menu too, but answering it is a model
      # choice, not a trust grant: name it distinctly and never pick for the operator.
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

# ── Confirm ──────────────────────────────────────────────────────────────────
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
