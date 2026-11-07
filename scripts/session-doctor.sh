#!/usr/bin/env bash
# session-doctor.sh — audit and clean up crss remote-control sessions across
# tmux windows, systemd --user units, the Anthropic session registry
# (GET /v1/sessions), and per-session git worktrees (~/.claude/worktrees/).
# Reaping locally does not relieve registry pressure: the registry and the
# worktrees each accumulate disconnected/zombie entries independently.
#
# Subcommands (no argument = read-only report):
#   reap-local                remove DEAD local sessions (proc gone, or orphaned unit+script)
#   reap <name> [flags]       tear down one named ALIVE session (tmux, unit, registry entry,
#                             worktree). Flags: --force --allow-young --keep-registry
#                             --keep-worktree --dry-run --outcome --outcome-note
#   reap-merged [--apply]     dry-run by default; candidate = merged PR for the worktree HEAD,
#                             no open PR, idle pane. --apply runs only plain reap
#   registry-stale [--days N] list registry sessions disconnected > N days (default 30)
#   registry-prune [--days N] [--apply]   same set; dry-run by default
#   worktree-stale            list worktrees whose owning session is dead (report only)
#   archive-ignored <wt>      save a worktree's gitignored, non-regenerable files (runs inside reap)
#   land-check                per-worktree unlanded-vs-default-branch and dirty status (report only)
#   idle-report [--days N | --minutes N] [--tsv]   live sessions with no genuine user turn
#   history <folder>          NOW + PAST transcript history and status for a worktree (report only)
#   auth-scan [--days N]      auth-failure turns; exit 1 if an outage looks ongoing
#   opus-subagents [--days N] sessions whose subagent transcripts ran on Opus (report only)
#   suggest-feeders           live TUIs that feed promptSuggestionUnusedStreak (report only)
#   auth-heal [--apply] [--days N]   nudge idle lanes whose last turn failed auth; dry-run by default
#   overlay                   $CRSS_HOME health check; never fails hard (report only)
#
# Safety:
#   * Protected names (CRSS_PROTECT_NAMES, default "claude-remote") are never reaped.
#     An invalid regex there fails closed: every session is treated as protected.
#   * A tmux/unit entry is reaped only when its claude process is gone (reap-local)
#     or the operator named it (reap).
#   * MIN-AGE GATE: reap, reap-local and reap-merged refuse sessions younger than
#     CRSS_REAP_MIN_AGE_H hours (default 24, 0 disables); age = first spawn in
#     session-starts.log. Dead tmux with young units is kept because session-resume
#     needs those units. --force does NOT bypass it; --allow-young does. See
#     _reap_age_gate; tests/test-reap-min-age.sh.
#   * reap refuses unlanded or uncommitted work (session-preserve.sh) unless --force.
#     A missing tmux session or unit never fails the rest of reap.
#   * reap removes only that session's own worktree, never its branch. It runs
#     `git worktree remove` without --force (dirty refuses) unless reap --force.
#     Guards: another unit references it, it is the caller's cwd, or it is the
#     primary checkout. See _reap_remove_worktree; tests/test-session-doctor-reap-worktree.sh.
#   * Gitignored non-regenerable files are archived to ~/backups/reaped-worktree-ignored/
#     before removal, because `git worktree remove` deletes them and status=clean hides
#     them. If archiving fails, the worktree is kept. See _wt_archive_ignored.
#   * Other worktree removal is not automated; worktree-stale prints candidates for review.
#   * registry-prune never touches a PROTECT-matching title, a title matching a live
#     tmux session, or a requires_action row (stale >2xN days rows are flagged only).
#     It mutates only with --apply and exits non-zero if any delete failed. registry-stale
#     never deletes. reap's registry cleanup reuses the same check and delete for one
#     entry; a failure there is soft and never changes reap's exit status.
#   * idle-report, land-check, history, auth-scan and suggest-feeders never mutate.
set -uo pipefail

# ── Host-local overlay config ────────────────────────────────────────────────
# Parses (never sources) $CRSS_HOME/config.sh for CRSS_* vars; an env var already set wins. A missing file is fine.
# Marker block copied verbatim across scripts (tests/test-crss-overlay-config.sh).
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

UD="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
BIN="$HOME/.local/bin"
# CRSS_PROTECT_NAMES (default: claude-remote) is never reaped. An empty value must fall back to a pattern that
# matches nothing: an empty ERE matches every line, which would protect everything.
: "${CRSS_PROTECT_NAMES:=claude-remote}"
PROTECT="$CRSS_PROTECT_NAMES"
[ -n "$PROTECT" ] || PROTECT='^$'
# An invalid ERE makes `grep -qiE "$PROTECT"` exit 2, which every caller reads as
# "not protected". Fail closed instead: protect everything (no reaps) and say so.
_crss_rc=0; grep -qiE -- "$PROTECT" </dev/null 2>/dev/null || _crss_rc=$?; [ "$_crss_rc" -le 1 ] || {
  echo "session-doctor: CRSS_PROTECT_NAMES is not a valid regex ('$PROTECT'); treating EVERY session as protected until it's fixed" >&2
  PROTECT='.'
}

# _is_protected <text> — match CRSS_PROTECT_NAMES against the text and its hyphen/underscore forms,
# so one term protects tmux, unit and title names alike.
_is_protected() {
  local t="$1"
  local v
  for v in "$t" "${t//_/-}" "${t//-/_}"; do
    grep -qiE "$PROTECT" <<<"$v" && return 0
  done
  return 1
}

# Session-name prefix (the CRSS-PREFIX-RE block below is copied verbatim across scripts).
# New sessions get CRSS_SESSION_PREFIX (default cs). CRSS_LEGACY_PREFIXES (|-separated) are
# recognised when parsing a name, never used to generate one. Each element must match
# ^[a-z][a-z0-9]{0,15}$, which also rules out ERE metacharacters. ANY invalid legacy element
# drops the WHOLE legacy list: an empty alternation would match everything, the dangerous
# direction in a reap path. Tests: tests/test-crss-overlay-config.sh.
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

MODE="${1:-report}"; shift || true
# DAYS default: 2 for idle-report, auth-scan, auth-heal and opus-subagents; 30 otherwise.
# --minutes (idle-report only) is mutually exclusive with --days (checked below).
case "$MODE" in idle-report|auth-scan|auth-heal|opus-subagents) DAYS=2;; *) DAYS=30;; esac
FORCE=no
ALLOW_YOUNG=no
TSV=no
APPLY=no
KEEP_REGISTRY=no
KEEP_WORKTREE=no
DRY_RUN=no
OUTCOME=""
OUTCOME_NOTE=""
MINUTES=""
IDLE_MIN=120
DAYS_SET=no
MINUTES_SET=no
# Positional args (e.g. the name in `reap <name>`) are collected into ARGS and restored below.
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --days) [ $# -ge 2 ] || { echo "session-doctor: --days needs a value" >&2; exit 2; }; DAYS="$2"; DAYS_SET=yes; shift 2;;
    --minutes) MINUTES="$2"; MINUTES_SET=yes; shift 2;;
    --idle-min) IDLE_MIN="${2:-}"; shift 2;;
    --tsv) TSV=yes; shift;;
    --force) FORCE=yes; shift;;
    --allow-young) ALLOW_YOUNG=yes; shift;;
    --apply) APPLY=yes; shift;;
    --keep-registry) KEEP_REGISTRY=yes; shift;;
    --keep-worktree) KEEP_WORKTREE=yes; shift;;
    --dry-run) DRY_RUN=yes; shift;;
    --outcome) OUTCOME="${2:?--outcome needs ok|failed|escalated|abandoned}"; shift 2;;
    --outcome-note) OUTCOME_NOTE="${2:?--outcome-note needs a value}"; shift 2;;
    # An unrecognized --flag must fail closed: a typo'd or assumed flag such as
    # `reap <name> --dry-run` was silently treated as a positional and the reap ran.
    --*) echo "session-doctor: unknown option '$1'" >&2; exit 2;;
    *) ARGS+=("$1"); shift;;
  esac
done
set -- "${ARGS[@]}"
case "$OUTCOME" in ""|ok|failed|escalated|abandoned) ;; *) echo "session-doctor: --outcome must be ok|failed|escalated|abandoned (got '$OUTCOME')" >&2; exit 2;; esac
if [ "$ALLOW_YOUNG" = yes ]; then
  case "$MODE" in reap|reap-local|reap-merged) ;; *) echo "session-doctor: --allow-young is not supported for $MODE" >&2; exit 2;; esac
fi
# CRSS_REAP_MIN_AGE_H: fail closed on a malformed value (an empty/garbage floor must not silently disable the gate).
REAP_MIN_AGE_H="${CRSS_REAP_MIN_AGE_H:-24}"
case "$REAP_MIN_AGE_H" in
  ''|*[!0-9]*) echo "session-doctor: CRSS_REAP_MIN_AGE_H must be a non-negative integer (hours), got '$REAP_MIN_AGE_H'" >&2; exit 2;;
esac
# Bound BEFORE arithmetic: a huge digit string wraps (2^64 -> 0 disables the gate) or goes negative.
[ "${#REAP_MIN_AGE_H}" -le 9 ] && [ "$((10#$REAP_MIN_AGE_H))" -le 8760 ] || { echo "session-doctor: CRSS_REAP_MIN_AGE_H must be <= 8760 hours, got '$REAP_MIN_AGE_H'" >&2; exit 2; }
REAP_MIN_AGE_H=$((10#$REAP_MIN_AGE_H))
AY_FLAG=""; [ "$ALLOW_YOUNG" = yes ] && AY_FLAG=--allow-young   # forwarded to reap-merged's `reap` subprocesses
# --dry-run is refused where it would be silently ignored (e.g. archive-ignored writes under ~/backups).
if [ "$DRY_RUN" = yes ]; then
  case "$MODE" in
    reap|reap-local|registry-prune|reap-merged) ;;
    *) echo "session-doctor: --dry-run is not supported for $MODE" >&2; exit 2;;
  esac
fi
# --dry-run conflicts with --apply and reap-local --force; refuse rather than guess the intent.
if [ "$DRY_RUN" = yes ] && { [ "$APPLY" = yes ] || { [ "$MODE" = reap-local ] && [ "$FORCE" = yes ]; }; }; then
  echo "session-doctor: --dry-run cannot be combined with $([ "$APPLY" = yes ] && echo --apply || echo --force) for $MODE" >&2
  exit 2
fi
# --days and --minutes both pick the idle-report threshold; giving both is ambiguous, so reject it.
if [ "$DAYS_SET" = yes ] && [ "$MINUTES_SET" = yes ]; then
  echo "session-doctor: --days and --minutes are mutually exclusive" >&2
  exit 2
fi
# DAYS is spliced as a bare literal into the embedded Python (registry-stale, idle-report).
# Validate it here, or a typo becomes a Python SyntaxError instead of a usage error.
case "$DAYS" in
  ''|*[!0-9]*) echo "session-doctor: --days requires a non-negative integer, got '$DAYS'" >&2; exit 2 ;;
esac
# Canonicalize to base-10: Python rejects a leading-zero literal such as 08.
DAYS=$((10#$DAYS))
# A zero --idle-min would let a session that is still mid-turn qualify for reap-merged.
case "$IDLE_MIN" in
  ''|*[!0-9]*) echo "session-doctor: --idle-min requires a positive integer, got '$IDLE_MIN'" >&2; exit 2 ;;
esac
IDLE_MIN=$((10#$IDLE_MIN))
[ "$IDLE_MIN" -gt 0 ] || { echo "session-doctor: --idle-min must be > 0" >&2; exit 2; }
# --minutes is validated only when given; an unset MINUTES is the not-requested sentinel.
if [ "$MINUTES_SET" = yes ]; then
  case "$MINUTES" in
    ''|*[!0-9]*) echo "session-doctor: --minutes requires a non-negative integer, got '$MINUTES'" >&2; exit 2 ;;
  esac
  MINUTES=$((10#$MINUTES))
fi

# registry_json — fetch every page of GET /v1/sessions (cursor: after_id=<last_id>) and print {"data": [...]}.
# A bare JSON array counts as one complete page. A page-1 failure returns 1; a later-page failure keeps
# what was already fetched. MAX_PAGES bounds a malformed has_more:true; each GET has curl's -m 25 timeout.
registry_json() {
  local tok org
  tok=$(python3 -c "import json;print(json.load(open('$HOME/.claude/.credentials.json'))['claudeAiOauth']['accessToken'])" 2>/dev/null) || return 1
  org=$(python3 -c "import json;print(json.load(open('$HOME/.claude.json')).get('oauthAccount',{}).get('organizationUuid',''))" 2>/dev/null)

  local tmpdir
  tmpdir=$(mktemp -d) || return 1
  local page=0 max_pages=50 after="" more=yes ok=1 pagefile url meta
  while [ "$more" = yes ] && [ "$page" -lt "$max_pages" ]; do
    page=$((page+1))
    pagefile="$tmpdir/page_$(printf '%03d' "$page").json"
    url="https://api.anthropic.com/v1/sessions"
    [ -n "$after" ] && url="${url}?after_id=${after}"
    curl -s -m 25 "$url" \
      -H "Authorization: Bearer $tok" -H "x-organization-uuid: $org" \
      -H "anthropic-version: 2023-06-01" -H "anthropic-beta: ccr-byoc-2025-07-29" \
      -o "$pagefile" 2>/dev/null
    meta=$(python3 -c "
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    print('error'); sys.exit()
if isinstance(d, list):
    print('done')
elif d.get('has_more') and d.get('last_id'):
    print('more ' + str(d['last_id']))
else:
    print('done')
" "$pagefile" 2>/dev/null)
    case "$meta" in
      more\ *) after="${meta#more }"; more=yes ;;
      error) [ "$page" -eq 1 ] && ok=0; more=no ;;
      *) more=no ;;
    esac
  done

  if [ "$ok" -ne 1 ]; then
    rm -rf "$tmpdir"
    return 1
  fi
  python3 -c "
import json, glob, sys
merged = []
for f in sorted(glob.glob(sys.argv[1] + '/page_*.json')):
    try:
        d = json.load(open(f))
    except Exception:
        continue
    merged.extend(d if isinstance(d, list) else d.get('data', d.get('sessions', [])))
print(json.dumps({'data': merged}))
" "$tmpdir"
  rm -rf "$tmpdir"
}

# _registry_candidates <DAYS> — registry JSON on stdin -> id<TAB>age<TAB>status<TAB>title, oldest first.
# Shared by registry-stale and registry-prune so both apply one stale rule: disconnected AND age > DAYS.
# Exits 1 on unparseable JSON; each caller words its own 'registry unavailable' message.
_registry_candidates() {
  local days="$1"
  python3 -c "
import sys,json,datetime
try:
    arr=json.load(sys.stdin)
except Exception:
    sys.exit(1)
arr=arr if isinstance(arr,list) else arr.get('sessions',arr.get('data',[]))
now=datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None); DAYS=$days
def agedays(s):
    try: return (now-datetime.datetime.fromisoformat((s.get('updated_at') or s.get('created_at'))[:19])).days
    except Exception: return -1
cand=[s for s in arr if s.get('connection_status')=='disconnected' and agedays(s)>DAYS]
cand.sort(key=agedays, reverse=True)
for s in cand:
    title=(s.get('title') or '').replace('\t',' ').replace(chr(10),' ')
    status=(s.get('session_status') or '').replace('\t',' ')
    print('%s\t%s\t%s\t%s' % (s.get('id'), agedays(s), status, title))
"
}

# _title_protected <title> — PROTECT is written for hyphenated machine names, but registry titles can
# contain spaces. Squeeze whitespace to '-' before matching; PROTECT itself stays unwidened.
# A failed producer counts as not protected. The trailing x sentinel keeps the exact bytes.
_title_protected() {
  local t
  t="$(printf '%s' "$1" | tr -s '[:space:]' '-' && printf x)" || return 1
  t=${t%x}
  [ -n "$t" ] && _is_protected "${t%$'\n'}"
}

# _registry_delete_one <id> <title> — protect-check + DELETE one registry
# entry by id, same auth/headers registry_json uses (token/org re-read fresh
# here rather than threaded through, since callers only have a handful of
# deletes at most). Prints one outcome line (deleted / skipped(protected) /
# failed(HTTP code)) and returns non-zero only when the DELETE itself failed
# (a protect-skip is not a failure). Never prints the token/org.
_registry_delete_one() {
  local id="$1" title="$2" tok org http_code
  if _title_protected "$title"; then
    echo "  skipped(protected)  $id  $title"
    return 0
  fi
  tok=$(python3 -c "import json;print(json.load(open('$HOME/.claude/.credentials.json'))['claudeAiOauth']['accessToken'])" 2>/dev/null)
  org=$(python3 -c "import json;print(json.load(open('$HOME/.claude.json')).get('oauthAccount',{}).get('organizationUuid',''))" 2>/dev/null)
  http_code=$(curl -s -o /dev/null -w '%{http_code}' -m 25 -X DELETE "https://api.anthropic.com/v1/sessions/$id" \
    -H "Authorization: Bearer $tok" -H "x-organization-uuid: $org" \
    -H "anthropic-version: 2023-06-01" -H "anthropic-beta: ccr-byoc-2025-07-29" 2>/dev/null)
  case "$http_code" in
    2??) echo "  deleted  $id  $title"; return 0 ;;
    *) echo "  failed($http_code)  $id  $title"; return 1 ;;
  esac
}

