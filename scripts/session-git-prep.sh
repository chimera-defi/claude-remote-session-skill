#!/usr/bin/env bash
# session-git-prep <repo> <tmux_session> <remote_name>
#
# Decides WHERE a spawned Claude session should run when the target is a git
# repo, so sessions start from the default branch instead of whatever branch
# happened to be checked out, and parallel sessions on the same repo never
# collide:
#
#   free + clean canonical tree -> put it on the default branch, run there
#   dirty OR already owned       -> run in a fresh per-session worktree
#                                   branched from the default branch
#
# Prints the chosen run directory to stdout (and nothing else). All diagnostics
# go to stderr. This never fails the spawn: on any problem it falls back to the
# canonical repo path so the session still starts.
set -u

REPO="${1:?usage: session-git-prep <repo> <tmux_session> <remote_name>}"
SESS="${2:-}"
REMOTE="${3:-session-$(date +%s)}"

log()  { echo "[session-git-prep] $*" >&2; }
emit() { printf '%s\n' "$1"; exit 0; }

# Not a git repo -> run in place (legacy behaviour).
if ! git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  emit "$REPO"
fi

# Does this repo have an 'origin' remote?
if git -C "$REPO" remote get-url origin >/dev/null 2>&1; then
  HAS_ORIGIN=1
else
  HAS_ORIGIN=0
fi

# Resolve the default branch: origin/HEAD -> main -> master -> current HEAD.
DEF=""
if [ "$HAS_ORIGIN" = 1 ]; then
  DEF=$(git -C "$REPO" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null \
        | sed 's@^refs/remotes/origin/@@')
fi
if [ -z "$DEF" ]; then
  if   git -C "$REPO" show-ref --verify --quiet refs/heads/main;   then DEF=main
  elif git -C "$REPO" show-ref --verify --quiet refs/heads/master; then DEF=master
  else DEF=$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
  fi
fi

# Best-effort refresh and pick the base ref (latest default branch).
BASE="$DEF"
if [ "$HAS_ORIGIN" = 1 ]; then
  git -C "$REPO" fetch --quiet origin "$DEF" 2>/dev/null || true
  if git -C "$REPO" rev-parse --verify --quiet "origin/$DEF" >/dev/null 2>&1; then
    BASE="origin/$DEF"
  fi
fi

# Dirty? Ignore the spawn skill's own housekeeping (.claude/ skills symlink and
# bootstrap edits, .sessions-init-* sentinels) so it never looks like real
# uncommitted work.
DIRTY=""
if git -C "$REPO" status --porcelain 2>/dev/null \
     | grep -qvE '^.. (\.claude(/|$)|\.sessions-init)'; then
  DIRTY=1
fi

# Busy? Is the canonical tree currently owned by a live session? The owner lock
# lives OUTSIDE the repo so claiming it never dirties the working tree.
LOCK_DIR="$HOME/.claude/session-locks"
mkdir -p "$LOCK_DIR" 2>/dev/null || true
LOCK_KEY=$(printf '%s' "$REPO" | tr '/ ' '__')
LOCK="$LOCK_DIR/${LOCK_KEY}.owner"
BUSY=""
if [ -f "$LOCK" ]; then
  OWNER=$(cat "$LOCK" 2>/dev/null)
  if [ -n "$OWNER" ] && tmux has-session -t "$OWNER" 2>/dev/null; then
    BUSY=1
  else
    rm -f "$LOCK" 2>/dev/null || true   # stale lock from a dead session
  fi
fi

# --- Decision -------------------------------------------------------------
if [ -z "$DIRTY" ] && [ -z "$BUSY" ]; then
  # Canonical tree is free + clean: land it on the default branch and claim it.
  CUR=$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [ "$CUR" != "$DEF" ]; then
    git -C "$REPO" checkout --quiet "$DEF" 2>/dev/null \
      || log "could not checkout '$DEF'; leaving canonical on '$CUR'"
  fi
  if [ "$HAS_ORIGIN" = 1 ]; then
    git -C "$REPO" merge --ff-only --quiet "origin/$DEF" 2>/dev/null \
      || log "ff-merge origin/$DEF skipped (diverged or offline)"
  fi
  printf '%s\n' "$SESS" > "$LOCK" 2>/dev/null || true
  log "canonical tree on '$DEF', claimed by '$SESS' -> $REPO"
  emit "$REPO"
fi

# Dirty or busy: isolate this session in its own worktree from the base ref.
WT_BASE="$HOME/.claude/worktrees"
mkdir -p "$WT_BASE" 2>/dev/null || true
WT="$WT_BASE/$REMOTE"
[ -e "$WT" ] && WT="$WT_BASE/${REMOTE}-$$"   # belt-and-suspenders; REMOTE is timestamped
BR="session/$REMOTE"
REASON="dirty=$([ -n "$DIRTY" ] && echo yes || echo no) busy=$([ -n "$BUSY" ] && echo yes || echo no)"

if git -C "$REPO" worktree add --quiet -b "$BR" "$WT" "$BASE" 2>/dev/null; then
  log "canonical unavailable ($REASON); isolated worktree on '$BR' from '$BASE' -> $WT"
  emit "$WT"
fi

# Worktree add failed — the branch/dir may already exist from a prior run.
# 1. If $WT already is a valid worktree of this repo, reuse it.
if [ -d "$WT" ] && git -C "$REPO" worktree list --porcelain 2>/dev/null | grep -qF "worktree $WT"; then
  log "worktree at $WT already registered; reusing -> $WT"
  emit "$WT"
fi
# 2. Retry once with a unique suffix so a second session doesn't collide.
WT2="$WT_BASE/${REMOTE}-$$"
BR2="session/${REMOTE}-$$"
if git -C "$REPO" worktree add --quiet -b "$BR2" "$WT2" "$BASE" 2>/dev/null; then
  log "retry worktree on '$BR2' from '$BASE' -> $WT2"
  emit "$WT2"
fi

# Last resort: don't block the spawn.
log "worktree add failed ($REASON); falling back to canonical as-is -> $REPO"
emit "$REPO"
