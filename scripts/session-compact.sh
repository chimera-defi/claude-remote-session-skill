#!/usr/bin/env bash
# session-compact.sh — reclaim idle or context-heavy sessions by issuing /compact.
# session-doctor.sh idle-report is the read-only sensor; this script does all mutation.
#
# Usage:
#   session-compact.sh report                          list eligible sessions; mutates nothing
#   session-compact.sh sweep [--dry-run|--apply]       idle-or-context sweep (default --dry-run)
#   session-compact.sh before-relay <session> (<msg>|--file <path>)   compact if stale, verify, relay
#   session-compact.sh install-timer [--force]         write systemd units; enables nothing
#
#   Flags: --min-idle N (60)  --max-idle N (0 = no cap)  --timeout N (240)  --managed-only
#   --managed-only limits sweep to names in $SESSION_COMPACT_MANAGED_FILE; a missing list means zero sessions.
set -uo pipefail

# Admission for autonomous compaction goes through the single Agent Host helper.
_crss_admit() {
  local helper_dir helper
  helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -f "$helper_dir/autonomous-admission.sh" ]; then
    helper="$helper_dir/autonomous-admission.sh"
  else
    helper="$(command -v autonomous-admission 2>/dev/null)" || return 2
  fi
  bash "$helper" "$@"
}

# ── helpers ──

# _find_helper <basename> — co-located <basename>.sh first, then PATH; fails safe on a miss.
_find_helper() {
  local base="$1" here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
  if [ -f "$here/${base}.sh" ]; then printf '%s\n' "$here/${base}.sh"; return 0; fi
  if command -v "$base" >/dev/null 2>&1; then command -v "$base"; return 0; fi
  return 1
}

# _encode_cwd <path> — transcript dir name. '.' -> '-' must run before '/' -> '-'.
_encode_cwd() {
  local p="$1"
  p="${p//./-}"
  printf '%s\n' "${p//\//-}"
}

# _compact_marker_newer <cwd> <baseline> -> newest compact marker timestamp after baseline, or empty.
# Python does the string compare: POSIX [ ] has no string ordering and [[ ]] is avoided here.
# The baseline is taken before send, so an earlier compact is never mistaken for this one.
_compact_marker_newer() {
  local cwd="$1" baseline="$2" dir
  dir="$HOME/.claude/projects/$(_encode_cwd "$cwd")"
  [ -d "$dir" ] || { echo ""; return; }
  python3 -c "
import sys, glob, json, os
d, baseline = sys.argv[1], sys.argv[2]
mx = None
for fn in glob.glob(os.path.join(d, '*.jsonl')):
    try:
        with open(fn, encoding='utf-8', errors='ignore') as fh:
            for line in fh:
                # Cheap prefilter before json.loads (same trick session-
                # doctor.sh's idle-report scan uses) — skip lines that can't
                # possibly be either marker shape.
                if 'compact_boundary' not in line and 'isCompactSummary' not in line:
                    continue
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                ts = None
                if o.get('type') == 'system' and o.get('subtype') == 'compact_boundary':
                    ts = o.get('timestamp')
                elif o.get('type') == 'user' and o.get('isCompactSummary'):
                    ts = o.get('timestamp')
                if not ts:
                    continue
                if baseline and ts <= baseline:
                    continue
                if mx is None or ts > mx:
                    mx = ts
    except OSError:
        pass   # transcript file gone mid-scan — just skip it
print(mx or '')
" "$dir" "$baseline"
}

# ── sweep: context-aware trigger ──

# _model_window_for <model> -> context window tokens, or empty if unknown (never guess a percentage).
# Add a model here when it is first spawned: a missing entry silently disables the context trigger.
_model_window_for() {
  case "$1" in
    *sonnet*|*opus*|*fable*) echo 1000000 ;;
    *haiku*)                 echo 200000 ;;
    *)                       echo "" ;;
  esac
}

