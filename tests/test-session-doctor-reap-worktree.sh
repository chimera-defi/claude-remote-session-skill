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
source "$HERE/lib.sh"
isolate_overlay
# Fixture shape: configured prefix "px", legacy "oldhost" — see
# examples/crss-overlay/README.md. Fixtures below assume this (smaller diff
# than converting every "px_"/"px-" literal to a generic-default shape).
export CRSS_SESSION_PREFIX=px
export CRSS_LEGACY_PREFIXES=oldhost
DOCTOR="$HERE/../scripts/session-doctor.sh"
# shellcheck disable=SC1090
source "$DOCTOR"   # must NOT run dispatch (source-guard)

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

WT_CLEAN="$TESTHOME/.claude/worktrees/px-rwclean-0101-0900"
git -C "$REPO" worktree add -q -b session/px-rwclean-0101-0900 "$WT_CLEAN" main >/dev/null 2>&1

WT_DIRTY="$TESTHOME/.claude/worktrees/px-rwdirty-0101-0900"
git -C "$REPO" worktree add -q -b session/px-rwdirty-0101-0900 "$WT_DIRTY" main >/dev/null 2>&1
echo untracked > "$WT_DIRTY/scratch.txt"

WT_WORKDIR="$TESTHOME/.claude/worktrees/px-rwworkdir-0101-0900"
git -C "$REPO" worktree add -q -b session/px-rwworkdir-0101-0900 "$WT_WORKDIR" main >/dev/null 2>&1
cat > "$UDIR/some-other-bus-unit.service" <<EOF
[Service]
WorkingDirectory=$WT_WORKDIR
ExecStart=/bin/true
EOF

WT_DROPIN="$TESTHOME/.claude/worktrees/px-rwdropin-0101-0900"
git -C "$REPO" worktree add -q -b session/px-rwdropin-0101-0900 "$WT_DROPIN" main >/dev/null 2>&1
mkdir -p "$UDIR/another-bus-unit.service.d"
cat > "$UDIR/another-bus-unit.service.d/override.conf" <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/python3 bus.py --state-dir=$WT_DROPIN
EOF

WT_OWNUNIT="$TESTHOME/.claude/worktrees/px-rwownunit-0101-0900"
git -C "$REPO" worktree add -q -b session/px-rwownunit-0101-0900 "$WT_OWNUNIT" main >/dev/null 2>&1
cat > "$UDIR/px-rwownunit-0101-0900.service" <<EOF
[Service]
WorkingDirectory=$WT_OWNUNIT
ExecStart=/bin/true
EOF

# ── 1. a clean worktree is removed and its branch is kept ─────────────────
out1="$(_reap_remove_worktree px-rwclean-0101-0900 no)"
nodir "clean-removed-dir-gone" "$WT_CLEAN"
ok "clean-branch-kept" "$(yn git -C "$REPO" show-ref --verify --quiet refs/heads/session/px-rwclean-0101-0900)" yes
has "clean-removed-message" "$out1" "worktree removed"

# ── 2. a dirty one is kept with a message (no --force) ─────────────────────
out2="$(_reap_remove_worktree px-rwdirty-0101-0900 no)"
isdir "dirty-kept-dir-present" "$WT_DIRTY"
has "dirty-kept-message" "$out2" "kept"

# same dirty worktree, but under reap's own --force => --force is passed
# through to `git worktree remove` and it actually goes, branch still kept.
out2f="$(_reap_remove_worktree px-rwdirty-0101-0900 yes)"
nodir "dirty-force-removed" "$WT_DIRTY"
ok "dirty-force-branch-kept" "$(yn git -C "$REPO" show-ref --verify --quiet refs/heads/session/px-rwdirty-0101-0900)" yes
has "dirty-force-removed-message" "$out2f" "worktree removed"

# (--keep-worktree itself is covered end-to-end in case 12b below, through
# the real `reap` dispatch — see its comment for why that, not a direct
# _reap_remove_worktree call, is the meaningful test of the flag.)

# ── 4. unit-reference guard: a WorkingDirectory hit keeps the worktree ─────
out4="$(_reap_remove_worktree px-rwworkdir-0101-0900 no)"
isdir "workdir-guard-kept" "$WT_WORKDIR"
has "workdir-guard-message" "$out4" "in use by unit some-other-bus-unit.service"

# ── 5. unit-reference guard: a drop-in ExecStart hit keeps the worktree ────
out5="$(_reap_remove_worktree px-rwdropin-0101-0900 no)"
isdir "dropin-guard-kept" "$WT_DROPIN"
has "dropin-guard-message" "$out5" "in use by unit another-bus-unit.service"

