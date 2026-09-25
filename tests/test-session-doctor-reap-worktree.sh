#!/usr/bin/env bash
# Tests for reap's worktree-removal step: _reap_remove_worktree and its guard
# helpers (_is_caller_cwd, _wt_used_by_other_unit). Exercised directly as
# sourced shell functions (same pattern test-session-doctor-registry-prune.sh
# uses for _registry_delete_one) rather than only through the full `reap`
# dispatch — a dirty-worktree case would otherwise never reach the worktree-
# removal step at all, because session-preserve's own safety gate (exercised
# separately in test-session-doctor.sh) already refuses a dirty session
# before `reap` gets this far. No real HOME, no real systemd unit, no
# network: everything lives under a throwaway HOME with a fake systemd
# --user dir, and $HOME/$UD (the globals session-doctor.sh's functions read
# directly) are pointed at that fixture for the rest of this process.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DOCTOR="$HERE/../scripts/session-doctor.sh"
# shellcheck disable=SC1090
source "$DOCTOR"   # must NOT run dispatch (source-guard)
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }
has(){ if printf '%s' "$2" | grep -qF "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — pattern not found: $3 in: $2"; fi; }

command -v git >/dev/null 2>&1 || { echo "session-doctor-reap-worktree: SKIP (no git)"; exit 0; }

WTTMP="$(mktemp -d)"; trap 'rm -rf "$WTTMP"' EXIT
REPO="$WTTMP/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@t.com; git -C "$REPO" config user.name t
echo hi > "$REPO/a.txt"; git -C "$REPO" add a.txt; git -C "$REPO" commit -q -m init

TESTHOME="$WTTMP/home"
mkdir -p "$TESTHOME/.claude/worktrees" "$TESTHOME/.config/systemd/user"
# _reap_remove_worktree/_wt_used_by_other_unit read $HOME and $UD directly
# (globals) — point both at this fixture for the rest of this process, the
# same as re-invoking `bash session-doctor.sh reap ...` with that HOME would.
export HOME="$TESTHOME"
UD="$TESTHOME/.config/systemd/user"
UDIR="$UD"

WT_CLEAN="$TESTHOME/.claude/worktrees/ah-rwclean-0101-0900"
git -C "$REPO" worktree add -q -b session/ah-rwclean-0101-0900 "$WT_CLEAN" main >/dev/null 2>&1

WT_DIRTY="$TESTHOME/.claude/worktrees/ah-rwdirty-0101-0900"
git -C "$REPO" worktree add -q -b session/ah-rwdirty-0101-0900 "$WT_DIRTY" main >/dev/null 2>&1
echo untracked > "$WT_DIRTY/scratch.txt"

WT_WORKDIR="$TESTHOME/.claude/worktrees/ah-rwworkdir-0101-0900"
git -C "$REPO" worktree add -q -b session/ah-rwworkdir-0101-0900 "$WT_WORKDIR" main >/dev/null 2>&1
cat > "$UDIR/some-other-bus-unit.service" <<EOF
[Service]
WorkingDirectory=$WT_WORKDIR
ExecStart=/bin/true
EOF

WT_DROPIN="$TESTHOME/.claude/worktrees/ah-rwdropin-0101-0900"
git -C "$REPO" worktree add -q -b session/ah-rwdropin-0101-0900 "$WT_DROPIN" main >/dev/null 2>&1
mkdir -p "$UDIR/another-bus-unit.service.d"
cat > "$UDIR/another-bus-unit.service.d/override.conf" <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/python3 bus.py --state-dir=$WT_DROPIN
EOF

WT_OWNUNIT="$TESTHOME/.claude/worktrees/ah-rwownunit-0101-0900"
git -C "$REPO" worktree add -q -b session/ah-rwownunit-0101-0900 "$WT_OWNUNIT" main >/dev/null 2>&1
cat > "$UDIR/ah-rwownunit-0101-0900.service" <<EOF
[Service]
WorkingDirectory=$WT_OWNUNIT
ExecStart=/bin/true
EOF

# ── 1. a clean worktree is removed and its branch is kept ─────────────────
out1="$(_reap_remove_worktree ah-rwclean-0101-0900 no)"
ok "clean-removed-dir-gone" "$([ -d "$WT_CLEAN" ] && echo yes || echo no)" "no"
ok "clean-branch-kept" "$(git -C "$REPO" show-ref --verify --quiet refs/heads/session/ah-rwclean-0101-0900 && echo yes || echo no)" "yes"
has "clean-removed-message" "$out1" "worktree removed"

# ── 2. a dirty one is kept with a message (no --force) ─────────────────────
out2="$(_reap_remove_worktree ah-rwdirty-0101-0900 no)"
ok "dirty-kept-dir-present" "$([ -d "$WT_DIRTY" ] && echo yes || echo no)" "yes"
has "dirty-kept-message" "$out2" "kept"