# _cli_compact_trigger <W> <PCT> -> auto-compact trigger tokens, or empty.
_cli_compact_trigger() {
  python3 - "$1" "$2" <<'PYTRIGGER'
import sys
if all(v.isascii() and v.isdecimal() for v in sys.argv[1:]):
    window, pct = map(int, sys.argv[1:])
    trigger = min((window - 20000) * pct // 100, window - 33000)
    if trigger > 0 and pct > 0:
        print(trigger)
PYTRIGGER
}

# Settings come from the live Claude process under the pane first, then settings.json.
_session_compact_env() {
  local session="$1" cap="$2" pane_pid
# list-panes, not display-message: display-message prints nothing for =name targets on tmux 3.4.
  pane_pid="$(tmux list-panes -t "=$session" -F '#{pane_pid}' 2>/dev/null | head -1)" || pane_pid=""
  python3 - "$pane_pid" "${SESSION_COMPACT_PROC_ROOT:-/proc}" \
    "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" "$cap" <<'PYENV'
import glob, json, os, sys
pane, root, settings_path, cap = sys.argv[1:]
keys = ('CLAUDE_CODE_AUTO_COMPACT_WINDOW', 'CLAUDE_AUTOCOMPACT_PCT_OVERRIDE')
live = {}
children = {}
if pane.isascii() and pane.isdecimal():
    for path in glob.glob(os.path.join(root, '[0-9]*', 'stat')):
        try:
            with open(path) as fh:
                ppid = fh.read().rsplit(')', 1)[1].split()[1]
            children.setdefault(ppid, []).append(os.path.basename(os.path.dirname(path)))
        except (OSError, IndexError):
            continue
    pending, seen = [pane], set()
    for pid in pending:
        if pid in seen:
            continue
        seen.add(pid)
        pending.extend(sorted(children.get(pid, []), key=int))
        try:
            with open(os.path.join(root, pid, 'comm')) as fh:
                comm = fh.read().strip()
            with open(os.path.join(root, pid, 'cmdline'), 'rb') as fh:
                args = fh.read().decode(errors='replace').split('\0')
            if not (comm == 'claude' or os.path.basename(args[0]) == 'claude'
                    or any(a.endswith('/@anthropic-ai/claude-code/cli.js') for a in args)):
                continue
            with open(os.path.join(root, pid, 'environ'), 'rb') as fh:
                live = dict(v.split('=', 1) for v in fh.read().decode(errors='replace').split('\0') if '=' in v)
            break  # nearest Claude ancestor of any nested agents owns the pane
        except OSError:
            continue
try:
    with open(settings_path) as fh:
        settings = json.load(fh).get('env', {})
    if not isinstance(settings, dict):
        settings = {}
except (OSError, ValueError, AttributeError):
    settings = {}
values = [str(live.get(k, settings.get(k, ''))) for k in keys]
if all(v.isascii() and v.isdecimal() for v in values):
    window, pct = map(int, values)
    if window > 0 and pct > 0:
        print('%d\t%d' % (min(window, int(cap)), pct))
PYENV
}

# _context_snapshot <cwd> -> "tokens<TAB>model" from the last real assistant turn, or empty.
# Tokens = input + cache_read + cache_creation; <synthetic> entries are skipped (zero usage).
_context_snapshot() {
  local cwd="$1" dir
  dir="$HOME/.claude/projects/$(_encode_cwd "$cwd")"
  [ -d "$dir" ] || { echo ""; return; }
  python3 -c "
import sys, glob, json, os
d = sys.argv[1]
best_ts = None
best = None
for fn in glob.glob(os.path.join(d, '*.jsonl')):
    try:
        with open(fn, encoding='utf-8', errors='ignore') as fh:
            for line in fh:
                if '\"assistant\"' not in line:
                    continue
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                if o.get('type') != 'assistant':
                    continue
                msg = o.get('message') or {}
                model = msg.get('model')
                if not model or model == '<synthetic>':
                    continue
                usage = msg.get('usage')
                if not isinstance(usage, dict):
                    continue
                ts = o.get('timestamp')
                if not ts:
                    continue
                if best_ts is None or ts > best_ts:
                    best_ts = ts
                    best = (usage, model)
    except OSError:
        pass   # transcript file gone mid-scan — just skip it
if best is None:
    print('')
else:
    usage, model = best
    def num(k):
        try:
            return int(usage.get(k) or 0)
        except Exception:
            return 0
    tokens = num('input_tokens') + num('cache_read_input_tokens') + num('cache_creation_input_tokens')
    print('%d\t%s' % (tokens, model))
" "$dir"
}

# _context_pct_for_row <cwd> <session> -> "tokens<TAB>pct" or empty; empty means context unknown.
_context_pct_for_row() {
  local cwd="$1" session="$2" raw tokens model window settings trigger
  raw="$(_context_snapshot "$cwd")"
  [ -n "$raw" ] || { echo ""; return; }
  tokens="${raw%%$'\t'*}"
  model="${raw#*$'\t'}"
  case "$tokens" in ''|*[!0-9]*) echo ""; return ;; esac
  window="$(_model_window_for "$model")"
  [ -n "$window" ] || { echo ""; return; }
  settings="$(_session_compact_env "$session" "$window")"
  [ -n "$settings" ] || { echo ""; return; }
  trigger="$(_cli_compact_trigger "${settings%%$'\t'*}" "${settings#*$'\t'}")"
  [ -n "$trigger" ] || { echo ""; return; }
  printf '%s\t%s\n' "$tokens" "$(( tokens * 100 / trigger ))"
}

# Managed sessions bind to the transcript's task state; any in_progress phase task fails closed.
_managed_task_state_for_cwd() {
  local cwd="$1" project_dir tasks_root
  project_dir="$HOME/.claude/projects/$(_encode_cwd "$cwd")"
  tasks_root="${SESSION_COMPACT_TASKS_ROOT:-$HOME/.claude/tasks}"
  [ -d "$project_dir" ] || { echo unknown; return; }
  python3 - "$project_dir" "$tasks_root" <<'PYTASK'
import glob, json, os, sys
project_dir, tasks_root = sys.argv[1], sys.argv[2]
best = None
for fn in glob.glob(os.path.join(project_dir, '*.jsonl')):
    try:
        with open(fn, encoding='utf-8', errors='ignore') as fh:
            for line in fh:
                if 'assistant' not in line or 'usage' not in line:
                    continue
                try: obj = json.loads(line)
                except Exception: continue
                if obj.get('type') != 'assistant': continue
                msg = obj.get('message')
                if not isinstance(msg, dict) or not isinstance(msg.get('usage'), dict): continue
                if msg.get('model') == '<synthetic>': continue
                ts = obj.get('timestamp')
                if not ts: continue
                candidate = (ts, os.path.splitext(os.path.basename(fn))[0])
                if best is None or candidate[0] > best[0]: best = candidate
    except OSError:
        continue
if best is None:
    print('unknown'); raise SystemExit
session_id = best[1]
task_dir = os.path.join(tasks_root, session_id)
if not os.path.isdir(task_dir):
    print('clear'); raise SystemExit
active = 0
for fn in glob.glob(os.path.join(task_dir, '*.json')):
    try:
        with open(fn, encoding='utf-8', errors='ignore') as fh: obj = json.load(fh)
    except Exception:
        print('unknown'); raise SystemExit
    if not isinstance(obj, dict):
        print('unknown'); raise SystemExit
    if obj.get('status') == 'in_progress': active += 1
print(('active:%d' % active) if active else 'clear')
PYTASK
}

# _validate_uint <flag> <var> — canonicalizes the named variable in place.
# Call it as a plain statement: in $(...) the exit 2 would only kill the subshell.
_validate_uint() {
  local name="$1"
  local -n ref="$2"
  case "$ref" in
    ''|*[!0-9]*) echo "session-compact: $name requires a non-negative integer, got '$ref'" >&2; exit 2 ;;
  esac
  ref=$((10#$ref))
}

# _managed_allowlist_file -> $SESSION_COMPACT_MANAGED_FILE or ~/.claude/session-compact-managed.
_managed_allowlist_file() {
  printf '%s\n' "${SESSION_COMPACT_MANAGED_FILE:-$HOME/.claude/session-compact-managed}"
}

# _read_managed_allowlist <path> -> trimmed names, skipping blanks and # lines; missing file prints nothing.
_read_managed_allowlist() {
  local f="$1" line trimmed
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [ -n "$trimmed" ] || continue
    case "$trimmed" in
      '#'*) continue ;;
    esac
    printf '%s\n' "$trimmed"
  done < "$f"
}

# _decide <min> <max> <session> <remote> <pid> <cwd> <idle> <last_ts> <protected> <compacted> <landed> <dirty> <marker_hit>
# Pure: no I/O. Prints eligible or skip:<reason>.
_decide() {
  local min_idle="$1" max_idle="$2"
# Missing fields default to empty; the four flags must match the sensor vocabulary or skip:malformed-row.
  local idle_minutes="${7:-}" protected="${9:-}" compacted="${10:-}" landed="${11:-}" dirty="${12:-}" marker_hit="${13:-}"

  if [ "$idle_minutes" = never ]; then echo "skip:never-touched"; return; fi
  case "$idle_minutes" in
    ''|*[!0-9]*) echo "skip:bad-idle-field"; return ;;
  esac
  local idle_n=$((10#$idle_minutes))

  case "$protected" in
    yes|no) : ;;
    *) echo "skip:malformed-row"; return ;;
  esac
  case "$compacted" in
    yes|no|unknown) : ;;
    *) echo "skip:malformed-row"; return ;;
  esac
  case "$landed" in
    yes|no|unknown|no-worktree) : ;;
    *) echo "skip:malformed-row"; return ;;
  esac
  case "$dirty" in
    clean|DIRTY|unknown) : ;;
    *) echo "skip:malformed-row"; return ;;
  esac

  if [ "$idle_n" -lt "$min_idle" ]; then echo "skip:outside-window"; return; fi
  if [ "$max_idle" != 0 ] && [ "$idle_n" -gt "$max_idle" ]; then echo "skip:outside-window"; return; fi

  if [ "$protected" = yes ]; then echo "skip:protected"; return; fi

  if [ "$landed" = yes ] && [ "$dirty" = clean ]; then echo "skip:landed-and-clean"; return; fi

  case "$compacted" in
    yes) echo "skip:already-compacted"; return ;;
    unknown)
      if [ "$marker_hit" = yes ]; then echo "skip:already-compacted"; return; fi
      ;;
  esac

  echo eligible
}