# Prefix mapping. Only the configured/recognised prefixes ($_crss_prefix_re —
# CRSS_SESSION_PREFIX + CRSS_LEGACY_PREFIXES) are ours; anything else (e.g.
# codexhost_) is NOT ours and must be left alone. PROTECT (line ~22) stays
# in sync with session-alias.sh.
tmux_to_base() {
  if [[ "$1" =~ ^(${_crss_prefix_re})_(.*)$ ]]; then
    echo "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"
  else
    echo ""
  fi
}

start_script_field() {
  local sc="$1" name="$2" line value
  [[ "$name" =~ ^[A-Z_][A-Z0-9_]*$ ]] || return 1
  [ -r "$sc" ] || return 1
  line="$(grep -m1 -E "^${name}=" "$sc" 2>/dev/null)" || return 1
  value="${line#*=}"
  python3 - "$value" <<'PY'
import shlex
import sys

try:
    parts = shlex.split(sys.argv[1], comments=False, posix=True)
except ValueError:
    sys.exit(1)
if len(parts) != 1:
    sys.exit(1)
print(parts[0])
PY
}

_reap_safe_base() {
  local base="$1"
  [ -n "$base" ] || return 1
  case "$base" in */*|*..*) return 1 ;; esac
  [[ "$base" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]
}

backend_of() {
  local rem sc backend
  rem="$(tmux_to_base "$1")"; [ -n "$rem" ] || { echo claude; return; }
  sc="$BIN/${rem}-start.sh"
  if [ -f "$sc" ]; then
    backend="$(start_script_field "$sc" BACKEND)"
    [ -n "$backend" ] && { echo "$backend"; return; }
  fi
  backend="$(grep -F "remote=$rem " "$HOME/.sessions/session-starts.log" 2>/dev/null | sed -n 's/.* backend=\([^ ]*\) .*/\1/p' | tail -1)"
  [ -n "$backend" ] && echo "$backend" || echo claude
}

live_tmux()  { tmux ls 2>/dev/null | cut -d: -f1; }
# _tmux_live_has <name> — exact match against the live tmux session list. The listing is captured whole,
# status checked first: a failed producer must read as not live, and SIGPIPE must not hide it.
_tmux_live_has() {
  local o
  o="$(live_tmux && printf x)" || return 1
  o=${o%x}
  [ -n "$o" ] && grep -qx -- "$1" <<<"${o%$'\n'}"
}
# Liveness is the tmux pane's foreground command, not a guessed remote-control name.
# sleep = supervisor backoff (still alive); a bare shell means the supervisor loop exited.
proc_alive() {  # $1 = tmux session name
  local cmd backend
  cmd="$(tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null)"
  backend="$(backend_of "$1")"
  case "$cmd" in
    sleep) return 0 ;;
    node) return 0 ;;
    claude) [ "$backend" = claude ] && return 0 ;;
    codex) [ "$backend" = codex ] && return 0 ;;
  esac
  return 1
}
svc_to_tmux() {
  if [[ "$1" =~ ^(${_crss_prefix_re})-(.*)$ ]]; then
    echo "${BASH_REMATCH[1]}_${BASH_REMATCH[2]}"
  else
    echo "$1"
  fi
}

# _find_helper <basename> — prefer a co-located <basename>.sh (repo layout), else PATH (deployed flat copies).
# Returns 1 on a miss; callers must fail SAFE (refuse), never skip what the helper was gating.
_find_helper() {
  local base="$1" here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
  if [ -f "$here/${base}.sh" ]; then printf '%s\n' "$here/${base}.sh"; return 0; fi
  if command -v "$base" >/dev/null 2>&1; then command -v "$base"; return 0; fi
  return 1
}

# _record_reap_event <session> <forced> [clean] — best-effort telemetry; never changes reap's exit status.
# Called only after something was torn down, so a no-op reap leaves no event.
_record_reap_event() {
  local rt
  rt="$(_find_helper record-spawn-telemetry)" || return 0
  timeout 5 bash "$rt" --reap "$1" "$2" "$OUTCOME" "$OUTCOME_NOTE" "${3:-unknown}" >/dev/null 2>&1 || true
}

# Shared by worktree-stale and land-check so both compute dirty/base/landed identically.

# _wt_dirty <worktree> -> clean | DIRTY | not-a-worktree. Ignores the spawner's own scaffolding (the
# .claude/skills symlink, .sessions-init-* sentinels), as session-git-prep.sh does. not-a-worktree is only
# a plain folder with no repo above it; any other git failure stays DIRTY. Callers act only on clean.
_wt_dirty() {
  local out
  if ! out="$(git -C "$1" status --porcelain 2>/dev/null)"; then
    if [ ! -e "$1/.git" ] && ! git -C "$1" rev-parse --git-dir >/dev/null 2>&1; then
      echo not-a-worktree
    else
      echo DIRTY
    fi
    return
  fi
  if [ -n "$out" ] && grep -qvE '^.. (\.claude(/|$)|\.sessions-init)' <<<"$out"; then
    echo DIRTY
  else
    echo clean
  fi
}

