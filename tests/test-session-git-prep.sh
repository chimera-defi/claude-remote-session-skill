#!/usr/bin/env bash
# Plain-bash assertions for session-git-prep. No external test framework.
# Covers the three core decision paths (non-git passthrough, clean+free ->
# canonical on default branch, dirty -> isolated worktree). Deliberately does
# not exercise the busy/owner-lock path — that requires a live tmux session
# and is exercised manually / by the reap tests instead.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PREP="$HERE/../scripts/session-git-prep.sh"
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ── non-git dir: run in place (legacy behaviour) ────────────────────────────
NONGIT="$WORK/plain-dir"; mkdir -p "$NONGIT"
out="$(bash "$PREP" "$NONGIT" sess-nongit remote-nongit 2>/dev/null)"
ok "non-git-passthrough" "$out" "$NONGIT"

mk_repo() { # $1 = path
  git init -q -b main "$1"
  echo hi > "$1/f.txt"
  git -C "$1" add -A
  git -C "$1" commit -q -m init
}

# ── clean + free canonical tree: checked out on default branch, run in place ─
REPO1="$WORK/repo-clean"; mk_repo "$REPO1"
git -C "$REPO1" checkout -q -b feature-branch
HOME1="$WORK/home-clean"; mkdir -p "$HOME1"
out1="$(HOME="$HOME1" bash "$PREP" "$REPO1" sess-clean remote-clean 2>/dev/null)"
ok "clean-free-runs-in-canonical" "$out1" "$REPO1"
ok "clean-free-checks-out-default" "$(git -C "$REPO1" rev-parse --abbrev-ref HEAD)" "main"
ok "clean-free-claims-owner-lock" "$([ -f "$HOME1/.claude/session-locks/"*".owner" ] && echo yes || echo no)" "yes"

# ── dirty canonical tree: isolated into a fresh worktree, canonical untouched ─
REPO2="$WORK/repo-dirty"; mk_repo "$REPO2"
echo "uncommitted change" >> "$REPO2/f.txt"
HOME2="$WORK/home-dirty"; mkdir -p "$HOME2"
out2="$(HOME="$HOME2" bash "$PREP" "$REPO2" sess-dirty remote-dirty 2>/dev/null)"
ok "dirty-uses-worktree-path" "$out2" "$HOME2/.claude/worktrees/remote-dirty"
ok "dirty-worktree-exists" "$([ -d "$out2" ] && echo yes || echo no)" "yes"
ok "dirty-worktree-on-session-branch" "$(git -C "$out2" rev-parse --abbrev-ref HEAD 2>/dev/null)" "session/remote-dirty"
ok "dirty-canonical-still-dirty" "$(git -C "$REPO2" status --porcelain | grep -qF 'f.txt' && echo yes || echo no)" "yes"
ok "dirty-canonical-not-locked" "$([ -f "$HOME2/.claude/session-locks/"*".owner" ] && echo yes || echo no)" "no"

# ── housekeeping-only dirt (skills symlink / bootstrap edits / sentinels) does
# NOT count as dirty — only the skill's own artifacts are ignored, so a real
# repo that only has these must still be treated as clean+free.
REPO3="$WORK/repo-housekeeping"; mk_repo "$REPO3"
mkdir -p "$REPO3/.claude"; ln -sf /nonexistent "$REPO3/.claude/skills"
touch "$REPO3/.sessions-init-remote-hk"
HOME3="$WORK/home-hk"; mkdir -p "$HOME3"
out3="$(HOME="$HOME3" bash "$PREP" "$REPO3" sess-hk remote-hk 2>/dev/null)"
ok "housekeeping-only-still-canonical" "$out3" "$REPO3"

echo "session-git-prep: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