# _marker_file <session> -> compact-marker JSON path.
_marker_file() { printf '%s\n' "$HOME/.sessions/compact-markers/$1.json"; }

# _marker_hit <session> <ts> -> yes|no. Only consulted when the sensor reports compacted=unknown.
_marker_hit() {
  local session="$1" ts="$2" f stored
  f="$(_marker_file "$session")"
  [ -f "$f" ] || { echo no; return; }
  stored="$(python3 -c "
import json, sys
try:
    print(json.load(open(sys.argv[1])).get('last_user_ts_at_compact', ''))
except Exception:
    print('')
" "$f" 2>/dev/null)"
  if [ -n "$stored" ] && [ "$stored" = "$ts" ]; then echo yes; else echo no; fi
}

# _write_marker — atomic write under flock. Written after every successful compact; the only
# safety net on CLIs without the compact_boundary marker.
_write_marker() {
  local session="$1" ts="$2" injected_at="$3" result="$4" dir f tmp
  dir="$HOME/.sessions/compact-markers"
  mkdir -p "$dir"
  f="$dir/$session.json"
  exec 9>"$f.lock"
  flock 9
  tmp="$(mktemp "$f.XXXXXX")"
  python3 -c "
import json, sys
json.dump({'session': sys.argv[1], 'last_user_ts_at_compact': sys.argv[2],
           'injected_at': sys.argv[3], 'result': sys.argv[4]}, open(sys.argv[5], 'w'))
" "$session" "$ts" "$injected_at" "$result" "$tmp"
  mv -f "$tmp" "$f"
  flock -u 9
}

