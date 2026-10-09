#!/usr/bin/env bash
# reap's worktree-removal step: _reap_remove_worktree and its guards (_is_caller_cwd, _wt_used_by_other_unit),
# called as sourced functions (a dirty worktree never reaches this step via `reap`: the preserve gate refuses first).
# Everything lives under a throwaway HOME with a fake systemd --user dir.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
isolate_overlay
export CRSS_REAP_MIN_AGE_H=0   # min-age gate is pinned in tests/test-reap-min-age.sh; this suite tests other reap behavior
# Fixture shape: configured prefix "px", legacy "oldhost".
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
# the functions read $HOME and $UD globals: point both at the fixture
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

# same dirty worktree under reap --force: --force reaches `git worktree remove`; branch still kept.
out2f="$(_reap_remove_worktree px-rwdirty-0101-0900 yes)"
nodir "dirty-force-removed" "$WT_DIRTY"
ok "dirty-force-branch-kept" "$(yn git -C "$REPO" show-ref --verify --quiet refs/heads/session/px-rwdirty-0101-0900)" yes
has "dirty-force-removed-message" "$out2f" "worktree removed"


# ── 4. unit-reference guard: a WorkingDirectory hit keeps the worktree ─────
out4="$(_reap_remove_worktree px-rwworkdir-0101-0900 no)"
isdir "workdir-guard-kept" "$WT_WORKDIR"
has "workdir-guard-message" "$out4" "in use by unit some-other-bus-unit.service"


# ── 5b. a drop-in referencing the worktree only via %h (= $HOME) must still be caught ──
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

# ── 6. the guard excludes the session's OWN unit ──
out6="$(_reap_remove_worktree px-rwownunit-0101-0900 no)"
nodir "ownunit-not-self-blocked" "$WT_OWNUNIT"
has "ownunit-removed-message" "$out6" "worktree removed"

# ── 7. a primary checkout (a repo root, not a linked worktree) is never removed ──
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

# ── 10. PID-suffix collision: the worktree DIR gets -$$ on collision while the BRANCH stays session/<base>;
# a plain path join would miss it, so _reap_remove_worktree must find it via the branch ──
WT_PIDSUFFIX="$TESTHOME/.claude/worktrees/px-rwpidsfx-0101-0900-88888"
git -C "$REPO" worktree add -q -b session/px-rwpidsfx-0101-0900 "$WT_PIDSUFFIX" main >/dev/null 2>&1
out10="$(_reap_remove_worktree px-rwpidsfx-0101-0900 no)"
nodir "pidsuffix-found-and-removed" "$WT_PIDSUFFIX"
ok "pidsuffix-branch-kept" "$(yn git -C "$REPO" show-ref --verify --quiet refs/heads/session/px-rwpidsfx-0101-0900)" yes
has "pidsuffix-removed-message" "$out10" "worktree removed"


# ── 12. full `reap` dispatch (--force skips the preserve gate, so only the worktree step is under test):
# covers the KEEP_WORKTREE gate and --keep-worktree parsing the direct-helper calls above never reach ──

# ── 12c. reap must reject an unsafe derived base (`px_/../../x`) BEFORE any cleanup; non-zero, deletes nothing ──
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

# ── 13. gitignored payload: `git worktree remove` silently deletes ignored files that _wt_dirty ignores, so reap
# must ARCHIVE non-regenerable ones first and keep the worktree if it cannot. The deny-list (not git) must
# keep scaffolding out of the payload. ──
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

# 13c. payload over the cap -> worktree KEPT naming the cap, no archive left (--force does not bypass).
mkwt px-rwcap-0101-0900
WT_CAP="$TESTHOME/.claude/worktrees/px-rwcap-0101-0900"
mkdir -p "$WT_CAP/artifacts"; head -c 500 /dev/urandom > "$WT_CAP/artifacts/big.bin"
out13c="$(SESSION_DOCTOR_IGNORED_ARCHIVE_MAX_BYTES=100 _reap_remove_worktree px-rwcap-0101-0900 yes)"
isfile "cap-worktree-kept" "$WT_CAP/artifacts/big.bin"
has "cap-kept-message" "$out13c" "worktree: kept (gitignored files not archived"
has "cap-names-cap" "$out13c" "SESSION_DOCTOR_IGNORED_ARCHIVE_MAX_BYTES"
ok "cap-no-archive-dir" "$(archives_of px-rwcap-0101-0900 | wc -l | tr -d ' ')" "0"

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


# 13f. _wt_ignored_payload: counts files (not the collapsed `artifacts/`), keeps bare `artifacts/` OUT of the deny-list,
# copes with odd file names and symlinks.
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

# 13i. the copy is VERIFIED; any archive failure fails closed (a test-only sitecustomize corrupts every copy:
# verify must catch it, keep the worktree, remove its partial archive).
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


# 13k. enumeration failure fails CLOSED: unreadable dir -> helper returns 2, reap keeps the worktree, nothing archived (skipped as root).
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

# 13g. full `reap`: cap / unwritable / --keep-worktree end-to-end; teardown continues past a kept worktree, --keep-worktree archives nothing.
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

  # 13l. a unit artifact and a worktree payload with the same relative path must not share an archive destination.
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
  rm -rf "$RSTUB2"
fi

finish "session-doctor-reap-worktree"