# ── 5b. unit-reference guard: a drop-in referencing the worktree only via
# systemd's %h specifier (= $HOME) must still be caught — real case:
# a service.d/state-dir.conf drop-in spells the path
# %h/.claude/worktrees/<name>/... instead of $HOME/.claude/worktrees/... ────
WT_PCTH="$TESTHOME/.claude/worktrees/px-rwpcth-0101-0900"
git -C "$REPO" worktree add -q -b session/px-rwpcth-0101-0900 "$WT_PCTH" main >/dev/null 2>&1
mkdir -p "$UDIR/pcth-bus-unit.service.d"
cat > "$UDIR/pcth-bus-unit.service.d/state-dir.conf" <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/python3 bus.py --state-dir=%h/.claude/worktrees/px-rwpcth-0101-0900
EOF
out5b="$(_reap_remove_worktree px-rwpcth-0101-0900 no)"
isdir "pcth-guard-kept" "$WT_PCTH"
has "pcth-guard-message" "$out5b" "in use by unit pcth-bus-unit.service"

# ── 6. the guard excludes the session's OWN unit (own WorkingDirectory match
# must not block removal of its own worktree) ─────────────────────────────
out6="$(_reap_remove_worktree px-rwownunit-0101-0900 no)"
nodir "ownunit-not-self-blocked" "$WT_OWNUNIT"
has "ownunit-removed-message" "$out6" "worktree removed"

# ── 7. a primary checkout (the resolved path IS itself a repo root, not a
# linked worktree of some other repo) is never removed ────────────────────
PRIMARY="$TESTHOME/.claude/worktrees/px-rwprimary-0101-0900"
mkdir -p "$PRIMARY"
git -C "$PRIMARY" init -q -b main
git -C "$PRIMARY" config user.email t@t.com; git -C "$PRIMARY" config user.name t
git -C "$PRIMARY" commit -q --allow-empty -m init
out7="$(_reap_remove_worktree px-rwprimary-0101-0900 no)"
isdir "primary-checkout-kept" "$PRIMARY"
has "primary-checkout-message" "$out7" "primary checkout"

# ── 8. no worktree at all for a base -> "(ok)", not an error ──────────────
out8="$(_reap_remove_worktree px-rwmissing-0101-0900 no)"
has "missing-worktree-ok" "$out8" "none found"

# ── 9. _is_caller_cwd / caller's own cwd is never removed ─────────────────
WT_CWD="$TESTHOME/.claude/worktrees/px-rwcwd-0101-0900"
git -C "$REPO" worktree add -q -b session/px-rwcwd-0101-0900 "$WT_CWD" main >/dev/null 2>&1
out9="$(cd "$WT_CWD" && _reap_remove_worktree px-rwcwd-0101-0900 no)"
isdir "callercwd-kept" "$WT_CWD"
has "callercwd-message" "$out9" "caller's own working directory"

# ── 10. PID-suffix collision: session-git-prep.sh suffixes the worktree
# DIRECTORY with -$$ on a path collision while leaving the BRANCH
# (session/<base>) unsuffixed (see session-doctor.sh worktree-stale and
# session-preserve.sh's worktree_of(), which special-case this the same
# way). A naive "$HOME/.claude/worktrees/$base" path join would miss this
# directory entirely and silently leave it behind forever — confirm
# _reap_remove_worktree finds and removes it via the branch match instead.
WT_PIDSUFFIX="$TESTHOME/.claude/worktrees/px-rwpidsfx-0101-0900-88888"
git -C "$REPO" worktree add -q -b session/px-rwpidsfx-0101-0900 "$WT_PIDSUFFIX" main >/dev/null 2>&1
out10="$(_reap_remove_worktree px-rwpidsfx-0101-0900 no)"
nodir "pidsuffix-found-and-removed" "$WT_PIDSUFFIX"
ok "pidsuffix-branch-kept" "$(yn git -C "$REPO" show-ref --verify --quiet refs/heads/session/px-rwpidsfx-0101-0900)" yes
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
  WT_DISPATCH1="$TESTHOME/.claude/worktrees/px-rwdispatch1-0101-0900"
  git -C "$DISPATCHREPO" worktree add -q -b session/px-rwdispatch1-0101-0900 "$WT_DISPATCH1" main >/dev/null 2>&1
  disp1_out="$(PATH="$RSTUB:$PATH" HOME="$TESTHOME" bash "$DOCTOR" reap px_rwdispatch1-0101-0900 --force 2>&1)"
  nodir "dispatch-force-worktree-removed" "$WT_DISPATCH1"
  has "dispatch-force-reap-message" "$disp1_out" "reaped 'px_rwdispatch1-0101-0900'"
  has "dispatch-force-worktree-message" "$disp1_out" "worktree removed"

  # 12b. reap --force --keep-worktree -> worktree left completely alone.
  WT_DISPATCH2="$TESTHOME/.claude/worktrees/px-rwdispatch2-0101-0900"
  git -C "$DISPATCHREPO" worktree add -q -b session/px-rwdispatch2-0101-0900 "$WT_DISPATCH2" main >/dev/null 2>&1
  disp2_out="$(PATH="$RSTUB:$PATH" HOME="$TESTHOME" bash "$DOCTOR" reap px_rwdispatch2-0101-0900 --force --keep-worktree 2>&1)"
  isdir "dispatch-keepworktree-still-present" "$WT_DISPATCH2"
  has "dispatch-keepworktree-reap-message" "$disp2_out" "reaped 'px_rwdispatch2-0101-0900'"
  ok "dispatch-keepworktree-no-worktree-line" "$(printf '%s' "$disp2_out" | grep -c 'worktree removed\|worktree: kept\|worktree: none found')" "0"

  rm -rf "$RSTUB"