_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ── sensor and session-handoff I/O ──

# _fetch_tsv <min> -> sensor TSV. $SESSION_COMPACT_SENSOR overrides it with a fixture command.
_fetch_tsv() {
  local min="$1"
  if [ -n "${SESSION_COMPACT_SENSOR:-}" ]; then
    # shellcheck disable=SC2086
    $SESSION_COMPACT_SENSOR --minutes "$min" --tsv
    return $?
  fi
  local bin
  bin="$(_find_helper session-doctor)" || {
    echo "session-compact: could not locate session-doctor (looked next to this script and on PATH)" >&2
    return 127
  }
  bash "$bin" idle-report --minutes "$min" --tsv
}

_SESSION_HANDOFF_BIN=""
# _session_handoff <args> — session-handoff, co-located first, then PATH; memoized.
_session_handoff() {
  if [ -z "$_SESSION_HANDOFF_BIN" ]; then
    _SESSION_HANDOFF_BIN="$(_find_helper session-handoff)" || {
      echo "session-compact: could not locate session-handoff (looked next to this script and on PATH)" >&2
      return 127
    }
  fi
  bash "$_SESSION_HANDOFF_BIN" "$@"
}

# _pane_ready_reason <session> -> "safe" (rc 0) or the reason (busy, menu, no-prompt, ...) (rc 1).
_pane_ready_reason() {
  local session="$1" ready_out rc reason
  ready_out="$(_session_handoff ready "$session" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    echo safe
    return 0
  fi
  reason="$(printf '%s' "$ready_out" | sed -n 's/.*reason=\(.*\)$/\1/p')"
  [ -n "$reason" ] || reason="unreachable"
  printf '%s\n' "$reason"
  return 1
}

# _evaluate_row <min> <max> <10 TSV fields> -> eligible or skip:<reason>.
# The live pane check runs only after the pure checks pass.
_evaluate_row() {
  local min_idle="$1" max_idle="$2"; shift 2
  local tmux_session="$1" last_user_ts="$6" compacted="$8"
  local marker_hit=na
  if [ "$compacted" = unknown ]; then
    marker_hit="$(_marker_hit "$tmux_session" "$last_user_ts")"
  fi
  local decision
  decision="$(_decide "$min_idle" "$max_idle" "$@" "$marker_hit")"
  if [ "$decision" != eligible ]; then
    printf '%s\n' "$decision"
    return
  fi
  local pane_reason pane_rc
  pane_reason="$(_pane_ready_reason "$tmux_session")"; pane_rc=$?
  if [ "$pane_rc" -eq 0 ]; then
    echo eligible
    return
  fi
  printf 'skip:pane-%s\n' "$pane_reason"
}

_pane_state() {  # $1=tmux_session -> dead|starting|busy|menu|blocked|ready|"" (I/O)
  local out
  out="$(_session_handoff check "$1" 2>&1)" || true
  printf '%s' "$out" | grep -oE 'state=[a-z]+' | head -1 | cut -d= -f2
}

# _sweep_evaluate_row_managed: same as _evaluate_row unless managed_only=yes.
# For managed rows only, skip:landed-and-clean is retried with dirty forced to DIRTY; every other guard still applies.
_sweep_evaluate_row_managed() {
  local min_idle="$1" max_idle="$2" managed_only="$3"; shift 3
  local decision
  decision="$(_evaluate_row "$min_idle" "$max_idle" "$@")"
  if [ "$decision" = "skip:landed-and-clean" ] && [ "$managed_only" = yes ]; then
    set -- "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" DIRTY
    decision="$(_evaluate_row "$min_idle" "$max_idle" "$@")"
  fi
  printf '%s\n' "$decision"
}

# _sweep_decide <min> <max> <context_pct> <managed_only> <TSV fields> -> eligible:idle | eligible:context | skip:<reason>.
# Trigger A: idle window and context >= 40%. Trigger B: idle >= 5 min and context >= 80% (50% managed).
# Both route through _evaluate_row, so the already-compacted and pane guards apply to each.
_SWEEP_CONTEXT_TRIGGER_PCT=80
_SWEEP_MANAGED_CONTEXT_TRIGGER_PCT=50
_SWEEP_CONTEXT_IDLE_FLOOR=5

