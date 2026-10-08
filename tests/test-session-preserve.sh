#!/usr/bin/env bash
# session-preserve.sh: the safe-to-reap audit that gates every reap/recycle.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
isolate_overlay
# Fixture shape: configured prefix "px", legacy "oldhost".
export CRSS_SESSION_PREFIX=px
export CRSS_LEGACY_PREFIXES=oldhost
SP="$HERE/../scripts/session-preserve.sh"

command -v tmux >/dev/null 2>&1 || { echo "session-preserve: SKIP (no tmux)"; exit 0; }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

mkrepo() { git init --quiet -b main "$1"; git -C "$1" commit --quiet --allow-empty -m init; }

# Sessions are named sp-test-$$-*; killed by pattern in the trap (spawn_in runs in a subshell, no parent array).
WORK="$(mktemp -d)"
trap 'tmux ls -F "#{session_name}" 2>/dev/null | grep "^sp-test-$$-" | while read -r s; do tmux kill-session -t "$s" 2>/dev/null || true; done; rm -rf "$WORK"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"

# spawn_in <dir> -> tmux session whose pane has a live child with cwd=<dir> (what rundir_of() walks).
# Runs in a command substitution, so a counter would not survive: names use $RANDOM.
spawn_in() {
  local dir="$1" s
  s="sp-test-$$-$RANDOM-$RANDOM"
  tmux new-session -d -s "$s" -c "$dir" 2>/dev/null
  tmux send-keys -t "$s" 'sleep 300 &' Enter
  # wait for the backgrounded `sleep` specifically, not any child: the login shell forks short-lived startup helpers
  # first, and returning on one of those made rundir_of() see no children (flaky ~30-40%)
  local pid tries=0 cpid found=no
  pid=$(tmux list-panes -t "$s" -F '#{pane_pid}' 2>/dev/null)
  while [ "$tries" -lt 20 ]; do
    for cpid in $(pgrep -P "$pid" 2>/dev/null); do
      [ "$(cat "/proc/$cpid/comm" 2>/dev/null)" = "sleep" ] && { found=yes; break; }
    done
    [ "$found" = yes ] && break
    sleep 0.1; tries=$((tries+1))
  done
  printf '%s' "$s"
}

# 1. No tmux session and no matching worktree -> SAFE-TO-REAP, under a reason distinct from an audited clean worktree.
out="$(bash "$SP" "no-such-session-$$" 2>&1)"; rc=$?
has "dead-session-unknown-rundir" "$out" "UNKNOWN (proc gone)"
has "dead-session-safe" "$out" "SAFE-TO-REAP"
has "dead-session-distinct-reason" "$out" "no rundir and no worktree found"
ok  "dead-session-exit0" "$rc" "0"

# 3. Live session, clean repo, HEAD on a branch -> SAFE-TO-REAP.
R1="$WORK/repo1"; mkrepo "$R1"
S_CLEAN="$(spawn_in "$R1")"
out="$(bash "$SP" "$S_CLEAN" 2>&1)"; rc=$?
has "clean-repo-safe" "$out" "SAFE-TO-REAP"
ok  "clean-repo-exit0" "$rc" "0"

# 4. Dirty TRACKED file -> NOT-SAFE-TO-REAP; --wip commits it and clears the flag.
R2="$WORK/repo2"; mkrepo "$R2"
echo "one" > "$R2/tracked.txt"; git -C "$R2" add tracked.txt; git -C "$R2" commit --quiet -m "add tracked"
echo "two" > "$R2/tracked.txt"   # uncommitted change to a tracked file
S_DIRTY="$(spawn_in "$R2")"
out="$(bash "$SP" "$S_DIRTY" 2>&1)"; rc=$?
has "dirty-tracked-not-safe" "$out" "NOT-SAFE-TO-REAP"
has "dirty-tracked-reason"   "$out" "uncommitted-tracked-changes"
ok  "dirty-tracked-exit1"   "$rc" "1"
out="$(bash "$SP" "$S_DIRTY" --wip 2>&1)"; rc=$?
has "wip-commits"      "$out" "WIP committed"
has "wip-then-safe"    "$out" "SAFE-TO-REAP"
ok  "wip-exit0"         "$rc" "0"
ok  "wip-clean-after"   "$(git -C "$R2" status --porcelain | grep -vE '^\?\? \.claude/' | wc -l | tr -d ' ')" "0"