fi

# ── 12c. full `reap` must reject an unsafe derived base BEFORE any filesystem
# cleanup. `tmux_to_base px_/../../x` used to derive `px-/../../x`, which let
# the unit/start-script archive+rm paths escape ~/.config/systemd/user and
# ~/.local/bin. A reject here must be non-zero and delete nothing.
RSTUB_TRAV="$(mktemp -d)"
cat > "$RSTUB_TRAV/systemctl" <<'STUB_EOF'
#!/usr/bin/env bash
exit 0
STUB_EOF
chmod +x "$RSTUB_TRAV/systemctl"
mkdir -p "$TESTHOME/.config/systemd/user/px-" "$TESTHOME/.local/bin/px-"
printf 'keep unit\n' > "$TESTHOME/.config/systemd/x.service"
printf 'keep script\n' > "$TESTHOME/.local/x-start.sh"
trav_arch_before="$(find "$TESTHOME/backups/reaped-worktree-ignored" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
trav_out="$(PATH="$RSTUB_TRAV:$PATH" HOME="$TESTHOME" bash "$DOCTOR" reap 'px_/../../x' --force 2>&1)"; rc_trav=$?
ok "traversal-reap-exit-nonzero" "$(yn test "$rc_trav" -ne 0)" "yes"
has "traversal-reap-refuses-base" "$trav_out" "unsafe derived session base"
isfile "traversal-unit-sentinel-kept" "$TESTHOME/.config/systemd/x.service"
isfile "traversal-script-sentinel-kept" "$TESTHOME/.local/x-start.sh"
trav_arch_after="$(find "$TESTHOME/backups/reaped-worktree-ignored" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
ok "traversal-no-archive-created" "$trav_arch_after" "$trav_arch_before"
rm -rf "$RSTUB_TRAV"

# ── 13. gitignored payload: `git worktree remove` (with or without --force)
# silently deletes gitignored files, and _wt_dirty / session-preserve both
# ignore them, so a "clean" worktree can hold a whole campaign's results
# (a real data loss). reap must ARCHIVE the non-regenerable ones before
# removing, and keep the worktree if it cannot. The fixture repo ignores the
# same scaffolding paths the host's global git ignore does, so the deny-list
# (not git) is what has to keep those out of the payload.
IGNREPO="$WTTMP/ign-repo"; mkdir -p "$IGNREPO"
git -C "$IGNREPO" init -q -b main
git -C "$IGNREPO" config user.email t@t.com; git -C "$IGNREPO" config user.name t
cat > "$IGNREPO/.gitignore" <<'EOF'
artifacts/
node_modules/
.venv/
__pycache__/
.claude/skills
.claude/token-reduce-state/
.claude/tmp-briefs/
.claude/settings.local.json
.claude/CLAUDE.md
.superpowers/
.gstack/
.sessions-init-*
coverage/
*.tsbuildinfo
next-env.d.ts
EOF
echo hi > "$IGNREPO/a.txt"; git -C "$IGNREPO" add -A; git -C "$IGNREPO" commit -q -m init
printf '.config/\n' > "$WTTMP/global-ignore"
git -C "$IGNREPO" config core.excludesFile "$WTTMP/global-ignore"
ARCHROOT="$TESTHOME/backups/reaped-worktree-ignored"
mkwt(){ git -C "$IGNREPO" worktree add -q -b "session/$1" "$TESTHOME/.claude/worktrees/$1" main >/dev/null 2>&1; }
archives_of(){ ls -d "$ARCHROOT/$1"-* 2>/dev/null; }