# Trigger A needs measured context >= 40%: long idle only means a cold cache, so compacting is cheap, not worthwhile.
_SWEEP_IDLE_CONTEXT_FLOOR_PCT=40

_sweep_decide() {
  local min_idle="$1" max_idle="$2" context_pct="$3" managed_only="$4"; shift 4
  local decision_a decision_b context_trigger_pct="$_SWEEP_CONTEXT_TRIGGER_PCT"
  if [ "$managed_only" = yes ]; then context_trigger_pct="$_SWEEP_MANAGED_CONTEXT_TRIGGER_PCT"; fi
  decision_a="$(_sweep_evaluate_row_managed "$min_idle" "$max_idle" "$managed_only" "$@")"
  if [ "$decision_a" = eligible ]; then
# Trigger A needs a measured context_pct; unknown context skips rather than acting on idle alone.
    case "$context_pct" in
      ''|*[!0-9]*) echo "skip:context-unknown"; return ;;
    esac
    if [ "$context_pct" -ge "$_SWEEP_IDLE_CONTEXT_FLOOR_PCT" ]; then
      echo "eligible:idle"
    else
      echo "skip:context-too-small"
    fi
    return
  fi
  if [ "$decision_a" != "skip:outside-window" ]; then
    printf '%s\n' "$decision_a"
    return
  fi
  decision_b="$(_sweep_evaluate_row_managed "$_SWEEP_CONTEXT_IDLE_FLOOR" 0 "$managed_only" "$@")"
  if [ "$decision_b" != eligible ]; then
    printf '%s\n' "$decision_b"
    return
  fi
# Trigger B: unknown context is skip:context-unknown, not an under-threshold outside-window.
  case "$context_pct" in
    ''|*[!0-9]*) echo "skip:context-unknown"; return ;;
  esac
  if [ "$context_pct" -ge "$context_trigger_pct" ]; then
    echo "eligible:context"
  else
    echo "skip:outside-window"
  fi
}

declare -A _COMPACT_ISSUED=()
# _do_compact <session> <timeout> [<cwd>] -> compacted | send-failed | timeout (exit 0 only when verified).
# The newer compact marker in the transcript is the primary signal; pane state is a fallback.
# Pane state needs busy seen first, because send's landed verdict can fire before the spinner.
# Fails closed: no signal within the timeout is a timeout, and no marker is written.
_do_compact() {
  local session="$1" timeout="$2" cwd="${3:-}" out rc waited=0 seen_busy=no state baseline_ts newer

  if [ -n "${_COMPACT_ISSUED[$session]+x}" ]; then
    echo "session-compact: INTERNAL — refusing to send /compact to '$session' a second time in this invocation" >&2
    echo send-failed
    return 1
  fi
  if [ "${CRSS_AUTONOMOUS:-0}" = 1 ] || [ "${MODE:-}" = sweep ]; then
# Sweep is unattended, so say so to the admission helper.
    CRSS_AUTONOMOUS=1 _crss_admit compact "$session" >&2 || { echo admission-denied; return 1; }
  fi
  _COMPACT_ISSUED[$session]=1

  baseline_ts=""
  [ -n "$cwd" ] && baseline_ts="$(_compact_marker_newer "$cwd" "")"

  out="$(_session_handoff send "$session" "/compact" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "session-compact: /compact to '$session' did not land: $out" >&2
    echo send-failed
    return 1
  fi

# Transcript is checked first; a ready or blocked pane counts only after busy was seen.
  while [ "$waited" -lt "$timeout" ]; do
    if [ -n "$cwd" ]; then
      newer="$(_compact_marker_newer "$cwd" "$baseline_ts")"
      [ -n "$newer" ] && { echo compacted; return 0; }
    fi
    state="$(_pane_state "$session")"
    case "$state" in
      busy) seen_busy=yes ;;
      ready|blocked) [ "$seen_busy" = yes ] && { echo compacted; return 0; } ;;
    esac
    sleep 3
    waited=$((waited+3))
  done
  echo timeout
  return 1
}

# ── mode dispatch ──

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
MODE="${1:-}"; shift || true

_usage() {
  echo "usage: session-compact.sh (report [--min-idle N] [--max-idle N]" >&2
  echo "         | sweep [--dry-run|--apply] [--min-idle N] [--max-idle N] [--timeout N] [--managed-only]  # default: --dry-run" >&2
  echo "         | before-relay <session> (<msg>|--file <path>) [--timeout N]" >&2
  echo "         | install-timer [--force])" >&2
  exit 2
}