# 4b. --wip commit rejected (pre-commit hook) -> `dirty` must NOT clear; verdict stays NOT-SAFE.
R2B="$WORK/repo2b"; mkrepo "$R2B"
mkdir -p "$R2B/.git/hooks"
printf '#!/bin/sh\nexit 1\n' > "$R2B/.git/hooks/pre-commit"; chmod +x "$R2B/.git/hooks/pre-commit"
echo "one" > "$R2B/tracked.txt"; git -C "$R2B" add tracked.txt; git -C "$R2B" commit --quiet --no-verify -m "add tracked"
echo "two" > "$R2B/tracked.txt"
S_HOOKFAIL="$(spawn_in "$R2B")"
out="$(bash "$SP" "$S_HOOKFAIL" --wip 2>&1)"; rc=$?
has "wip-hookfail-message" "$out" "WIP commit FAILED"
has "wip-hookfail-not-safe" "$out" "NOT-SAFE-TO-REAP"
has "wip-hookfail-reason"  "$out" "uncommitted-tracked-changes"
ok  "wip-hookfail-exit1"   "$rc" "1"

# 5. Untracked file -> NOT-SAFE-TO-REAP; --rescue copies it out and clears the flag.
R3="$WORK/repo3"; mkrepo "$R3"
echo "orphan" > "$R3/scratch.txt"
S_UNTRACKED="$(spawn_in "$R3")"
out="$(bash "$SP" "$S_UNTRACKED" 2>&1)"; rc=$?
has "untracked-not-safe" "$out" "NOT-SAFE-TO-REAP"
has "untracked-reason"   "$out" "untracked-files"
ok  "untracked-exit1"    "$rc" "1"
out="$(bash "$SP" "$S_UNTRACKED" --rescue 2>&1)"; rc=$?
has "rescue-copies"      "$out" "rescued: scratch.txt"
has "rescue-then-safe"   "$out" "SAFE-TO-REAP"
ok  "rescue-exit0"       "$rc" "0"
RESCUED_DIR="$HOME/.sessions/rescued-$(date +%Y-%m-%d)"
ok "rescue-file-on-disk" "$(cat "$RESCUED_DIR/$S_UNTRACKED/scratch.txt" 2>/dev/null)" "orphan"

# 5b. src/util.txt and src_util.txt (collide under the old flatten-slashes naming) must both survive --rescue
# intact (data-loss regression: the second cp clobbered the first).
R3B="$WORK/repo3b"; mkrepo "$R3B"
mkdir -p "$R3B/src"
echo "nested" > "$R3B/src/util.txt"
echo "flat" > "$R3B/src_util.txt"
S_COLLIDE="$(spawn_in "$R3B")"
out="$(bash "$SP" "$S_COLLIDE" --rescue 2>&1)"; rc=$?
has "collide-rescue-safe" "$out" "SAFE-TO-REAP"
ok  "collide-rescue-exit0" "$rc" "0"
ok "collide-nested-preserved" "$(cat "$RESCUED_DIR/$S_COLLIDE/src/util.txt" 2>/dev/null)" "nested"
ok "collide-flat-preserved"   "$(cat "$RESCUED_DIR/$S_COLLIDE/src_util.txt" 2>/dev/null)" "flat"

