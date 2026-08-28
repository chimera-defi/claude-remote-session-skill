#!/usr/bin/env bash
# Regression coverage for session-git-prep.sh: which run directory it picks
# (canonical vs. isolated worktree) and why. Previously untested despite
# owning git checkout/merge/worktree/locking side effects.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SGP="$HERE/../scripts/session-git-prep.sh"
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

mkrepo() { git init --quiet -b main "$1"; git -C "$1" commit --quiet --allow-empty -m init; }
# Mirrors session-git-prep.sh's LOCK_KEY derivation exactly (kept in sync by hand).
lock_key() { printf '%s_%s' "$(printf '%s' "$1" | tr '/ ' '__')" "$(printf '%s' "$1" | cksum | cut -d' ' -f1)"; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"

# 1. Not a git repo -> run in place, unchanged.
PLAIN="$WORK/plain"; mkdir -p "$PLAIN"
out="$(bash "$SGP" "$PLAIN" sess-1 remote-1 2>/dev/null)"
ok "non-git-passthrough" "$out" "$PLAIN"

# 2. Clean + free canonical tree: lands on the default branch and claims the lock.
R1="$WORK/repo1"; mkrepo "$R1"
git -C "$R1" checkout --quiet -b other-branch
out="$(bash "$SGP" "$R1" sess-clean remote-clean 2>/dev/null)"
ok "clean-free-emits-repo" "$out" "$R1"
ok "clean-free-checks-out-default" "$(git -C "$R1" rev-parse --abbrev-ref HEAD)" "main"
LOCK_KEY1=$(lock_key "$R1")
ok "clean-free-claims-lock" "$(cat "$HOME/.claude/session-locks/${LOCK_KEY1}.owner" 2>/dev/null)" "sess-clean"

# 3. Dirty canonical tree: isolated into a fresh worktree; canonical is untouched.
R2="$WORK/repo2"; mkrepo "$R2"
echo "uncommitted" > "$R2/dirty.txt"
out="$(bash "$SGP" "$R2" sess-dirty remote-dirty 2>/dev/null)"
ok "dirty-isolated-path" "$out" "$HOME/.claude/worktrees/remote-dirty"
ok "dirty-worktree-branch" "$(git -C "$out" rev-parse --abbrev-ref HEAD 2>/dev/null)" "session/remote-dirty"
ok "dirty-canonical-untouched" "$([ -f "$R2/dirty.txt" ] && echo yes || echo no)" "yes"
ok "dirty-canonical-branch-unchanged" "$(git -C "$R2" rev-parse --abbrev-ref HEAD)" "main"
LOCK_KEY2=$(lock_key "$R2")
ok "dirty-canonical-not-locked" "$([ -f "$HOME/.claude/session-locks/${LOCK_KEY2}.owner" ] && echo yes || echo no)" "no"

# 4. Changes confined to .claude/ and .sessions-init-* sentinels must NOT count as
# dirty (the spawn skill's own housekeeping) — regression for the exclusion filter.
R3="$WORK/repo3"; mkrepo "$R3"
mkdir -p "$R3/.claude"
echo x > "$R3/.claude/skills"
touch "$R3/.sessions-init-remote-housekeeping"
out="$(bash "$SGP" "$R3" sess-housekeeping remote-housekeeping 2>/dev/null)"
ok "housekeeping-not-dirty" "$out" "$R3"

# 5. Busy (lock held by a LIVE tmux session) forces a worktree even on a clean tree.
if command -v tmux >/dev/null 2>&1; then
  R4="$WORK/repo4"; mkrepo "$R4"
  OWNER="sgp-test-owner-$$"
  tmux new-session -d -s "$OWNER" 2>/dev/null
  LOCK_KEY4=$(lock_key "$R4")
  mkdir -p "$HOME/.claude/session-locks"
  printf '%s' "$OWNER" > "$HOME/.claude/session-locks/${LOCK_KEY4}.owner"
  out="$(bash "$SGP" "$R4" sess-busy remote-busy 2>/dev/null)"
  tmux kill-session -t "$OWNER" 2>/dev/null || true
  ok "busy-lock-forces-worktree" "$out" "$HOME/.claude/worktrees/remote-busy"
  ok "busy-canonical-branch-unchanged" "$(git -C "$R4" rev-parse --abbrev-ref HEAD)" "main"
fi

# 6. A stale lock (owner tmux session no longer alive) is treated as free: canonical
# is claimed and the lock file is overwritten with the new owner.
R5="$WORK/repo5"; mkrepo "$R5"
git -C "$R5" checkout --quiet -b other-branch
LOCK_KEY5=$(lock_key "$R5")
mkdir -p "$HOME/.claude/session-locks"
printf '%s' "sgp-test-owner-does-not-exist-$$" > "$HOME/.claude/session-locks/${LOCK_KEY5}.owner"
out="$(bash "$SGP" "$R5" sess-stale remote-stale 2>/dev/null)"
ok "stale-lock-treated-as-free" "$out" "$R5"
ok "stale-lock-checks-out-default" "$(git -C "$R5" rev-parse --abbrev-ref HEAD)" "main"
ok "stale-lock-overwritten" "$(cat "$HOME/.claude/session-locks/${LOCK_KEY5}.owner")" "sess-stale"

# 7. A worktree is branched from the DEFAULT branch's tip, not whatever happens to
# be checked out — a file only on main must be present, despite the dirty checkout
# sitting on a feature branch that deleted it.
R6="$WORK/repo6"; mkrepo "$R6"
echo "on-main" > "$R6/marker.txt"; git -C "$R6" add marker.txt; git -C "$R6" commit --quiet -m "add marker"
git -C "$R6" checkout --quiet -b feature-branch
git -C "$R6" rm --quiet marker.txt; git -C "$R6" commit --quiet -m "remove marker on feature"
echo "still-dirty" > "$R6/other.txt"
out="$(bash "$SGP" "$R6" sess-base remote-base 2>/dev/null)"
ok "worktree-based-on-default-not-current" "$([ -f "$out/marker.txt" ] && echo yes || echo no)" "yes"

# 8. With an 'origin' remote, the canonical tree ff-merges the latest origin/<default>
# instead of just checking out whatever the local branch already had.
SRC="$WORK/src"; mkrepo "$SRC"
ORIGIN_BARE="$WORK/origin.git"
git clone --quiet --bare "$SRC" "$ORIGIN_BARE" 2>/dev/null
R7="$WORK/repo7"
git clone --quiet "$ORIGIN_BARE" "$R7" 2>/dev/null
echo "sync-marker" > "$SRC/sync.txt"
git -C "$SRC" add sync.txt
git -C "$SRC" commit --quiet -m "add sync marker"
git -C "$SRC" push --quiet "$ORIGIN_BARE" main:main
out="$(bash "$SGP" "$R7" sess-sync remote-sync 2>/dev/null)"
ok "origin-emits-repo" "$out" "$R7"
ok "origin-ff-merge-pulls-latest" "$([ -f "$R7/sync.txt" ] && echo yes || echo no)" "yes"

# 9. Two distinct repo paths that flatten to the SAME string under a bare
# tr '/ ' '__' (e.g. .../foo_bar and .../foo/bar both -> "..._foo_bar") must
# still get DISTINCT lock files — regression for a lock-key collision that
# could let one repo's busy/free claim corrupt another's.
mkdir -p "$WORK/collide/foo"
RA="$WORK/collide/foo_bar"; mkrepo "$RA"
RB="$WORK/collide/foo/bar"; mkrepo "$RB"
out_a="$(bash "$SGP" "$RA" sess-collide-a remote-collide-a 2>/dev/null)"
out_b="$(bash "$SGP" "$RB" sess-collide-b remote-collide-b 2>/dev/null)"
ok "collide-a-emits-repo" "$out_a" "$RA"
ok "collide-b-emits-repo" "$out_b" "$RB"
ok "collide-distinct-lock-keys" "$([ "$(lock_key "$RA")" != "$(lock_key "$RB")" ] && echo yes || echo no)" "yes"
ok "collide-a-lock-is-a" "$(cat "$HOME/.claude/session-locks/$(lock_key "$RA").owner" 2>/dev/null)" "sess-collide-a"
ok "collide-b-lock-is-b" "$(cat "$HOME/.claude/session-locks/$(lock_key "$RB").owner" 2>/dev/null)" "sess-collide-b"

echo "session-git-prep: pass=$pass fail=$fail"; [ "$fail" -eq 0 ]
