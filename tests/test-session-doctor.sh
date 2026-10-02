#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
isolate_overlay
# Fixture shape: configured prefix "px", legacy "oldhost" (see examples/crss-overlay/README.md).
export CRSS_SESSION_PREFIX=px
export CRSS_LEGACY_PREFIXES=oldhost
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.com
SD="$HERE/../scripts/session-doctor.sh"
# shellcheck disable=SC1090
source "$SD"   # must NOT run report (source-guard)

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; for s in wtlive wtpidlive lclive reaplivetest reapdrytest; do tmux kill-session -t "px_$s-0101-0900" 2>/dev/null; done' EXIT
# systemctl stub: always "active", logs its argv (reap-local must not trust is-active; reap must daemon-reload).
mkdir -p "$TMP/stub"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "${SYSTEMCTL_LOG:-/dev/null}"\nexit 0\n' > "$TMP/stub/systemctl"; chmod +x "$TMP/stub/systemctl"

ok "legacy tmux->base" "$(tmux_to_base oldhost_foo-20260101-0900)" "oldhost-foo-20260101-0900"
ok "new tmux->base"    "$(tmux_to_base px_0101-0900-foo)"            "px-0101-0900-foo"
ok "foreign tmux->base" "$(tmux_to_base codexhost_x)"               ""
ok "legacy svc->tmux"  "$(svc_to_tmux oldhost-foo-20260101-0900)" "oldhost_foo-20260101-0900"
ok "new svc->tmux"     "$(svc_to_tmux px-0101-0900-foo)"            "px_0101-0900-foo"

# registry-stale must degrade gracefully (no traceback) with no credentials.
mkdir -p "$TMP/nohome"
out="$(HOME="$TMP/nohome" bash "$SD" registry-stale 2>&1)"
hasnt "registry-stale-no-traceback" "$out" Traceback
has "registry-stale-graceful-msg" "$out" '(registry unavailable)'

# --days is spliced into embedded Python: non-numeric is rejected up front (rc 2, clean message);
# valid values, including a leading-zero one (08 -> 8), must not crash it.
out="$(bash "$SD" registry-stale --days abc 2>&1)"; rc=$?
ok "days-nonnumeric-rejected" "$rc" 2
hasnt "days-nonnumeric-no-traceback" "$out" Traceback
has "days-nonnumeric-clean-msg" "$out" "--days requires a non-negative integer"
# An unknown --flag must be rejected before any mode runs (reap <name> --dry-run once reaped for real).
out="$(bash "$SD" reap px_nonexistent-0101-0900 --dryrun 2>&1)"; rc=$?
ok "reap-unknown-flag-rejected" "$rc" 2
has "reap-unknown-flag-msg" "$out" "unknown option '--dryrun'"
# --dry-run is contradictory with flags that mean "mutate": refused, not guessed.
out="$(bash "$SD" registry-prune --dry-run --apply 2>&1)"; rc=$?
ok "dry-run-apply-rejected" "$rc" 2
has "dry-run-apply-msg" "$out" "--dry-run cannot be combined with --apply"
out="$(bash "$SD" reap-local --dry-run --force 2>&1)"; rc=$?
ok "dry-run-reap-local-force-rejected" "$rc" 2
# ...and is refused by modes that would otherwise ignore it (archive-ignored writes under ~/backups).
out="$(bash "$SD" archive-ignored "$HERE/.." --dry-run 2>&1)"; rc=$?
ok "dry-run-archive-ignored-rejected" "$rc" 2
has "dry-run-archive-ignored-msg" "$out" "--dry-run is not supported for archive-ignored"
for d in 30 08; do
  out="$(bash "$SD" registry-stale --days $d 2>&1)"
  hasnt "days-$d-not-rejected" "$out" "requires a non-negative integer"
  hasnt "days-$d-no-traceback" "$out" Traceback
  hasnt "days-$d-no-syntaxerror" "$out" SyntaxError
done
has "days-leadingzero-normalized" "$out" '> 8d'

# backend_of / proc_alive read BACKEND from the generated start script (quoted and bare forms).
mkdir -p "$TMP/meta/.local/bin" "$TMP/metastub"
printf '#!/usr/bin/env bash\nBACKEND="codex"\nMODEL="gpt-5.5"\n' > "$TMP/meta/.local/bin/px-oldmeta-0101-0000-start.sh"
printf '#!/usr/bin/env bash\nBACKEND=codex\nMODEL=gpt-5.5\n' > "$TMP/meta/.local/bin/px-newmeta-0101-0001-start.sh"
printf '#!/usr/bin/env bash\n[ "$1" = display-message ] && { echo codex; exit 0; }\nexit 1\n' > "$TMP/metastub/tmux"; chmod +x "$TMP/metastub/tmux"
# shellcheck disable=SC2034  # backend_of reads BIN from the sourced script.
BIN="$TMP/meta/.local/bin"
ok "doctor-start-meta-old-backend" "$(backend_of px_oldmeta-0101-0000)" "codex"
ok "doctor-start-meta-new-backend" "$(backend_of px_newmeta-0101-0001)" "codex"
ok "doctor-codex-proc-alive-from-new-meta" "$(PATH="$TMP/metastub:$PATH" yn proc_alive px_newmeta-0101-0001)" "yes"