# _wt_mainrepo <worktree> -> absolute path of the main repo, via --git-common-dir.
_wt_mainrepo() {
  local common_dir
  common_dir="$(git -C "$1" rev-parse --git-common-dir 2>/dev/null)" || { echo ""; return; }
  case "$common_dir" in /*) : ;; *) common_dir="$1/$common_dir" ;; esac
  (cd "$common_dir/.." 2>/dev/null && pwd) || echo ""
}

declare -A _DEFBR_CACHE
# _default_branch <repo> -> the real default branch name. Every git call is -C scoped, so a decoy ref in
# another repo cannot leak in. Order is LOCAL-FIRST: origin/HEAD, then gh, then local main/master, then HEAD.
# Local-first is deliberate: this runs per worktree on an hourly timer. The accepted risk is a stale local
# origin/HEAD, which fails conservative (reads as unlanded). gh is tried only for a github.com origin, under timeout 5.
_default_branch() {
  local repo="$1" def="" url slug
  if [ -n "${_DEFBR_CACHE[$repo]+x}" ]; then printf '%s\n' "${_DEFBR_CACHE[$repo]}"; return; fi
  if git -C "$repo" remote get-url origin >/dev/null 2>&1; then
    def="$(git -C "$repo" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')"
  fi
  if [ -z "$def" ] && command -v gh >/dev/null 2>&1 && url="$(git -C "$repo" remote get-url origin 2>/dev/null)"; then
    case "$url" in
      *github.com*)
        slug="$(printf '%s' "$url" | sed -E 's#^(git@github\.com:|https://github\.com/|git://github\.com/)##; s#\.git$##')"
        def="$(timeout 5 gh repo view "$slug" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)"
        ;;
    esac
  fi
  if [ -z "$def" ]; then
    if   git -C "$repo" show-ref --verify --quiet refs/heads/main;   then def=main
    elif git -C "$repo" show-ref --verify --quiet refs/heads/master; then def=master
    else
# Check emptiness, not exit status: on an unborn HEAD git can print HEAD and still exit non-zero.
      def="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)"
      [ -n "$def" ] || def="HEAD"
    fi
  fi
  _DEFBR_CACHE[$repo]="$def"
  printf '%s\n' "$def"
}

# _wt_content_landed <worktree> <base_ref>: true when every file the branch changed since the merge-base has
# the same content at HEAD and base_ref. Covers squash/rebase merges. A file main changed later reads as not
# landed: that costs a suggestion, never a wrong delete.
_wt_content_landed() {
  local wt="$1" base_ref="$2" mb f n=0 tmp
  mb="$(git -C "$wt" merge-base HEAD "$base_ref" 2>/dev/null)" || return 1
# NUL-delimited via a temp file so odd filenames survive; a failed or empty diff is a no.
  tmp="$(mktemp)" || return 1
  if ! git -C "$wt" diff --name-only --no-renames -z "$mb" HEAD > "$tmp" 2>/dev/null; then rm -f "$tmp"; return 1; fi
  local lh lb
  while IFS= read -r -d '' f; do
    n=$((n+1))
# ls-tree compares mode and object id (rev-parse would miss an exec-bit change); literal pathspecs.
    lh="$(git --literal-pathspecs -C "$wt" ls-tree HEAD -- "$f" 2>/dev/null)" || { rm -f "$tmp"; return 1; }
    lb="$(git --literal-pathspecs -C "$wt" ls-tree "$base_ref" -- "$f" 2>/dev/null)" || { rm -f "$tmp"; return 1; }
    [ "$lh" = "$lb" ] || { rm -f "$tmp"; return 1; }
  done < "$tmp"
  rm -f "$tmp"
  [ "$n" -gt 0 ]
}

# _wt_pr_landed <worktree> <default-branch>: true when a PR merged into the default branch has a head that
# contains HEAD. Needs gh; any failure is a no.
_wt_pr_landed() {
  local wt="$1" def="$2" br oid
  [ -n "$def" ] || return 1
  command -v gh >/dev/null 2>&1 || return 1
# Only a github.com origin is queried (same gate as _default_branch); CRSS_PR_LANDED_ANY_REMOTE=1 lifts it for tests.
  [ -n "${CRSS_PR_LANDED_ANY_REMOTE:-}" ] || case "$(git -C "$wt" remote get-url origin 2>/dev/null)" in *github.com*) ;; *) return 1 ;; esac
  br="$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null)" || return 1
  while IFS= read -r oid; do
    [ -n "$oid" ] || continue
    git -C "$wt" cat-file -e "$oid^{commit}" 2>/dev/null || continue
    git -C "$wt" merge-base --is-ancestor HEAD "$oid" 2>/dev/null && return 0
  done < <(cd "$wt" && timeout 10 gh pr list --state merged --base "$def" --head "$br" --json headRefOid -q '.[].headRefOid' 2>/dev/null)
  return 1
}

# _wt_landed <worktree> <mainrepo> -> "base=<branch> landed=yes|no|unknown". yes = HEAD is an ancestor of the
# default branch, or content-landed, or in a PR merged to it. unknown = nothing to compare against.
_wt_landed() {
  local wt="$1" mainrepo="$2" def base_ref landed
  def="$(_default_branch "$mainrepo")"
  if git -C "$wt" show-ref --verify --quiet "refs/remotes/origin/$def"; then
    base_ref="origin/$def"
  elif git -C "$wt" show-ref --verify --quiet "refs/heads/$def"; then
    base_ref="$def"
  else
    base_ref=""
  fi
  if [ -z "$base_ref" ]; then
    landed=unknown
  elif git -C "$wt" merge-base --is-ancestor HEAD "$base_ref" 2>/dev/null; then
    landed=yes
  elif _wt_content_landed "$wt" "$base_ref" || _wt_pr_landed "$wt" "$def"; then
    landed=yes
  else
    landed=no
  fi
  printf 'base=%s landed=%s\n' "$def" "$landed"
}

# ── gitignored-payload guard ────────────────────────────────────────────────
# `git worktree remove` (even --force) silently deletes gitignored files, and _wt_dirty and session-preserve
# never count them, so a clean-looking worktree once lost unsaved results under artifacts/. reap archives that
# payload first. tests/test-session-doctor-reap-worktree.sh pins this.

# Regenerable scaffolding, NOT payload: matched at any depth, plus root .sessions-init-*. No bare `artifacts`:
# that is where results live. A false positive costs an archive; a false negative costs data.
_WT_IGNORED_DENY_RE='(^|/)(node_modules|\.venv|venv|__pycache__|\.next|dist|build|target|coverage|\.cache|\.pytest_cache|\.mypy_cache|\.gstack|\.superpowers|\.claude/(skills|token-reduce-state|tmp-briefs|settings\.local\.json|CLAUDE\.md)|artifacts/token-reduction)(/|$)|(^|/)(artifacts/qmd-repo-[^/]*\.stamp|next-env\.d\.ts|[^/]*\.tsbuildinfo)$|^\.sessions-init-[^/]*$'
# CRSS_JUNK_RE_EXTRA appends host scaffolding patterns (same env var as session-preserve.sh's JUNK_RE).
# The two base lists differ (pre-existing drift); only the additive suffix is kept in sync.
if [ -n "${CRSS_JUNK_RE_EXTRA:-}" ]; then
  # An invalid extra pattern would break the whole combined regex; drop it (built-in list still applies).
  _crss_rc=0; grep -qE -- "$CRSS_JUNK_RE_EXTRA" </dev/null 2>/dev/null || _crss_rc=$?
  if [ "$_crss_rc" -le 1 ]; then
    _WT_IGNORED_DENY_RE="${_WT_IGNORED_DENY_RE}|${CRSS_JUNK_RE_EXTRA}"
  else
    echo "$(basename "$0"): ignoring invalid CRSS_JUNK_RE_EXTRA regex ('$CRSS_JUNK_RE_EXTRA')" >&2
  fi
fi

# _wt_ignored_payload <worktree> <listfile> — write NUL-separated, worktree-relative paths of gitignored files
# not deny-listed. Sets _WTI_COUNT/_WTI_BYTES/_WTI_EXAMPLES. Returns 0 non-empty, 1 empty, 2 unknown (listing
# failed): callers must treat 2 as unknown, never empty. Call it directly, not via $(...).
# Collapsed directories are expanded with find so counts are file-level.
_wt_ignored_payload() {
  local wt="$1" out="$2" raw="$2.raw" found="$2.find" ent rel n=0 bad=0
  _WTI_COUNT=0; _WTI_BYTES=0; _WTI_EXAMPLES=""
  git -C "$wt" ls-files -z --others --ignored --exclude-standard --directory > "$raw" 2>/dev/null \
    || { rm -f "$raw"; : > "$out"; return 2; }
  while IFS= read -r -d '' ent; do
    if [ "${ent: -1}" = / ]; then
      [[ $ent =~ $_WT_IGNORED_DENY_RE ]] && continue
      (cd "$wt" 2>/dev/null && find "./${ent%/}" \( -type f -o -type l \) -print0) > "$found" 2>/dev/null || bad=1
      while IFS= read -r -d '' rel; do
        rel="${rel#./}"
        [[ $rel =~ $_WT_IGNORED_DENY_RE ]] || printf '%s\0' "$rel"
      done < "$found"
    else
      [[ $ent =~ $_WT_IGNORED_DENY_RE ]] || printf '%s\0' "$ent"
    fi
  done < "$raw" > "$out"
  rm -f "$raw" "$found"
  [ "$bad" -eq 0 ] || return 2
  _WTI_COUNT="$(tr -cd '\0' < "$out" | wc -c | tr -d ' ')"
  [ "$_WTI_COUNT" -gt 0 ] || return 1
  _WTI_BYTES="$(cd "$wt" && xargs -0 -a "$out" stat -c %s -- 2>/dev/null | awk '{s+=$1} END{print s+0}')"
  while IFS= read -r -d '' rel; do
    _WTI_EXAMPLES="${_WTI_EXAMPLES:+$_WTI_EXAMPLES, }$(printf '%q' "$rel")"
    n=$((n+1)); [ "$n" -ge 3 ] && break
  done < "$out"
  return 0
}

# _wt_archive_ignored <worktree> — copy the gitignored payload to ~/backups/reaped-worktree-ignored/<name>-<stamp>/
# (mode 0700: ignored dirs often hold .env files) and re-hash every copy against its source. Returns 1 (reason
# in _WTI_ERR) when over SESSION_DOCTOR_IGNORED_ARCHIVE_MAX_BYTES (default 2 GB) or on any copy/verify failure;
# the caller then keeps the worktree. Prints paths and sizes only, never contents.
_reap_archive_prepare() {
  local base="$1" root dest
  _REAP_ARCHIVE_ERR=""
  [ -n "${_REAP_ARCHIVE_DIR:-}" ] && return 0
  root="$HOME/backups/reaped-worktree-ignored"
  dest="$root/${base}-$(date -u +%Y%m%dT%H%M%SZ)"
  if ! ( umask 077; mkdir -p "$root" && mkdir "$dest" && : > "$dest/MANIFEST" ); then
    _REAP_ARCHIVE_ERR="could not create archive directory $dest"
    return 1
  fi
  _REAP_ARCHIVE_DIR="$dest"
  return 0
}

_reap_archive_home_paths() {
  local base="$1" dest rel src dst dir hash got size archived manifest_path
  shift
  if ! _reap_archive_prepare "$base"; then
    return 1
  fi
  dest="$_REAP_ARCHIVE_DIR"
  mkdir -p "$dest/unit" || { _REAP_ARCHIVE_ERR="could not create $dest/unit"; return 1; }
  archived=0
  for rel in "$@"; do
    src="$HOME/$rel"
    [ -e "$src" ] || [ -L "$src" ] || continue
    dst="$dest/unit/$rel"
    manifest_path="unit/$rel"
    dir="$(dirname "$dst")"
    mkdir -p "$dir" || { _REAP_ARCHIVE_ERR="could not create $dir"; return 1; }
    if [ -L "$src" ]; then
      local tgt
      tgt="$(readlink "$src")" || { _REAP_ARCHIVE_ERR="could not read symlink $rel"; return 1; }
      ln -s "$tgt" "$dst" || { _REAP_ARCHIVE_ERR="could not archive symlink $rel"; return 1; }
      [ "$(readlink "$dst")" = "$tgt" ] || { _REAP_ARCHIVE_ERR="could not verify symlink $rel"; return 1; }
      printf 'symlink\t0\t%s\t-> %s\n' "$manifest_path" "$tgt" >> "$dest/MANIFEST" || { _REAP_ARCHIVE_ERR="could not update $dest/MANIFEST"; return 1; }
      echo "    archived: $rel"
      archived=$((archived+1))
      continue
    fi
    hash="$(sha256sum "$src" | awk '{print $1}')" || { _REAP_ARCHIVE_ERR="could not hash $rel"; return 1; }
    cp -p "$src" "$dst" || { _REAP_ARCHIVE_ERR="could not copy $rel"; return 1; }
    got="$(sha256sum "$dst" | awk '{print $1}')" || { _REAP_ARCHIVE_ERR="could not hash archived $rel"; return 1; }
    [ "$got" = "$hash" ] || { _REAP_ARCHIVE_ERR="could not verify archived $rel"; return 1; }
    size="$(wc -c < "$src" | tr -d ' ')" || { _REAP_ARCHIVE_ERR="could not size $rel"; return 1; }
    printf '%s\t%s\t%s\n' "$hash" "$size" "$manifest_path" >> "$dest/MANIFEST" || { _REAP_ARCHIVE_ERR="could not update $dest/MANIFEST"; return 1; }
    echo "    archived: $rel"
    archived=$((archived+1))
  done
  echo "  archived $archived unit/start file(s) → $dest"
  return 0
}

_reap_archive_unit_files() {
  local base="$1" service_rel script_rel
  service_rel=".config/systemd/user/${base}.service"
  script_rel=".local/bin/${base}-start.sh"
  if _reap_archive_home_paths "$base" "$service_rel" "$script_rel"; then
    [ -e "$HOME/$service_rel" ] || [ -L "$HOME/$service_rel" ] || [ -e "$HOME/$script_rel" ] || [ -L "$HOME/$script_rel" ] \
      || echo "  unit/start archive: no unit file or start script found (ok)"
    rm -f -- "$HOME/$service_rel" "$HOME/$script_rel"
  else
    echo "  WARNING: unit/start-script archive failed for '$base' ($_REAP_ARCHIVE_ERR); leaving originals in place" >&2
  fi
# Drop the one-shot resume pin too, or a later session reusing this name would consume it.
  rm -f -- "$HOME/.sessions/resume/${base}.uuid" "$HOME/.sessions/resume/${base}.codex-thread" "$HOME/.sessions/resume/${base}".codex-thread.stale.*
  systemctl --user daemon-reload >/dev/null 2>&1 || true
}

_wt_archive_ignored() {
  local wt="$1" list root dest cap py_out mb prc own_dest
  _WTI_ERR=""; _WTI_ARCHIVE=""
  list="$(mktemp)" || { _WTI_ERR="mktemp failed"; return 1; }
  _wt_ignored_payload "$wt" "$list"; prc=$?
  if [ "$prc" -eq 1 ]; then rm -f "$list"; return 0; fi
  if [ "$prc" -ne 0 ]; then
    _WTI_ERR="could not list the gitignored files (git error or an unreadable directory)"
    rm -f "$list"; return 1
  fi
  cap="${SESSION_DOCTOR_IGNORED_ARCHIVE_MAX_BYTES:-2147483648}"
  case "$cap" in ''|*[!0-9]*) cap=2147483648 ;; esac
  if [ "$_WTI_BYTES" -gt "$cap" ]; then
    _WTI_ERR="$_WTI_COUNT gitignored file(s), $_WTI_BYTES bytes, exceed the $cap-byte archive cap (SESSION_DOCTOR_IGNORED_ARCHIVE_MAX_BYTES)"
    rm -f "$list"; return 1
  fi
  root="$HOME/backups/reaped-worktree-ignored"
  dest="${_REAP_ARCHIVE_DIR:-}"
  own_dest=no
  if [ -z "$dest" ]; then
    dest="$root/$(basename "$wt")-$(date -u +%Y%m%dT%H%M%SZ)"
    own_dest=yes
  fi
  if ! py_out="$( { umask 077; mkdir -p "$root" && mkdir -p "$dest" && python3 - "$wt" "$dest" "$list" <<'PY'
import hashlib, os, shutil, sys
wt, dest, listfile = (os.fsencode(a) for a in sys.argv[1:4])
def sha(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for c in iter(lambda: f.read(1 << 20), b''):
            h.update(c)
    return h.hexdigest()
def main():
    n = total = 0
    os.makedirs(dest + b'/worktree', exist_ok=True)
    with open(dest + b'/MANIFEST', 'ab') as m:
        for rel in open(listfile, 'rb').read().split(b'\0'):
            if not rel:
                continue
            archive_rel = b'worktree/' + rel
            src, dst = wt + b'/' + rel, dest + b'/' + archive_rel
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            if os.path.islink(src):
                tgt = os.readlink(src)
                os.symlink(tgt, dst)
                if os.readlink(dst) != tgt:
                    sys.exit('verify failed: ' + os.fsdecode(rel))
                m.write(b'symlink\t0\t' + archive_rel + b'\t-> ' + tgt + b'\n')
                n += 1
                continue
            want = sha(src)
            shutil.copy2(src, dst)
            if sha(dst) != want or os.path.getsize(dst) != os.path.getsize(src):
                sys.exit('verify failed: ' + os.fsdecode(rel))
            size = os.path.getsize(dst)
            m.write(want.encode() + b'\t' + str(size).encode() + b'\t' + archive_rel + b'\n')
            n += 1
            total += size
    print(n, total)
try:
    main()
except Exception as e:
    sys.exit(type(e).__name__ + ': ' + str(e))
PY
  } 2>&1 )"; then
    _WTI_ERR="archive to $dest failed${py_out:+ ($py_out)}"
    if [ "$own_dest" = yes ]; then
      case "$dest" in "$root"/?*) rm -rf "$dest" ;; esac
    fi
    rm -f "$list"; return 1
  fi
  rm -f "$list"
  _WTI_ARCHIVE="$dest"
  py_out="${py_out##*$'\n'}"
  mb="$(awk -v b="${py_out#* }" 'BEGIN{printf "%.1f", b/1048576}')"
  echo "  archived ${py_out%% *} ignored file(s), $mb MB → $dest"
  return 0
}

# ── reap worktree-removal helpers: each guard is unit-tested directly (tests/test-session-doctor-reap-worktree.sh).

# _is_caller_cwd <worktree> -> true if the calling process's cwd is that worktree or under it.
# Removing it would pull the rug out from under the rest of reap.
_is_caller_cwd() {
  local wt="$1" wt_real pwd_real
  wt_real="$(cd "$wt" 2>/dev/null && pwd -P)" || return 1
  pwd_real="$(pwd -P)"
  case "$pwd_real" in
    "$wt_real"|"$wt_real"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# _wt_used_by_other_unit <worktree> <own_service> -> prints the blocking unit and returns 0 if another systemd
# --user unit references the worktree (WorkingDirectory, ExecStart, or a drop-in), literally or %h-relative.
# A plain substring match is deliberate: generated units hold only [Unit]/[Service]/[Install] directives.
# Real case: a long-lived unit can keep a worktree as its WorkingDirectory after the session is reaped.
_wt_ref_in_file() {
  local f="$1" wt="$2" wt_real="$3" cand
  for cand in "$wt" "$wt_real"; do
    [ -n "$cand" ] || continue
    grep -qF "$cand" "$f" 2>/dev/null && return 0
    case "$cand" in
      "$HOME"/*) grep -qF "%h/${cand#"$HOME"/}" "$f" 2>/dev/null && return 0 ;;
    esac
  done
  return 1
}
_wt_used_by_other_unit() {
  local wt="$1" own="$2" wt_real f unit
  wt_real="$(cd "$wt" 2>/dev/null && pwd -P)" || wt_real="$wt"
  for f in "$UD"/*.service; do
    [ -f "$f" ] || continue
    unit="$(basename "$f")"
    [ "$unit" = "$own" ] && continue
    if _wt_ref_in_file "$f" "$wt" "$wt_real"; then
      printf '%s\n' "$unit"; return 0
    fi
  done
  for f in "$UD"/*.service.d/*.conf; do
    [ -f "$f" ] || continue
    unit="$(basename "$(dirname "$f")")"; unit="${unit%.d}"
    [ "$unit" = "$own" ] && continue
    if _wt_ref_in_file "$f" "$wt" "$wt_real"; then
      printf '%s\n' "$unit"; return 0
    fi
  done
  return 1
}

# _wt_resolve_for_base <base> -> path of the worktree owned by session <base>, or return 1.
# A branch match (session/<base>) wins over a directory-name match: session-git-prep.sh suffixes the directory
# with -$$ on a collision but leaves the branch unsuffixed, so a plain path join would orphan the worktree.
_wt_resolve_for_base() {
  local base="$1" dir="$HOME/.claude/worktrees" wt branch fallback=""
  [ -d "$dir" ] || return 1
  for wt in "$dir"/*/; do
    [ -d "$wt" ] || continue
    wt="${wt%/}"
    branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" || true
    if [ "$branch" = "session/$base" ]; then printf '%s\n' "$wt"; return 0; fi
    [ -z "$fallback" ] && [ "$(basename "$wt")" = "$base" ] && fallback="$wt"
  done
  if [ -n "$fallback" ]; then printf '%s\n' "$fallback"; return 0; fi
  return 1
}

# _reap_remove_worktree <base> <force:yes|no> — the removal step of reap (skipped by --keep-worktree). Resolves the session's
# worktree (branch-first, see _wt_resolve_for_base) and its main repo, then removes only the registration and directory.
# The branch is never deleted. `git worktree remove` runs without --force, so git decides dirtiness; a refusal is reported
# and never fails reap. --force is forwarded only when reap itself got --force.
# Refusals (worktree kept), each checked before `git worktree remove`:
#   - the path is the primary checkout (defensive: this only looks under ~/.claude/worktrees)
#   - the caller's own cwd is that worktree (_is_caller_cwd)
#   - another systemd user unit references it (_wt_used_by_other_unit)
#   - its gitignored payload could not be archived, or is over the cap (_wt_archive_ignored)
# `git worktree prune` runs afterward regardless, as bookkeeping only.
_reap_remove_worktree() {
  local base="$1" force="$2" wt mainrepo wt_real mainrepo_real own_unit blocking
  wt="$(_wt_resolve_for_base "$base")"
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    echo "  worktree: none found for '$base' (ok)"
    return 0
  fi
  mainrepo="$(_wt_mainrepo "$wt")"
  if [ -z "$mainrepo" ]; then
    echo "  worktree: $wt is not a git worktree (main repo unresolvable) — leaving in place" >&2
    return 0
  fi
  wt_real="$(cd "$wt" 2>/dev/null && pwd -P)"
  mainrepo_real="$(cd "$mainrepo" 2>/dev/null && pwd -P)"
  if [ -n "$wt_real" ] && [ "$wt_real" = "$mainrepo_real" ]; then
    echo "  worktree: $wt IS $mainrepo's primary checkout — refusing to remove"
    return 0
  fi
  if _is_caller_cwd "$wt"; then
    echo "  worktree: $wt is the caller's own working directory — refusing to remove"
    return 0
  fi
  own_unit="${base}.service"
  if blocking="$(_wt_used_by_other_unit "$wt" "$own_unit")"; then
    echo "  worktree: kept (in use by unit $blocking): $wt"
    return 0
  fi
# Last guard, checked after every refusal above so nothing is archived for a worktree that would not be removed.
# `git worktree remove` deletes gitignored files, so archive the non-regenerable ones first. --force does NOT skip this.
  if ! _wt_archive_ignored "$wt"; then
    echo "  worktree: kept (gitignored files not archived: $_WTI_ERR): $wt"
    return 0
  fi
  local -a rmargs=(worktree remove)
  [ "$force" = yes ] && rmargs+=(--force)
  rmargs+=("$wt")
  if git -C "$mainrepo" "${rmargs[@]}" >/dev/null 2>&1; then
    echo "  worktree removed (branch kept): $wt"
  else
    echo "  worktree: kept (git worktree remove refused — untracked/modified files?): $wt"
  fi
  git -C "$mainrepo" worktree prune >/dev/null 2>&1 || true
  return 0
}

