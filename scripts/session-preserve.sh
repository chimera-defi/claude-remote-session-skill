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

RESCUE_ROOT="$HOME/.sessions/rescued-$(date +%Y-%m-%d)"
# Junk that every session regenerates — never worth rescuing or blocking a reap.
JUNK_RE='(^|/)(\.claude/skills|\.claude/token-reduce-state|\.claude/tmp-briefs|\.superpowers|__pycache__|\.pytest_cache|node_modules|\.venv|\.gstack)(/|$)'
# CRSS_JUNK_RE_EXTRA (default empty — today's behaviour is unchanged) appends
# host-specific extra scaffolding patterns without touching the base list
# above. session-doctor.sh's _WT_IGNORED_DENY_RE takes the SAME env var,
# appended the same way — but the two BASE lists are not identical
# (pre-existing drift, see CLAUDE.md's "cruft pass" note); this only keeps
# the ADDITIVE suffix in sync, it does not reconcile the bases.
if [ -n "${CRSS_JUNK_RE_EXTRA:-}" ]; then
  # An invalid extra pattern would break the whole combined regex; drop it (built-in list still applies).
  _crss_rc=0; grep -qE -- "$CRSS_JUNK_RE_EXTRA" </dev/null 2>/dev/null || _crss_rc=$?
  if [ "$_crss_rc" -le 1 ]; then
    JUNK_RE="${JUNK_RE}|${CRSS_JUNK_RE_EXTRA}"
  else
    echo "$(basename "$0"): ignoring invalid CRSS_JUNK_RE_EXTRA regex ('$CRSS_JUNK_RE_EXTRA')" >&2
  fi
fi
# The spawner's own untracked .sessions-init-<remote> sentinel (see
# new-session.sh), which sits at the worktree ROOT for the life of every
# session — session-git-prep.sh and session-doctor.sh's _wt_dirty already
# ignore it when deciding clean/DIRTY; without an exclusion here, EVERY live
# session audited without --rescue was misreported NOT-SAFE-TO-REAP on that
# sentinel alone, defeating the audit for the common case (found in review,
# PR #76). Kept as its own whole-path anchor, NOT folded into JUNK_RE's
# (^|/)...(/|$) group: that group matches a component at any depth, so it
# would also swallow real work like a nested docs/.sessions-init-notes file
# or anything inside a .sessions-init-output/ directory (caught by Codex
# review on PR #77) — the real sentinel is always a single root-level file.
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

# tmux_to_base <tmux-session> -> worktree/systemd-unit base name, or "" if
# not one of ours. Mirrors session-doctor.sh's tmux_to_base exactly (same
# name, same logic — kept as a local copy rather than sourced, matching how
# every script in this repo is a standalone deployable file): the first "_"
# after the recognised prefix ($_crss_prefix_re — the configured
# CRSS_SESSION_PREFIX or a CRSS_LEGACY_PREFIXES entry) becomes "-".
# <prefix>_hh-0717-0224 -> <prefix>-hh-0717-0224. Any later "_" in the
# slug is left alone.
tmux_to_base() {
  if [[ "$1" =~ ^(${_crss_prefix_re})_(.*)$ ]]; then
    echo "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"
  else
    echo ""
  fi
}

# worktree_of <tmux-session> -> best-guess worktree dir on disk, used when
# rundir_of() can't find a live process to ask. Scans every dir under the
# worktrees root ONCE, preferring a BRANCH match (session/<base>) over a
# dirname match, not the reverse:
#
# session-git-prep.sh suffixes the worktree DIRECTORY with -$$ on a name
# collision while leaving the branch (session/<base>) unsuffixed (see
# session-doctor.sh worktree-stale, which special-cases this the same way).
# So on a collision, TWO dirs can exist for the same <base> — the original
# $dir/$base (left behind on whatever branch it happened to be on, possibly
# clean) and the real, suffixed $dir/$base-<pid> (on session/<base>, possibly
# dirty). Trusting the dirname hit first would silently audit the WRONG one
# and report the real, dirty worktree as untouched — the exact fail-open
# class this whole fix exists to close. The branch is therefore checked
# first and wins immediately; a dirname match is only used as a fallback if
# no directory anywhere under the root carries that branch.
#
# There is no fixed list of "known main repos" in this codebase to run
# `git worktree list` against from the other side; asking each worktree for
# its own branch is the same authoritative signal without needing one.
# Prints nothing and returns 1 if neither lookup finds a directory.
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