# reap-local must flag an orphan unit even though systemctl says "active" (Type=oneshot/RemainAfterExit
# units stay active after their tmux session dies; an is-active gate would defeat orphan reaping).
mkdir -p "$TMP/orph/cfg/systemd/user" "$TMP/orph/home"
touch "$TMP/orph/cfg/systemd/user/px-test-orphan-0101-0100.service"
out="$(PATH="$TMP/stub:$PATH" XDG_CONFIG_HOME="$TMP/orph/cfg" HOME="$TMP/orph/home" bash "$SD" reap-local 2>&1)"
has "reap-local-ignores-is-active" "$out" 'ORPHAN unit (no tmux): px-test-orphan-0101-0100.service'

# ── helpers for the git/tmux scenarios below ──────────────────────────────────
# mkrepo DIR [BRANCH]: repo with one commit.  mkwt REPO NAME [DIRNAME]: worktree under $WTD on branch session/NAME.
mkrepo() { git init -q -b "${2:-main}" "$1" >/dev/null 2>&1; echo hi > "$1/a.txt"; git -C "$1" add a.txt; git -C "$1" commit -q -m init; }
mkwt() { git -C "$1" worktree add -q -b "session/$2" "$WTD/${3:-$2}" main >/dev/null 2>&1; }
# blk TEXT PATH: a candidate row (its first line contains PATH) plus its indented continuation lines.
blk() { printf '%s\n' "$1" | awk -v p="$2" 'index($0,p){f=1;print;next} f&&/^    /{print;next} {f=0}'; }
rmline() { printf '%s\n' "$1" | grep -F 'remove:' | sed 's/^ *remove: //'; }
KEEP_PHRASE='— do not remove'