declare -A _TSV_STATUS_CACHE
# _tsv_git_status <cwd> -> sets _TSV_LANDED/_TSV_DIRTY for idle-report --tsv columns 9/10 (landed: yes|no|unknown|no-worktree;
# dirty: clean|DIRTY|unknown). Reuses _wt_dirty/_wt_landed/_wt_mainrepo. Transcripts outlive worktrees, so a gone cwd is no-worktree.
# Caches per cwd. It sets globals instead of echoing: a $(...) subshell would discard the cache write on every row, so call it directly.
_tsv_git_status() {
  local cwd="$1" mainrepo landedinfo
  if [ -n "${_TSV_STATUS_CACHE[$cwd]+x}" ]; then
    _TSV_LANDED="${_TSV_STATUS_CACHE[$cwd]%%$'\t'*}"
    _TSV_DIRTY="${_TSV_STATUS_CACHE[$cwd]#*$'\t'}"
    return
  fi
  if [ ! -d "$cwd" ] || ! git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    _TSV_LANDED="no-worktree"; _TSV_DIRTY="unknown"
  else
    _TSV_DIRTY="$(_wt_dirty "$cwd")"
# Defensive: git found a repo here, so _wt_dirty should not answer not-a-worktree; map it to unknown anyway (session-compact.sh validates this vocabulary).
    [ "$_TSV_DIRTY" = not-a-worktree ] && _TSV_DIRTY=unknown
    mainrepo="$(_wt_mainrepo "$cwd")"
    if [ -n "$mainrepo" ]; then
      landedinfo="$(_wt_landed "$cwd" "$mainrepo")"
      _TSV_LANDED="${landedinfo#*landed=}"
    else
      _TSV_LANDED="unknown"
    fi
  fi
  _TSV_STATUS_CACHE[$cwd]="$_TSV_LANDED"$'\t'"$_TSV_DIRTY"
}

# ── history helpers ────────────────────────────────────────────────────────

# _encode_cwd <path> -> the ~/.claude/projects/<encoded> dir name. Pure string transform; '.' -> '-' must run before '/' -> '-'.
_encode_cwd() {
  local p="$1"
  p="${p//./-}"
  printf '%s\n' "${p//\//-}"
}

