#!/usr/bin/env bash
# session-preserve — verify a session's work is durable BEFORE reaping it.
#
# Usage:
#   session-preserve <tmux-session>            # audit only (default). exit 0 = safe to reap
#   session-preserve <tmux-session> --rescue   # + copy non-junk untracked files to a rescue dir
#   session-preserve <tmux-session> --wip      # + commit uncommitted TRACKED changes as a WIP commit
#   session-preserve --all                     # audit every live session (recognised prefix)
#
# WHY THIS EXISTS: a reap sweep was nearly run against a fleet
# audited with `git log @{u}..`, which returns NOTHING when a branch has no
# upstream configured — so thousands of local-only commits were reported as "0
# unpushed". Never use @{u} for this. Use `git log HEAD --not --remotes`, and
# treat "repo has no remote at all" as its own finding.
#
# FAIL-OPEN FIX: when rundir_of() fails (no tmux session, no live
# claude proc under it — the COMMON case when reaping DEAD sessions, not an
# edge case) this used to print "SAFE-TO-REAP (nothing to preserve)" and exit
# 0. That verdict was inferred from the PROCESS being gone, not from the
# WORKTREE being clean, and destroyed real work (an orphaned
# worktree carrying hundreds of uncommitted/untracked lines audited as "nothing to
# preserve"). Now falls back to worktree_of(), which locates the session's
# worktree on disk from its tmux name and runs the SAME audit against it
# (dirty/untracked/reachability, same as a live session). Only when no
# worktree can be found either is it genuinely safe — reported under a
# distinct string ("no rundir and no worktree found") so that case can never
# be mistaken for an audited, actually-clean worktree.
set -uo pipefail

# Parses (never sources) $CRSS_HOME/config.sh; env vars win. Copied verbatim into every script
# that reads it (tests/test-crss-overlay-config.sh).
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

# CRSS_SESSION_PREFIX names NEW sessions (default "cs"); CRSS_LEGACY_PREFIXES are extra prefixes
# recognised when parsing, never generated. Each token must match ^[a-z][a-z0-9]{0,15}$. An invalid
# prefix falls back to the default; ANY invalid legacy token drops the WHOLE list, never to an empty
# pattern (that would match everything on a reap path). Copied verbatim into each script that needs it.
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

RESCUE_ROOT="$HOME/.sessions/rescued-$(date +%Y-%m-%d)"
# Junk that every session regenerates — never worth rescuing or blocking a reap.
JUNK_RE='(^|/)(\.claude/skills|\.claude/token-reduce-state|\.claude/tmp-briefs|\.superpowers|__pycache__|\.pytest_cache|node_modules|\.venv|\.gstack)(/|$)'
# CRSS_JUNK_RE_EXTRA appends host patterns. session-doctor.sh takes the same var; the base lists
# differ (known drift), so only the additive suffix is kept in sync.
if [ -n "${CRSS_JUNK_RE_EXTRA:-}" ]; then
  # An invalid extra pattern would break the whole combined regex; drop it (built-in list still applies).
  _crss_rc=0; grep -qE -- "$CRSS_JUNK_RE_EXTRA" </dev/null 2>/dev/null || _crss_rc=$?
  if [ "$_crss_rc" -le 1 ]; then
    JUNK_RE="${JUNK_RE}|${CRSS_JUNK_RE_EXTRA}"
  else
    echo "$(basename "$0"): ignoring invalid CRSS_JUNK_RE_EXTRA regex ('$CRSS_JUNK_RE_EXTRA')" >&2
  fi
fi
# The spawner's .sessions-init-<remote> sentinel sits at the worktree root for a session's life and
# is never real work. Anchored to the root only: a nested match would hide real files.
SENTINEL_RE='^\.sessions-init-[^/]*$'

MODE_RESCUE=no; MODE_WIP=no; TARGET=""; ALL=no
while [ $# -gt 0 ]; do
  case "$1" in
    --rescue) MODE_RESCUE=yes; shift ;;
    --wip)    MODE_WIP=yes; shift ;;
    --all)    ALL=yes; shift ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) TARGET="$1"; shift ;;
  esac
done