if command -v git >/dev/null 2>&1 && command -v tmux >/dev/null 2>&1; then
  # ── worktree-stale: dead-session worktrees listed with a removal command; live/protected skipped ──
  REPO="$TMP/repo"; mkrepo "$REPO"
  WTHOME="$TMP/home"; WTD="$WTHOME/.claude/worktrees"; mkdir -p "$WTD"
  WTUD="$WTHOME/.config/systemd/user"; mkdir -p "$WTUD"
  ws() { HOME="$WTHOME" XDG_CONFIG_HOME="$WTHOME/.config" bash "$SD" worktree-stale; }
  for n in px-wtdead-0101-0900 px-wtlive-0101-0900 px-thirdbot-0101-0900; do mkwt "$REPO" "$n"; done
  WT_DEAD="$WTD/px-wtdead-0101-0900"; WT_LIVE="$WTD/px-wtlive-0101-0900"; WT_PROT="$WTD/px-thirdbot-0101-0900"
  tmux new-session -d -s px_wtlive-0101-0900 -c "$WT_LIVE" 'sleep 60'
  # PROTECT's generic default is only "claude-remote"; thirdbot comes from config.
  out="$(HOME="$WTHOME" CRSS_PROTECT_NAMES='claude-remote|thirdbot' bash "$SD" worktree-stale)"
  tmux kill-session -t px_wtlive-0101-0900 2>/dev/null
  has "worktree-stale-lists-dead" "$out" "$WT_DEAD"
  hasnt "worktree-stale-skips-live" "$out" "$WT_LIVE"
  hasnt "worktree-stale-skips-protected" "$out" "$WT_PROT"
  has "worktree-stale-prints-removal-cmd" "$out" 'worktree remove --force'

  # PID-suffixed dir (session-git-prep collision fallback): liveness comes from the branch, not the dir name.
  mkwt "$REPO" px-wtpidlive-0101-0900 px-wtpidlive-0101-0900-99999
  tmux new-session -d -s px_wtpidlive-0101-0900 -c "$WTD/px-wtpidlive-0101-0900-99999" 'sleep 60'
  out="$(ws)"; tmux kill-session -t px_wtpidlive-0101-0900 2>/dev/null
  hasnt "worktree-stale-skips-pidsuffixed-live" "$out" "$WTD/px-wtpidlive-0101-0900-99999"

  # Session switched off its session/* branch: never suggest `branch -D` on the unrelated branch; clean row keeps --force.
  mkwt "$REPO" px-wtswitched-0101-0900; WT_SW="$WTD/px-wtswitched-0101-0900"
  git -C "$WT_SW" checkout -q -b feature/unrelated >/dev/null 2>&1
  b="$(blk "$(ws)" "$WT_SW")"
  has "worktree-stale-lists-switched-branch" "$b" "$WT_SW"
  hasnt "worktree-stale-no-branch-D-on-switched" "$b" 'branch -D'
  has "worktree-stale-clean-switched-keeps-force" "$(rmline "$b")" 'worktree remove --force'

  # The printed removal command must survive a path containing a space when eval'd.
  git clone -q "$REPO" "$TMP/my repo" >/dev/null 2>&1
  mkwt "$TMP/my repo" px-wtspacey-0101-0900; WT_SP="$WTD/px-wtspacey-0101-0900"
  out="$(ws)"
  ( eval "$(rmline "$(blk "$out" "$WT_SP")")" ) >/dev/null 2>&1
  ok "worktree-stale-quoted-cmd-evals-cleanly" "$?" 0
  nodir "worktree-stale-quoted-cmd-removed-it" "$WT_SP"
  ok "worktree-stale-no-units-no-keep" "$(grep -c KEEP <<<"$out")" 0

  # A dead worktree another systemd --user unit runs from gets KEEP and no `remove:` line
  # (same guard `reap` uses; see test-session-doctor-reap-worktree.sh).
  mkwt "$REPO" px-wtunit-0101-0900;  WT_UNIT="$WTD/px-wtunit-0101-0900"
  mkwt "$REPO" px-wtdrop-0101-0900;  WT_DROP="$WTD/px-wtdrop-0101-0900"
  mkwt "$REPO" px-wtown-0101-0900;   WT_OWN="$WTD/px-wtown-0101-0900"
  printf '[Service]\nWorkingDirectory=%s\nExecStart=/bin/true\n' "$WT_UNIT" > "$WTUD/wtstale-bus.service"
  mkdir -p "$WTUD/wtstale-reaper.service.d"   # drop-in referencing the path in %h form
  printf '[Service]\nExecStart=\nExecStart=/usr/bin/python3 bus.py --state-dir=%%h/.claude/worktrees/px-wtdrop-0101-0900\n' > "$WTUD/wtstale-reaper.service.d/state-dir.conf"
  # the dead session's OWN unit goes away with it, so it must not count as "another unit"
  printf '[Service]\nWorkingDirectory=%s\nExecStart=/bin/true\n' "$WT_OWN" > "$WTUD/px-wtown-0101-0900.service"
  out="$(ws)"
  b="$(blk "$out" "$WT_UNIT")"
  has "worktree-stale-unit-ref-still-listed" "$b" "$WT_UNIT"
  hasnt "worktree-stale-unit-ref-no-remove-line" "$b" 'remove:'
  hasnt "worktree-stale-unit-ref-no-branch-D" "$b" 'branch -D'
  has "worktree-stale-unit-ref-keep-names-unit" "$b" "KEEP: in use by unit wtstale-bus.service $KEEP_PHRASE"
  b="$(blk "$out" "$WT_DROP")"
  has "worktree-stale-dropin-ref-still-listed" "$b" "$WT_DROP"
  hasnt "worktree-stale-dropin-ref-no-remove-line" "$b" 'remove:'
  has "worktree-stale-dropin-ref-keep-names-unit" "$b" "KEEP: in use by unit wtstale-reaper.service $KEEP_PHRASE"
  # the guard must not over-block: unreferenced and own-unit rows keep their remove line, no KEEP
  for w in "$WT_DEAD" "$WT_OWN"; do
    b="$(blk "$out" "$w")"
    has "worktree-stale-unblocked-has-remove-$(basename "$w")" "$b" 'remove:'
    hasnt "worktree-stale-unblocked-no-keep-$(basename "$w")" "$b" 'KEEP:'
  done
  has "worktree-stale-footer-counts-keeps" "$out" ", 2 KEEP (in use by a systemd unit"

  # Gitignored payload: `git worktree remove` deletes ignored files, so a row with non-regenerable
  # ignored files gets a NOTE and the archive chained ahead of remove. No payload (none, or only
  # deny-listed node_modules/.venv) and KEEP rows are unchanged.
  printf 'artifacts/\nnode_modules/\n.venv/\n' >> "$REPO/.git/info/exclude"
  for n in pay nopay paydirty paykeep; do mkwt "$REPO" px-wt$n-0101-0900; done
  WT_PAY="$WTD/px-wtpay-0101-0900"
  mkdir -p "$WT_PAY/artifacts"; echo raw > "$WT_PAY/artifacts/results.tsv"; echo more > "$WT_PAY/artifacts/keeper.log"
  mkdir -p "$WTD/px-wtnopay-0101-0900/node_modules/x" "$WTD/px-wtnopay-0101-0900/.venv/lib"
  echo a > "$WTD/px-wtnopay-0101-0900/node_modules/x/i.js"; echo a > "$WTD/px-wtnopay-0101-0900/.venv/lib/l.py"
  mkdir -p "$WTD/px-wtpaydirty-0101-0900/artifacts"; echo x > "$WTD/px-wtpaydirty-0101-0900/artifacts/r.tsv"; echo work > "$WTD/px-wtpaydirty-0101-0900/scratch.txt"
  mkdir -p "$WTD/px-wtpaykeep-0101-0900/artifacts"; echo x > "$WTD/px-wtpaykeep-0101-0900/artifacts/r.tsv"
  printf '[Service]\nWorkingDirectory=%s\nExecStart=/bin/true\n' "$WTD/px-wtpaykeep-0101-0900" > "$WTUD/wtstale-paykeep.service"
  out="$(ws)"
  b="$(blk "$out" "$WT_PAY")"
  has "worktree-stale-payload-row-status-clean" "$(head -1 <<<"$b")" 'status=clean'
  has "worktree-stale-payload-note-count" "$b" "NOTE: 2 gitignored file(s)"
  has "worktree-stale-payload-note-example" "$b" "artifacts/"
  has "worktree-stale-payload-note-says-remove-deletes" "$b" "git worktree remove deletes them"
  has "worktree-stale-payload-note-archive-cmd" "$b" "session-doctor archive-ignored $WT_PAY"
  has "worktree-stale-payload-remove-chains-archive" "$(rmline "$b")" "session-doctor archive-ignored $WT_PAY && git -C"
  has "worktree-stale-payload-remove-still-there" "$(rmline "$b")" 'worktree remove --force'
  b="$(blk "$out" "$WTD/px-wtnopay-0101-0900")"
  ok "worktree-stale-nopayload-row-listed" "$(yn test -n "$b")" yes
  hasnt "worktree-stale-nopayload-no-note" "$b" gitignored
  hasnt "worktree-stale-nopayload-remove-not-chained" "$b" archive-ignored
  b="$(blk "$out" "$WT_DEAD")"
  hasnt "worktree-stale-plain-row-no-note" "$b" gitignored
  hasnt "worktree-stale-plain-row-no-archive" "$b" archive-ignored
  # DIRTY + payload: both NOTEs; the DIRTY rule (no --force, no branch -D) is unchanged.
  b="$(blk "$out" "$WTD/px-wtpaydirty-0101-0900")"
  has "worktree-stale-payload-dirty-keeps-dirty-note" "$b" "NOTE: worktree has uncommitted changes (status=DIRTY)"
  has "worktree-stale-payload-dirty-has-payload-note" "$b" "NOTE: 1 gitignored file(s)"
  hasnt "worktree-stale-payload-dirty-still-no-force" "$(rmline "$b")" --force
  b="$(blk "$out" "$WTD/px-wtpaykeep-0101-0900")"
  has "worktree-stale-payload-keep-row-still-keep" "$b" "KEEP: in use by unit wtstale-paykeep.service $KEEP_PHRASE"
  for s in gitignored archive-ignored remove:; do hasnt "worktree-stale-payload-keep-row-no-$s" "$b" "$s"; done
  # An unreadable dir inside the payload must not read as "no payload": archive stays chained and
  # says why; the archive itself refuses (skipped as root, which ignores modes).
  if [ "$(id -u)" -ne 0 ]; then
    mkwt "$REPO" px-wtlocked-0101-0900; WT_LK="$WTD/px-wtlocked-0101-0900"
    mkdir -p "$WT_LK/artifacts/locked"; echo x > "$WT_LK/artifacts/locked/f"; chmod 000 "$WT_LK/artifacts/locked"
    out="$(ws)"
    HOME="$WTHOME" bash "$SD" archive-ignored "$WT_LK" >/dev/null 2>&1; rc=$?
    chmod 755 "$WT_LK/artifacts/locked"
    b="$(blk "$out" "$WT_LK")"
    has "worktree-stale-unlistable-note" "$b" "NOTE: could not list this worktree's gitignored files"
    has "worktree-stale-unlistable-still-chained" "$(rmline "$b")" "session-doctor archive-ignored $WT_LK && git -C"
    ok "worktree-stale-unlistable-archive-refuses" "$rc" 1
  fi
  # the printed archive command is runnable and archives the payload
  HOME="$WTHOME" bash "$SD" archive-ignored "$WT_PAY" >/dev/null 2>&1
  ok "worktree-stale-payload-archive-cmd-runs" "$?" 0
  ok "worktree-stale-payload-archive-cmd-made-archive" "$(ls -d "$WTHOME/backups/reaped-worktree-ignored/px-wtpay-0101-0900-"*/worktree/artifacts/results.tsv 2>/dev/null | wc -l | tr -d ' ')" 1

  # The whole chained line, eval'd with a `session-doctor` shim on PATH against a repo with a space
  # in its path: (1) archive over the cap fails -> `&&` stops, worktree survives; (2) archive ok -> removed after.
  mkdir -p "$TMP/shim"; printf '#!/usr/bin/env bash\nexec bash "%s" "$@"\n' "$SD" > "$TMP/shim/session-doctor"; chmod +x "$TMP/shim/session-doctor"
  printf 'artifacts/\n' >> "$TMP/my repo/.git/info/exclude"
  for n in chain1 chain2; do
    mkwt "$TMP/my repo" px-wt$n-0101-0900
    mkdir -p "$WTD/px-wt$n-0101-0900/artifacts"; echo data > "$WTD/px-wt$n-0101-0900/artifacts/results.tsv"
  done
  out="$(ws)"
  ( export PATH="$TMP/shim:$PATH" HOME="$WTHOME" SESSION_DOCTOR_IGNORED_ARCHIVE_MAX_BYTES=1; eval "$(rmline "$(blk "$out" "$WTD/px-wtchain1-0101-0900")")" ) >/dev/null 2>&1
  isfile "worktree-stale-chain-failed-archive-keeps-worktree" "$WTD/px-wtchain1-0101-0900/artifacts/results.tsv"
  ( export PATH="$TMP/shim:$PATH" HOME="$WTHOME"; eval "$(rmline "$(blk "$out" "$WTD/px-wtchain2-0101-0900")")" ) >/dev/null 2>&1
  nodir "worktree-stale-chain-removed-after-archive" "$WTD/px-wtchain2-0101-0900"
  ok "worktree-stale-chain-archive-has-the-file" "$(cat "$WTHOME"/backups/reaped-worktree-ignored/px-wtchain2-0101-0900-*/worktree/artifacts/results.tsv 2>/dev/null)" data