# 13a. results under a gitignored artifacts/ -> archived byte-for-byte + MANIFEST,
# then the worktree is removed. Deny-listed node_modules content is NOT archived.
mkwt px-rwpayload-0101-0900
WT_PAY="$TESTHOME/.claude/worktrees/px-rwpayload-0101-0900"
mkdir -p "$WT_PAY/artifacts/sub" "$WT_PAY/node_modules/x"
printf 'raw\tdata\n1\t2\n' > "$WT_PAY/artifacts/results.tsv"
head -c 3000 /dev/urandom > "$WT_PAY/artifacts/sub/blob.bin"
echo junk > "$WT_PAY/node_modules/x/i.js"
cp "$WT_PAY/artifacts/results.tsv" "$WTTMP/orig-results.tsv"; cp "$WT_PAY/artifacts/sub/blob.bin" "$WTTMP/orig-blob.bin"
out13a="$(_reap_remove_worktree px-rwpayload-0101-0900 no)"
ARCH_A="$(archives_of px-rwpayload-0101-0900 | head -1)"
ok "payload-archive-dir-exists" "$([ -n "$ARCH_A" ] && [ -d "$ARCH_A" ] && echo yes || echo no)" "yes"
ok "payload-results-bytes-identical" "$(yn cmp -s "$WTTMP/orig-results.tsv" "$ARCH_A/worktree/artifacts/results.tsv")" yes
ok "payload-blob-bytes-identical" "$(yn cmp -s "$WTTMP/orig-blob.bin" "$ARCH_A/worktree/artifacts/sub/blob.bin")" yes
ok "payload-manifest-has-sha-size-path" "$(grep -cF "$(sha256sum < "$WTTMP/orig-results.tsv" | cut -d' ' -f1)"$'\t'"$(stat -c %s "$WTTMP/orig-results.tsv")"$'\t'"worktree/artifacts/results.tsv" "$ARCH_A/MANIFEST")" "1"
ok "payload-manifest-lists-both-files" "$(wc -l < "$ARCH_A/MANIFEST" | tr -d ' ')" "2"
gone "payload-denylisted-not-archived" "$ARCH_A/worktree/node_modules"
ok "payload-archive-dir-private" "$(stat -c %a "$ARCH_A")" "700"
has "payload-archived-message" "$out13a" "archived 2 ignored file(s)"
has "payload-archived-message-dest" "$out13a" "$ARCH_A"
has "payload-removed-message" "$out13a" "worktree removed"
nodir "payload-worktree-removed" "$WT_PAY"
ok "payload-branch-kept" "$(yn git -C "$IGNREPO" show-ref --verify --quiet refs/heads/session/px-rwpayload-0101-0900)" yes

# 13b. only deny-listed / scaffolding ignored content (node_modules, .venv,
# the spawner's .claude/skills symlink + sentinels, token-reduction telemetry)
# -> nothing archived, no archive dir even created, removal exactly as before.
mkwt px-rwdeny-0101-0900
WT_DENY="$TESTHOME/.claude/worktrees/px-rwdeny-0101-0900"
mkdir -p "$WT_DENY/node_modules/x" "$WT_DENY/.venv/lib" "$WT_DENY/pkg/node_modules/y" "$WT_DENY/__pycache__" \
         "$WT_DENY/.claude/token-reduce-state" "$WT_DENY/.claude/tmp-briefs" "$WT_DENY/.superpowers" "$WT_DENY/.gstack" \
         "$WT_DENY/artifacts/token-reduction"
echo a > "$WT_DENY/node_modules/x/i.js"; echo a > "$WT_DENY/.venv/lib/l.py"; echo a > "$WT_DENY/pkg/node_modules/y/i.js"
echo a > "$WT_DENY/__pycache__/m.pyc"; echo a > "$WT_DENY/.claude/token-reduce-state/s"; echo a > "$WT_DENY/.claude/tmp-briefs/b"
echo a > "$WT_DENY/.superpowers/p"; echo a > "$WT_DENY/.gstack/g"; echo a > "$WT_DENY/artifacts/token-reduction/events.jsonl"
echo a > "$WT_DENY/artifacts/qmd-repo-0123456789ab.stamp"; echo a > "$WT_DENY/.claude/settings.local.json"; echo a > "$WT_DENY/.claude/CLAUDE.md"
ln -s /nonexistent "$WT_DENY/.claude/skills"; echo a > "$WT_DENY/.sessions-init-px-rwdeny-0101-0900"
mkdir -p "$WT_DENY/frontend/coverage/lcov-report"; echo a > "$WT_DENY/frontend/coverage/lcov-report/base.css"
echo a > "$WT_DENY/frontend/tsconfig.tsbuildinfo"; echo a > "$WT_DENY/frontend/next-env.d.ts"
out13b="$(_reap_remove_worktree px-rwdeny-0101-0900 no)"
nodir "denylist-worktree-removed" "$WT_DENY"
ok "denylist-no-archive" "$(archives_of px-rwdeny-0101-0900 | wc -l | tr -d ' ')" "0"
ok "denylist-no-archived-line" "$(printf '%s' "$out13b" | grep -c 'archived')" "0"
has "denylist-removed-message" "$out13b" "worktree removed"