case "$MODE" in
  report)
    MIN_IDLE=60; MAX_IDLE=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --min-idle) MIN_IDLE="$2"; shift 2 ;;
        --max-idle) MAX_IDLE="$2"; shift 2 ;;
        *) echo "session-compact: $MODE: unrecognized argument '$1'" >&2; exit 2 ;;
      esac
    done
    _validate_uint --min-idle MIN_IDLE
    _validate_uint --max-idle MAX_IDLE

    TSV="$(_fetch_tsv "$MIN_IDLE")"; rc=$?
    [ "$rc" -eq 0 ] || { echo "session-compact: sensor command failed (exit $rc)" >&2; exit 1; }

    window_desc="idle >= ${MIN_IDLE}m"
    [ "$MAX_IDLE" != 0 ] && window_desc="$window_desc, <= ${MAX_IDLE}m"

    echo "=== session-compact report: $window_desc — REPORT ONLY, mutates nothing ==="
    printf '%-40s %-9s %-8s %s\n' "TMUX SESSION" "ELIGIBLE" "IDLE" "REASON"
    n=0
    while IFS=$'\t' read -r c1 c2 c3 c4 c5 c6 c7 c8 c9 c10; do
      [ -n "$c1" ] || continue
      n=$((n+1))
      decision="$(_evaluate_row "$MIN_IDLE" "$MAX_IDLE" "$c1" "$c2" "$c3" "$c4" "$c5" "$c6" "$c7" "$c8" "$c9" "$c10")"
      case "$decision" in
        eligible) elig=yes; reason=eligible ;;
        skip:*)   elig=no;  reason="${decision#skip:}" ;;
        *)        elig=no;  reason="$decision" ;;
      esac
      printf '%-40s %-9s %-8s %s\n' "$c1" "$elig" "$c5" "$reason"
    done <<< "$TSV"
    echo "  --- $n candidate(s) scanned. Report only; mutates nothing."
    ;;

  sweep)
# sweep uses its own two-trigger model; report and before-relay keep the idle-window model.
    MIN_IDLE=60; MAX_IDLE=0; TIMEOUT=240; DRY_RUN=no; APPLY=no; MANAGED_ONLY=no
    while [ $# -gt 0 ]; do
      case "$1" in
        --min-idle)     MIN_IDLE="$2"; shift 2 ;;
        --max-idle)     MAX_IDLE="$2"; shift 2 ;;
        --timeout)      TIMEOUT="$2"; shift 2 ;;
        --dry-run)      DRY_RUN=yes; shift ;;
        --apply)        APPLY=yes; shift ;;
        --managed-only) MANAGED_ONLY=yes; shift ;;
        *) echo "session-compact: sweep: unrecognized argument '$1'" >&2; exit 2 ;;
      esac
    done
    _validate_uint --min-idle MIN_IDLE
    _validate_uint --max-idle MAX_IDLE
    _validate_uint --timeout TIMEOUT

    if [ "$DRY_RUN" = yes ] && [ "$APPLY" = yes ]; then
      echo "session-compact: sweep: pass at most one of --dry-run or --apply, not both" >&2
      exit 2
    fi
    if [ "$DRY_RUN" = no ] && [ "$APPLY" = no ]; then DRY_RUN=yes; fi

# --managed-only: sweep sees only allowlisted sessions. An empty or missing allowlist means zero sessions,
# never the whole fleet. tests/test-session-compact-sweep.sh pins this fail-safe.
    MANAGED_FILE="$(_managed_allowlist_file)"
    n_managed=0
    declare -A _MANAGED_SET=()
    if [ "$MANAGED_ONLY" = yes ]; then
      while IFS= read -r _managed_name; do
        [ -n "$_managed_name" ] || continue
        n_managed=$((n_managed+1))
        _MANAGED_SET["$_managed_name"]=1
      done < <(_read_managed_allowlist "$MANAGED_FILE")
      if [ "$n_managed" -eq 0 ]; then
        echo "=== session-compact sweep --managed-only: allowlist ($MANAGED_FILE) is missing, empty, or has no usable entries — 0 sessions in scope. Refusing to fall back to fleet-wide scanning. ==="
        echo "sweep --managed-only: 0 managed, 0 live — 0 session(s) in scope."
        exit 0
      fi
    fi

# Ask for every live row (min 0): the context trigger can fire below --min-idle.
    TSV="$(_fetch_tsv 0)"; rc=$?
    [ "$rc" -eq 0 ] || { echo "session-compact: sensor command failed (exit $rc)" >&2; exit 1; }

# Apply the scope filter before eligibility. Stale allowlist entries are dropped silently.
# TSV is reassigned, never coalesced back to the fleet list, even when the filtered result is empty.
    scope_note=""
    if [ "$MANAGED_ONLY" = yes ]; then
      n_live=0
      TSV_FILTERED=""
      while IFS=$'\t' read -r _row_session _row_rest; do
        [ -n "$_row_session" ] || continue
        if [ -n "${_MANAGED_SET[$_row_session]+x}" ]; then
          n_live=$((n_live+1))
          TSV_FILTERED="${TSV_FILTERED}${_row_session}$(printf '\t')${_row_rest}"$'\n'
        fi
      done <<< "$TSV"
      TSV="$TSV_FILTERED"
      scope_note="; scope: managed-only ($n_managed managed, $n_live live)"
    fi

    window_desc="idle >= ${MIN_IDLE}m"
    [ "$MAX_IDLE" != 0 ] && window_desc="$window_desc, <= ${MAX_IDLE}m"

    context_trigger_pct="$_SWEEP_CONTEXT_TRIGGER_PCT"
    [ "$MANAGED_ONLY" = yes ] && context_trigger_pct="$_SWEEP_MANAGED_CONTEXT_TRIGGER_PCT"
    echo "=== session-compact sweep --$([ "$DRY_RUN" = yes ] && echo dry-run || echo apply): $window_desc, OR context >= $context_trigger_pct% + idle >= ${_SWEEP_CONTEXT_IDLE_FLOOR}m$scope_note ==="
    printf '%-32s %-8s %-11s %-6s %-22s %s\n' "SESSION" "IDLE(m)" "CTX_TOKENS" "CTX%" "VERDICT" "NOTE"
    n=0; n_eligible=0; n_compacted=0; n_failed=0
    while IFS=$'\t' read -r c1 c2 c3 c4 c5 c6 c7 c8 c9 c10; do
      [ -n "$c1" ] || continue
      n=$((n+1))

      ctx_raw="$(_context_pct_for_row "$c4" "$c1")"
      if [ -n "$ctx_raw" ]; then
        ctx_tokens="${ctx_raw%%$'\t'*}"
        ctx_pct="${ctx_raw#*$'\t'}"
        note="-"
      else