# _history_matches <query> <wt_base> <proj_base> — print matched worktree paths, one per line (they may not exist on disk).
# Query: a folder name, a path (only its basename is used), or a repo-name substring. Candidates come from live dirs under
# <wt_base> AND names recovered from <proj_base> transcript dirs, so removed worktrees still match. Exact match wins; else substring. Returns 1 if none.
_history_matches() {
  local query="$1" wt_base="$2" proj_base="$3" qname d dn n prefix found=0 trimmed
# A query that looks like a path and resolves to a real directory is authoritative. Skipping name matching matters: a basename
# substring once hijacked a real checkout outside wt_base onto a stale legacy-prefixed worktree. Unresolved queries fall through to name matching.
  case "$query" in
    */*|.|..)
      trimmed="${query%/}"
      [ -n "$trimmed" ] || trimmed="/"
      if [ -d "$trimmed" ]; then
        printf '%s\n' "$(cd "$trimmed" >/dev/null 2>&1 && pwd)"
        return 0
      fi
      qname="$(basename "$trimmed")"
      ;;
    *) qname="$query" ;;
  esac
  local -A seen=()
  local -a candidates=()
  for d in "$wt_base"/*/; do
    [ -d "$d" ] || continue
    n="$(basename "${d%/}")"
    [ -n "${seen[$n]+x}" ] && continue
    seen[$n]=1; candidates+=("$n")
  done
  prefix="$(_encode_cwd "$wt_base")-"
  if [ -d "$proj_base" ]; then
    for d in "$proj_base"/*/; do
      [ -d "$d" ] || continue
      dn="$(basename "${d%/}")"
      case "$dn" in
        "$prefix"*) n="${dn#"$prefix"}" ;;
        *) continue ;;
      esac
      [ -n "$n" ] || continue
      [ -n "${seen[$n]+x}" ] && continue
      seen[$n]=1; candidates+=("$n")
    done
  fi
  if [ "${#candidates[@]}" -gt 0 ]; then
    mapfile -t candidates < <(printf '%s\n' "${candidates[@]}" | sort)
  fi
  if [ -n "${seen[$qname]+x}" ]; then
    printf '%s\n' "$wt_base/$qname"
    return 0
  fi
  for n in "${candidates[@]}"; do
    case "$n" in
      *"$qname"*) printf '%s\n' "$wt_base/$n"; found=1 ;;
    esac
  done
  [ "$found" -eq 1 ]
}

# _history_report <worktree> <proj_base> — report-only: NOW (live processes whose cwd is exactly this worktree, found the same way
# as idle-report) and PAST (transcript history for this cwd). A pid carries no session uuid, so the transcript with the latest
# user timestamp is folded into NOW as the likely writer. That is a heuristic, and the output says so.
_history_report() {
  local wt="$1" proj_base="$2" encoded tdir now_rows
  encoded="$(_encode_cwd "$wt")"
  tdir="$proj_base/$encoded"
  echo ""
  echo "--- $wt ---"
  now_rows="$(
    pgrep -af 'claude.*--remote-control' 2>/dev/null | while read -r pid cmd; do
      case "$(basename "$(printf '%s' "$cmd" | awk '{print $1}')")" in claude|node) ;; *) continue;; esac
      rc="$(printf '%s' "$cmd" | grep -oE -- '--remote-control[ =][^ ]+' | head -1 | sed -E 's/^--remote-control[ =]//')"
      [ -n "$rc" ] || continue
      tm="$(svc_to_tmux "$rc")"
      cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null)"
      [ -n "$cwd" ] || continue
      [ "$cwd" = "$wt" ] || continue
      prot=no; _is_protected "$rc $tm $cwd" && prot=yes
      printf '%s\t%s\t%s\t%s\n' "$pid" "$rc" "$tm" "$prot"
    done
  )"
  python3 - "$tdir" "$now_rows" <<'PYEOF'
import sys, os, glob, json, datetime

tdir, now_raw = sys.argv[1], sys.argv[2]
now_rows = [l.split('\t') for l in now_raw.splitlines() if l.strip()]
now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)

files = sorted(glob.glob(os.path.join(tdir, '*.jsonl')))
per_file = {}
dir_max_ts = None
for fn in files:
    uuid = os.path.basename(fn)
    if uuid.endswith('.jsonl'):
        uuid = uuid[:-6]
    first_ts = last_ts = None
    turns = 0
    try:
        size = os.path.getsize(fn)
    except OSError:
        size = 0
    try:
        with open(fn, encoding='utf-8', errors='ignore') as fh:
            for line in fh:
                if '"user"' not in line:            # cheap prefilter, same trick idle-report uses
                    continue
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                if o.get('type') != 'user':
                    continue
                ts = o.get('timestamp')
                if not ts:
                    continue
                turns += 1
                if first_ts is None or ts < first_ts:
                    first_ts = ts
                if last_ts is None or ts > last_ts:
                    last_ts = ts
    except OSError:
        pass                                          # transcript dir/file gone mid-scan — just skip it
    per_file[uuid] = {'first': first_ts, 'last': last_ts, 'turns': turns, 'size': size}
    if last_ts and (dir_max_ts is None or last_ts > dir_max_ts):
        dir_max_ts = last_ts

def human_size(n):
    n = float(n)
    for unit in ('B', 'K', 'M', 'G', 'T'):
        if n < 1024 or unit == 'T':
            return ('%d%s' % (n, unit)) if unit == 'B' else ('%.1f%s' % (n, unit))
        n /= 1024

print('  NOW — live session(s) with this cwd:')
if not now_rows:
    print('    (none)')
else:
    print('    %-30s %-30s %-8s %-9s %s' % ('TMUX SESSION', 'REMOTE-CONTROL NAME', 'PID', 'IDLE', 'PROT'))
    for pid, rc, tm, prot in now_rows:
        if dir_max_ts:
            try:
                dt = datetime.datetime.fromisoformat(dir_max_ts[:19])
                idle_s = '%dm' % int((now - dt).total_seconds() // 60)
            except Exception:
                idle_s = '?'
        else:
            idle_s = 'never'
        flag = '[P]' if prot == 'yes' else ''
        print('    %-30s %-30s %-8s %-9s %s' % (tm[:30], rc[:30], pid, idle_s, flag))

# See _history_report's comment above for why this cross-reference is a
# heuristic (no uuid on the process command line to match against directly).
live_uuid = None
if now_rows and dir_max_ts:
    for uuid, info in per_file.items():
        if info['last'] == dir_max_ts:
            live_uuid = uuid
            break

past = [u for u in per_file if u != live_uuid]
past.sort(key=lambda u: (per_file[u]['last'] or '', per_file[u]['first'] or ''))

print('')
print('  PAST — sessions that previously touched this folder (%s):' % tdir)
if not files:
    print('    (no transcript directory — no recorded sessions)')
elif not past:
    print('    (no PAST sessions%s)' % (' — only session here is the LIVE one above' if live_uuid else ''))
else:
    print('    %-10s %-21s %-21s %-6s %s' % ('SESSION', 'FIRST type:user', 'LAST type:user', 'TURNS', 'SIZE'))
    for uuid in past:
        info = per_file[uuid]
        first_s = (info['first'][:19] + 'Z') if info['first'] else '(none)'
        last_s = (info['last'][:19] + 'Z') if info['last'] else '(none)'
        print('    %-10s %-21s %-21s %-6d %s' % (uuid[:8], first_s, last_s, info['turns'], human_size(info['size'])))
if live_uuid:
    print('    [%s is LIVE now — see NOW section above, not double-counted here]' % live_uuid[:8])
print('  --- %d past session(s), %d live session(s) ---' % (len(past), len(now_rows)))
PYEOF
}

# _history_footer <worktree> — branch, dirty, landed and recent commits. A worktree gone from disk is reported, not probed.
_history_footer() {
  local wt="$1" branch dirty mainrepo landedinfo logout
  echo ""
  echo "  worktree status:"
  if [ ! -d "$wt" ]; then
    echo "    worktree no longer exists on disk at $wt (history above is from transcripts only)"
    return 0
  fi
  branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  dirty="$(_wt_dirty "$wt")"
  mainrepo="$(_wt_mainrepo "$wt")"
  landedinfo="base=? landed=unknown"
  [ -n "$mainrepo" ] && landedinfo="$(_wt_landed "$wt" "$mainrepo")"
  printf '    branch=%s status=%s %s\n' "$branch" "$dirty" "$landedinfo"
  echo "    git log --oneline -5:"
  logout="$(git -C "$wt" log --oneline -5 2>/dev/null)"
  if [ -n "$logout" ]; then
    printf '%s\n' "$logout" | sed 's/^/      /'
  else
    echo "      (no commits)"
  fi
}

# _crss_overlay_report — read-only overlay health check. Never fails hard: every check is a plain conditional and the
# function always returns 0. Warns about config.sh lines that look like assignments but are not loaded.
_crss_overlay_report() {
  local home cfg rules localmd line
  home="$CRSS_HOME"
  echo "=== OVERLAY: $home ==="
  if [ -d "$home" ]; then echo "  dir: found"; else echo "  dir: absent"; fi
  cfg="$home/config.sh"
  if [ -f "$cfg" ]; then
    echo "  config.sh: found"
    while IFS= read -r line || [ -n "$line" ]; do
      [[ "$line" =~ ^CRSS_[A-Z0-9_]+= ]] && continue
      [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && echo "  warn: config.sh line looks like an assignment but will be ignored (must match ^CRSS_[A-Z0-9_]+=): $line"
    done < "$cfg" 2>/dev/null
  else
    echo "  config.sh: absent"
  fi
  rules="${CRSS_CLAUDE_HOME:-$HOME/.claude}/rules/crss-host.md"
  if [ -f "$rules" ]; then
    if grep -Eq '@[^[:space:]]*local\.md' "$rules" 2>/dev/null; then
      echo "  rules: found ($rules, imports local.md)"
    else
      echo "  rules: found ($rules) — warn: no @import of local.md found"
    fi
  else
    echo "  rules: absent ($rules)"
  fi
  localmd="$home/local.md"
  if [ -f "$localmd" ]; then echo "  local.md: found"; else echo "  local.md: absent"; fi
  return 0
}

# ── reap-merged ──────────────────────────────────────────────────────────────
# _rm_strip_ansi — drop CSI escape sequences from stdin.
_rm_strip_ansi() { sed -E $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g'; }

# _rm_handoff_blocked <plain-capture> — 0 blocked, 1 clear, 2 unavailable. Runs session-handoff's _is_blocked in a
# subprocess (sourcing it would redefine tmux_to_base). Unavailable fails closed: reaping a lane that may be waiting
# on the operator is the unsafe direction.
_rm_handoff_blocked() {
  local helper rc
  helper="$(_find_helper session-handoff)" || return 2
  printf '%s' "$1" | bash -c '
    source "$1" >/dev/null || exit 2
    cap=$(cat)
    declare -F _is_blocked >/dev/null || exit 2
    if _is_blocked "$cap"; then exit 0; else exit 1; fi
  ' _ "$helper"
  rc=$?
  return "$rc"
}

# _rm_pane_state <tmux-session> -> RM_PANE=busy|blocked|typed|ok. capture-pane -e tells dim autosuggest ghost text from
# typed input. busy = spinner, interrupt hint or background-task counter; an unreadable pane is busy (fail closed).
# blocked = waiting on the operator; never reaped.
_rm_pane_state() {
  local raw plain tail_ line after
  RM_PANE=ok; RM_PANE_WHY=""
  raw="$(tmux capture-pane -p -e -t "$1" 2>/dev/null)" || { RM_PANE=busy; RM_PANE_WHY="pane unreadable"; return; }
  plain="$(printf '%s\n' "$raw" | _rm_strip_ansi)"
# The footer's "← N agents" is constant on idle panes, so it is stripped before matching.
  tail_="$(printf '%s\n' "$plain" | tail -n 8 | sed -E 's/← *[0-9]+ agents?//g')"
  busy_re='esc to interrupt|ctrl\+c to interrupt|[0-9]+ (local )?(agents?|background|bg|shells?|tasks?|monitors?)\b|running in the background|Running…'
  if grep -qiE "$busy_re" <<<"$tail_"; then
    RM_PANE=busy; RM_PANE_WHY="busy marker visible: $(grep -iE -m1 "$busy_re" <<<"$tail_" | tr -s ' ' | sed -E 's/^ //' | cut -c1-60)"
    return
  fi
  _rm_handoff_blocked "$plain"
  case $? in
    1) ;;
    0) RM_PANE=blocked; RM_PANE_WHY="pane-blocked"; return ;;
    *) RM_PANE=blocked; RM_PANE_WHY="pane-blocked check unavailable"; return ;;
  esac
  line="$(printf '%s\n' "$raw" | grep -E '❯|›' | tail -n 1)"
  if [ -n "$line" ]; then
    case "$line" in *❯*) after="${line#*❯}" ;; *) after="${line#*›}" ;; esac
    # Mark dim (ghost) text with \001, strip other escapes, then trim whitespace including NBSP.
    after="$(printf '%s' "$after" | sed -E $'s/\x1b\\[2m/\x01/g' | _rm_strip_ansi | sed -E $'s/^([[:space:]]|\xc2\xa0)+//; s/([[:space:]]|\xc2\xa0)+$//')"
    if [ -n "$after" ] && [ "${after:0:1}" != $'\x01' ]; then
      RM_PANE=typed; RM_PANE_WHY="unsent text at the prompt"
    fi
  fi
}

# _rm_idle_minutes <tmux-session> <cwd> -> whole idle minutes from the NEWER of transcript mtime and tmux window activity.
# Returns 1 if either signal is missing: a session is never judged idle on one signal alone.
_rm_idle_minutes() {
  local pdir f t_tr t_win now newest
  pdir="$HOME/.claude/projects/${2//[\/.]/-}"
  f="$(ls -t "$pdir"/*.jsonl 2>/dev/null | head -n 1)"
  [ -n "$f" ] && t_tr="$(stat -c %Y "$f" 2>/dev/null)" || return 1
  t_win="$(tmux display-message -p -t "$1" '#{window_activity}' 2>/dev/null)"
  case "$t_win" in ''|*[!0-9]*) return 1 ;; esac
  now="$(date +%s)"
  newest=$t_tr; [ "$t_win" -gt "$newest" ] && newest=$t_win
  echo $(( (now - newest) / 60 ))
}

# _rm_gh_prs <wt> <state> <branch> -> JSON from gh, run inside the worktree so the repo is inferred.
_rm_gh_prs() {
  (cd "$1" && timeout 30 gh pr list --state "$2" --head "$3" --json number,headRefOid --limit 30 2>/dev/null)
}

# _reap_age_gate <tmux-session> — min-age gate for every reap of a LIVE session. Returns 1 (reason in REAP_AGE_MSG) when the
# session is younger than CRSS_REAP_MIN_AGE_H or its age is unknown; bypass with --allow-young or CRSS_REAP_MIN_AGE_H=0.
# Age is first spawn via session-registry --first-seen. --force deliberately does NOT bypass (it covers unlanded work).
REAP_AGE_MSG=""
_reap_age_gate() {
  local name="$1" sr start age_s min_s
  REAP_AGE_MSG=""
  [ "$REAP_MIN_AGE_H" -gt 0 ] || return 0
  [ "$ALLOW_YOUNG" = yes ] && return 0
  min_s=$((REAP_MIN_AGE_H * 3600))
  sr="$(_find_helper session-registry)" && start="$(bash "$sr" --first-seen "$name" 2>/dev/null)" || start=""
  case "$start" in ''|*[!0-9]*)
    REAP_AGE_MSG="age unknown (no spawn record in session-starts.log), use --allow-young or CRSS_REAP_MIN_AGE_H=0"; return 1;;
  esac
  age_s=$(( $(date -u +%s) - start ))
  if [ "$age_s" -lt "$min_s" ]; then
    REAP_AGE_MSG="age $((age_s / 3600))h$(( (age_s % 3600) / 60 ))m < minimum ${REAP_MIN_AGE_H}h; override with --allow-young or CRSS_REAP_MIN_AGE_H=0 (--force does not bypass)"
    return 1
  fi
  return 0
}

# _reap_merged_check <tmux-session> -> RM_VERDICT=candidate|skipped plus RM_REASON. Cheapest checks first; any unknown is a
# skip, never a candidate. The last gate runs `reap --dry-run` as a subprocess because reap's dispatch calls exit.
_reap_merged_check() {
  local name="$1" base cwd wt br def head mj oj pr idle me out rc
  RM_VERDICT=skipped; RM_REASON=""
  base="$(tmux_to_base "$name")"
  [ -n "$base" ] || { RM_REASON="not a crss-prefixed session"; return; }
  if _is_protected "$name"; then RM_REASON="protected name"; return; fi
  case "$name" in *desk*) RM_REASON="operator desk"; return ;; esac
  if [ -n "${TMUX:-}" ]; then
    me="$(tmux display-message -p '#S' 2>/dev/null)"
    [ "$me" = "$name" ] && { RM_REASON="caller's own session"; return; }
  fi
  _reap_age_gate "$name" || { RM_REASON="min-age gate: $REAP_AGE_MSG"; return; }
  cwd="$(tmux display-message -p -t "$name" '#{pane_current_path}' 2>/dev/null)"
  [ -n "$cwd" ] || { RM_REASON="no pane cwd"; return; }
  case "$cwd" in "$HOME/.claude/worktrees/"*) ;; *) RM_REASON="not in a crss worktree"; return ;; esac
  wt="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || { RM_REASON="not a git worktree"; return; }
  br="$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null)" || { RM_REASON="detached HEAD"; return; }
  def="$(_default_branch "$(_wt_mainrepo "$wt")")"
  [ "$br" != "$def" ] || { RM_REASON="on default branch $def"; return; }
  [ "$(_wt_dirty "$wt")" = clean ] || { RM_REASON="uncommitted work in worktree"; return; }
  head="$(git -C "$wt" rev-parse HEAD 2>/dev/null)" || { RM_REASON="cannot read HEAD"; return; }
  git -C "$wt" remote get-url origin >/dev/null 2>&1 || { RM_REASON="no origin remote (no PR to verify)"; return; }
  oj="$(_rm_gh_prs "$wt" open "$br")" || { RM_REASON="gh open-PR lookup failed"; return; }
  [ "$(python3 -c 'import json,sys;print(len(json.load(sys.stdin)))' <<<"$oj" 2>/dev/null)" = 0 ] || { RM_REASON="open PR on $br"; return; }
  mj="$(_rm_gh_prs "$wt" merged "$br")" || { RM_REASON="gh merged-PR lookup failed"; return; }
  pr="$(python3 -c '
import json,sys
head=sys.argv[1]
for p in json.load(sys.stdin):
    if p.get("headRefOid")==head: print(p["number"]); break
' "$head" <<<"$mj" 2>/dev/null)"
  [ -n "$pr" ] || { RM_REASON="no merged PR whose head is this worktree's HEAD"; return; }
  idle="$(_rm_idle_minutes "$name" "$cwd")" || { RM_REASON="idle time unknown (no transcript or tmux activity)"; return; }
  [ "$idle" -ge "$IDLE_MIN" ] || { RM_REASON="active ${idle}m ago (< ${IDLE_MIN}m)"; return; }
  _rm_pane_state "$name"
  [ "$RM_PANE" = ok ] || { RM_REASON="$RM_PANE_WHY"; return; }
  out="$(bash "${BASH_SOURCE[0]}" reap "$name" --dry-run $AY_FLAG 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    RM_REASON="reap audit refused: $(grep -iE -m1 'REFUSING|unlanded|uncommitted|NOT-SAFE' <<<"$out" | cut -c1-100)"; return
  fi
  RM_VERDICT=candidate; RM_REASON="merged PR #$pr, idle ${idle}m"
}

# Shared transcript auth detection for auth-scan and auth-heal (no credential reads).
_auth_python_common() {
  cat <<'PY'
import sys, json, datetime
AUTH = ("Please run /login", "could not be refreshed", "Login expired", "OAuth token revoked",
        "OAuth session expired", "OAuth access token has expired", "Not logged in", "Invalid API key")
def when(ts):
    try:
        d = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
        return d if d.tzinfo else d.replace(tzinfo=datetime.timezone.utc)
    except (ValueError, AttributeError):
        return None
def auth_text(d):
    m = d.get("message")
    c = m.get("content") if isinstance(m, dict) else None
    return c if isinstance(c, str) else " ".join(x.get("text", "") for x in (c or []) if isinstance(x, dict))
def auth_failure(d):
    if d.get("type") == "system" and d.get("subtype") == "api_error":
        error = d.get("error")
        status = d.get("status", error.get("status") if isinstance(error, dict) else None)
        if str(status) == "401": return True
    return bool(d.get("isApiErrorMessage") and
                (d.get("error") == "authentication_failed" or any(k in auth_text(d) for k in AUTH)))
PY
}

# Only the newest UUID transcript for this cwd counts. User/assistant turns and system api_error records are meaningful;
# other metadata records are skipped.
_auth_heal_failure() {
  python3 -I -c "$(_auth_python_common)
"'
import pathlib, uuid
project = pathlib.Path(sys.argv[1])
try:
    files = []
    for f in project.glob("*.jsonl"):
        try: uuid.UUID(f.stem)
        except ValueError: continue
        if not f.is_symlink() and f.is_file(): files.append(f)
    if not files: sys.exit(0)
    latest = max(files, key=lambda f: f.stat().st_mtime_ns)
    last = None
    with latest.open() as fh:
        for line in fh:
            try: d = json.loads(line)
            except ValueError: continue
            if not isinstance(d, dict): continue
            if d.get("type") in ("assistant", "user") or (d.get("type") == "system" and d.get("subtype") == "api_error"):
                last = d
    if last and auth_failure(last):
        ts = last.get("timestamp") or ""
        w = when(ts)
        if w and w >= datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=int(sys.argv[2])):
            key = last.get("uuid") or ts
            if isinstance(key, str) and not any(c in key + ts for c in "\t\r\n"):
                print(key + "\t" + ts)
except (OSError, ValueError, TypeError):
    sys.exit(1)
' "$1" "$DAYS"
}

_auth_heal() {
  local here send handoff status state s cwd proj event key ts old_s old_key at heal_lock
  local rc=0 considered=0 nudged=0 candidate_count=0 seen recent now
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  send="${CRSS_SESSION_SEND:-}"
  if [ -z "$send" ]; then
    send="$here/session-send.sh"
    [ -f "$send" ] || send="$(command -v session-send)"
  fi
  handoff="$here/session-handoff.sh"
  [ -f "$handoff" ] || handoff="$(command -v session-handoff)"
  if ! status="$(timeout 20 "${CRSS_CLAUDE_BIN:-claude}" auth status 2>/dev/null)" ||
     ! python3 -I -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("loggedIn") is True else 1)' <<<"$status" 2>/dev/null; then
    echo 'host not logged in — operator must /login'
    echo 'auth-heal: considered=0 candidates=0 nudged=0 operator=1'
    return 1
  fi
  state="${XDG_STATE_HOME:-$HOME/.local/state}/crss/auth-heal.tsv"
  # Serialize apply callers across the read/send/record sequence. Dry-run creates nothing.
  if [ "$APPLY" = yes ]; then
    mkdir -p "$(dirname "$state")" && exec {heal_lock}>"$state.lock" && flock -x "$heal_lock" || { echo "auth-heal: cannot lock $state.lock (flock missing?)" >&2; return 1; }
  fi
  now="$(date +%s)"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    considered=$((considered+1))
    if _is_protected "$s"; then echo "$s skip(protected)"; continue; fi
    cwd="$(tmux display-message -p -t "$s" '#{pane_current_path}' 2>/dev/null)"
    if [ -z "$cwd" ]; then echo "$s skip(no-cwd)"; continue; fi
    proj="${CRSS_CLAUDE_HOME:-$HOME/.claude}/projects/$(printf '%s' "$cwd" | sed 's/[^A-Za-z0-9]/-/g')"
    if ! event="$(_auth_heal_failure "$proj")"; then echo "$s skip(transcript-unreadable)"; rc=1; continue; fi
    if [ -z "$event" ]; then echo "$s skip(no-auth-failure)"; continue; fi
    IFS=$'\t' read -r key ts <<<"$event"
    seen=no; recent=no
    if [ -f "$state" ]; then
      while IFS=$'\t' read -r old_s old_key at; do
        [ "$old_s" = "$s" ] || continue
        [ "$old_key" = "$key" ] && seen=yes
        if [[ "$at" =~ ^[0-9]{1,12}$ ]] && (( now - at < 21600 )); then recent=yes; fi
      done < "$state"
    fi
    if [ "$seen" = yes ]; then echo "$s skip(already-nudged)"; continue; fi
    if [ "$recent" = yes ]; then echo "$s skip(repeat-failure — login likely dead; operator /login)"; rc=1; continue; fi
    if ! bash "$handoff" ready "$s" >/dev/null 2>&1; then echo "$s skip(busy)"; continue; fi
    candidate_count=$((candidate_count+1))
    if [ "$APPLY" != yes ]; then echo "would-nudge $s (failure $ts)"; continue; fi
    if "$send" "$s" "Your last turn stopped on a Claude sign-in error; the host login is valid again (auto-heal by session-doctor). Please continue where you left off; re-read your TASKS.md if you have one." >/dev/null 2>&1; then
      if printf '%s\t%s\t%s\n' "$s" "$key" "$(date +%s)" >> "$state"; then
        echo "nudged $s (failure $ts)"; nudged=$((nudged+1))
      else echo "$s failed(state-write)"; rc=1; fi
    else echo "$s failed(send)"; rc=1; fi
  done < <(live_tmux)
  if [ "$APPLY" = yes ]; then exec {heal_lock}>&-; fi
  echo "auth-heal: considered=$considered candidates=$candidate_count nudged=$nudged operator=$rc"
  return "$rc"
}

# _auth_scan <proj_base> <days> — report-only scan of transcripts for CLI auth-failure turns. Reads transcripts only,
# never the credentials file. rc 1 = the newest failure is newer than every success (outage ongoing); else 0.
_auth_scan() {
  local proj_base="$1" days="$2"
  [ -d "$proj_base" ] || { echo "  (no transcript dir: $proj_base)"; return 0; }
  # The trailing slash follows a symlinked projects dir; -type f keeps a planted symlinked file from being opened.
  find "${proj_base%/}/" -type f -name '*.jsonl' -mtime "-$days" -print0 2>/dev/null | python3 -I -c "$(_auth_python_common)
"'
days = int(sys.argv[1])
cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days)
fails, last_ok, files, unreadable = [], None, set(), 0
for f in sys.stdin.buffer.read().split(b"\0"):
    if not f: continue
    f = f.decode(errors="replace")
    try: fh = open(f, errors="replace")
    except OSError: unreadable += 1; continue
    with fh:
        for line in fh:
            if "isApiErrorMessage" not in line and "\"requestId\"" not in line and "api_error" not in line: continue
            try:
                d = json.loads(line)
                if not isinstance(d, dict): continue
                w = when(d.get("timestamp") or "")
                if w is None or w < cutoff: continue
                if d.get("source") == "request_retry": continue  # retry record precedes the final error turn; count the incident once
                if auth_failure(d):
                    fails.append((w, auth_text(d)[:90])); files.add(f)
                elif not d.get("isApiErrorMessage") and d.get("type") == "assistant" and d.get("requestId") and (last_ok is None or w > last_ok):
                    last_ok = w
            except (ValueError, AttributeError, TypeError):
                continue
iso = lambda w: w.strftime("%Y-%m-%dT%H:%M:%SZ") if w else "none in window"
if unreadable: print("  WARNING: %d transcript(s) unreadable — result may be incomplete" % unreadable)
if not fails:
    print("  no auth failures in the last %d day(s)" % days); sys.exit(0)
fails.sort(key=lambda x: x[0])
ongoing = last_ok is None or fails[-1][0] > last_ok
print("  auth failures: %d across %d transcript(s); first %s, last %s" % (len(fails), len(files), iso(fails[0][0]), iso(fails[-1][0])))
print("  last failure text: %s" % fails[-1][1])
print("  last successful assistant turn: %s" % iso(last_ok))
print("  AUTH OUTAGE LOOKS ONGOING — newest failure is newer than every success; operator must /login (see references/troubleshooting.md)" if ongoing else "  recovered: a successful turn is newer than the last failure")
sys.exit(1 if ongoing else 0)
' "$days"
  local rc=${PIPESTATUS[1]}  # python's status; a find error must not read as "outage ongoing"
  [ "$rc" -le 1 ] || echo "  auth-scan: internal error (rc=$rc)" >&2
  return "$rc"
}

# _opus_subagent_scan <proj_base> <days> — report-only: parent sessions whose subagent transcripts ran on Opus.
# The rule is builder/Sonnet subagents (CLAUDE.md "Subagent models"); a call with no subagent_type inherits Opus.
# suggest-feeders — live interactive claude TUIs that can feed promptSuggestionUnusedStreak (the ~/.claude.json back-off counter).
# --print, stream-json/--sdk-url children and `claude remote-control` never count. A TUI is quiet when
# CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION is 0/false (env or --settings). PROC_ROOT (default /proc) is overridable for tests.
_suggest_feeders() {
  python3 - "${PROC_ROOT:-/proc}" "$HOME/.claude.json" <<'PY'
import sys, os, json
root, cj = sys.argv[1], sys.argv[2]
try: streak = json.load(open(cj)).get('promptSuggestionUnusedStreak', 0)
except Exception: streak = '?'
off = lambda v: str(v).strip().lower() in ('0', 'false')
feeders, quiet = [], 0
for pid in sorted((d for d in os.listdir(root) if d.isdigit()), key=int):
    try:
        argv = open(f'{root}/{pid}/cmdline', 'rb').read().split(b'\0')
        argv = [a.decode('utf-8', 'replace') for a in argv if a]
    except Exception: continue
    if not argv or os.path.basename(argv[0]) not in ('claude', 'claude.exe'): continue
    if any(a in ('-p', '--print', '--sdk-url') or a.startswith('--sdk-url') or a == 'stream-json' for a in argv): continue
    if len(argv) > 1 and argv[1] == 'remote-control': continue
    try: env = dict(l.split('=', 1) for l in open(f'{root}/{pid}/environ', 'rb').read().decode('utf-8', 'replace').split('\0') if '=' in l)
    except Exception: env = {}
    val = env.get('CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION')
    arg = next((argv[i + 1] for i, a in enumerate(argv[:-1]) if a == '--settings'),
               next((a.split('=', 1)[1] for a in argv if a.startswith('--settings=')), None))
    if arg is not None:
        try:
            if not arg.lstrip().startswith('{') and not os.path.isabs(arg): arg = f'{root}/{pid}/cwd/{arg}'  # relative to the process cwd
            d = json.loads(arg) if arg.lstrip().startswith('{') else json.load(open(arg))
            val = d.get('env', {}).get('CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION', val)
        except Exception: pass
    if val is not None and off(val): quiet += 1
    else: feeders.append((pid, ' '.join(argv)[:110]))
print(f'  promptSuggestionUnusedStreak={streak} (>=20 = back-off); interactive claude TUIs with suggestions off: {quiet}')
if not feeders: print('  no TUI can feed the counter')
for pid, c in feeders: print(f'  FEEDER pid={pid}: {c}')
PY
}

_opus_subagent_scan() {
  local proj_base="$1" days="$2"
  [ -d "$proj_base" ] || { echo "  (no transcript dir: $proj_base)"; return 0; }
  find "${proj_base%/}/" -type f -path '*/subagents/agent-*.jsonl' -mtime "-$days" -print0 2>/dev/null | python3 -I -c '
import sys, json, os, datetime
def when(ts):
    try:
        d = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
        return d if d.tzinfo else d.replace(tzinfo=datetime.timezone.utc)
    except (ValueError, AttributeError):
        return None
days = int(sys.argv[1])
cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days)
sessions, scanned, unreadable = {}, 0, 0
for f in sys.stdin.buffer.read().split(b"\0"):
    if not f: continue
    f = f.decode(errors="replace"); scanned += 1
    opus, out_tok, last, sid, cwd, atype = set(), 0, None, "", "", ""
    try: fh = open(f, errors="replace")
    except OSError: unreadable += 1; continue
    with fh:
        for line in fh:
            if "\"assistant\"" not in line: continue
            try:
                d = json.loads(line)
                if not isinstance(d, dict) or d.get("type") != "assistant": continue
                w = when(d.get("timestamp") or "")
                if w is None or w < cutoff: continue
                m = d.get("message") if isinstance(d.get("message"), dict) else {}
                model = m.get("model") or d.get("requestedModel") or ""
                if not isinstance(model, str) or model == "<synthetic>" or "opus" not in model.lower(): continue
                opus.add(model); u = m.get("usage") if isinstance(m.get("usage"), dict) else {}
                out_tok += u.get("output_tokens", 0) if isinstance(u.get("output_tokens", 0), int) else 0
                last = w if last is None or w > last else last
                sid = sid or str(d.get("sessionId") or ""); cwd = cwd or str(d.get("cwd") or "")
                atype = atype or str(d.get("attributionAgent") or "")
            except (ValueError, AttributeError, TypeError):
                continue
    if not opus: continue
    if not atype:
        meta = f[:-len(".jsonl")] + ".meta.json"
        try:
            if os.path.isfile(meta) and not os.path.islink(meta):
                with open(meta, errors="replace") as mh: atype = str(json.load(mh).get("agentType") or "")
        except (OSError, ValueError, AttributeError):
            pass
    sid = sid or os.path.basename(os.path.dirname(os.path.dirname(f)))
    s = sessions.setdefault(sid, {"n": 0, "out": 0, "types": set(), "models": set(), "cwd": cwd, "last": last})
    s["n"] += 1; s["out"] += out_tok; s["types"].add(atype or "?"); s["models"] |= opus
    s["last"] = max(s["last"], last); s["cwd"] = s["cwd"] or cwd