# 13c. payload over the cap -> worktree KEPT with a reason naming the cap; no
# archive left behind. (--force does not bypass this: it is the ignored files
# the operator never sees that this guard exists for.)
mkwt px-rwcap-0101-0900
WT_CAP="$TESTHOME/.claude/worktrees/px-rwcap-0101-0900"
mkdir -p "$WT_CAP/artifacts"; head -c 500 /dev/urandom > "$WT_CAP/artifacts/big.bin"
out13c="$(SESSION_DOCTOR_IGNORED_ARCHIVE_MAX_BYTES=100 _reap_remove_worktree px-rwcap-0101-0900 yes)"
isfile "cap-worktree-kept" "$WT_CAP/artifacts/big.bin"
has "cap-kept-message" "$out13c" "worktree: kept (gitignored files not archived"
has "cap-names-cap" "$out13c" "SESSION_DOCTOR_IGNORED_ARCHIVE_MAX_BYTES"
ok "cap-no-archive-dir" "$(archives_of px-rwcap-0101-0900 | wc -l | tr -d ' ')" "0"
# ...and the same payload under the default cap (2 GB) is archived + removed.
out13c2="$(_reap_remove_worktree px-rwcap-0101-0900 no)"
nodir "cap-default-archives-and-removes" "$WT_CAP"
has "cap-default-archived-message" "$out13c2" "archived 1 ignored file(s)"

# 13d. archive location unwritable (a regular FILE where ~/backups should be)
# -> worktree KEPT, with the reason; nothing removed.
mkwt px-rwunwr-0101-0900
WT_UNWR="$TESTHOME/.claude/worktrees/px-rwunwr-0101-0900"
mkdir -p "$WT_UNWR/artifacts"; echo data > "$WT_UNWR/artifacts/results.tsv"
mv "$TESTHOME/backups" "$TESTHOME/backups.real"; : > "$TESTHOME/backups"
out13d="$(_reap_remove_worktree px-rwunwr-0101-0900 yes)"
rm -f "$TESTHOME/backups"; mv "$TESTHOME/backups.real" "$TESTHOME/backups"
isfile "unwritable-worktree-kept" "$WT_UNWR/artifacts/results.tsv"
has "unwritable-kept-message" "$out13d" "worktree: kept (gitignored files not archived"

# 13e. payload guard is per-helper and independent of reap's other guards:
# a worktree another unit still runs from stays kept BEFORE any archive is made.
mkwt px-rwpayunit-0101-0900
WT_PU="$TESTHOME/.claude/worktrees/px-rwpayunit-0101-0900"
mkdir -p "$WT_PU/artifacts"; echo data > "$WT_PU/artifacts/results.tsv"
cat > "$UDIR/payload-bus.service" <<EOF
[Service]
WorkingDirectory=$WT_PU
ExecStart=/bin/true
EOF
out13e="$(_reap_remove_worktree px-rwpayunit-0101-0900 no)"
has "payload-unit-guard-message" "$out13e" "in use by unit payload-bus.service"
ok "payload-unit-guard-no-archive" "$(archives_of px-rwpayunit-0101-0900 | wc -l | tr -d ' ')" "0"

