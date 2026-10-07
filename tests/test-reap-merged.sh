#!/usr/bin/env bash
# session-doctor.sh `reap-merged` (rules: _reap_merged_check). Fully hermetic: fake HOME, bare "origin", and
# tmux/gh/systemctl/curl stubs in <fakeHOME>/.local/bin (first on PATH). TMUX_TMPDIR points at an empty dir that must
# stay empty (a real tmux server would create its socket there), so a real tmux slipping through fails the suite.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
DOCTOR="$HERE/../scripts/session-doctor.sh"
command -v git >/dev/null 2>&1 || { echo "reap-merged: SKIP (no git)"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; FIX="$T/fix"
mkdir -p "$HOME/.local/bin" "$HOME/.claude/worktrees" "$HOME/.config/systemd/user" "$HOME/.sessions" "$FIX"/{tmux,gh/open,gh/merged,gh/fail}
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.com
isolate_overlay
export CRSS_REAP_MIN_AGE_H=0   # min-age gate is pinned in tests/test-reap-min-age.sh; this suite tests other reap behavior
export CRSS_SESSION_PREFIX=px CRSS_LEGACY_PREFIXES=oldhost CRSS_PROTECT_NAMES='px_keep'
export TMUX_TMPDIR="$T/no-tmux-here"; mkdir -p "$TMUX_TMPDIR"
export FIX
unset TMUX

# ── stubs ──
cat > "$HOME/.local/bin/tmux" <<'STUB'
#!/usr/bin/env bash
# fixture per session in $FIX/tmux/<name>.{path,act,pane}; every call is logged
echo "tmux $*" >> "$FIX/tmux.log"
tgt=""; fmt=""; args=("$@"); i=0
while [ $i -lt ${#args[@]} ]; do case "${args[$i]}" in -t) i=$((i+1)); tgt="${args[$i]}";; -F) i=$((i+1)); fmt="${args[$i]}";; esac; i=$((i+1)); done
case "$1" in
  ls|list-sessions) for f in "$FIX"/tmux/*.path; do [ -e "$f" ] || continue; n="$(basename "$f" .path)"; if [ -n "$fmt" ]; then echo "$n"; else echo "$n: 1 windows"; fi; done ;;
  has-session) [ -e "$FIX/tmux/$tgt.path" ] ;;
  list-panes) exit 0 ;;
  kill-session) rm -f "$FIX/tmux/$tgt".{path,act,pane}; exit 0 ;;
  display-message)
    last="${args[$((${#args[@]}-1))]}"
    if [ -z "$tgt" ]; then echo "${FAKE_SELF:-}"; exit 0; fi
    case "$last" in
      '#{pane_current_path}') cat "$FIX/tmux/$tgt.path" ;;
      '#{window_activity}') cat "$FIX/tmux/$tgt.act" ;;
      '#{pane_current_command}') echo claude ;;
    esac ;;
  capture-pane) cat "$FIX/tmux/$tgt.pane" 2>/dev/null ;;
esac
STUB
cat > "$HOME/.local/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $* (cwd=$PWD)" >> "$FIX/gh.log"
state=""; head=""; args=("$@"); i=0
while [ $i -lt ${#args[@]} ]; do case "${args[$i]}" in --state) i=$((i+1)); state="${args[$i]}";; --head) i=$((i+1)); head="${args[$i]}";; esac; i=$((i+1)); done
key="${head//\//_}"
[ -e "$FIX/gh/fail/$key" ] && { echo "gh: boom" >&2; exit 1; }
if [ -f "$FIX/gh/$state/$key.json" ]; then cat "$FIX/gh/$state/$key.json"; else echo '[]'; fi
STUB
for c in systemctl curl; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$FIX/%s.log"\n[ "%s" = curl ] && echo "[]"\nexit 0\n' "$c" "$c" "$c" > "$HOME/.local/bin/$c"
done
chmod +x "$HOME/.local/bin"/*
export PATH="$HOME/.local/bin:$PATH"
ok "stub-tmux-first-on-path" "$(command -v tmux)" "$HOME/.local/bin/tmux"
ok "stub-gh-first-on-path" "$(command -v gh)" "$HOME/.local/bin/gh"

# ── git fixture: bare origin + a primary clone ──
git init -q --bare -b main "$T/origin.git"
git clone -q "$T/origin.git" "$T/repo" 2>/dev/null
echo hi > "$T/repo/a.txt"; git -C "$T/repo" add a.txt; git -C "$T/repo" commit -q -m init; git -C "$T/repo" push -q origin main 2>/dev/null
git -C "$T/repo" remote set-head origin main >/dev/null 2>&1

# mk NAME [idle-minutes]: worktree on a pushed branch, transcript + tmux activity <idle> minutes old, quiet pane.
mk() {
  local name="$1" idle="${2:-300}" base wt br
  base="${name/_/-}"; br="session/$base"; wt="$HOME/.claude/worktrees/$base"
  git -C "$T/repo" worktree add -q -b "$br" "$wt" origin/main >/dev/null 2>&1
  echo "$name" > "$wt/work.txt"; git -C "$wt" add work.txt; git -C "$wt" commit -q -m "work $name"
  git -C "$wt" push -q -u origin "$br" 2>/dev/null
  printf '%s' "$wt" > "$FIX/tmux/$name.path"
  local ts=$(( $(date +%s) - idle*60 ))
  echo "$ts" > "$FIX/tmux/$name.act"
  local pd="$HOME/.claude/projects/${wt//[\/.]/-}"; mkdir -p "$pd"; : > "$pd/s.jsonl"; touch -d "@$ts" "$pd/s.jsonl"
  printf '\033[39m❯\302\240\n\033[38;5;244m────\033[39m\n  [Sonnet] x\n  bypass permissions on\n' > "$FIX/tmux/$name.pane"
}
# merged NAME [oid]: record a merged PR #N whose head is the worktree's HEAD (or the given oid)
PRN=100
merged() { local name="$1" base="${1/_/-}" oid; oid="${2:-$(git -C "$HOME/.claude/worktrees/$base" rev-parse HEAD)}"; PRN=$((PRN+1))
  printf '[{"number":%s,"headRefOid":"%s"}]' "$PRN" "$oid" > "$FIX/gh/merged/session_$base.json"; }

for n in px_ok-0101-0900 px_ghost-0101-0900 px_desk-0101-0900 px_keep px_open-0101-0900 px_nomerge-0101-0900 px_stale-0101-0900 \
         px_busy-0101-0900 px_agents-0101-0900 px_typed-0101-0900 px_active-0101-0900 px_dirty-0101-0900 px_ghfail-0101-0900 px_self-0101-0900; do
  case "$n" in px_active*) mk "$n" 10;; *) mk "$n";; esac
done
for n in px_ok-0101-0900 px_ghost-0101-0900 px_desk-0101-0900 px_keep px_open-0101-0900 px_stale-0101-0900 px_busy-0101-0900 px_agents-0101-0900 \
         px_typed-0101-0900 px_active-0101-0900 px_dirty-0101-0900 px_ghfail-0101-0900 px_self-0101-0900; do merged "$n"; done
printf '[{"number":7,"headRefOid":"x"}]' > "$FIX/gh/open/session_px-open-0101-0900.json"
merged px_stale-0101-0900 0000000000000000000000000000000000000000
touch "$FIX/gh/fail/session_px-ghfail-0101-0900"
printf '\033[39m❯\302\240\033[2mcontinue when the slices finish\033[0m\n  bypass permissions on (shift+tab to cycle) · ← 3 agents\n' > "$FIX/tmux/px_ghost-0101-0900.pane"          # dim ghost text: idle
printf '  esc to interrupt\n\033[39m❯\302\240\n  bypass permissions on\n' > "$FIX/tmux/px_busy-0101-0900.pane"
printf '\033[39m❯\302\240\n  bypass permissions on · 1 shell · ← 3 agents\n' > "$FIX/tmux/px_agents-0101-0900.pane"      # live-calibrated: a background shell counter
printf '\033[39m❯\302\240fix the thing now\n' > "$FIX/tmux/px_typed-0101-0900.pane"                                       # real typed text
echo scratch > "$HOME/.claude/worktrees/px-dirty-0101-0900/untracked.txt"
# not in a crss worktree / not prefixed / default branch / detached
mkdir -p "$HOME/.sessions/px-elsewhere"; printf '%s' "$HOME/.sessions/px-elsewhere" > "$FIX/tmux/px_elsewhere-0101-0900.path"; echo 0 > "$FIX/tmux/px_elsewhere-0101-0900.act"
printf '%s' "$HOME/.claude/worktrees/px-ok-0101-0900" > "$FIX/tmux/other_x.path"; echo 0 > "$FIX/tmux/other_x.act"
git clone -q "$T/origin.git" "$HOME/.claude/worktrees/px-onmain-0101-0900" 2>/dev/null
printf '%s' "$HOME/.claude/worktrees/px-onmain-0101-0900" > "$FIX/tmux/px_onmain-0101-0900.path"; echo 0 > "$FIX/tmux/px_onmain-0101-0900.act"
# reap-audit refusal: everything else clean/merged/idle, but the audit helper (a wrapper beside a copy of the doctor, see
# below) refuses this one — proves a refusing `reap --dry-run` demotes a candidate to skipped and --apply never reaps it
mk px_audit-0101-0900; merged px_audit-0101-0900
REAL_DOCTOR="$DOCTOR"; ALT="$T/alt"; mkdir -p "$ALT"; cp "$REAL_DOCTOR" "$ALT/session-doctor.sh"
cat > "$ALT/session-preserve.sh" <<WRAP
#!/usr/bin/env bash
case "\$1" in px_audit-*) echo "unlanded work (fixture)"; exit 1;; esac
exec bash "$HERE/../scripts/session-preserve.sh" "\$@"
WRAP
DOCTOR="$ALT/session-doctor.sh"

# ── dry run ──
: > "$FIX/tmux.log"
out="$(FAKE_SELF=px_self-0101-0900 TMUX=/fake bash "$DOCTOR" reap-merged 2>&1)"; rc=$?
ok "dry-rc" "$rc" 0
line() { grep -E "^(candidate|skipped|reaped|failed) +$1 " <<<"$out"; }
has "dry-header" "$out" "DRY-RUN, nothing changed"
hasre "ok-candidate" "$(line px_ok-0101-0900)" '^candidate +px_ok-0101-0900 +merged PR #[0-9]+, idle [0-9]+m'
hasre "ghost-text-is-idle" "$(line px_ghost-0101-0900)" '^candidate '
hasre "desk-skipped"   "$(line px_desk-0101-0900)" 'skipped.*operator desk'
hasre "protected"      "$(line px_keep)" 'skipped.*protected name'
hasre "open-pr"        "$(line px_open-0101-0900)" 'skipped.*open PR'
hasre "no-merged-pr"   "$(line px_nomerge-0101-0900)" 'skipped.*no merged PR'
hasre "stale-head"     "$(line px_stale-0101-0900)" "skipped.*no merged PR whose head is this worktree's HEAD"
hasre "busy"           "$(line px_busy-0101-0900)" 'skipped.*busy marker visible'
hasre "agents-counter" "$(line px_agents-0101-0900)" 'skipped.*busy marker visible.*1 shell'
hasre "typed"          "$(line px_typed-0101-0900)" 'skipped.*unsent text at the prompt'
hasre "active"         "$(line px_active-0101-0900)" 'skipped.*active 1?[0-9]m ago'
hasre "dirty"          "$(line px_dirty-0101-0900)" 'skipped.*uncommitted work'
hasre "gh-fail"        "$(line px_ghfail-0101-0900)" 'skipped.*gh open-PR lookup failed'
hasre "self"           "$(line px_self-0101-0900)" "skipped.*caller's own session"
hasre "elsewhere"      "$(line px_elsewhere-0101-0900)" 'skipped.*not in a crss worktree'
hasre "unprefixed"     "$(line other_x)" 'skipped.*not a crss-prefixed session'
hasre "on-default"     "$(line px_onmain-0101-0900)" 'skipped.*on default branch main'
hasre "audit-refusal"  "$(line px_audit-0101-0900)" 'skipped.*reap audit refused'
ok "dry-candidate-count" "$(grep -c '^candidate ' <<<"$out")" 2
has "dry-summary" "$out" "reap-merged: 2 candidate(s)"
hasnt "dry-kill" "$(cat "$FIX/tmux.log")" "kill-session"
ok "dry-no-systemctl" "$([ -e "$FIX/systemctl.log" ] && echo yes || echo no)" no
isdir "dry-worktree-kept" "$HOME/.claude/worktrees/px-ok-0101-0900"
# idle floor is honored: with 600m neither candidate is idle enough
out600="$(bash "$DOCTOR" reap-merged --idle-min 600 2>&1)"
ok "idle-min-floor" "$(grep -c '^candidate ' <<<"$out600")" 0
# flag validation
bash "$DOCTOR" reap-merged --idle-min abc >/dev/null 2>&1; ok "idle-min-bad" "$?" 2
bash "$DOCTOR" reap-merged --idle-min 0 >/dev/null 2>&1; ok "idle-min-zero" "$?" 2
bash "$DOCTOR" reap-merged --apply --dry-run >/dev/null 2>&1; ok "apply-dry-conflict" "$?" 2

# ── apply: only the two candidates are reaped, via plain reap (no --force), branches kept ──
: > "$FIX/tmux.log"
outa="$(FAKE_SELF=px_self-0101-0900 TMUX=/fake bash "$DOCTOR" reap-merged --apply 2>&1)"; rca=$?
ok "apply-rc" "$rca" 0
hasre "apply-ok-reaped" "$(grep -E "^reaped +px_ok-0101-0900" <<<"$outa")" 'merged PR #'
hasre "apply-ghost-reaped" "$(grep -E "^reaped +px_ghost-0101-0900" <<<"$outa")" 'reaped'
ok "apply-kill-targets" "$(grep '^tmux kill-session' "$FIX/tmux.log" | sort | tr '\n' ' ')" "tmux kill-session -t px_ghost-0101-0900 tmux kill-session -t px_ok-0101-0900 "
nodir "apply-ok-worktree-removed" "$HOME/.claude/worktrees/px-ok-0101-0900"
ok "apply-branch-kept" "$(yn git -C "$T/repo" show-ref --verify --quiet refs/heads/session/px-ok-0101-0900)" yes
for keep in px-desk-0101-0900 px-open-0101-0900 px-busy-0101-0900 px-typed-0101-0900 px-active-0101-0900 px-dirty-0101-0900 px-audit-0101-0900; do
  isdir "apply-untouched-$keep" "$HOME/.claude/worktrees/$keep"
done
ok "apply-systemctl-targets" "$(grep disable "$FIX/systemctl.log" | grep -vc 'px-ok-0101-0900\|px-ghost-0101-0900')" 0
# the apply path may only call plain reap: no --force anywhere in the reap-merged dispatch block
blk="$(sed -n '/^  reap-merged)/,/^  reap)/p' "$REAL_DOCTOR")"
ok "no-force-in-block" "$(grep -v '^ *#' <<<"$blk" | grep -c -- '--force')" 0
ok "no-branch-delete-in-block" "$(grep -v '^ *#' <<<"$blk" | grep -cE 'branch -[dD]|worktree remove')" 0
# real tmux never reached
ok "real-tmux-untouched" "$(find "$TMUX_TMPDIR" -mindepth 1 | wc -l)" 0
finish "reap-merged"