if unreadable: print("  WARNING: %d transcript(s) unreadable — result may be incomplete" % unreadable)
if not sessions:
    print("  no Opus subagent transcripts in the last %d day(s) (%d subagent transcript(s) scanned)" % (days, scanned)); sys.exit(0)
n = sum(s["n"] for s in sessions.values())
print("  Opus subagents: %d across %d session(s) in the last %d day(s) (%d subagent transcript(s) scanned); use subagent_type: builder or model: sonnet" % (n, len(sessions), days, scanned))
for sid, s in sorted(sessions.items(), key=lambda kv: -kv[1]["out"])[:10]:
    print("  %-8s n=%-3d out=%-7d last=%s types=%s models=%s cwd=%s" % (sid[:8], s["n"], s["out"], s["last"].strftime("%Y-%m-%dT%H:%MZ"),
          ",".join(sorted(s["types"])), ",".join(sorted(s["models"])), s["cwd"] or "?"))
if len(sessions) > 10: print("  ... %d more session(s)" % (len(sessions) - 10))
' "$days"
  local rc=${PIPESTATUS[1]}
  [ "$rc" -eq 0 ] || echo "  opus-subagents: internal error (rc=$rc)" >&2
  return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
case "$MODE" in
  overlay)
    _crss_overlay_report
    ;;
  auth-heal)
    [ $# -eq 0 ] || { echo "usage: session-doctor.sh auth-heal [--apply] [--days N]" >&2; exit 2; }
    _auth_heal
    ;;
  auth-scan)
    echo "=== AUTH: transcript auth-failure scan (last $DAYS day(s)) ==="
    _auth_scan "$HOME/.claude/projects" "$DAYS"
    ;;
  suggest-feeders)
    echo "=== PROMPT SUGGESTIONS: TUIs that can feed the host-wide unused-streak ==="
    _suggest_feeders
    ;;
  opus-subagents)
    echo "=== OPUS SUBAGENTS: subagent transcripts on Opus (last $DAYS day(s)) ==="
    _opus_subagent_scan "$HOME/.claude/projects" "$DAYS"
    ;;
  report)
    echo "=== LOCAL: tmux sessions ==="
    for s in $(live_tmux); do
      alive=$(proc_alive "$s" && echo yes || echo NO-PROC)
      prot=$(_is_protected "$s" && echo " [PROTECTED]" || true)
      printf "  %-52s proc=%s%s\n" "$s" "$alive" "$prot"
    done
    echo "=== LOCAL: systemd units without a live tmux (orphans) ==="
    for u in $(ls "$UD" 2>/dev/null | grep -E "^(${_crss_prefix_re})-.*\.service\$"); do
      base="${u%.service}"; tm="$(svc_to_tmux "$base")"
      _tmux_live_has "$tm" || echo "  ORPHAN unit: $u"
    done
    echo "=== REGISTRY: staleness summary ==="
    registry_json | python3 -c "
import sys,json,datetime
try: arr=json.load(sys.stdin)
except: print('  (registry unavailable)'); sys.exit()
arr=arr if isinstance(arr,list) else arr.get('sessions',arr.get('data',[]))
from collections import Counter
now=datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
def agedays(s):
    try: return (now-datetime.datetime.fromisoformat((s.get('updated_at') or s.get('created_at'))[:19])).days
    except: return -1
disc=[s for s in arr if s.get('connection_status')=='disconnected']
zomb=[s for s in arr if s.get('connection_status')=='connected' and agedays(s)>7]
print('  total=%d  connected=%d  disconnected=%d' % (len(arr),
      sum(1 for s in arr if s.get('connection_status')=='connected'), len(disc)))