# 13f. _wt_ignored_payload directly: counts file-level (not the collapsed
# `artifacts/` entry), reports bytes + examples, keeps a bare `artifacts/`
# OUT of the deny-list (a deny-list entry for it would recreate the incident),
# and copes with awkward file names and symlinks.
mkwt px-rwhelper-0101-0900
WT_H="$TESTHOME/.claude/worktrees/px-rwhelper-0101-0900"
mkdir -p "$WT_H/artifacts/a b" "$WT_H/artifacts/token-reduction"
printf 12345 > "$WT_H/artifacts/results.tsv"; printf 123 > "$WT_H/artifacts/a b/spaced name.txt"
echo t > "$WT_H/artifacts/token-reduction/events.jsonl"; ln -s results.tsv "$WT_H/artifacts/link"
plist="$WTTMP/payload.list"
_wt_ignored_payload "$WT_H" "$plist"; rc13f=$?
ok "helper-nonempty-rc0" "$rc13f" "0"
ok "helper-counts-files-not-dirs" "$_WTI_COUNT" "3"
ok "helper-bytes-cover-regular-files" "$([ "$_WTI_BYTES" -ge 8 ] && [ "$_WTI_BYTES" -lt 100 ] && echo yes || echo no)" "yes"
has "helper-example-path" "$_WTI_EXAMPLES" "artifacts/"
ok "helper-list-has-spaced-name" "$(tr '\0' '\n' < "$plist" | grep -cxF 'artifacts/a b/spaced name.txt')" "1"
ok "helper-list-excludes-token-reduction" "$(tr '\0' '\n' < "$plist" | grep -c 'token-reduction')" "0"
out13f="$(_wt_archive_ignored "$WT_H")"; rc13f2=$?
ARCH_H="$(archives_of px-rwhelper-0101-0900 | head -1)"
ok "helper-archive-rc0" "$rc13f2" "0"
has "helper-archive-message" "$out13f" "archived 3 ignored file(s)"
ok "helper-archive-spaced-name-bytes" "$(yn cmp -s "$WT_H/artifacts/a b/spaced name.txt" "$ARCH_H/worktree/artifacts/a b/spaced name.txt")" yes
ok "helper-archive-symlink-kept-as-link" "$(readlink "$ARCH_H/worktree/artifacts/link")" "results.tsv"
# an empty payload returns 1 and leaves the list empty
mkwt px-rwhelper2-0101-0900
_wt_ignored_payload "$TESTHOME/.claude/worktrees/px-rwhelper2-0101-0900" "$plist"; rc13g=$?
ok "helper-empty-rc1" "$rc13g" "1"
ok "helper-empty-count0" "$_WTI_COUNT" "0"

# 13i. the copy is VERIFIED, and any archive failure fails closed: a test-only
# sitecustomize (on PYTHONPATH, so no hook lives in the script) makes
# shutil.copy2 append a byte to every copy. The verify step must catch it, keep
# the worktree, and remove its own partial archive.
CORRUPT="$WTTMP/corrupt-py"; mkdir -p "$CORRUPT"
cat > "$CORRUPT/sitecustomize.py" <<'PYEOF'
import shutil
_orig = shutil.copy2
def _bad(src, dst, **kw):
    _orig(src, dst, **kw)
    with open(dst, 'ab') as f:
        f.write(b'X')
    return dst
shutil.copy2 = _bad
PYEOF
mkwt px-rwcorrupt-0101-0900
WT_CORR="$TESTHOME/.claude/worktrees/px-rwcorrupt-0101-0900"
mkdir -p "$WT_CORR/artifacts"; echo data > "$WT_CORR/artifacts/results.tsv"
out13i="$(PYTHONPATH="$CORRUPT" _reap_remove_worktree px-rwcorrupt-0101-0900 yes)"
isfile "verify-corrupt-copy-worktree-kept" "$WT_CORR/artifacts/results.tsv"
has "verify-corrupt-copy-message" "$out13i" "gitignored files not archived"
has "verify-corrupt-copy-says-verify" "$out13i" "verify failed"
ok "verify-corrupt-copy-partial-archive-removed" "$(archives_of px-rwcorrupt-0101-0900 | wc -l | tr -d ' ')" "0"

# an unreadable payload file (skipped as root, which ignores modes) -> kept.
if [ "$(id -u)" -ne 0 ]; then
  mkwt px-rwunread-0101-0900
  WT_UR="$TESTHOME/.claude/worktrees/px-rwunread-0101-0900"
  mkdir -p "$WT_UR/artifacts"; echo data > "$WT_UR/artifacts/results.tsv"; echo more > "$WT_UR/artifacts/secret.bin"; chmod 000 "$WT_UR/artifacts/secret.bin"
  out13j="$(_reap_remove_worktree px-rwunread-0101-0900 yes)"
  chmod 600 "$WT_UR/artifacts/secret.bin"
  isfile "unreadable-worktree-kept" "$WT_UR/artifacts/results.tsv"
  has "unreadable-kept-message" "$out13j" "gitignored files not archived"
  ok "unreadable-partial-archive-removed" "$(archives_of px-rwunread-0101-0900 | wc -l | tr -d ' ')" "0"
fi

