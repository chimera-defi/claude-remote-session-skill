#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1090
source "$HERE/../scripts/session-doctor.sh"   # must NOT run report (source-guard)
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }

ok "legacy tmux->base" "$(tmux_to_base agenthost_foo-20260101-0900)" "agenthost-foo-20260101-0900"
ok "new tmux->base"    "$(tmux_to_base ah_0101-0900-foo)"            "ah-0101-0900-foo"
ok "foreign tmux->base" "$(tmux_to_base codexhost_x)"               ""
ok "legacy svc->tmux"  "$(svc_to_tmux agenthost-foo-20260101-0900)" "agenthost_foo-20260101-0900"
ok "new svc->tmux"     "$(svc_to_tmux ah-0101-0900-foo)"            "ah_0101-0900-foo"

# registry-stale must degrade gracefully (no Python traceback) when the registry
# is unavailable (e.g. missing/expired credentials), same as `report` mode already
# does — regression for a bare `json.load(sys.stdin)` with no try/except.
NOHOME="$(mktemp -d)"; trap 'rm -rf "$NOHOME"' EXIT
out="$(HOME="$NOHOME" bash "$HERE/../scripts/session-doctor.sh" registry-stale 2>&1)"
ok "registry-stale-no-traceback" "$(printf '%s' "$out" | grep -qi 'Traceback' && echo yes || echo no)" "no"
ok "registry-stale-graceful-msg" "$(printf '%s' "$out" | grep -qF '(registry unavailable)' && echo yes || echo no)" "yes"

# worktree-stale: a worktree under ~/.claude/worktrees/ whose owning tmux session
# is dead (or absent) is reported as a candidate with its dirty/unpushed status
# and an exact removal command; a worktree with a genuinely LIVE owning session,
# or a protected name, must NOT be listed. Removal is never automated (mirrors
# registry-stale — a dead session's worktree may hold unpushed work).
if command -v git >/dev/null 2>&1 && command -v tmux >/dev/null 2>&1; then
  WTTMP="$(mktemp -d)"; trap 'rm -rf "$WTTMP"; tmux kill-session -t ah_wtlive-0101-0900 2>/dev/null || true' EXIT
  REPO="$WTTMP/repo"; mkdir -p "$REPO"
  git -C "$REPO" init -q -b main
  git -C "$REPO" config user.email t@t.com; git -C "$REPO" config user.name t
  echo hi > "$REPO/a.txt"; git -C "$REPO" add a.txt; git -C "$REPO" commit -q -m init

  WTHOME="$WTTMP/home"; mkdir -p "$WTHOME/.claude/worktrees"
  WT_DEAD="$WTHOME/.claude/worktrees/ah-wtdead-0101-0900"
  git -C "$REPO" worktree add -q -b session/ah-wtdead-0101-0900 "$WT_DEAD" main >/dev/null 2>&1
  WT_LIVE="$WTHOME/.claude/worktrees/ah-wtlive-0101-0900"
  git -C "$REPO" worktree add -q -b session/ah-wtlive-0101-0900 "$WT_LIVE" main >/dev/null 2>&1
  WT_PROT="$WTHOME/.claude/worktrees/ah-hermes-0101-0900"
  git -C "$REPO" worktree add -q -b session/ah-hermes-0101-0900 "$WT_PROT" main >/dev/null 2>&1
  tmux new-session -d -s ah_wtlive-0101-0900 -c "$WT_LIVE" 'sleep 60'

  wtout="$(HOME="$WTHOME" bash "$HERE/../scripts/session-doctor.sh" worktree-stale)"
  tmux kill-session -t ah_wtlive-0101-0900 2>/dev/null || true

  ok "worktree-stale-lists-dead"     "$(printf '%s' "$wtout" | grep -qF "$WT_DEAD" && echo yes || echo no)" "yes"
  ok "worktree-stale-skips-live"     "$(printf '%s' "$wtout" | grep -qF "$WT_LIVE" && echo yes || echo no)" "no"
  ok "worktree-stale-skips-protected" "$(printf '%s' "$wtout" | grep -qF "$WT_PROT" && echo yes || echo no)" "no"
  ok "worktree-stale-prints-removal-cmd" "$(printf '%s' "$wtout" | grep -qF 'worktree remove --force' && echo yes || echo no)" "yes"
fi

echo "session-doctor: pass=$pass fail=$fail"; [ "$fail" -eq 0 ]