# Unknown context means neither trigger fires; skip:context-unknown explains it.
        ctx_tokens="n/a"; ctx_pct=""; note="context unavailable (unparseable/missing transcript, unrecognized model, or unknown CLI auto-compact settings)"
      fi

# VERDICT keeps a distinct label per cause, so a malformed row and an under-threshold session differ.
# skip:outside-window is the only routine under-threshold case.
      decision="$(_sweep_decide "$MIN_IDLE" "$MAX_IDLE" "$ctx_pct" "$MANAGED_ONLY" "$c1" "$c2" "$c3" "$c4" "$c5" "$c6" "$c7" "$c8" "$c9" "$c10")"
      if [ "$MANAGED_ONLY" = yes ]; then
        case "$decision" in
          eligible:*)
            task_state="$(_managed_task_state_for_cwd "$c4")"
            case "$task_state" in
              active:*) decision="skip:active-task"; active_task_count="${task_state#active:}" ;;
              clear) : ;;
              *) decision="skip:task-state-unknown" ;;
            esac
            ;;
        esac
      fi
      detail="-"
      case "$decision" in
        eligible:idle)          verdict="would-compact: idle" ;;
        eligible:context)       verdict="would-compact: context" ;;
        skip:context-too-small)
          verdict="skip: context too small"
          detail="idle trigger needs context >= ${_SWEEP_IDLE_CONTEXT_FLOOR_PCT}% (has ${ctx_pct}%) — idle alone is not need"
          ;;
        skip:context-unknown)
          verdict="skip: context unknown"
# Expand the context-unknown note: name the settings to inspect, and fail closed.
          note="cannot verify need: context unavailable — check transcript usage, _model_window_for's table, and CLAUDE_CODE_AUTO_COMPACT_WINDOW / CLAUDE_AUTOCOMPACT_PCT_OVERRIDE in the live Claude environment or settings.json env; refusing to compact on idle alone until the CLI trigger can be measured"
          ;;
        skip:protected)         verdict="skip: protected" ;;
        skip:active-task)       verdict="skip: active task"; detail="${active_task_count:-1} in_progress Claude task(s); checkpoint/finish phase before compacting" ;;
        skip:task-state-unknown) verdict="skip: task state unknown"; detail="cannot bind managed session to a readable Claude task ledger; fail closed" ;;
        skip:pane-*)            verdict="skip: busy"; detail="live pane: ${decision#skip:pane-}" ;;
        skip:already-compacted) verdict="skip: compacted"; detail="already compacted this idle window" ;;
        skip:landed-and-clean)  verdict="skip: landed+clean"; detail="worktree landed + clean" ;;
        skip:malformed-row)     verdict="skip: malformed row"; detail="malformed sensor row" ;;
        skip:never-touched)     verdict="skip: never touched"; detail="never had a genuine user turn" ;;
        skip:bad-idle-field)    verdict="skip: bad idle field"; detail="unparseable idle field" ;;
        *)                      verdict="skip: under thresholds" ;;
      esac
      if [ "$note" = "-" ]; then
        note="$detail"
      elif [ "$detail" != "-" ]; then
        note="$note; $detail"
      fi
      printf '%-32s %-8s %-11s %-6s %-22s %s\n' "${c1:0:32}" "$c5" "$ctx_tokens" "${ctx_pct:-n/a}" "$verdict" "$note"

      case "$decision" in
        eligible:*)
          n_eligible=$((n_eligible+1))
          if [ "$DRY_RUN" = yes ]; then
            echo "would-compact: $c1 (idle=${c5}m)"
            continue
          fi
          echo "compacting: $c1 (idle=${c5}m) ..."
          result="$(_do_compact "$c1" "$TIMEOUT" "$c4")"; rc2=$?
          if [ "$rc2" -eq 0 ]; then
            _write_marker "$c1" "$c6" "$(_now_iso)" compacted
            n_compacted=$((n_compacted+1))
            echo "  -> compacted: $c1"
          else
            n_failed=$((n_failed+1))
            echo "  -> FAILED ($result): $c1 — NOT writing a success marker" >&2
          fi
          ;;
      esac
    done <<< "$TSV"
    if [ "$DRY_RUN" = yes ]; then
      echo "sweep --dry-run: $n_eligible session(s) would be compacted"
    else
      echo "sweep --apply: $n_eligible eligible, $n_compacted compacted, $n_failed failed"
    fi
    echo "  --- $n session(s) scanned."
    ;;

  before-relay)