# 13k. enumeration failure fails CLOSED: an unreadable directory inside the
# payload means the list is incomplete, so the helper returns 2 (never "empty"),
# reap keeps the worktree, and nothing is archived (skipped as root).
if [ "$(id -u)" -ne 0 ]; then
  mkwt px-rwlocked-0101-0900
  WT_LK="$TESTHOME/.claude/worktrees/px-rwlocked-0101-0900"
  mkdir -p "$WT_LK/artifacts/locked"; echo data > "$WT_LK/artifacts/results.tsv"; echo more > "$WT_LK/artifacts/locked/f"; chmod 000 "$WT_LK/artifacts/locked"
  _wt_ignored_payload "$WT_LK" "$plist"; rc13k=$?
  ok "helper-unreadable-dir-rc2" "$rc13k" "2"
  out13k="$(_reap_remove_worktree px-rwlocked-0101-0900 yes)"
  chmod 755 "$WT_LK/artifacts/locked"
  isfile "unreadable-dir-worktree-kept" "$WT_LK/artifacts/results.tsv"
  has "unreadable-dir-kept-message" "$out13k" "could not list the gitignored files"
  ok "unreadable-dir-no-archive" "$(archives_of px-rwlocked-0101-0900 | wc -l | tr -d ' ')" "0"
fi