print('  disconnected >%dd (reapable): %d' % (30, sum(1 for s in disc if agedays(s)>30)))
print('  \"connected\" but >7d (likely zombies): %d' % len(zomb))
print('  session_status:', dict(Counter(s.get('session_status') for s in arr)))
"
    echo "=== AUTH: transcript auth-failure scan (last 2 days; auth-scan for detail) ==="
    _auth_scan "$HOME/.claude/projects" 2 || true
    echo "=== OPUS SUBAGENTS: last 2 days (opus-subagents for detail) ==="
    _osa_out="$(_opus_subagent_scan "$HOME/.claude/projects" 2)" || true
    grep -m1 -E '^  (Opus subagents|no Opus|\(no transcript)' <<<"$_osa_out" || true
    _crss_overlay_report
    ;;

  reap-local)
    [ "$FORCE" = yes ] || echo "(DRY-RUN — re-run with --force to actually reap)"
    do_reap() {  # $1=tmux-name-or-empty $2=service $3=start-script
      local acted=no
      if [ "$FORCE" = yes ]; then
        { [ -n "$UD" ] && [ -f "$UD/$2" ]; } && acted=yes
        { [ -n "$BIN" ] && [ -n "$3" ] && [ -f "$BIN/$3" ]; } && acted=yes
        # Archive unit and start script before any rm; if the archive fails, delete nothing.
        if ! _reap_archive_home_paths "${2%.service}" ".config/systemd/user/$2" ".local/bin/$3"; then
          echo "  WARNING: unit/start-script archive failed for '$2' ($_REAP_ARCHIVE_ERR); leaving originals in place" >&2
          return
        fi
        systemctl --user disable --now "$2" >/dev/null 2>&1 || true
        [ -n "$UD" ] && [ -f "$UD/$2" ] && rm -f "$UD/$2"
        [ -n "$UD" ] && [ -L "$UD/default.target.wants/$2" ] && rm -f "$UD/default.target.wants/$2"
        [ -n "$BIN" ] && [ -n "$3" ] && [ -f "$BIN/$3" ] && rm -f "$BIN/$3"
        [ -n "$1" ] && tmux kill-session -t "=$1" 2>/dev/null && acted=yes
        [ "$acted" = yes ] && _record_reap_event "${2%.service}" yes
      fi
    }
    reaped=0
    # 1. tmux sessions whose claude proc is gone (skip protected).
    for s in $(live_tmux); do
      _is_protected "$s" && continue
      base="$(tmux_to_base "$s")"; [ -z "$base" ] && continue   # not ours (e.g. codexhost_) → leave it
      proc_alive "$s" && continue                                # alive → keep
      if ! _reap_age_gate "$s"; then
        echo "SKIPPED young/unknown-age dead tmux: $s — $REAP_AGE_MSG"; continue
      fi
      echo "DEAD tmux (no claude proc): $s"
      do_reap "$s" "${base}.service" "${base}-start.sh"
      reaped=$((reaped+1))
    done
    # 2. orphaned units. They are Type=oneshot/RemainAfterExit=yes, so `is-active` is almost always true and cannot test
    # liveness. The test is no live tmux match, the same as report's ORPHAN listing.
    for u in $(ls "$UD" 2>/dev/null | grep -E "^(${_crss_prefix_re})-.*\.service\$"); do
      _is_protected "$u" && continue
      base="${u%.service}"; tm="$(svc_to_tmux "$base")"
      _tmux_live_has "$tm" && continue
      if ! _reap_age_gate "$tm"; then
        echo "SKIPPED young/unknown-age orphan unit: $u — $REAP_AGE_MSG"; continue
      fi
      echo "ORPHAN unit (no tmux): $u"
      do_reap "" "$u" "${base}-start.sh"
      reaped=$((reaped+1))
    done
    [ "$FORCE" = yes ] && systemctl --user daemon-reload >/dev/null 2>&1 || true
    echo "$([ "$FORCE" = yes ] && echo reaped || echo would-reap) $reaped dead local item(s)"
    ;;

  registry-stale)
    echo "=== registry sessions disconnected > ${DAYS}d (deletion candidates; NOT auto-deleted) ==="
    if ! out=$(registry_json | _registry_candidates "$DAYS"); then
      echo "  (registry unavailable)"
    else
      n=0
      while IFS=$'\t' read -r id age status title; do
        [ -z "$id" ] && continue
        printf '  %s  age=%3dd  status=%-9s  %s\n' "$id" "$age" "$status" "${title:0:40}"
        n=$((n+1))
      done <<< "$out"
      echo "  --- $n candidate(s). To delete one (VERIFY FIRST): ---"
      echo "  curl -X DELETE https://api.anthropic.com/v1/sessions/<ID> \\"
      echo "    -H \"Authorization: Bearer \$TOKEN\" -H \"x-organization-uuid: \$ORG\" \\"
      echo "    -H \"anthropic-version: 2023-06-01\" -H \"anthropic-beta: ccr-byoc-2025-07-29\""
    fi
    ;;

  registry-prune)
    # Automated form of registry-stale's candidate set (see _registry_candidates
    # Dry run by default. --apply deletes via _registry_delete_one, the same helper reap's registry cleanup uses.
    echo "=== registry-prune: sessions disconnected > ${DAYS}d ($([ "$APPLY" = yes ] && echo APPLY || echo DRY-RUN)) ==="
    if ! cand_out=$(registry_json | _registry_candidates "$DAYS"); then
      echo "  (registry unavailable)"
      exit 1
    fi
    # Live tmux names in the hyphenated base form that registry titles use, so the live-tmux check compares like with like.
    live_bases=""
    for s in $(live_tmux); do
      b="$(tmux_to_base "$s")"
      [ -n "$b" ] && live_bases="$live_bases$b"$'\n'
    done
    n_del=0; n_skip=0; n_fail=0
    while IFS=$'\t' read -r id age status title; do
      [ -z "$id" ] && continue
      if _title_protected "$title"; then
        echo "  skipped(protected)  $id  $title"
        n_skip=$((n_skip+1)); continue
      fi
      if [ -n "$live_bases" ] && grep -qxF -- "$title" <<<"${live_bases%$'\n'}"; then
        echo "  skipped(live-tmux)  $id  $title"
        n_skip=$((n_skip+1)); continue
      fi
      # requires_action is always skipped (it may need a human decision); past 2xDAYS it is flagged louder for review.
      if [ "$status" = "requires_action" ]; then
        if [ "$age" -gt $((2*DAYS)) ]; then
          echo "  skipped(requires_action, age=${age}d > $((2*DAYS))d — needs operator review)  $id  $title"
        else
          echo "  skipped(requires_action)  $id  $title"
        fi
        n_skip=$((n_skip+1)); continue
      fi
      if [ "$APPLY" != yes ]; then
        echo "  would-delete  $id  age=${age}d  $title"
        n_del=$((n_del+1)); continue
      fi
      if _registry_delete_one "$id" "$title"; then n_del=$((n_del+1)); else n_fail=$((n_fail+1)); fi
    done <<< "$cand_out"
    echo "  --- $([ "$APPLY" = yes ] && echo deleted || echo would-delete)=$n_del skipped=$n_skip failed=$n_fail ---"
    if [ "$n_fail" -gt 0 ]; then
      exit 1
    fi
    ;;

  worktree-stale)
    echo "=== ~/.claude/worktrees/ dirs with no live owning session (NOT auto-removed) ==="
    WT_BASE="$HOME/.claude/worktrees"
    cand=0; kept=0; nonwt=0
    wti_list="$(mktemp)"
    for wt in "$WT_BASE"/*/; do
      [ -d "$wt" ] || continue
      wt="${wt%/}"
      branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
      # Prefer the branch's session name (session/<remote>) over the directory name: session-git-prep suffixes a colliding
      # directory with -$$ but not the branch, and liveness from the directory would misread a live worktree as dead.
      case "$branch" in
        session/*) owned=yes; remote="${branch#session/}" ;;
        *)         owned=no;  remote="$(basename "$wt")" ;;
      esac
      _is_protected "$remote" && continue
      tm="$(svc_to_tmux "$remote")"
      # Owning session still live (tmux present AND its claude proc running)? Keep it.
      if [ -n "$tm" ] && _tmux_live_has "$tm" && proc_alive "$tm"; then
        continue
      fi
      dirty="$(_wt_dirty "$wt")"
      # A plain folder has no git repo: list it, but never offer a command for it.
      if [ "$dirty" = not-a-worktree ]; then
        printf '  %-60s status=not-a-worktree\n' "$wt"
        printf '    NOTE: plain folder, not a git work tree — never offered for removal; inspect it by hand\n'
        nonwt=$((nonwt+1))
        continue
      fi
      cand=$((cand+1))
      # Resolve the main repo so the printed command is copy-pasteable and landed-ness uses its real default branch.
      mainrepo="$(_wt_mainrepo "$wt")"
      landedinfo="base=? landed=unknown"
      [ -n "$mainrepo" ] && landedinfo="$(_wt_landed "$wt" "$mainrepo")"
      printf '  %-60s branch=%-30s status=%-6s %s\n' "$wt" "$branch" "$dirty" "$landedinfo"
      # Same guard as reap (_reap_remove_worktree): a worktree another unit still references is never offered.
      # The dead session's own unit does not count.
      if blocking="$(_wt_used_by_other_unit "$wt" "${remote}.service")"; then
        printf '    KEEP: in use by unit %s — do not remove\n' "$blocking"
        kept=$((kept+1))
      elif [ -n "$mainrepo" ]; then
        # %q shell-quotes each value so a printed command is safe to paste.
        q_main="$(printf '%q' "$mainrepo")"; q_wt="$(printf '%q' "$wt")"
        # DIRTY rows get plain `worktree remove`: git refuses while tracked or untracked changes exist. Clean rows keep
        # --force because _wt_dirty ignores the spawner's own .claude/* and .sessions-init-* baseline, which plain remove
        # would refuse over. Only a clean status earns --force.
        rmforce=""; [ "$dirty" = clean ] && rmforce=" --force"
        # Gitignored payload: `worktree remove` deletes it unseen, so the archive step is chained AHEAD of the printed remove line.
        arch_pre=""
        _wt_ignored_payload "$wt" "$wti_list"; prc=$?
        [ "$prc" -ne 1 ] && arch_pre="session-doctor archive-ignored $q_wt && "
        if [ "$owned" = yes ]; then
          # Force-delete the branch only when known landed (unknown counts as not). The session/* ref keeps a dead session's
          # commits reachable. A squash-merged branch reads landed=yes via content or a merged PR: a suggestion, never a wrong delete.
          if [ "${landedinfo#*landed=}" = yes ] && [ "$dirty" = clean ]; then
            q_branch="$(printf '%q' "$branch")"
            printf '    remove: %sgit -C %s worktree remove --force %s && git -C %s branch -D %s\n' "$arch_pre" "$q_main" "$q_wt" "$q_main" "$q_branch"
          else
            printf '    remove: %sgit -C %s worktree remove%s %s\n' "$arch_pre" "$q_main" "$rmforce" "$q_wt"
            if [ "${landedinfo#*landed=}" != yes ]; then
              printf '    NOTE: branch %s is not known-landed — keep the ref; it is the only thing keeping its commits reachable\n' "$branch"
            fi
          fi
        else
          # The session switched branches: remove only the worktree; deleting an unrelated branch could destroy work.
          printf '    remove: %sgit -C %s worktree remove%s %s\n' "$arch_pre" "$q_main" "$rmforce" "$q_wt"
          printf '    NOTE: current branch %s is not a session/* name — leaving branch cleanup for manual review\n' "$branch"
        fi
        if [ "$dirty" = DIRTY ]; then
          printf '    NOTE: worktree has uncommitted changes (status=DIRTY) — inspect it first (git -C %s status --ignored); add --force only if they are not needed\n' "$q_wt"
        fi
        if [ "$prc" -eq 0 ]; then
          printf '    NOTE: %s gitignored file(s), %s bytes, e.g. %s — invisible to status; git worktree remove deletes them. Archive first: session-doctor archive-ignored %s (already chained ahead of the remove command above)\n' "$_WTI_COUNT" "$_WTI_BYTES" "$_WTI_EXAMPLES" "$q_wt"
        elif [ "$prc" -ne 1 ]; then
          printf '    NOTE: could not list this worktree'"'"'s gitignored files (unreadable directory?) — git worktree remove would delete them unseen; the archive-ignored step chained ahead of the remove command above will refuse until that is fixed\n'
        fi
      fi
    done
    rm -f "$wti_list"
    keepnote=""
    [ "$kept" -gt 0 ] && keepnote=", $kept KEEP (in use by a systemd unit — no removal command printed)"
    [ "$nonwt" -gt 0 ] && keepnote="$keepnote, $nonwt not-a-worktree (plain folder — not counted, no command)"
    echo "  --- $cand candidate(s)$keepnote. VERIFY dirty/unpushed work is not needed before removing. ---"
    ;;
  idle-report)
    # Report-only (mirrors registry-stale): live sessions with no genuine user turn in the last N days (default 2) or N minutes.
    # Never kills; every row is still alive, so feed dead ones to reap-local. Protected names are flagged, never to be reaped.
    # A tool-result turn counts as activity. A /compact summary entry does not, or a compacted session would be re-compacted forever.
    # --tsv: one row per session, 10 tab-separated columns, no header or footer. Columns 9/10 reuse _tsv_git_status.
    if [ "$TSV" != yes ]; then
      if [ "$MINUTES_SET" = yes ]; then
        if [ "$MINUTES" -gt 0 ] 2>/dev/null; then
          echo "=== LOCAL: live sessions with NO genuine user turn in the last ${MINUTES} minute(s) — REPORT ONLY, kills nothing ==="
        else
          echo "=== LOCAL: ALL live sessions, no threshold (--minutes 0) — REPORT ONLY, kills nothing ==="
        fi
      else
        if [ "$DAYS" -gt 0 ] 2>/dev/null; then
          echo "=== LOCAL: live sessions with NO type:user message in the last ${DAYS} day(s) — REPORT ONLY, kills nothing ==="
        else
          echo "=== LOCAL: ALL live sessions, no threshold (--days 0) — REPORT ONLY, kills nothing ==="
        fi
      fi
    fi
    PY_TSV=False; [ "$TSV" = yes ] && PY_TSV=True
    PY_MINUTES=None; [ "$MINUTES_SET" = yes ] && PY_MINUTES="$MINUTES"
    {
      # pgrep -f also matches the tmux launcher and the supervisor loop, so keep only the claude or node executable.
      pgrep -af 'claude.*--remote-control' | while read -r pid cmd; do
        case "$(basename "$(printf '%s' "$cmd" | awk '{print $1}')")" in claude|node) ;; *) continue;; esac
        rc="$(printf '%s' "$cmd" | grep -oE -- '--remote-control[ =][^ ]+' | head -1 | sed -E 's/^--remote-control[ =]//')"
        [ -n "$rc" ] || continue
        tm="$(svc_to_tmux "$rc")"                       # reuse existing name mapping
        cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null)"
        [ -n "$cwd" ] || continue                       # proc vanished mid-scan
        prot=no; _is_protected "$rc $tm $cwd" && prot=yes
        printf '%s\t%s\t%s\t%s\t%s\n' "$pid" "$rc" "$tm" "$cwd" "$prot"
      done
    } | python3 -c "
import sys, os, glob, json, datetime
DAYS = $DAYS
MINUTES = $PY_MINUTES
TSV = $PY_TSV
home = os.path.expanduser('~')
now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
if MINUTES is not None:
    cutoff = (now - datetime.timedelta(minutes=MINUTES)) if MINUTES > 0 else None
else:
    cutoff = (now - datetime.timedelta(days=DAYS)) if DAYS > 0 else None

# The only Claude Code build empirically verified to emit a
# type:system/subtype:compact_boundary entry (with a compactMetadata object)
# for a completed /compact is 2.1.206. The true minimum version this shipped
# in is unknown, so rather than guess a lower bound, only a transcript whose
# highest seen 'version' is >= this exact verified build is treated as
# 'version-aware' (making an absence a real 'no'); anything older, unparseable,
# or missing a version entirely reports 'unknown' rather than a guessed 'no'.
MIN_COMPACT_AWARE_VERSION = (2, 1, 206)

def parse_version(v):
    try:
        parts = [int(x) for x in str(v).split('.')[:3]]
    except Exception:
        return None
    if not parts:
        return None
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts)

rows, seen = [], set()
for line in sys.stdin:
    line = line.rstrip('\n')
    if not line: continue
    f = line.split('\t')
    if len(f) < 5: continue
    pid, rc, tm, cwd, prot = f[0], f[1], f[2], f[3], f[4]
    key = tm or rc
    if key in seen: continue
    seen.add(key)
    # cwd -> ~/.claude/projects/<encoded> transcript dir (verified empirically,
    # incl. dotted paths: '.'-> '-' then '/'-> '-').
    d = os.path.join(home, '.claude', 'projects', cwd.replace('.', '-').replace('/', '-'))
    files = glob.glob(os.path.join(d, '*.jsonl'))
    genuine_mx = None    # max ts over type:user entries that are NOT a /compact summary
    compact_mx = None    # max ts over type:system/subtype:compact_boundary entries
    ver_mx = None         # highest 'version' field seen on any entry read below
    for fn in files:
        try:
            for l in open(fn, encoding='utf-8', errors='ignore'):
                # Cheap prefilter before json.loads (same trick the rest of
                # this file uses): an ordinary type:user line always contains
                # the literal substring \"user\"; a compact_boundary line does
                # NOT (its only 'user'-ish key is userType, which doesn't
                # match the quoted-literal check) but always carries its
                # subtype name verbatim — check both in the one pass instead
                # of adding a second scan over the same files.
                if '\"user\"' not in l and 'compact_boundary' not in l:
                    continue
                try: o = json.loads(l)
                except Exception: continue
                v = o.get('version')
                if v:
                    vt = parse_version(v)
                    if vt and (ver_mx is None or vt > ver_mx): ver_mx = vt
                t = o.get('type')
                if t == 'user':
                    if o.get('isCompactSummary'):
                        continue   # the /compact write itself is not genuine activity
                    # A completed /compact leaves THREE MORE type:user artifacts
                    # in the transcript beyond the isCompactSummary write above,
                    # and none of them is genuine activity either. Confirmed
                    # against two REAL sweep --apply runs:
                    # excluding only isCompactSummary was NOT
                    # enough to fix the resulting idle-reset bug, because the
                    # /compact keystroke itself is EARLIER than these three, so
                    # it was never the max timestamp — these three were:
                    #   1. an isMeta:true local-command-caveat wrapper Claude
                    #      Code re-emits for ANY local slash command, not just
                    #      /compact.
                    #   2. the command-name echo of /compact itself.
                    #   3. the local-command-stdout line Claude Code writes once
                    #      compaction finishes (reads 'Compacted ...'). This one
                    #      lands LAST and LATEST of the four, so it — not 1 or 2
                    #      — is what actually dominated genuine_mx pre-fix.
                    # Also excluded: the bare '/compact' keystroke that triggers
                    # the whole cascade (see below).
                    #
                    # isMeta is excluded UNCONDITIONALLY (any command, not just
                    # /compact): it is pure caveat boilerplate, and excluding it
                    # loses no human-presence signal, because Claude Code writes
                    # a sibling command-name echo (kept as genuine here) at
                    # essentially the same timestamp for every OTHER command —
                    # confirmed against a real /clear in a live transcript.
                    #
                    # The command-name echo, the bare trigger, and the stdout
                    # line are, by contrast, excluded ONLY when tied to /compact
                    # specifically. Do NOT generalize this to 'any command-name
                    # echo' or 'any bare slash command' or 'any local-command-
                    # stdout': a human typing /clear, /context, /model, etc. is
                    # real evidence of presence, and blanket-excluding those
                    # would push toward compacting a session someone is
                    # actively using — the dangerous direction. (/model and
                    # /login were both observed emitting their own
                    # local-command-stdout line; an un-scoped
                    # 'starts with local-command-stdout' exclusion would have
                    # swallowed those genuine turns too.)
                    #
                    # The bare-trigger match is EXACT ('/compact', stripped),
                    # not a prefix match: a real transcript can hold
                    # a genuine chat message '/compact handoff first' that is
                    # NOT a command invocation (no caveat/echo/stdout cascade
                    # follows it) — a prefix match would have wrongly swallowed
                    # that real human turn.
                    if o.get('isMeta'):
                        continue
                    msg = o.get('message') or {}
                    content = msg.get('content')
                    if not isinstance(content, str):
                        content = ''
                    if content.startswith('<command-name>/compact</command-name>'):
                        continue
                    if content.strip() == '/compact':
                        continue
                    # ANSI dim styling (e.g. ESC[2m) sits between the tag and
                    # 'Compacted' on a real capture, so match within a short
                    # window after the tag rather than requiring adjacency.
                    if content.startswith('<local-command-stdout>') and 'Compacted' in content[:64]:
                        continue
                    ts = o.get('timestamp')
                    if ts and (genuine_mx is None or ts > genuine_mx): genuine_mx = ts
                elif t == 'system' and o.get('subtype') == 'compact_boundary':
                    ts = o.get('timestamp')
                    if ts and (compact_mx is None or ts > compact_mx): compact_mx = ts
        except Exception: pass
    mx = genuine_mx
    if mx is None:
        # 'never messaged' — distinguish no-transcript from present-but-no-user.
        state = 'never: no transcript' if not files else 'never: no user msgs'
        mxdt = None
    else:
        state = mx[:19] + 'Z'
        try: mxdt = datetime.datetime.fromisoformat(mx[:19])
        except Exception: mxdt = None
    if cutoff is not None and mxdt is not None and mxdt >= cutoff:
        continue                                          # had a genuine turn within the window -> not idle
    idle_field = str(int((now - mxdt).total_seconds() // 60)) if mxdt is not None else 'never'
    last_ts_field = (mx[:19] + 'Z') if mx else '-'
    if compact_mx is not None and (genuine_mx is None or compact_mx > genuine_mx):
        compacted = 'yes'
    elif ver_mx is not None and ver_mx >= MIN_COMPACT_AWARE_VERSION:
        compacted = 'no'
    else:
        compacted = 'unknown'
    rows.append((mxdt, state, cwd, prot, pid, rc, tm, idle_field, last_ts_field, compacted))
# oldest-first: 'never' (mxdt None) first, then ascending timestamp.
rows.sort(key=lambda r: (r[0] is not None, r[0] or datetime.datetime.min))

if TSV:
    for mxdt, state, cwd, prot, pid, rc, tm, idle_field, last_ts_field, compacted in rows:
        print('\t'.join([tm, rc, pid, cwd, idle_field, last_ts_field, prot, compacted]))
else:
    print('  %-22s %-5s %-46s %s' % ('LAST type:user', 'PROT', 'TMUX SESSION', 'CWD'))
    nprot = 0
    for mxdt, state, cwd, prot, pid, rc, tm, idle_field, last_ts_field, compacted in rows:
        if prot == 'yes': nprot += 1
        print('  %-22s %-5s %-46s %s' % (state[:22], ('[P]' if prot == 'yes' else ''), tm[:46], cwd))
    print('  --- %d idle session(s)%s. All are ALIVE -> reap-local will NOT touch them.' % (
          len(rows), (', incl. %d PROTECTED (never reap)' % nprot) if nprot else ''))
    print('  Report only. Reap an idle-but-alive one by hand:')
    print('    tmux kill-session -t <name> ; systemctl --user disable --now <name>.service')
" | {
      if [ "$TSV" = yes ]; then
        while IFS=$'\t' read -r tmux_session remote_name pid cwd idle_minutes last_ts prot compacted; do
          [ -n "$tmux_session" ] && [ -n "$cwd" ] || continue
          # Called directly (NOT via `$(...)`) so _TSV_STATUS_CACHE's writes
          # land in THIS while loop's own subshell and actually persist across
          # iterations — see _tsv_git_status's comment above for why a
          # command-substitution call site would silently defeat the cache.
          _tsv_git_status "$cwd"
          printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$tmux_session" "$remote_name" "$pid" "$cwd" "$idle_minutes" "$last_ts" "$prot" "$compacted" "$_TSV_LANDED" "$_TSV_DIRTY"
        done
      else
        cat
      fi
    }
    ;;

  reap-merged)
    # Auto-cleanup of finished sessions (the desktop app archives a session once its PR merges).
    # DRY-RUN unless --apply; --apply runs only the plain `reap` below, which re-audits. Rules: _reap_merged_check.
    [ "$APPLY" = yes ] && echo "=== reap-merged: APPLY (idle >= ${IDLE_MIN}m) ===" || echo "=== reap-merged: DRY-RUN, nothing changed (idle >= ${IDLE_MIN}m) ==="
    rm_cands=0; rm_fail=0
    while IFS= read -r rm_s; do
      [ -n "$rm_s" ] || continue
      _reap_merged_check "$rm_s"
      if [ "$RM_VERDICT" != candidate ]; then
        printf 'skipped    %s  %s\n' "$rm_s" "$RM_REASON"; continue
      fi
      rm_cands=$((rm_cands+1))
      if [ "$APPLY" != yes ]; then
        printf 'candidate  %s  %s\n' "$rm_s" "$RM_REASON"; continue
      fi
      if rm_out="$(bash "${BASH_SOURCE[0]}" reap "$rm_s" $AY_FLAG --outcome "${OUTCOME:-ok}" --outcome-note "$RM_REASON" 2>&1)"; then
        # reap soft-fails its worktree step (kept, not an error); surface that.
        printf 'reaped     %s  %s%s\n' "$rm_s" "$RM_REASON" "$(grep -iE -m1 'worktree.*(kept|refus)|kept' <<<"$rm_out" | sed -E 's/^ +/ -- /')"
      else
        rm_fail=$((rm_fail+1)); printf 'failed     %s  reap exited non-zero (%s)\n' "$rm_s" "$RM_REASON"
      fi
    done < <(live_tmux)
    echo "reap-merged: $rm_cands candidate(s)$([ "$APPLY" = yes ] && echo ", $rm_fail failed")"
    [ "$rm_fail" -eq 0 ]
    ;;

  reap)
    # One-shot teardown of a named ALIVE session (the live counterpart to reap-local). A missing tmux session or unit does not fail it.
    NAME="${1:?usage: session-doctor.sh reap <tmux-session> [--force]}"
    _is_protected "$NAME" && { echo "session-doctor: refusing to reap PROTECTED session '$NAME'" >&2; exit 2; }
    # Min-age gate (before any audit or mutation, also under --dry-run). --force does not bypass.
    if ! _reap_age_gate "$NAME"; then
      echo "session-doctor: REFUSING to reap '$NAME' — $REAP_AGE_MSG" >&2
      exit 1
    fi
    # Safety gate: refuse unlanded or uncommitted work unless --force, reusing session-preserve.sh's audit (exit 0 = safe).
    # If that helper cannot be found, fail SAFE.
    if [ "$FORCE" != yes ]; then
      SP="$(_find_helper session-preserve)" || {
        echo "session-doctor: REFUSING to reap '$NAME' — could not locate session-preserve to check for unlanded work (looked next to this script and on PATH). Re-run with --force to skip the safety check." >&2
        exit 1
      }
      if ! bash "$SP" "$NAME"; then
        echo "" >&2
        echo "REFUSING to reap '$NAME': unlanded/uncommitted work detected (see session-preserve output above)." >&2
        echo "  Rescue first: session-preserve $NAME --rescue --wip   (then re-run reap)" >&2
        echo "  Or force through data loss: session-doctor reap $NAME --force" >&2
        exit 1
      fi
    fi
    base="$(tmux_to_base "$NAME")"
    if [ -n "$base" ] && ! _reap_safe_base "$base"; then
      echo "session-doctor: refusing to reap '$NAME' — unsafe derived session base '$base'" >&2
      exit 2
    fi
    # --dry-run runs every refusal above, then previews the teardown and stops before the first mutation. No registry call.
    if [ "$DRY_RUN" = yes ]; then
      echo "(DRY-RUN — nothing changed; re-run without --dry-run to reap)"
      if tmux has-session -t "=$NAME" 2>/dev/null; then
        echo "  would kill tmux session: $NAME"
      else
        echo "  no live tmux session '$NAME' (ok)"
      fi
      if [ -n "$base" ]; then
        echo "  would disable ${base}.service and archive its unit/start-script files"
        [ "$KEEP_REGISTRY" = yes ] || echo "  would delete the registry entry titled '$base', if any"
        if [ "$KEEP_WORKTREE" != yes ]; then
          dry_wt="$(_wt_resolve_for_base "$base")"
          if [ -n "$dry_wt" ] && [ -d "$dry_wt" ]; then
            echo "  would remove worktree (branch kept, subject to reap's worktree guards): $dry_wt"
          else
            echo "  worktree: none found for '$base' (ok)"
          fi
        fi
      else
        echo "  '$NAME' does not match a recognised session prefix (${_crss_prefix_re}) — no systemd unit to tear down" >&2
      fi
      echo "would-reap '$NAME'"
      exit 0
    fi
    torn=no
    if [ -n "$base" ] && { [ -f "${UD:-/nonexistent}/${base}.service" ] || [ -f "${BIN:-/nonexistent}/${base}-start.sh" ]; }; then torn=yes; fi
    tmux kill-session -t "=$NAME" 2>/dev/null \
      && { torn=yes; echo "  tmux session killed: $NAME"; } || echo "  no live tmux session '$NAME' (ok)"
    if [ -n "$base" ]; then
      _REAP_ARCHIVE_DIR=""
      systemctl --user disable --now "${base}.service" >/dev/null 2>&1 \
        && { torn=yes; echo "  unit disabled: ${base}.service"; } || echo "  unit '${base}.service' not active/installed (ok)"
      systemctl --user reset-failed "${base}.service" >/dev/null 2>&1 || true
      _reap_archive_unit_files "$base"
    else
      echo "  '$NAME' does not match a recognised session prefix (${_crss_prefix_re}) — no systemd unit to tear down" >&2
    fi
    echo "reaped '$NAME'"
    [ "$torn" = yes ] && _record_reap_event "${base:-$NAME}" "$FORCE" "$([ "$FORCE" = yes ] && echo unknown || echo yes)"
    # Registry cleanup: delete this session's entry (matched by title == base name) unless --keep-registry.
    # Fails soft: an unreachable registry prints a note and never changes reap's exit status.
    if [ "$KEEP_REGISTRY" != yes ] && [ -n "$base" ]; then
      if reg_json=$(registry_json); then
        match_id=$(printf '%s' "$reg_json" | python3 -c "
import sys,json
try:
    arr=json.load(sys.stdin)
except Exception:
    sys.exit(1)
arr=arr if isinstance(arr,list) else arr.get('sessions',arr.get('data',[]))
target=sys.argv[1]
for s in arr:
    if (s.get('title') or '')==target:
        print(s.get('id')); break
" "$base" 2>/dev/null)
        if [ -n "$match_id" ]; then
          _registry_delete_one "$match_id" "$base"
        else
          echo "  registry: no entry found for '$base' (ok)"
        fi
      else
        echo "  registry: unreachable — leaving any registry entry for '$base' in place (reap still counts as done)" >&2
      fi
    fi
    # Worktree cleanup: remove this session's ~/.claude/worktrees/<base> unless --keep-worktree (guards in _reap_remove_worktree).
    if [ "$KEEP_WORKTREE" != yes ] && [ -n "$base" ]; then
      _reap_remove_worktree "$base" "$FORCE"
    fi
    ;;

  archive-ignored)
    # Explicit form of the archive step `reap` runs before removing a worktree (_wt_archive_ignored). Never touches the worktree.
    # Exit 0 = archived or nothing to archive; 1 = not archived, so the `&&` in a worktree-stale remove line keeps the worktree.
    AWT="${1:?usage: session-doctor.sh archive-ignored <worktree>}"
    if [ ! -d "$AWT" ] || [ "$(git -C "$AWT" rev-parse --show-toplevel 2>/dev/null)" != "$(cd "$AWT" && pwd -P)" ]; then
      echo "session-doctor: '$AWT' is not the top of a git worktree" >&2
      exit 2
    fi
    if ! _wt_archive_ignored "$AWT"; then
      echo "session-doctor: NOT archived — $_WTI_ERR" >&2
      exit 1
    fi
    [ -n "$_WTI_ARCHIVE" ] || echo "  no gitignored payload to archive (only regenerable/scaffold paths, if any): $AWT"
    ;;

  land-check)
    # Report-only: audits EVERY worktree, live owner or not. A "will I lose this?" check, not a cleanup list (see worktree-stale).
    echo "=== ~/.claude/worktrees/ land-check: unlanded-vs-correct-base + real-dirty (report-only) ==="
    WT_BASE="$HOME/.claude/worktrees"
    n=0
    for wt in "$WT_BASE"/*/; do
      [ -d "$wt" ] || continue
      wt="${wt%/}"
      n=$((n+1))
      branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
      dirty="$(_wt_dirty "$wt")"
      mainrepo="$(_wt_mainrepo "$wt")"
      landedinfo="base=? landed=unknown"
      [ -n "$mainrepo" ] && landedinfo="$(_wt_landed "$wt" "$mainrepo")"
      printf '  %-60s branch=%-30s status=%-6s %s\n' "$wt" "$branch" "$dirty" "$landedinfo"
    done
    echo "  --- $n worktree(s) checked. Report only; see worktree-stale for removal candidates + commands. ---"
    ;;

  history)
    # Report-only: for each match, NOW (live sessions), PAST (transcript history) and a worktree-status footer.
    # WT_BASE and PROJ_BASE come from $HOME like every other mode, so tests can sandbox it with HOME.
    NAME="${1:?usage: session-doctor.sh history <foldername|path|repo-substring>}"
    WT_BASE="$HOME/.claude/worktrees"
    PROJ_BASE="$HOME/.claude/projects"
    mapfile -t MATCHES < <(_history_matches "$NAME" "$WT_BASE" "$PROJ_BASE")
    if [ "${#MATCHES[@]}" -eq 0 ]; then
      echo "session-doctor: no worktree matches '$NAME' under $WT_BASE (checked live worktree dirs, transcript history, and repo-name substrings)" >&2
      exit 2
    fi
    echo "=== history: ${#MATCHES[@]} worktree(s) matching '$NAME' ==="
    for wt in "${MATCHES[@]}"; do
      _history_report "$wt" "$PROJ_BASE"
      _history_footer "$wt"
    done
    ;;
  *) echo "usage: session-doctor.sh [report|auth-scan [--days N]|opus-subagents [--days N]|suggest-feeders|auth-heal [--apply] [--days N]|reap-local|reap <name> [--force] [--keep-registry] [--keep-worktree]|reap-merged [--apply] [--idle-min N] [--outcome ok]|registry-stale [--days N]|registry-prune [--days N] [--apply]|worktree-stale|archive-ignored <worktree>|land-check|idle-report [--days N|--minutes N] [--tsv]|history <foldername>]" >&2; exit 2;;
esac
fi