audit_one() {
  local s="$1" cwd br nremote local_only unreach dirty untracked reasons via
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

  # What actually decides reap safety: is HEAD reachable from a named branch?
  # If yes, removing the worktree/tmux session cannot orphan the commits.
  if git -C "$cwd" for-each-ref --format='%(refname:short)' refs/heads \
       | while read -r b; do git -C "$cwd" merge-base --is-ancestor HEAD "refs/heads/$b" 2>/dev/null && echo hit && break; done | grep -q hit; then
    unreach=no
  else
    unreach=yes
  fi
  echo "   HEAD reachable from a named local branch: $([ "$unreach" = no ] && echo yes || echo 'NO')"

  dirty=$(git -C "$cwd" diff --name-only HEAD 2>/dev/null | grep -vE "$JUNK_RE" | wc -l)
  untracked=$(git -C "$cwd" ls-files --others --exclude-standard 2>/dev/null | grep -vE "$JUNK_RE" | grep -vE "$SENTINEL_RE" | wc -l)
  echo "   uncommitted TRACKED changes (non-junk): $dirty"
  echo "   untracked files (non-junk): $untracked"
  [ "$untracked" -gt 0 ] && git -C "$cwd" ls-files --others --exclude-standard 2>/dev/null \
      | grep -vE "$JUNK_RE" | grep -vE "$SENTINEL_RE" | head -10 | sed 's/^/       /'

  if [ "$MODE_WIP" = yes ] && [ "$dirty" -gt 0 ]; then
    # Stage exactly the paths counted as "dirty" above (git diff --name-only
    # HEAD, filtered by the SAME $JUNK_RE) — not `git add -A`. -A also picks up
    # any new untracked file (only .claude/skills was ever excluded from it),
    # so a tracked-but-JUNK_RE-matched path (e.g. a committed node_modules/ or
    # .venv/ file, unusual but real for vendored deps) that was modified would
    # get silently staged and WIP-committed even though the audit above never
    # counted it as dirty and told the operator it wasn't there. Building the
    # add list from the identical filtered diff guarantees the commit can
    # never contain more than what was actually reported.
    mapfile -t wip_files < <(git -C "$cwd" diff --name-only HEAD 2>/dev/null | grep -vE "$JUNK_RE")
    [ "${#wip_files[@]}" -gt 0 ] && git -C "$cwd" add -- "${wip_files[@]}" 2>/dev/null
    # Only clear `dirty` when the commit actually lands. A failed commit (no
    # git identity configured, a rejecting pre-commit hook, GPG signing
    # misconfigured, ...) must fall through to NOT-SAFE-TO-REAP below —
    # otherwise the printed "do not reap" warning is immediately contradicted
    # by a SAFE-TO-REAP verdict a few lines later.
    if git -C "$cwd" commit -q -m "wip(session-preserve): checkpoint before reaping $s" 2>/dev/null; then
      echo "   WIP committed on $br"
      dirty=0
    else
      echo "   WIP commit FAILED — do not reap"
    fi
  fi

  if [ "$MODE_RESCUE" = yes ] && [ "$untracked" -gt 0 ]; then
    # Preserve the relative path under the session's own subdir instead of
    # flattening it (old: tr '/' '_' into one shared directory) — two distinct
    # untracked paths that flatten to the same string (e.g. src/util.txt and
    # src_util.txt) would otherwise collide on one filename, and the second
    # cp -f silently overwrites the first while both still print "rescued".
    #
    # A path component can itself collide across two rescues of the SAME
    # session on the SAME day (one $RESCUE_ROOT): if untracked "foo" (a file)
    # was rescued earlier and "foo" later becomes a directory containing an
    # untracked "foo/bar", `mkdir -p .../foo` fails because "foo" already
    # exists there as a plain file — so the rescue for "foo/bar" cannot land.
    # Track that per-file so `untracked` is only cleared when every rescue
    # actually succeeded; otherwise the audit must keep reporting
    # NOT-SAFE-TO-REAP instead of a false SAFE-TO-REAP over a lost file.
    # (`< <(...)` process substitution, not a `| while` pipe, so
    # rescue_failed set inside the loop is visible after it — a pipe would
    # run the loop in a subshell and silently drop that state.)
    rescue_failed=0
    while read -r rel; do
      dest="$RESCUE_ROOT/$s/$rel"
      if mkdir -p "$(dirname "$dest")" 2>/dev/null && cp -f "$cwd/$rel" "$dest" 2>/dev/null; then
        echo "   rescued: $rel"
      else
        echo "   RESCUE FAILED: $rel (path conflict with an earlier rescue?)" >&2
        rescue_failed=1
      fi
    done < <(git -C "$cwd" ls-files --others --exclude-standard 2>/dev/null | grep -vE "$JUNK_RE" | grep -vE "$SENTINEL_RE")
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