# --timeout is read only as a leading flag, so a free-form message can never collide with it.
    TIMEOUT=240
    if [ "${1:-}" = "--timeout" ]; then TIMEOUT="$2"; shift 2; fi
    _validate_uint --timeout TIMEOUT
    SESSION="${1:?usage: session-compact.sh before-relay <tmux-session> (<msg>|--file <path>) [--timeout N]}"; shift
    if [ "${1:-}" = "--file" ]; then
      MSG_ARGS=(--file "${2:?--file needs a path}")
    else
      MSG_ARGS=("${1:?message required}")
    fi

    MIN_IDLE=60; MAX_IDLE=0
    TSV="$(_fetch_tsv 0)"; rc=$?
    [ "$rc" -eq 0 ] || { echo "session-compact: sensor command failed (exit $rc)" >&2; exit 1; }
    row_line="$(printf '%s\n' "$TSV" | awk -F'\t' -v s="$SESSION" '$1==s{print; exit}')"

    if [ -z "$row_line" ]; then
# Not in the sensor output: the pane must still pass the safety check before any relay.
      pane_reason="$(_pane_ready_reason "$SESSION")"; pane_rc=$?
      if [ "$pane_rc" -ne 0 ]; then
        echo "before-relay: '$SESSION' not seen by the sensor AND not safe to inject into (${pane_reason}) — refusing to relay" >&2
        exit 1
      fi
      echo "before-relay: '$SESSION' not seen by the sensor — pane is safe, relaying without compacting"
      _session_handoff send "$SESSION" "${MSG_ARGS[@]}"
      exit $?
    fi
    IFS=$'\t' read -r c1 c2 c3 c4 c5 c6 c7 c8 c9 c10 <<< "$row_line"

    decision="$(_evaluate_row "$MIN_IDLE" "$MAX_IDLE" "$c1" "$c2" "$c3" "$c4" "$c5" "$c6" "$c7" "$c8" "$c9" "$c10")"
    case "$decision" in
      eligible) : ;;
      skip:pane-*)
# The pane was just flagged unsafe; fail closed rather than relay into it.
        echo "before-relay: '$SESSION' is not safe to inject into (${decision#skip:pane-}) — refusing to relay" >&2
        exit 1 ;;
      *)
        echo "before-relay: '$SESSION' not stale/eligible (${decision#skip:}) — relaying without compacting"
        _session_handoff send "$SESSION" "${MSG_ARGS[@]}"
        exit $? ;;
    esac

    echo "before-relay: '$SESSION' is stale and eligible — compacting first"
    result="$(_do_compact "$SESSION" "$TIMEOUT" "$c4")"; rc2=$?
    if [ "$rc2" -ne 0 ]; then
      echo "before-relay: compact of '$SESSION' could not be verified ($result) — FAILING CLOSED, message NOT sent" >&2
      exit 1
    fi
    _write_marker "$SESSION" "$c6" "$(_now_iso)" compacted
    echo "before-relay: compact verified — relaying message"
    _session_handoff send "$SESSION" "${MSG_ARGS[@]}"
    exit $?
    ;;

  install-timer)
    FORCE=no
    while [ $# -gt 0 ]; do
      case "$1" in
        --force) FORCE=yes; shift ;;
        *) echo "session-compact: install-timer: unrecognized argument '$1'" >&2; exit 2 ;;
      esac
    done
    UD="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    STATE_DIR="$HOME/.local/state/session-compact"
    SVC="$UD/session-compact-report.service"
    TMR="$UD/session-compact-report.timer"
    if [ "$FORCE" != yes ] && { [ -f "$SVC" ] || [ -f "$TMR" ]; }; then
      echo "session-compact: install-timer: unit file(s) already exist ($SVC and/or $TMR) — refusing to overwrite without --force" >&2
      exit 2
    fi
    mkdir -p "$UD" "$STATE_DIR"
    cat > "$SVC" <<EOF
[Unit]
Description=session-compact report-only scan (report mode; never mutates)

[Service]
Type=oneshot
ExecStart=$HOME/.local/bin/session-compact report
StandardOutput=append:$STATE_DIR/report.log
StandardError=append:$STATE_DIR/report.log
EOF
    cat > "$TMR" <<EOF
[Unit]
Description=Trigger for session-compact-report.service

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
EOF
    echo "session-compact: wrote $SVC"
    echo "session-compact: wrote $TMR"
    echo "session-compact: NOT enabled (report mode only; no mutation ever happens from this unit)."
    echo "session-compact: to opt in, run:"
    echo "  systemctl --user enable --now session-compact-report.timer"
    ;;

  *) _usage ;;
esac
fi