fi

# ── _default_branch: no remote (main / master), a plain clone (origin/HEAD), cached repeat; no gh needed ──
if command -v git >/dev/null 2>&1; then
  mkrepo "$TMP/db-main" main; mkrepo "$TMP/db-master" master
  ok "defbr-no-remote-local-main" "$(_default_branch "$TMP/db-main")" main
  ok "defbr-no-remote-local-master" "$(_default_branch "$TMP/db-master")" master
  git clone -q "$TMP/db-main" "$TMP/db-clone" >/dev/null 2>&1
  ok "defbr-clone-origin-head" "$(_default_branch "$TMP/db-clone")" main
  ok "defbr-cached-call" "$(_default_branch "$TMP/db-clone")" main
  # Real github.com origin resolved through authenticated gh (a stale hardcoded "main" was the bug).
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    ok "defbr-real-github-repo-nonempty" "$([ -n "$(_default_branch "$(cd "$HERE/.." && pwd)")" ] && echo yes || echo no)" yes
  fi

  # _wt_dirty ignores the spawner's own baseline (.claude/skills symlink, .sessions-init-* sentinel) but flags real files.
  mkrepo "$TMP/dirty"
  ok "wtdirty-clean-repo" "$(_wt_dirty "$TMP/dirty")" clean
  mkdir -p "$TMP/dirty/.claude"; ln -sf /nonexistent-skills-target "$TMP/dirty/.claude/skills"
  ok "wtdirty-ignores-claude-skills-baseline" "$(_wt_dirty "$TMP/dirty")" clean
  touch "$TMP/dirty/.sessions-init-px-something"
  ok "wtdirty-ignores-sessions-init-sentinel" "$(_wt_dirty "$TMP/dirty")" clean
  echo x > "$TMP/dirty/real-untracked.txt"
  ok "wtdirty-still-flags-real-untracked" "$(_wt_dirty "$TMP/dirty")" DIRTY