# 13g. full `reap` dispatch: cap / unwritable / --keep-worktree, end-to-end.
# Teardown must continue past a kept worktree (exit 0, "reaped" printed), and
# --keep-worktree must not archive anything.
if command -v tmux >/dev/null 2>&1; then
  RSTUB2="$(mktemp -d)"; printf '#!/usr/bin/env bash\nexit 0\n' > "$RSTUB2/systemctl"; chmod +x "$RSTUB2/systemctl"
  reapd(){ PATH="$RSTUB2:$PATH" HOME="$TESTHOME" bash "$DOCTOR" reap "$@" 2>&1; }

  mkwt px-rwdcap-0101-0900; WT_DC="$TESTHOME/.claude/worktrees/px-rwdcap-0101-0900"
  mkdir -p "$WT_DC/artifacts"; head -c 500 /dev/urandom > "$WT_DC/artifacts/big.bin"
  d_cap="$(SESSION_DOCTOR_IGNORED_ARCHIVE_MAX_BYTES=100 reapd px_rwdcap-0101-0900 --force)"; rc_dc=$?
  ok "dispatch-cap-exit0" "$rc_dc" "0"
  has "dispatch-cap-teardown-continues" "$d_cap" "reaped 'px_rwdcap-0101-0900'"
  has "dispatch-cap-kept-message" "$d_cap" "worktree: kept (gitignored files not archived"
  isfile "dispatch-cap-worktree-kept" "$WT_DC/artifacts/big.bin"

  mkwt px-rwdunw-0101-0900; WT_DU="$TESTHOME/.claude/worktrees/px-rwdunw-0101-0900"
  mkdir -p "$WT_DU/artifacts"; echo data > "$WT_DU/artifacts/results.tsv"
  mv "$TESTHOME/backups" "$TESTHOME/backups.real"; : > "$TESTHOME/backups"
  d_unw="$(reapd px_rwdunw-0101-0900 --force)"; rc_du=$?
  rm -f "$TESTHOME/backups"; mv "$TESTHOME/backups.real" "$TESTHOME/backups"
  ok "dispatch-unwritable-exit0" "$rc_du" "0"
  has "dispatch-unwritable-teardown-continues" "$d_unw" "reaped 'px_rwdunw-0101-0900'"
  isfile "dispatch-unwritable-worktree-kept" "$WT_DU/artifacts/results.tsv"

  mkwt px-rwdkeep-0101-0900; WT_DK="$TESTHOME/.claude/worktrees/px-rwdkeep-0101-0900"
  mkdir -p "$WT_DK/artifacts"; echo data > "$WT_DK/artifacts/results.tsv"
  d_keep="$(reapd px_rwdkeep-0101-0900 --force --keep-worktree)"
  ARCH_DK="$(archives_of px-rwdkeep-0101-0900 | head -1)"
  isfile "dispatch-keep-worktree-present" "$WT_DK/artifacts/results.tsv"
  ok "dispatch-keep-worktree-unit-archive-dir" "$([ -n "$ARCH_DK" ] && [ -d "$ARCH_DK" ] && echo yes || echo no)" "yes"
  ok "dispatch-keep-worktree-no-ignored-archive-line" "$(printf '%s' "$d_keep" | grep -c 'ignored file(s)\|worktree removed\|worktree: kept')" "0"

  mkwt px-rwdok-0101-0900; WT_DO="$TESTHOME/.claude/worktrees/px-rwdok-0101-0900"
  mkdir -p "$WT_DO/artifacts"; echo data > "$WT_DO/artifacts/results.tsv"
  d_ok="$(reapd px_rwdok-0101-0900 --force)"
  has "dispatch-archived-message" "$d_ok" "archived 1 ignored file(s)"
  nodir "dispatch-archived-and-removed" "$WT_DO"
  ok "dispatch-archived-copy-exists" "$(archives_of px-rwdok-0101-0900 | head -1 | xargs -I{} test -f {}/worktree/artifacts/results.tsv && echo yes || echo no)" "yes"

  # 13l. A unit/start-script artifact and an ignored worktree payload with the
  # same relative path must not share one archive destination. Keep them in
  # separate archive subtrees so the worktree copy cannot overwrite the unit.
  mkwt px-rwdcollide-0101-0900; WT_COL="$TESTHOME/.claude/worktrees/px-rwdcollide-0101-0900"
  mkdir -p "$TESTHOME/.config/systemd/user" "$WT_COL/.config/systemd/user"
  printf 'unit bytes\n' > "$TESTHOME/.config/systemd/user/px-rwdcollide-0101-0900.service"
  printf 'worktree bytes\n' > "$WT_COL/.config/systemd/user/px-rwdcollide-0101-0900.service"
  d_col="$(reapd px_rwdcollide-0101-0900 --force)"
  ARCH_COL="$(archives_of px-rwdcollide-0101-0900 | head -1)"
  has "dispatch-collision-unit-archived" "$d_col" "archived 1 unit/start file(s)"
  has "dispatch-collision-worktree-archived" "$d_col" "archived 1 ignored file(s)"
  ok "dispatch-collision-unit-bytes" "$(grep -qxF 'unit bytes' "$ARCH_COL/unit/.config/systemd/user/px-rwdcollide-0101-0900.service" && echo yes || echo no)" "yes"
  ok "dispatch-collision-worktree-bytes" "$(grep -qxF 'worktree bytes' "$ARCH_COL/worktree/.config/systemd/user/px-rwdcollide-0101-0900.service" && echo yes || echo no)" "yes"
  ok "dispatch-collision-manifest-unit" "$(grep -cF $'\tunit/.config/systemd/user/px-rwdcollide-0101-0900.service' "$ARCH_COL/MANIFEST")" "1"
  ok "dispatch-collision-manifest-worktree" "$(grep -cF $'\tworktree/.config/systemd/user/px-rwdcollide-0101-0900.service' "$ARCH_COL/MANIFEST")" "1"

  # 13h. `archive-ignored <worktree>` — the explicit form of the same step.
  mkwt px-rwsub-0101-0900; WT_S="$TESTHOME/.claude/worktrees/px-rwsub-0101-0900"
  mkdir -p "$WT_S/artifacts"; echo data > "$WT_S/artifacts/results.tsv"
  s_out="$(HOME="$TESTHOME" bash "$DOCTOR" archive-ignored "$WT_S" 2>&1)"; rc_s=$?
  ok "subcmd-archive-rc0" "$rc_s" "0"
  has "subcmd-archive-message" "$s_out" "archived 1 ignored file(s)"
  isfile "subcmd-leaves-worktree-alone" "$WT_S/artifacts/results.tsv"
  s_out2="$(HOME="$TESTHOME" bash "$DOCTOR" archive-ignored "$WT_DENY" 2>&1)"; rc_s2=$?   # removed dir -> not a worktree
  ok "subcmd-nonworktree-rc2" "$rc_s2" "2"
  has "subcmd-nonworktree-message" "$s_out2" "not the top of a git worktree"
  mkwt px-rwsub2-0101-0900
  s_out3="$(HOME="$TESTHOME" bash "$DOCTOR" archive-ignored "$TESTHOME/.claude/worktrees/px-rwsub2-0101-0900" 2>&1)"; rc_s3=$?
  ok "subcmd-empty-rc0" "$rc_s3" "0"
  has "subcmd-empty-message" "$s_out3" "no gitignored payload"
  s_out4="$(SESSION_DOCTOR_IGNORED_ARCHIVE_MAX_BYTES=1 HOME="$TESTHOME" bash "$DOCTOR" archive-ignored "$WT_S" 2>&1)"; rc_s4=$?
  ok "subcmd-over-cap-rc1" "$rc_s4" "1"
  has "subcmd-over-cap-message" "$s_out4" "NOT archived"
  rm -rf "$RSTUB2"
fi

finish "session-doctor-reap-worktree"