# 5c. An earlier rescue left "foo" as a FILE, then "foo" becomes a dir holding untracked foo/bar: mkdir fails, the
# file can't be copied, and the verdict must stay NOT-SAFE (not flip to SAFE over a lost file; PR #43).
R3C="$WORK/repo3c"; mkrepo "$R3C"
echo "v1" > "$R3C/foo"
S_CONFLICT="$(spawn_in "$R3C")"
bash "$SP" "$S_CONFLICT" --rescue >/dev/null 2>&1
ok "conflict-first-rescue-on-disk" "$(cat "$RESCUED_DIR/$S_CONFLICT/foo" 2>/dev/null)" "v1"
rm -f "$R3C/foo"; mkdir -p "$R3C/foo"; echo "v2" > "$R3C/foo/bar"
out="$(bash "$SP" "$S_CONFLICT" --rescue 2>&1)"; rc=$?
has "conflict-second-rescue-not-safe" "$out" "NOT-SAFE-TO-REAP"
ok  "conflict-second-rescue-exit1"    "$rc" "1"

# 6. Untracked JUNK_RE file (node_modules/) is regenerable clutter and must NOT count.
R4="$WORK/repo4"; mkrepo "$R4"
mkdir -p "$R4/node_modules/pkg"; echo x > "$R4/node_modules/pkg/index.js"
S_JUNK="$(spawn_in "$R4")"
out="$(bash "$SP" "$S_JUNK" 2>&1)"; rc=$?
has "junk-untracked-safe" "$out" "SAFE-TO-REAP"
ok  "junk-untracked-exit0" "$rc" "0"

# 6c. The spawner's root-level .sessions-init-<remote> sentinel must NOT count as untracked work (it made every
# restarted session NOT-SAFE; PR #76).
R4C="$WORK/repo4c"; mkrepo "$R4C"
echo x > "$R4C/.sessions-init-px-example-0101-0100"
S_SENTINEL="$(spawn_in "$R4C")"
out="$(bash "$SP" "$S_SENTINEL" 2>&1)"; rc=$?
has "sentinel-untracked-safe" "$out" "SAFE-TO-REAP"
ok  "sentinel-untracked-exit0" "$rc" "0"

# 6d. A sentinel next to a genuine untracked file must still report NOT-SAFE for the real file.
R4D="$WORK/repo4d"; mkrepo "$R4D"
echo x > "$R4D/.sessions-init-px-example-0101-0100"
echo "real work" > "$R4D/scratch.txt"
S_SENTINELPLUS="$(spawn_in "$R4D")"
out="$(bash "$SP" "$S_SENTINELPLUS" 2>&1)"; rc=$?
has "sentinel-plus-not-safe" "$out" "NOT-SAFE-TO-REAP"
has "sentinel-plus-reason"   "$out" "untracked-files"
ok  "sentinel-plus-exit1"    "$rc" "1"

# 6e. The sentinel exemption is anchored to a ROOT-LEVEL file: nested paths containing ".sessions-init-" (docs/.sessions-init-notes,
# .sessions-init-output/) are real content and must still block reap (PR #77).
R4E="$WORK/repo4e"; mkrepo "$R4E"
mkdir -p "$R4E/docs" "$R4E/.sessions-init-output"
echo "real doc" > "$R4E/docs/.sessions-init-notes"
echo "real result" > "$R4E/.sessions-init-output/result.txt"
S_NESTEDSENTINEL="$(spawn_in "$R4E")"
out="$(bash "$SP" "$S_NESTEDSENTINEL" 2>&1)"; rc=$?
has "nested-sentinel-not-safe" "$out" "NOT-SAFE-TO-REAP"
has "nested-sentinel-reason"   "$out" "untracked-files"
ok  "nested-sentinel-exit1"    "$rc" "1"

# 8. HEAD not reachable from any named local branch -> NOT-SAFE (reaping would orphan it).
R6="$WORK/repo6"; mkrepo "$R6"
git -C "$R6" checkout --quiet --detach main
echo "orphan-commit" > "$R6/f.txt"; git -C "$R6" add f.txt
git -C "$R6" commit --quiet -m "detached commit, no branch points here"
S_DETACHED="$(spawn_in "$R6")"
out="$(bash "$SP" "$S_DETACHED" 2>&1)"; rc=$?
has "detached-not-safe" "$out" "NOT-SAFE-TO-REAP"
has "detached-reason"   "$out" "HEAD-not-on-a-branch"
ok  "detached-exit1"    "$rc" "1"