fi

# ── worktree-stale / land-check end to end: base + landed reporting, branch -D policy, DIRTY rows ──
if command -v git >/dev/null 2>&1 && command -v tmux >/dev/null 2>&1; then
  LCREPO="$TMP/lcrepo"; mkrepo "$LCREPO"
  LCHOME="$TMP/lchome"; WTD="$LCHOME/.claude/worktrees"; mkdir -p "$WTD"
  ws() { HOME="$LCHOME" bash "$SD" worktree-stale; }
  # Landed (off main, WITH the .claude/skills baseline: proves it is not read as DIRTY) and unlanded (own commit).
  mkwt "$LCREPO" px-lclanded-0101-0900; WT_LANDED="$WTD/px-lclanded-0101-0900"
  mkdir -p "$WT_LANDED/.claude"; ln -sf /nonexistent-skills-target "$WT_LANDED/.claude/skills"
  mkwt "$LCREPO" px-lcunlanded-0101-0900; WT_UNLANDED="$WTD/px-lcunlanded-0101-0900"
  echo new > "$WT_UNLANDED/new.txt"; git -C "$WT_UNLANDED" add new.txt; git -C "$WT_UNLANDED" commit -q -m "unlanded work"
  out="$(ws)"
  ok "wstale-skips-skills-baseline-dirty" "$(grep -F "$WT_LANDED" <<<"$out" | grep -oE 'status=[a-zA-Z]+')" "status=clean"
  ok "wstale-reports-landed-yes" "$(grep -F "$WT_LANDED" <<<"$out" | grep -oE 'base=[a-z]+ landed=[a-z]+')" "base=main landed=yes"
  ok "wstale-reports-landed-no" "$(grep -F "$WT_UNLANDED" <<<"$out" | grep -oE 'base=[a-z]+ landed=[a-z]+')" "base=main landed=no"

  # landed=unknown: a detached-HEAD main repo makes _default_branch answer the literal "HEAD" (no ref to compare).
  mkrepo "$TMP/repo-unknown" trunk; git -C "$TMP/repo-unknown" checkout -q --detach
  git -C "$TMP/repo-unknown" worktree add -q -b session/px-lcunknown-0101-0900 "$WTD/px-lcunknown-0101-0900" HEAD >/dev/null 2>&1
  WT_UNKNOWN="$WTD/px-lcunknown-0101-0900"
  # DIRTY rows: owned+landed=yes (also an ignored file), owned+landed=no, and switched off session/*.
  mkwt "$LCREPO" px-lcdirtyyes-0101-0900; WT_DY="$WTD/px-lcdirtyyes-0101-0900"
  echo scratch > "$WT_DY/scratch.txt"; echo edit >> "$WT_DY/a.txt"
  echo '*.ignored-log' >> "$LCREPO/.git/info/exclude"; echo precious > "$WT_DY/local-only.ignored-log"
  mkwt "$LCREPO" px-lcdirtyno-0101-0900; WT_DN="$WTD/px-lcdirtyno-0101-0900"
  echo new > "$WT_DN/new.txt"; git -C "$WT_DN" add new.txt; git -C "$WT_DN" commit -q -m "unlanded work"; echo scratch > "$WT_DN/scratch.txt"
  mkwt "$LCREPO" px-lcdirtysw-0101-0900; WT_DSW="$WTD/px-lcdirtysw-0101-0900"
  git -C "$WT_DSW" checkout -q -b feature/dirty-switched >/dev/null 2>&1; echo scratch > "$WT_DSW/scratch.txt"

  out="$(ws)"
  b_yes="$(blk "$out" "$WT_LANDED")"; b_no="$(blk "$out" "$WT_UNLANDED")"; b_unk="$(blk "$out" "$WT_UNKNOWN")"
  # `branch -D` only for a known-landed branch: landed=no/unknown get worktree removal alone plus a NOTE
  # (the session/* ref is all that keeps a dead session's commits reachable).
  ok "wstale-branchD-fixture-unknown" "$(grep -oE 'landed=[a-z]+' <<<"$b_unk")" "landed=unknown"
  has "wstale-branchD-landed-yes-keeps-it" "$b_yes" 'branch -D session/px-lclanded-0101-0900'
  hasnt "wstale-branchD-landed-yes-no-keep-note" "$b_yes" 'not known-landed'
  for k in no:unlanded unk:unknown; do
    b_var=b_${k%%:*}
    has "wstale-branchD-landed-${k%%:*}-still-removes-wt" "${!b_var}" 'worktree remove --force'
    hasnt "wstale-branchD-landed-${k%%:*}-dropped" "${!b_var}" 'branch -D'
    has "wstale-branchD-landed-${k%%:*}-note" "${!b_var}" "NOTE: branch session/px-lc${k##*:}-0101-0900 is not known-landed — keep the ref; it is the only thing keeping its commits reachable"
  done

  # A DIRTY row must not offer a line that discards uncommitted changes: no --force, no branch -D, plain
  # `worktree remove` (which refuses on modified/untracked files); the NOTE points at `status --ignored`
  # because ignored files would still be deleted. Clean rows keep --force.
  b_dy="$(blk "$out" "$WT_DY")"; b_dn="$(blk "$out" "$WT_DN")"; b_dsw="$(blk "$out" "$WT_DSW")"
  ok "wstale-dirty-fixture-yes-row" "$(grep -oE 'status=[a-zA-Z]+ +base=[a-z]+ landed=[a-z]+' <<<"$b_dy" | tr -s ' ')" "status=DIRTY base=main landed=yes"
  ok "wstale-dirty-fixture-no-row" "$(grep -oE 'status=[a-zA-Z]+ +base=[a-z]+ landed=[a-z]+' <<<"$b_dn" | tr -s ' ')" "status=DIRTY base=main landed=no"
  ok "wstale-dirty-fixture-sw-row" "$(head -1 <<<"$b_dsw" | grep -oE 'status=[a-zA-Z]+')" "status=DIRTY"
  has "wstale-dirty-yes-still-offers-remove" "$(rmline "$b_dy")" "worktree remove $WT_DY"
  hasnt "wstale-dirty-yes-no-force" "$(rmline "$b_dy")" --force
  hasnt "wstale-dirty-yes-no-branch-D" "$b_dy" 'branch -D'
  has "wstale-dirty-yes-note" "$b_dy" "NOTE: worktree has uncommitted changes (status=DIRTY) — inspect it first (git -C $WT_DY status --ignored); add --force only if they are not needed"
  hasnt "wstale-dirty-yes-no-branch-note" "$b_dy" 'not known-landed'
  # The NOTE's own hint, run as printed, must list the ignored file (a paste could still delete it).
  hint="$(sed -n 's/.*inspect it first (\(git -C .* status --ignored\)); add --force.*/\1/p' <<<"$b_dy")"
  has "wstale-dirty-note-hint-shows-ignored" "$( (export HOME="$LCHOME" LC_ALL=C; eval "$hint" 2>/dev/null) | awk '/^Ignored files:/{f=1;next} f')" 'local-only.ignored-log'
  # The printed line, actually pasted, must refuse and leave everything intact.
  ( export HOME="$LCHOME"; eval "$(rmline "$b_dy")" ) >/dev/null 2>&1; rc=$?
  ok "wstale-dirty-pasted-cmd-refuses" "$([ "$rc" -ne 0 ] && echo refused || echo removed)" refused
  isdir "wstale-dirty-pasted-cmd-kept-worktree" "$WT_DY"
  isfile "wstale-dirty-pasted-cmd-kept-untracked" "$WT_DY/scratch.txt"
  ok "wstale-dirty-pasted-cmd-kept-modified" "$(grep -cx edit "$WT_DY/a.txt")" 1
  ok "wstale-dirty-pasted-cmd-kept-branch" "$(yn git -C "$LCREPO" show-ref --verify --quiet refs/heads/session/px-lcdirtyyes-0101-0900)" yes
  hasnt "wstale-dirty-no-no-force" "$(rmline "$b_dn")" --force
  hasnt "wstale-dirty-no-no-branch-D" "$b_dn" 'branch -D'
  has "wstale-dirty-no-dirty-note" "$b_dn" "NOTE: worktree has uncommitted changes (status=DIRTY) — inspect it first (git -C $WT_DN status --ignored)"
  has "wstale-dirty-no-branch-note" "$b_dn" "NOTE: branch session/px-lcdirtyno-0101-0900 is not known-landed"
  hasnt "wstale-dirty-sw-no-force" "$(rmline "$b_dsw")" --force
  has "wstale-dirty-sw-dirty-note" "$b_dsw" "NOTE: worktree has uncommitted changes (status=DIRTY) — inspect it first (git -C $WT_DSW status --ignored)"
  has "wstale-dirty-sw-branch-note" "$b_dsw" "NOTE: current branch feature/dirty-switched is not a session/* name"
  # Clean rows unchanged: --force kept (and branch -D when landed), no dirty NOTE.
  has "wstale-clean-yes-keeps-force" "$(rmline "$b_yes")" 'worktree remove --force'
  has "wstale-clean-yes-keeps-branch-D" "$(rmline "$b_yes")" 'branch -D session/px-lclanded-0101-0900'
  hasnt "wstale-clean-yes-no-dirty-note" "$b_yes" 'uncommitted changes'
  has "wstale-clean-no-keeps-force" "$(rmline "$b_no")" 'worktree remove --force'
  hasnt "wstale-clean-no-no-dirty-note" "$b_no" 'uncommitted changes'

  # land-check: report-only (no mutation) and, unlike worktree-stale, does NOT filter by liveness.
  mkwt "$LCREPO" px-lclive-0101-0900; WT_LCLIVE="$WTD/px-lclive-0101-0900"
  tmux new-session -d -s px_lclive-0101-0900 -c "$WT_LCLIVE" 'sleep 60'
  out="$(HOME="$LCHOME" bash "$SD" land-check)"; tmux kill-session -t px_lclive-0101-0900 2>/dev/null
  has "landcheck-lists-landed" "$out" "$WT_LANDED"
  has "landcheck-lists-unlanded" "$out" "$WT_UNLANDED"
  has "landcheck-lists-live-too" "$out" "$WT_LCLIVE"
  isdir "landcheck-no-mutation-landed" "$WT_LANDED"
  isdir "landcheck-no-mutation-unlanded" "$WT_UNLANDED"
