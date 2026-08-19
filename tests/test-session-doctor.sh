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

# --days is spliced verbatim into an embedded Python snippet as a bare identifier
# (DAYS=$DAYS) — an unvalidated non-numeric value is live Python there, not data,
# and previously threw an uncaught NameError traceback instead of a clean usage
# error. Must be rejected up front, before any registry call.
days_out="$(bash "$HERE/../scripts/session-doctor.sh" registry-stale --days abc 2>&1)"; days_rc=$?
ok "days-nonnumeric-rejected"   "$days_rc" "2"
ok "days-nonnumeric-no-traceback" "$(printf '%s' "$days_out" | grep -qi 'Traceback' && echo yes || echo no)" "no"
ok "days-nonnumeric-clean-msg"  "$(printf '%s' "$days_out" | grep -qF -- "--days requires a non-negative integer" && echo yes || echo no)" "yes"
# Exit code for a *valid* --days still depends on registry/credential availability
# (unrelated to this validation), so assert on behavior, not a specific exit code:
# no rejection message, and the same graceful degradation as the no-credentials
# case above.
numeric_out="$(bash "$HERE/../scripts/session-doctor.sh" registry-stale --days 30 2>&1)"
ok "days-numeric-not-rejected"  "$(printf '%s' "$numeric_out" | grep -qF -- "requires a non-negative integer" && echo yes || echo no)" "no"
ok "days-numeric-no-traceback"  "$(printf '%s' "$numeric_out" | grep -qi 'Traceback' && echo yes || echo no)" "no"

# A digit-only --days can still crash the embedded Python: a LEADING ZERO (e.g.
# `08`) passes the digits-only check above but Python 3 rejects `DAYS=08` as an
# integer literal (SyntaxError: leading zeros not permitted) once spliced in —
# caught in PR review (codex). Must be canonicalized to base-10, not just
# digit-validated.
leadzero_out="$(bash "$HERE/../scripts/session-doctor.sh" registry-stale --days 08 2>&1)"
ok "days-leadingzero-no-traceback" "$(printf '%s' "$leadzero_out" | grep -qi 'Traceback\|SyntaxError' && echo yes || echo no)" "no"
ok "days-leadingzero-normalized"   "$(printf '%s' "$leadzero_out" | grep -qF '> 8d' && echo yes || echo no)" "yes"

# reap-local orphan detection must NOT skip a unit just because systemd still
# reports it "active" (regression: Type=oneshot/RemainAfterExit=yes units —
# see new-session.sh's generated .service — go "active (exited)" once ExecStart
# finishes and STAY that way indefinitely, independent of whether the tmux
# session they spawned later dies. A systemctl is-active gate here would
# almost never be false and would defeat orphan reaping, the exact case this
# loop exists for). Stub systemctl to always report active and confirm the
# orphan (no live tmux) is still flagged.
STUBBIN="$(mktemp -d)"; trap 'rm -rf "$STUBBIN"' RETURN 2>/dev/null || true
cat > "$STUBBIN/systemctl" <<'STUB_EOF'
#!/usr/bin/env bash
exit 0
STUB_EOF
chmod +x "$STUBBIN/systemctl"
TESTCFG="$(mktemp -d)"; mkdir -p "$TESTCFG/systemd/user"
touch "$TESTCFG/systemd/user/ah-test-orphan-0101-0100.service"
TESTHOME="$(mktemp -d)"
orphan_out="$(PATH="$STUBBIN:$PATH" XDG_CONFIG_HOME="$TESTCFG" HOME="$TESTHOME" bash "$HERE/../scripts/session-doctor.sh" reap-local 2>&1)"
ok "reap-local-ignores-is-active" "$(printf '%s' "$orphan_out" | grep -qF 'ORPHAN unit (no tmux): ah-test-orphan-0101-0100.service' && echo yes || echo no)" "yes"
rm -rf "$STUBBIN" "$TESTCFG" "$TESTHOME"

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

  # PID-suffixed directory (session-git-prep's collision fallback: the WORKTREE dir
  # gets a -$$ suffix but the BRANCH — and so the real tmux session — stays
  # unsuffixed). Liveness must be derived from the branch, not the directory name,
  # or a live session's worktree gets misreported as stale and offered for --force
  # removal (regression: found via review).
  WT_PIDLIVE="$WTHOME/.claude/worktrees/ah-wtpidlive-0101-0900-99999"
  git -C "$REPO" worktree add -q -b session/ah-wtpidlive-0101-0900 "$WT_PIDLIVE" main >/dev/null 2>&1
  tmux new-session -d -s ah_wtpidlive-0101-0900 -c "$WT_PIDLIVE" 'sleep 60'
  wtout2="$(HOME="$WTHOME" bash "$HERE/../scripts/session-doctor.sh" worktree-stale)"
  tmux kill-session -t ah_wtpidlive-0101-0900 2>/dev/null || true
  ok "worktree-stale-skips-pidsuffixed-live" "$(printf '%s' "$wtout2" | grep -qF "$WT_PIDLIVE" && echo yes || echo no)" "no"

  # A dead worktree whose session switched off its session/<remote> branch onto
  # something else must NOT suggest `branch -D` on that (possibly unmerged,
  # unrelated) branch — only the worktree removal (regression: found via review).
  WT_SWITCHED="$WTHOME/.claude/worktrees/ah-wtswitched-0101-0900"
  git -C "$REPO" worktree add -q -b session/ah-wtswitched-0101-0900 "$WT_SWITCHED" main >/dev/null 2>&1
  git -C "$WT_SWITCHED" checkout -q -b feature/unrelated >/dev/null 2>&1
  wtout3="$(HOME="$WTHOME" bash "$HERE/../scripts/session-doctor.sh" worktree-stale)"
  ok "worktree-stale-lists-switched-branch" "$(printf '%s' "$wtout3" | grep -qF "$WT_SWITCHED" && echo yes || echo no)" "yes"
  ok "worktree-stale-no-branch-D-on-switched" "$(printf '%s' "$wtout3" | grep -A1 -F "$WT_SWITCHED" | grep -qF 'branch -D' && echo yes || echo no)" "no"

  # Removal command must be safe to copy-paste even when a path contains a space
  # (and generally shell-quoted) — regression: found via review (unquoted %s
  # interpolation).
  REPO_SP="$WTTMP/my repo"; git clone -q "$REPO" "$REPO_SP" >/dev/null 2>&1
  WT_SP="$WTHOME/.claude/worktrees/ah-wtspacey-0101-0900"
  git -C "$REPO_SP" worktree add -q -b session/ah-wtspacey-0101-0900 "$WT_SP" main >/dev/null 2>&1
  wtout4="$(HOME="$WTHOME" bash "$HERE/../scripts/session-doctor.sh" worktree-stale)"
  cmd="$(printf '%s' "$wtout4" | grep -F 'remove:' | grep -F "$WT_SP" | sed 's/^ *remove: //')"
  ( eval "$cmd" ) >/dev/null 2>&1
  ok "worktree-stale-quoted-cmd-evals-cleanly" "$?" "0"
  ok "worktree-stale-quoted-cmd-removed-it" "$([ -d "$WT_SP" ] && echo yes || echo no)" "no"
fi

echo "session-doctor: pass=$pass fail=$fail"; [ "$fail" -eq 0 ]