# same dirty worktree, but under reap's own --force => --force is passed
# through to `git worktree remove` and it actually goes, branch still kept.
out2f="$(_reap_remove_worktree ah-rwdirty-0101-0900 yes)"
ok "dirty-force-removed" "$([ -d "$WT_DIRTY" ] && echo yes || echo no)" "no"
ok "dirty-force-branch-kept" "$(git -C "$REPO" show-ref --verify --quiet refs/heads/session/ah-rwdirty-0101-0900 && echo yes || echo no)" "yes"
has "dirty-force-removed-message" "$out2f" "worktree removed"

# (--keep-worktree itself is covered end-to-end in case 12b below, through
# the real `reap` dispatch — see its comment for why that, not a direct
# _reap_remove_worktree call, is the meaningful test of the flag.)

# ── 4. unit-reference guard: a WorkingDirectory hit keeps the worktree ─────
out4="$(_reap_remove_worktree ah-rwworkdir-0101-0900 no)"
ok "workdir-guard-kept" "$([ -d "$WT_WORKDIR" ] && echo yes || echo no)" "yes"
has "workdir-guard-message" "$out4" "in use by unit some-other-bus-unit.service"

# ── 5. unit-reference guard: a drop-in ExecStart hit keeps the worktree ────
out5="$(_reap_remove_worktree ah-rwdropin-0101-0900 no)"
ok "dropin-guard-kept" "$([ -d "$WT_DROPIN" ] && echo yes || echo no)" "yes"
has "dropin-guard-message" "$out5" "in use by unit another-bus-unit.service"

# ── 5b. unit-reference guard: a drop-in referencing the worktree only via
# systemd's %h specifier (= $HOME) must still be caught — real case:
# bus-router-idle-reaper.service.d/state-dir.conf spells the path
# %h/.claude/worktrees/<name>/... instead of $HOME/.claude/worktrees/... ────
WT_PCTH="$TESTHOME/.claude/worktrees/ah-rwpcth-0101-0900"
git -C "$REPO" worktree add -q -b session/ah-rwpcth-0101-0900 "$WT_PCTH" main >/dev/null 2>&1
mkdir -p "$UDIR/pcth-bus-unit.service.d"
cat > "$UDIR/pcth-bus-unit.service.d/state-dir.conf" <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/python3 bus.py --state-dir=%h/.claude/worktrees/ah-rwpcth-0101-0900
EOF
out5b="$(_reap_remove_worktree ah-rwpcth-0101-0900 no)"
ok "pcth-guard-kept" "$([ -d "$WT_PCTH" ] && echo yes || echo no)" "yes"
has "pcth-guard-message" "$out5b" "in use by unit pcth-bus-unit.service"

# ── 6. the guard excludes the session's OWN unit (own WorkingDirectory match
# must not block removal of its own worktree) ─────────────────────────────
out6="$(_reap_remove_worktree ah-rwownunit-0101-0900 no)"
ok "ownunit-not-self-blocked" "$([ -d "$WT_OWNUNIT" ] && echo yes || echo no)" "no"
has "ownunit-removed-message" "$out6" "worktree removed"

# ── 7. a primary checkout (the resolved path IS itself a repo root, not a
# linked worktree of some other repo) is never removed ────────────────────
PRIMARY="$TESTHOME/.claude/worktrees/ah-rwprimary-0101-0900"
mkdir -p "$PRIMARY"
git -C "$PRIMARY" init -q -b main
git -C "$PRIMARY" config user.email t@t.com; git -C "$PRIMARY" config user.name t
git -C "$PRIMARY" commit -q --allow-empty -m init
out7="$(_reap_remove_worktree ah-rwprimary-0101-0900 no)"
ok "primary-checkout-kept" "$([ -d "$PRIMARY" ] && echo yes || echo no)" "yes"
has "primary-checkout-message" "$out7" "primary checkout"

# ── 8. no worktree at all for a base -> "(ok)", not an error ──────────────
out8="$(_reap_remove_worktree ah-rwmissing-0101-0900 no)"
has "missing-worktree-ok" "$out8" "none found"

# ── 9. _is_caller_cwd / caller's own cwd is never removed ─────────────────
WT_CWD="$TESTHOME/.claude/worktrees/ah-rwcwd-0101-0900"
git -C "$REPO" worktree add -q -b session/ah-rwcwd-0101-0900 "$WT_CWD" main >/dev/null 2>&1
out9="$(cd "$WT_CWD" && _reap_remove_worktree ah-rwcwd-0101-0900 no)"
ok "callercwd-kept" "$([ -d "$WT_CWD" ] && echo yes || echo no)" "yes"
has "callercwd-message" "$out9" "caller's own working directory"

