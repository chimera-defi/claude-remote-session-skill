#!/usr/bin/env bash
# Regression coverage for session-preserve.sh: the safe-to-reap audit that
# gates every reap/recycle in session-doctor and the SKILL.md recipes.
# Previously untested despite deciding whether commits/files are safe to lose.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SP="$HERE/../scripts/session-preserve.sh"
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }
has(){ if printf '%s' "$2" | grep -qF "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — pattern not found: $3 in: $2"; fi; }

command -v tmux >/dev/null 2>&1 || { echo "session-preserve: SKIP (no tmux)"; exit 0; }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

mkrepo() { git init --quiet -b main "$1"; git -C "$1" commit --quiet --allow-empty -m init; }

# Sessions are named sp-test-$$-* (see spawn_in below); killed by pattern in the
# trap rather than tracked in an array, since spawn_in runs in a command-
# substitution subshell and could not append to a parent-scope array anyway.
WORK="$(mktemp -d)"
trap 'tmux ls -F "#{session_name}" 2>/dev/null | grep "^sp-test-$$-" | while read -r s; do tmux kill-session -t "$s" 2>/dev/null || true; done; rm -rf "$WORK"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"

# spawn_in <dir> -> tmux session name whose pane shell has a live child process
# with cwd=<dir>, matching what rundir_of() walks (pane_pid -> first child -> cwd).
# Each call runs in a command-substitution subshell (`s=$(spawn_in ...)`), so a
# plain incrementing counter variable would never survive back to the caller —
# every call would see the same starting value and mint the same session name,
# silently colliding with (and reusing the cwd of) whichever session claimed
# that name first. $RANDOM is per-subshell-call-safe since it needs no shared
# state across calls.
spawn_in() {
  local dir="$1" s
  s="sp-test-$$-$RANDOM-$RANDOM"
  tmux new-session -d -s "$s" -c "$dir" 2>/dev/null
  tmux send-keys -t "$s" 'sleep 300 &' Enter
  # Wait for the backgrounded `sleep` to actually appear before returning — NOT
  # just any child. The pane's login shell can fork a short-lived startup
  # helper first (observed live: rbenv-rehash and other transients that exit
  # before `ps` can even read their cmdline); stopping as soon as ANY child
  # shows up can return while that transient is the only one present, and by
  # the time the caller invokes session-preserve.sh it may have already exited
  # with `sleep` not yet started — a window where rundir_of() sees no children
  # and spuriously reports the proc gone (flaky test failures, ~30-40% rate).
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

# 1. No such tmux session at all -> proc gone -> SAFE-TO-REAP, nothing to preserve.
out="$(bash "$SP" "no-such-session-$$" 2>&1)"; rc=$?
has "dead-session-unknown-rundir" "$out" "UNKNOWN (proc gone)"
has "dead-session-safe" "$out" "SAFE-TO-REAP"
ok  "dead-session-exit0" "$rc" "0"

# 2. Live session, cwd is not a git repo -> SAFE-TO-REAP.
PLAIN="$WORK/plain"; mkdir -p "$PLAIN"
S_PLAIN="$(spawn_in "$PLAIN")"
out="$(bash "$SP" "$S_PLAIN" 2>&1)"; rc=$?
has "non-git-safe" "$out" "SAFE-TO-REAP"
ok  "non-git-exit0" "$rc" "0"

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

# 5b. Two untracked files that would collide under the OLD flatten-slashes-to-
# underscores naming (src/util.txt and src_util.txt both -> src_util.txt) must
# both survive --rescue with their real content intact — regression for a
# data-loss bug where the second cp -f silently clobbered the first while both
# still printed "rescued".
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

# 5c. A path component that already exists as a FILE from an earlier rescue of
# the SAME session on the SAME day (one $RESCUE_ROOT) must not be silently
# marked safe when the second rescue can't land: untracked "foo" is rescued,
# then "foo" is replaced by a directory containing untracked "foo/bar" —
# `mkdir -p .../foo` now fails because "foo" is a file there, so "foo/bar"
# can't be copied. Verdict must stay NOT-SAFE-TO-REAP, not flip to SAFE over a
# silently-lost file (found in review, chatgpt-codex-connector, PR #43).
R3C="$WORK/repo3c"; mkrepo "$R3C"
echo "v1" > "$R3C/foo"
S_CONFLICT="$(spawn_in "$R3C")"
bash "$SP" "$S_CONFLICT" --rescue >/dev/null 2>&1
ok "conflict-first-rescue-on-disk" "$(cat "$RESCUED_DIR/$S_CONFLICT/foo" 2>/dev/null)" "v1"
rm -f "$R3C/foo"; mkdir -p "$R3C/foo"; echo "v2" > "$R3C/foo/bar"
out="$(bash "$SP" "$S_CONFLICT" --rescue 2>&1)"; rc=$?
has "conflict-second-rescue-not-safe" "$out" "NOT-SAFE-TO-REAP"
ok  "conflict-second-rescue-exit1"    "$rc" "1"

# 6. Untracked file matching JUNK_RE (e.g. under node_modules/) must NOT count —
# it is regenerable clutter every session produces, not real work to preserve.
R4="$WORK/repo4"; mkrepo "$R4"
mkdir -p "$R4/node_modules/pkg"; echo x > "$R4/node_modules/pkg/index.js"
S_JUNK="$(spawn_in "$R4")"
out="$(bash "$SP" "$S_JUNK" 2>&1)"; rc=$?
has "junk-untracked-safe" "$out" "SAFE-TO-REAP"
ok  "junk-untracked-exit0" "$rc" "0"

# 6b. --wip must not sweep in a TRACKED file under a JUNK_RE path (e.g. a
# committed node_modules/ entry -- unusual but real for vendored deps). The
# audit above never counts it as dirty, so committing it anyway via a bare
# `git add -A` would silently include content the operator was never told was
# there. Only the real, non-junk tracked change should land in the WIP commit;
# the junk change stays uncommitted (harmless -- it was never blocking reap).
R4B="$WORK/repo4b"; mkrepo "$R4B"
mkdir -p "$R4B/node_modules/pkg"; echo v1 > "$R4B/node_modules/pkg/index.js"
echo one > "$R4B/real.txt"
git -C "$R4B" add -A; git -C "$R4B" commit --quiet -m "add tracked + junk"
echo v2 > "$R4B/node_modules/pkg/index.js"   # tracked JUNK_RE path, modified
echo two > "$R4B/real.txt"                    # tracked real path, modified
S_JUNKWIP="$(spawn_in "$R4B")"
out="$(bash "$SP" "$S_JUNKWIP" 2>&1)"; rc=$?
has "junk-wip-dirty-excludes-junk" "$out" "uncommitted TRACKED changes (non-junk): 1"
out="$(bash "$SP" "$S_JUNKWIP" --wip 2>&1)"; rc=$?
has "junk-wip-commits"   "$out" "WIP committed"
has "junk-wip-then-safe" "$out" "SAFE-TO-REAP"
ok "junk-wip-real-committed" "$(git -C "$R4B" diff --name-only HEAD)" "node_modules/pkg/index.js"
ok "junk-wip-junk-not-committed" "$(git -C "$R4B" show HEAD:real.txt)" "two"

# 7. No remote configured -> flagged explicitly, since local-only commits there
# have nowhere to be pushed to (the finding that prompted this script, see the
# header comment: @{u}.. silently reports 0 unpushed with no upstream at all).
R5="$WORK/repo5"; mkrepo "$R5"
S_NOREMOTE="$(spawn_in "$R5")"
out="$(bash "$SP" "$S_NOREMOTE" 2>&1)"; rc=$?
has "no-remote-flagged" "$out" "repo has NO REMOTE"
has "no-remote-still-safe" "$out" "SAFE-TO-REAP"   # HEAD is still on branch 'main'
ok  "no-remote-exit0"   "$rc" "0"

# 8. HEAD not reachable from any named local branch (a commit made after
# detaching) -> NOT-SAFE-TO-REAP, since reaping would orphan it.
R6="$WORK/repo6"; mkrepo "$R6"
git -C "$R6" checkout --quiet --detach main
echo "orphan-commit" > "$R6/f.txt"; git -C "$R6" add f.txt
git -C "$R6" commit --quiet -m "detached commit, no branch points here"
S_DETACHED="$(spawn_in "$R6")"
out="$(bash "$SP" "$S_DETACHED" 2>&1)"; rc=$?
has "detached-not-safe" "$out" "NOT-SAFE-TO-REAP"
has "detached-reason"   "$out" "HEAD-not-on-a-branch"
ok  "detached-exit1"    "$rc" "1"

# 9. --all audits every live ah_/agenthost_ session. The synthetic sp-test-*
# sessions above are NOT ah_/agenthost_-prefixed, so --all must skip them.
# Its EXIT CODE reflects real host state (0 = every audited session safe,
# 1 = at least one not-safe) — both are valid completions. So assert it
# completed without a crash/usage error (rc 0 or 1) AND that it never named a
# synthetic session, rather than pinning a host-state-dependent exit code
# (asserting 0 spuriously fails on any active host with an in-flight not-safe
# session — e.g. one with untracked telemetry pending --rescue).
out="$(bash "$SP" --all 2>&1)"; rc=$?
if [ "$rc" = 0 ] || [ "$rc" = 1 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: all-completes-no-crash — got rc=$rc; out: $out"; fi
ok "all-skips-synthetic-sessions" "$(printf '%s' "$out" | grep -c "sp-test-$$-")" "0"

echo "session-preserve: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
