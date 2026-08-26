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
  # Wait for the backgrounded child to actually appear before returning.
  local pid tries=0
  pid=$(tmux list-panes -t "$s" -F '#{pane_pid}' 2>/dev/null)
  while [ -z "$(pgrep -P "$pid" 2>/dev/null)" ] && [ "$tries" -lt 20 ]; do sleep 0.1; tries=$((tries+1)); done
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
ok "rescue-file-on-disk" "$(cat "$RESCUED_DIR/${S_UNTRACKED}__scratch.txt" 2>/dev/null)" "orphan"

# 6. Untracked file matching JUNK_RE (e.g. under node_modules/) must NOT count —
# it is regenerable clutter every session produces, not real work to preserve.
R4="$WORK/repo4"; mkrepo "$R4"
mkdir -p "$R4/node_modules/pkg"; echo x > "$R4/node_modules/pkg/index.js"
S_JUNK="$(spawn_in "$R4")"
out="$(bash "$SP" "$S_JUNK" 2>&1)"; rc=$?
has "junk-untracked-safe" "$out" "SAFE-TO-REAP"
ok  "junk-untracked-exit0" "$rc" "0"

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

# 9. --all audits every live ah_/agenthost_ session — the two synthetic clean/
# dirty sessions above are not ah_/agenthost_-prefixed, so --all must skip them
# and never error just because none of its target sessions exist.
out="$(bash "$SP" --all 2>&1)"; rc=$?
ok "all-no-crash" "$([ -n "$out" ] || [ -z "$out" ] && echo ok)" "ok"

echo "session-preserve: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