# ── 10. PID-suffix collision: session-git-prep.sh suffixes the worktree
# DIRECTORY with -$$ on a path collision while leaving the BRANCH
# (session/<base>) unsuffixed (see session-doctor.sh worktree-stale and
# session-preserve.sh's worktree_of(), which special-case this the same
# way). A naive "$HOME/.claude/worktrees/$base" path join would miss this
# directory entirely and silently leave it behind forever — confirm
# _reap_remove_worktree finds and removes it via the branch match instead.
WT_PIDSUFFIX="$TESTHOME/.claude/worktrees/ah-rwpidsfx-0101-0900-88888"
git -C "$REPO" worktree add -q -b session/ah-rwpidsfx-0101-0900 "$WT_PIDSUFFIX" main >/dev/null 2>&1
out10="$(_reap_remove_worktree ah-rwpidsfx-0101-0900 no)"
ok "pidsuffix-found-and-removed" "$([ -d "$WT_PIDSUFFIX" ] && echo yes || echo no)" "no"
ok "pidsuffix-branch-kept" "$(git -C "$REPO" show-ref --verify --quiet refs/heads/session/ah-rwpidsfx-0101-0900 && echo yes || echo no)" "yes"
has "pidsuffix-removed-message" "$out10" "worktree removed"

# ── 11. `git worktree prune` ran afterward: no stale registrations left for
# worktrees actually removed above, but a kept one is still registered ─────
list_out="$(git -C "$REPO" worktree list --porcelain)"
ok "prune-clean-gone-from-list"      "$(printf '%s' "$list_out" | grep -c "$WT_CLEAN")" "0"
ok "prune-dirtyforce-gone-from-list" "$(printf '%s' "$list_out" | grep -c "$WT_DIRTY")" "0"
ok "prune-ownunit-gone-from-list"    "$(printf '%s' "$list_out" | grep -c "$WT_OWNUNIT")" "0"
ok "prune-pidsuffix-gone-from-list"  "$(printf '%s' "$list_out" | grep -c "$WT_PIDSUFFIX")" "0"
ok "prune-kept-still-listed"         "$(printf '%s' "$list_out" | grep -c "$WT_DROPIN")" "1"

# ── 12. full `reap` DISPATCH (not just the helper directly): a real `bash
# session-doctor.sh reap <name> --force` call, with a worktree fixture
# actually present at ~/.claude/worktrees/<base>, wires KEEP_WORKTREE/base
# through correctly end-to-end — the direct-helper calls above never
# exercise the `if [ "$KEEP_WORKTREE" != yes ] && [ -n "$base" ]` gate in the
# `reap)` case block itself, nor flag parsing for --keep-worktree. Mirrors
# test-session-doctor-registry-prune.sh's own end-to-end reap coverage for
# --keep-registry. --force skips the session-preserve gate (same as every
# other throwaway-session reap test in this repo) so only the worktree step
# is under test; HOME has no credentials, so the registry step fails soft
# and never touches the network.
if command -v tmux >/dev/null 2>&1; then
  RSTUB="$(mktemp -d)"
  cat > "$RSTUB/systemctl" <<'STUB_EOF'
#!/usr/bin/env bash
exit 0
STUB_EOF
  chmod +x "$RSTUB/systemctl"

  DISPATCHREPO="$WTTMP/dispatch-repo"; mkdir -p "$DISPATCHREPO"
  git -C "$DISPATCHREPO" init -q -b main
  git -C "$DISPATCHREPO" config user.email t@t.com; git -C "$DISPATCHREPO" config user.name t
  git -C "$DISPATCHREPO" commit -q --allow-empty -m init

  # 12a. reap --force (no --keep-worktree) -> worktree actually removed.
  WT_DISPATCH1="$TESTHOME/.claude/worktrees/ah-rwdispatch1-0101-0900"
  git -C "$DISPATCHREPO" worktree add -q -b session/ah-rwdispatch1-0101-0900 "$WT_DISPATCH1" main >/dev/null 2>&1
  disp1_out="$(PATH="$RSTUB:$PATH" HOME="$TESTHOME" bash "$DOCTOR" reap ah_rwdispatch1-0101-0900 --force 2>&1)"
  ok "dispatch-force-worktree-removed" "$([ -d "$WT_DISPATCH1" ] && echo yes || echo no)" "no"
  has "dispatch-force-reap-message" "$disp1_out" "reaped 'ah_rwdispatch1-0101-0900'"
  has "dispatch-force-worktree-message" "$disp1_out" "worktree removed"

  # 12b. reap --force --keep-worktree -> worktree left completely alone.
  WT_DISPATCH2="$TESTHOME/.claude/worktrees/ah-rwdispatch2-0101-0900"
  git -C "$DISPATCHREPO" worktree add -q -b session/ah-rwdispatch2-0101-0900 "$WT_DISPATCH2" main >/dev/null 2>&1
  disp2_out="$(PATH="$RSTUB:$PATH" HOME="$TESTHOME" bash "$DOCTOR" reap ah_rwdispatch2-0101-0900 --force --keep-worktree 2>&1)"
  ok "dispatch-keepworktree-still-present" "$([ -d "$WT_DISPATCH2" ] && echo yes || echo no)" "yes"
  has "dispatch-keepworktree-reap-message" "$disp2_out" "reaped 'ah_rwdispatch2-0101-0900'"
  ok "dispatch-keepworktree-no-worktree-line" "$(printf '%s' "$disp2_out" | grep -c 'worktree removed\|worktree: kept\|worktree: none found')" "0"

  rm -rf "$RSTUB"
fi

echo "session-doctor-reap-worktree: pass=$pass fail=$fail"; [ "$fail" -eq 0 ]
