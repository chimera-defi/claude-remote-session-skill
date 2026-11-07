#!/usr/bin/env bash
# session-git-prep <repo> <tmux_session> <remote_name>
#
# Picks the run dir for a spawned session when the target is a git repo:
#   free + clean canonical tree -> check out the default branch there and claim it
#   dirty or owned             -> a fresh worktree from the default branch
# Prints only the run dir on stdout. Never fails the spawn: any problem falls back to the repo path.
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

# Ignore the skill's own housekeeping (.claude/ symlink, .sessions-init-* sentinels).
DIRTY=""
if git -C "$REPO" status --porcelain 2>/dev/null \
     | grep -qvE '^.. (\.claude(/|$)|\.sessions-init)'; then
  DIRTY=1
fi

# Owner lock lives outside the repo, so claiming it never dirties the tree.
LOCK_DIR="$HOME/.claude/session-locks"
mkdir -p "$LOCK_DIR" 2>/dev/null || true
# Key = flattened path + cksum: tr alone is not injective (/a/b_c and /a/b/c collide).
FLAT_KEY="$(printf '%s' "$REPO" | tr '/ ' '__')"
LOCK_KEY="${FLAT_KEY}_$(printf '%s' "$REPO" | cksum | cut -d' ' -f1)"
LOCK="$LOCK_DIR/${LOCK_KEY}.owner"
BUSY=""
check_lock() {  # $1 = lock file -> 0 (busy, live owner) or 1 (free; removes a stale lock)
  local f="$1" owner
  [ -f "$f" ] || return 1
  owner=$(cat "$f" 2>/dev/null)
  if [ -n "$owner" ] && tmux has-session -t "$owner" 2>/dev/null; then
    return 0
  fi
  rm -f "$f" 2>/dev/null || true   # stale lock from a dead session
  return 1
}
if check_lock "$LOCK"; then
  BUSY=1
fi

# --- Decision -------------------------------------------------------------
WT_BASE="$HOME/.claude/worktrees"
mkdir -p "$WT_BASE" 2>/dev/null || true
WT="$WT_BASE/$REMOTE"
BR="session/$REMOTE"

# REMOTE is stable across restarts of one session, so a worktree registered at $WT is that session's own.
# Reuse it first: a restart in the canonical tree loses its transcript dir (--continue and
# session-resume find nothing), and a -$$ suffix would orphan uncommitted work.
if [ -d "$WT" ] && git -C "$REPO" worktree list --porcelain 2>/dev/null | grep -qxF "worktree $WT"; then
  log "worktree at $WT already registered (prior run of '$REMOTE'); reusing -> $WT"
  emit "$WT"
fi
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
REASON="dirty=$([ -n "$DIRTY" ] && echo yes || echo no) busy=$([ -n "$BUSY" ] && echo yes || echo no)"

[ -e "$WT" ] && WT="$WT_BASE/${REMOTE}-$$"   # belt-and-suspenders: path exists but isn't a worktree of this repo

if git -C "$REPO" worktree add --quiet -b "$BR" "$WT" "$BASE" 2>/dev/null; then
  log "canonical unavailable ($REASON); isolated worktree on '$BR' from '$BASE' -> $WT"
  emit "$WT"
fi

# Add failed (e.g. the branch exists): retry once with a unique suffix.
WT2="$WT_BASE/${REMOTE}-$$"
BR2="session/${REMOTE}-$$"
if git -C "$REPO" worktree add --quiet -b "$BR2" "$WT2" "$BASE" 2>/dev/null; then
  log "retry worktree on '$BR2' from '$BASE' -> $WT2"
  emit "$WT2"
fi

# Last resort: don't block the spawn.
log "worktree add failed ($REASON); falling back to canonical as-is -> $REPO"
emit "$REPO"