fi

# ── reap: one-shot teardown of a named ALIVE session; every fixture is a throwaway ──
# A credential-less HOME makes registry_json() fail soft instead of hitting the real registry.
if command -v tmux >/dev/null 2>&1; then
  RHOME="$TMP/rhome"; mkdir -p "$RHOME"
  SYSTEMCTL_LOG="$RHOME/systemctl.log"; export SYSTEMCTL_LOG
  reap() { PATH="$TMP/stub:$PATH" HOME="${RH:-$RHOME}" bash "$SD" reap "$@" 2>&1; }

  # protected name: refused regardless of --force
  out="$(CRSS_PROTECT_NAMES='claude-remote|thirdbot' reap px-thirdbot-fake-0101-0900 --force)"; rc=$?
  has "reap-protected-refused" "$out" PROTECTED
  ok "reap-protected-exit2" "$rc" 2
  # idempotent no-op: tmux session and unit both absent -> exit 0
  out="$(reap px_reap-noop-test-0101-0900 --force)"; rc=$?
  ok "reap-noop-exit0" "$rc" 0
  has "reap-noop-message" "$out" "reaped 'px_reap-noop-test-0101-0900'"

  # unit cleanup: <base>.service and <base>-start.sh archived to the per-reap backup dir (MANIFEST), originals
  # removed, resume pin removed, daemon-reload issued.
  B=px-reapunit-0101-0900
  mkdir -p "$RHOME/.config/systemd/user" "$RHOME/.local/bin" "$RHOME/.sessions/resume"
  printf '[Service]\nExecStart=/bin/true\n' > "$RHOME/.config/systemd/user/$B.service"
  printf '#!/usr/bin/env bash\necho start\n' > "$RHOME/.local/bin/$B-start.sh"
  echo 11111111-1111-4111-8111-111111111111 > "$RHOME/.sessions/resume/$B.uuid"
  out="$(reap px_reapunit-0101-0900 --force)"; rc=$?
  A="$(ls -d "$RHOME/backups/reaped-worktree-ignored/$B"-* 2>/dev/null | head -1)"
  ok "reap-unit-archive-exit0" "$rc" 0
  isdir "reap-unit-archive-dir-exists" "$A"
  gone "reap-unit-resume-pin-removed" "$RHOME/.sessions/resume/$B.uuid"
  gone "reap-unit-service-removed" "$RHOME/.config/systemd/user/$B.service"
  gone "reap-unit-start-removed" "$RHOME/.local/bin/$B-start.sh"
  ok "reap-unit-service-archived" "$(grep -cF ".config/systemd/user/$B.service" "$A/MANIFEST" 2>/dev/null)" 1
  ok "reap-unit-start-archived" "$(grep -cF ".local/bin/$B-start.sh" "$A/MANIFEST" 2>/dev/null)" 1
  has "reap-unit-service-bytes" "$(cat "$A/unit/.config/systemd/user/$B.service")" 'ExecStart=/bin/true'
  has "reap-unit-start-bytes" "$(cat "$A/unit/.local/bin/$B-start.sh")" 'echo start'
  has "reap-unit-archive-message-service" "$out" ".config/systemd/user/$B.service"
  has "reap-unit-daemon-reload" "$(cat "$SYSTEMCTL_LOG")" "--user daemon-reload"

  # missing unit/start files: fine, but the per-reap archive dir (empty MANIFEST) is still created
  out="$(reap px_reapmissing-0101-0900 --force)"; rc=$?
  A="$(ls -d "$RHOME/backups/reaped-worktree-ignored/px-reapmissing-0101-0900"-* 2>/dev/null | head -1)"
  ok "reap-missing-unit-exit0" "$rc" 0
  isdir "reap-missing-archive-dir-exists" "$A"
  ok "reap-missing-manifest-empty" "$(wc -l < "$A/MANIFEST" | tr -d ' ')" 0
  has "reap-missing-message" "$out" "reaped 'px_reapmissing-0101-0900'"

  # archive failure (backups is a file): reap still completes, originals are NOT deleted
  FH="$TMP/failhome"; B=px-reaparchfail-0101-0900; mkdir -p "$FH/.config/systemd/user" "$FH/.local/bin"
  : > "$FH/backups"; echo unit > "$FH/.config/systemd/user/$B.service"; echo start > "$FH/.local/bin/$B-start.sh"
  out="$(RH="$FH" reap px_reaparchfail-0101-0900 --force)"; rc=$?
  ok "reap-archive-failure-exit0" "$rc" 0
  isfile "reap-archive-failure-keeps-service" "$FH/.config/systemd/user/$B.service"
  isfile "reap-archive-failure-keeps-start" "$FH/.local/bin/$B-start.sh"
  has "reap-archive-failure-warns" "$out" "WARNING: unit/start-script archive failed"
  has "reap-archive-failure-still-reaped" "$out" "reaped 'px_reaparchfail-0101-0900'"

  # --dry-run on a live session with a unit, start script and registry candidate: previews the
  # teardown and changes nothing (it once ignored --dry-run and reaped for real).
  B=px-reapdrytest-0101-0900; DS=px_reapdrytest-0101-0900
  printf '[Service]\nExecStart=/bin/true\n' > "$RHOME/.config/systemd/user/$B.service"
  printf '#!/usr/bin/env bash\necho start\n' > "$RHOME/.local/bin/$B-start.sh"
  tmux new-session -d -s "$DS" -c "$TMP" 2>/dev/null
  : > "$SYSTEMCTL_LOG"
  out="$(reap "$DS" --dry-run --force)"; rc=$?
  ok "reap-dry-run-exit0" "$rc" 0
  has "reap-dry-run-banner" "$out" "DRY-RUN"
  has "reap-dry-run-would-kill" "$out" "would kill tmux session: $DS"
  has "reap-dry-run-would-disable" "$out" "would disable $B.service"
  has "reap-dry-run-would-reap" "$out" "would-reap '$DS'"
  hasnt "reap-dry-run-not-reaped" "$out" "reaped '$DS'"
  ok "reap-dry-run-session-survives" "$(yn tmux has-session -t "$DS")" yes
  isfile "reap-dry-run-keeps-service" "$RHOME/.config/systemd/user/$B.service"
  isfile "reap-dry-run-keeps-start" "$RHOME/.local/bin/$B-start.sh"
  ok "reap-dry-run-no-archive" "$(ls -d "$RHOME/backups/reaped-worktree-ignored/$B"-* 2>/dev/null | wc -l | tr -d ' ')" 0
  ok "reap-dry-run-no-systemctl" "$(cat "$SYSTEMCTL_LOG")" ""
  tmux kill-session -t "$DS" 2>/dev/null

  # live session with unlanded work: refused without --force (session survives), reaped with it (session gone)
  mkrepo "$TMP/reaprepo"; echo uncommitted > "$TMP/reaprepo/scratch.txt"
  RS=px_reaplivetest-0101-0900
  tmux new-session -d -s "$RS" -c "$TMP/reaprepo" 2>/dev/null; tmux send-keys -t "$RS" 'sleep 300 &' Enter; sleep 1
  out="$(reap "$RS")"; rc=$?
  has "reap-refuses-unlanded" "$out" "REFUSING to reap"
  ok "reap-refuses-unlanded-exit1" "$rc" 1
  ok "reap-refused-session-survives" "$(yn tmux has-session -t "$RS")" yes
  out="$(reap "$RS" --force)"; rc=$?
  ok "reap-force-exit0" "$rc" 0
  has "reap-force-message" "$out" "reaped '$RS'"
  ok "reap-force-session-gone" "$(yn tmux has-session -t "$RS")" no
fi

finish "session-doctor"