# 10. FAIL-OPEN REGRESSION: a dead session whose name maps to a worktree with unsaved work printed SAFE-TO-REAP
# purely because the process was gone (nearly lost 320 lines). Must fall back to auditing the worktree -> NOT-SAFE.
WT_BASE="$HOME/.claude/worktrees"; mkdir -p "$WT_BASE"
R7="$WT_BASE/px-sp-repro-$$"; mkrepo "$R7"
echo "unsaved work" > "$R7/scratch.txt"    # untracked, real work
S_DEAD_DIRTY="px_sp-repro-$$"               # no tmux session spawned for this name
out="$(bash "$SP" "$S_DEAD_DIRTY" 2>&1)"; rc=$?
has "deadwt-found-via-fallback" "$out" "located via worktree lookup"
has "deadwt-not-safe"           "$out" "NOT-SAFE-TO-REAP"
has "deadwt-reason"             "$out" "untracked-files"
ok  "deadwt-exit1"              "$rc" "1"

# 11. Same fallback, worktree CLEAN -> the SAME SAFE verdict as a live session. The slug carries a second underscore
# (px_sp_clean_$$) to prove only the FIRST "_" after the prefix becomes "-".
R8="$WT_BASE/px-sp_clean_$$"; mkrepo "$R8"
S_DEAD_CLEAN="px_sp_clean_$$"
out="$(bash "$SP" "$S_DEAD_CLEAN" 2>&1)"; rc=$?
has "deadwt-clean-found" "$out" "located via worktree lookup"
has "deadwt-clean-safe"  "$out" "SAFE-TO-REAP (work is on branch"
ok  "deadwt-clean-exit0" "$rc" "0"

# 13. Collision with TWO coexisting dirs: a clean decoy $dir/<base> on an unrelated branch and the dirty real
# worktree $dir/<base>-<pid> on session/<base>. Branch match must win over dirname (else fail-open).
R10="$WT_BASE/px-sp-decoy-$$"; mkrepo "$R10"   # clean, dirname matches guess exactly
R11="$WT_BASE/px-sp-decoy-$$-5555"; mkrepo "$R11"  # dirty, dirname does NOT match
git -C "$R11" checkout --quiet -b "session/px-sp-decoy-$$"
echo "unsaved" > "$R11/scratch.txt"
S_DECOY_DEAD="px_sp-decoy-$$"
out="$(bash "$SP" "$S_DECOY_DEAD" 2>&1)"; rc=$?
has "decoy-finds-real-dirty-worktree" "$out" "$R11"
has "decoy-not-safe"                  "$out" "NOT-SAFE-TO-REAP"
has "decoy-reason"                    "$out" "untracked-files"
ok  "decoy-exit1"                     "$rc" "1"

# 14. A file already rescued (identical copy in rescued-*/<session>/) must not re-flag on a plain audit (what
# `session-doctor reap` runs after `--rescue`); an edit after the rescue must.
R12="$WT_BASE/px-sp-rescued-$$"; mkrepo "$R12"
git -C "$R12" checkout --quiet -b "session/px-sp-rescued-$$"
echo "keep" > "$R12/notes.txt"
S_RESCUED="$(spawn_in "$R12")"
bash "$SP" "$S_RESCUED" --rescue >/dev/null 2>&1
out="$(bash "$SP" "$S_RESCUED" 2>&1)"; rc=$?
has "rescued-then-plain-audit-safe" "$out" "SAFE-TO-REAP"
ok  "rescued-then-plain-audit-exit0" "$rc" "0"
echo "edited after rescue" >> "$R12/notes.txt"
out="$(bash "$SP" "$S_RESCUED" 2>&1)"; rc=$?
has "edited-after-rescue-not-safe" "$out" "NOT-SAFE-TO-REAP"
ok  "edited-after-rescue-exit1"    "$rc" "1"

ln -s notes.txt "$R12/link.txt"
bash "$SP" "$S_RESCUED" --rescue >/dev/null 2>&1
out="$(bash "$SP" "$S_RESCUED" 2>&1)"; rc=$?
ok  "symlink-never-counts-as-rescued" "$rc" "1"

finish "session-preserve"