rundir_of() {  # $1 = tmux session -> cwd of the claude process
  local pid cpid
  pid=$(tmux list-panes -t "$1" -F '#{pane_pid}' 2>/dev/null | head -1) || return 1
  [ -n "$pid" ] || return 1
  cpid=$(pgrep -P "$pid" 2>/dev/null | head -1)
  [ -n "$cpid" ] || return 1
  readlink "/proc/$cpid/cwd" 2>/dev/null
}

# tmux_to_base: <prefix>_slug -> <prefix>-slug (first "_" becomes "-"), or "" when not ours.
# Mirrors session-doctor.sh; a local copy, because each script here is standalone.
tmux_to_base() {
  if [[ "$1" =~ ^(${_crss_prefix_re})_(.*)$ ]]; then
    echo "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"
  else
    echo ""
  fi
}

# worktree_of <tmux-session>: best guess at the worktree on disk when no live process is found.
# A branch match (session/<base>) wins over a dirname match: a name collision leaves a stale dir
# beside the real -$$ one, and trusting the dirname would audit the wrong, possibly clean, one.
# Prints nothing and returns 1 when neither matches.
worktree_of() {
  local sess="$1" base dir wt branch fallback=""
  base="$(tmux_to_base "$sess")"
  [ -n "$base" ] || return 1
  dir="${WORKTREES_BASE:-$HOME/.claude/worktrees}"
  [ -d "$dir" ] || return 1
  for wt in "$dir"/*/; do
    [ -d "$wt" ] || continue
    wt="${wt%/}"
    branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" || true
    if [ "$branch" = "session/$base" ]; then printf '%s' "$wt"; return 0; fi
    [ -z "$fallback" ] && [ "$(basename "$wt")" = "$base" ] && fallback="$wt"
  done
  [ -n "$fallback" ] && { printf '%s' "$fallback"; return 0; }
  return 1
}

# True when a byte-identical copy of untracked file $3 (of session $1, in
# worktree $2) already exists under any $HOME/.sessions/rescued-*/$1/ dir.
_already_rescued() {
  local s="$1" cwd="$2" rel="$3" d
  for d in "$HOME"/.sessions/rescued-*/"$s"/"$rel"; do
# A symlink is never already rescued: cp/cmp dereference it.
    [ -L "$cwd/$rel" ] && return 1
    [ -f "$d" ] && cmp -s "$cwd/$rel" "$d" && return 0
  done
  return 1
}

audit_one() {
  local s="$1" cwd br nremote local_only unreach brs b dirty untracked unrescued reasons via
  cwd=$(rundir_of "$s")
  via=""
  if [ -z "$cwd" ]; then
    cwd=$(worktree_of "$s")
    [ -n "$cwd" ] && via=" (proc gone; located via worktree lookup)"
  fi
  echo "### $s"
  if [ -z "$cwd" ]; then
    echo "   rundir: UNKNOWN (proc gone) — verdict: SAFE-TO-REAP (no rundir and no worktree found)"
    return 0
  fi
  echo "   rundir: $cwd$via"
  if ! git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
    echo "   (not a git repo) — verdict: SAFE-TO-REAP"; return 0
  fi

  br=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
  nremote=$(git -C "$cwd" remote 2>/dev/null | wc -l)
  echo "   branch: $br"
  echo "   remotes configured: $nremote"

  # Correct local-only count. NOT @{u}.. — that is silent without an upstream.
  local_only=$(git -C "$cwd" log --oneline HEAD --not --remotes 2>/dev/null | wc -l)
  echo "   commits not on any remote: $local_only"
  if [ "$nremote" -eq 0 ]; then
    echo "   ^^ repo has NO REMOTE — these commits exist ONLY on this disk. Pushing is impossible"
    echo "      until a remote is added; the local branch ref IS the only copy."
  fi

# Reap safety: HEAD must be reachable from a named local branch. Only merge-base status 0 proves it;
# a failed listing counts as unreachable.
  unreach=yes
  if brs="$(git -C "$cwd" for-each-ref --format='%(refname:short)' refs/heads && printf x)"; then
    brs=${brs%x}
    if [ -n "$brs" ]; then
      while read -r b; do
        if git -C "$cwd" merge-base --is-ancestor HEAD "refs/heads/$b" 2>/dev/null; then unreach=no; break; fi
      done <<<"${brs%$'\n'}"
    fi
  fi
  echo "   HEAD reachable from a named local branch: $([ "$unreach" = no ] && echo yes || echo 'NO')"

  dirty=$(git -C "$cwd" diff --name-only HEAD 2>/dev/null | grep -vE "$JUNK_RE" | wc -l)
  untracked=$(git -C "$cwd" ls-files --others --exclude-standard 2>/dev/null | grep -vE "$JUNK_RE" | grep -vE "$SENTINEL_RE" | wc -l)
# A byte-identical copy already in a rescued-* dir counts as saved; otherwise re-audits flag it
# again and --force becomes the only exit.
  unrescued=$(git -C "$cwd" ls-files --others --exclude-standard 2>/dev/null | grep -vE "$JUNK_RE" | grep -vE "$SENTINEL_RE" \
      | while read -r rel; do _already_rescued "$s" "$cwd" "$rel" || echo "$rel"; done)
  untracked=$(printf '%s' "$unrescued" | grep -c .)
  echo "   uncommitted TRACKED changes (non-junk): $dirty"
  echo "   untracked files (non-junk): $untracked"
  [ "$untracked" -gt 0 ] && printf '%s\n' "$unrescued" | head -10 | sed 's/^/       /'

  if [ "$MODE_WIP" = yes ] && [ "$dirty" -gt 0 ]; then
# --wip stages exactly the paths counted as dirty (same JUNK_RE filter), never git add -A,
# so the commit cannot exceed what was reported.
    mapfile -t wip_files < <(git -C "$cwd" diff --name-only HEAD 2>/dev/null | grep -vE "$JUNK_RE")
    [ "${#wip_files[@]}" -gt 0 ] && git -C "$cwd" add -- "${wip_files[@]}" 2>/dev/null
# Clear dirty only when the commit lands; a failed commit must stay NOT-SAFE-TO-REAP.
    if git -C "$cwd" commit -q -m "wip(session-preserve): checkpoint before reaping $s" 2>/dev/null; then
      echo "   WIP committed on $br"
      dirty=0
    else
      echo "   WIP commit FAILED — do not reap"
    fi
  fi

  if [ "$MODE_RESCUE" = yes ] && [ "$untracked" -gt 0 ]; then
    # Keep the relative path under the session's own subdir: flattening collides (src/util.txt vs src_util.txt).
    # A path component can clash with an earlier rescue (file, then dir), so count a file saved only when
    # every rescue succeeds. Process substitution, not a pipe, keeps rescue_failed visible after the loop.
    rescue_failed=0
    while read -r rel; do
      dest="$RESCUE_ROOT/$s/$rel"
      if mkdir -p "$(dirname "$dest")" 2>/dev/null && cp -f "$cwd/$rel" "$dest" 2>/dev/null; then
        echo "   rescued: $rel"
      else
        echo "   RESCUE FAILED: $rel (path conflict with an earlier rescue?)" >&2
        rescue_failed=1
      fi
    done < <(printf '%s\n' "$unrescued")
    [ "$rescue_failed" -eq 0 ] && untracked=0
  fi

  reasons=""
  [ "$unreach"   = yes ] && reasons="$reasons HEAD-not-on-a-branch"
  [ "$dirty"     -gt 0 ] && reasons="$reasons uncommitted-tracked-changes"
  [ "$untracked" -gt 0 ] && reasons="$reasons untracked-files"
  if [ -n "$reasons" ]; then
    echo "   VERDICT: NOT-SAFE-TO-REAP —$reasons"
    echo "            re-run with --wip and/or --rescue, then re-audit."
    return 1
  fi
  echo "   VERDICT: SAFE-TO-REAP (work is on branch '$br'; NEVER delete that branch)"
  return 0
}

if [ "$ALL" = yes ]; then
  rc=0
  for s in $(tmux ls -F '#{session_name}' 2>/dev/null | grep -E "^(${_crss_prefix_re})_" | sort); do
    audit_one "$s" || rc=1; echo
  done
  exit $rc
fi

[ -n "$TARGET" ] || { echo "usage: session-preserve <tmux-session> [--rescue] [--wip] | --all" >&2; exit 2; }
audit_one "$TARGET"
