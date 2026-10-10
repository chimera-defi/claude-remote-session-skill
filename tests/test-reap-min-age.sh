#!/usr/bin/env bash
# Minimum-age gate on session-doctor.sh reap / reap-local / reap-merged (rules: _reap_age_gate; age source:
# session-registry.sh --first-seen over ~/.sessions/session-starts.log). Hermetic: fake HOME, tmux/systemctl/curl
# stubs in <fakeHOME>/.local/bin (first on PATH), TMUX_TMPDIR at an empty dir.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
DOCTOR="$HERE/../scripts/session-doctor.sh"
REGISTRY="$HERE/../scripts/session-registry.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; FIX="$T/fix"
mkdir -p "$HOME/.local/bin" "$HOME/.config/systemd/user" "$HOME/.sessions" "$FIX/tmux"
isolate_overlay
export CRSS_SESSION_PREFIX=px CRSS_PROTECT_NAMES='px_keep'
export TMUX_TMPDIR="$T/no-tmux-here"; mkdir -p "$TMUX_TMPDIR"
export FIX
unset TMUX CRSS_REAP_MIN_AGE_H XDG_CONFIG_HOME

cat > "$HOME/.local/bin/tmux" <<'STUB'
#!/usr/bin/env bash
echo "tmux $*" >> "$FIX/tmux.log"
tgt=""; args=("$@"); i=0
while [ $i -lt ${#args[@]} ]; do case "${args[$i]}" in -t) i=$((i+1)); tgt="${args[$i]}";; esac; i=$((i+1)); done
case "$1" in
  ls|list-sessions) for f in "$FIX"/tmux/*; do [ -e "$f" ] && echo "$(basename "$f"): 1 windows"; done ;;
  # real tmux: bare -t is a PREFIX match (unique prefix -> that session), "=name" is exact
  has-session|kill-session)
    if [ "${tgt#=}" != "$tgt" ]; then real="${tgt#=}"; else real="$(ls "$FIX/tmux" | grep -F -m1 -- "$tgt")"; fi
    [ -n "$real" ] && [ -e "$FIX/tmux/$real" ] || exit 1
    [ "$1" = kill-session ] && rm -f "$FIX/tmux/$real"; exit 0 ;;
  display-message) echo bash ;;   # pane foreground = bash -> claude proc is gone (DEAD)
esac
STUB
for c in systemctl curl; do printf '#!/usr/bin/env bash\necho "%s $*" >> "$FIX/%s.log"\n[ "%s" = curl ] && echo "[]"\nexit 0\n' "$c" "$c" "$c" > "$HOME/.local/bin/$c"; done
chmod +x "$HOME/.local/bin"/*
export PATH="$HOME/.local/bin:$PATH"

LOG="$HOME/.sessions/session-starts.log"
stamp() { date -u -d "$1 hours ago" +%Y-%m-%dT%H:%M:%SZ; }   # $1 hours ago
spawn() { echo "[$(stamp "$2")] host=h session=$1 remote=${1//_/-} backend=claude" >> "$LOG"; }
spawn px_young-0101-0900 2
spawn px_old-0101-0900 30
# first-ever spawn wins: an old session that was restarted 1h ago is still old
spawn px_restarted-0101-0900 30; spawn px_restarted-0101-0900 1
# px_nolog has no log entry at all
doctor() { bash "$DOCTOR" "$@" 2>&1; }

# ── session-registry --first-seen (the shared age source) ──
fs="$(bash "$REGISTRY" --first-seen px_restarted-0101-0900)"
hasre "first-seen-epoch" "$fs" '^[0-9]+$'
ok "first-seen-is-first-line" "$(( ($(date -u +%s) - fs) / 3600 ))" 30
bash "$REGISTRY" --first-seen px_nolog >/dev/null 2>&1; ok "first-seen-unlogged-exit1" "$?" 1

# ── reap <name> ──
out="$(doctor reap px_young-0101-0900)"; rc=$?
ok "young-refused-exit1" "$rc" 1
has "young-refused-names-session" "$out" "px_young-0101-0900"
has "young-refused-says-age" "$out" "age 2h"
has "young-refused-names-override" "$out" "--allow-young"
out="$(doctor reap px_young-0101-0900 --force)"; rc=$?
ok "force-does-not-bypass-exit1" "$rc" 1
has "force-does-not-bypass-msg" "$out" "REFUSING to reap 'px_young-0101-0900'"
out="$(doctor reap px_young-0101-0900 --dry-run)"; rc=$?
ok "young-dry-run-also-refused" "$rc" 1
out="$(doctor reap px_old-0101-0900 --force)"; rc=$?
ok "old-allowed-exit0" "$rc" 0
has "old-allowed-reaps" "$out" "reaped 'px_old-0101-0900'"
out="$(doctor reap px_restarted-0101-0900 --force)"; rc=$?
ok "restarted-uses-first-spawn-exit0" "$rc" 0
out="$(doctor reap px_young-0101-0900 --force --allow-young)"; rc=$?
ok "allow-young-works-exit0" "$rc" 0
has "allow-young-reaps" "$out" "reaped 'px_young-0101-0900'"
spawn px_young2-0101-0900 2
out="$(CRSS_REAP_MIN_AGE_H=0 doctor reap px_young2-0101-0900 --force)"; rc=$?
ok "env0-disables-exit0" "$rc" 0
spawn px_young3-0101-0900 2
out="$(CRSS_REAP_MIN_AGE_H=1 doctor reap px_young3-0101-0900 --force)"; rc=$?
ok "env-lower-floor-allows-2h-old" "$rc" 0
spawn px_young4-0101-0900 2
out="$(CRSS_REAP_MIN_AGE_H=3 doctor reap px_young4-0101-0900 --force)"; rc=$?
ok "env-higher-floor-refuses-2h-old" "$rc" 1
out="$(doctor reap px_nolog-0101-0900 --force)"; rc=$?
ok "unknown-age-refused-exit1" "$rc" 1
has "unknown-age-message" "$out" "age unknown"
has "unknown-age-names-override" "$out" "--allow-young"
out="$(doctor reap px_nolog-0101-0900 --force --allow-young)"; rc=$?
ok "unknown-age-allow-young-exit0" "$rc" 0
out="$(CRSS_REAP_MIN_AGE_H=abc doctor reap px_old-0101-0900 --force)"; rc=$?
ok "bad-env-fails-closed-exit2" "$rc" 2
# prefix collision: old logged name absent, fresh session whose name merely starts with it must survive
spawn px_job-0101-0900 48
touch "$FIX/tmux/px_job-0101-0900-new"; spawn px_job-0101-0900-new 1
out="$(doctor reap px_job-0101-0900 --force)"; rc=$?
ok "prefix-collision-young-tmux-survives" "$(yn test -e "$FIX/tmux/px_job-0101-0900-new")" yes
# huge CRSS_REAP_MIN_AGE_H must not wrap/negate the gate
out="$(CRSS_REAP_MIN_AGE_H=18446744073709551616 doctor reap px_young-0101-0900 --force)"; rc=$?
ok "env-wraparound-rejected-exit2" "$rc" 2
out="$(CRSS_REAP_MIN_AGE_H=5124095576030431 doctor reap px_young-0101-0900 --force)"; rc=$?
ok "env-negative-wrap-rejected-exit2" "$rc" 2
out="$(CRSS_REAP_MIN_AGE_H=8761 doctor reap px_young-0101-0900 --force)"; rc=$?
ok "env-over-cap-rejected-exit2" "$rc" 2
out="$(CRSS_REAP_MIN_AGE_H=8760 doctor reap px_young-0101-0900 --force)"; rc=$?
ok "env-at-cap-accepted-then-refuses-young" "$rc" 1
out="$(doctor report --allow-young)"; rc=$?
ok "allow-young-rejected-elsewhere" "$rc" 2

# ── reap-local: dead tmux AND orphan units (no tmux) are gated; reaped orphans are archived first ──
touch "$FIX/tmux/px_deadyoung-0101-0900" "$FIX/tmux/px_deadold-0101-0900" "$FIX/tmux/px_deadnolog-0101-0900"
spawn px_deadyoung-0101-0900 2; spawn px_deadold-0101-0900 30
UD="$HOME/.config/systemd/user"
spawn px_orphan-0101-0900 30; spawn px_orphanyoung-0101-0900 2
spawn px_keep-0101-0900 30   # PROTECT term is underscore-form (px_keep); the hyphen unit must still be protected
for o in px-orphan-0101-0900 px-orphanyoung-0101-0900 px-keep-0101-0900; do
  echo "[Unit] $o" > "$UD/$o.service"; echo "#!/bin/sh" > "$HOME/.local/bin/$o-start.sh"
done
out="$(doctor reap-local --force)"; rc=$?
ok "reap-local-exit0" "$rc" 0
has "reap-local-young-skipped" "$out" "SKIPPED young/unknown-age dead tmux: px_deadyoung-0101-0900"
has "reap-local-unknown-skipped" "$out" "SKIPPED young/unknown-age dead tmux: px_deadnolog-0101-0900"
ok "reap-local-young-tmux-kept" "$(yn test -e "$FIX/tmux/px_deadyoung-0101-0900")" yes
ok "reap-local-unknown-tmux-kept" "$(yn test -e "$FIX/tmux/px_deadnolog-0101-0900")" yes
ok "reap-local-old-tmux-killed" "$(yn test -e "$FIX/tmux/px_deadold-0101-0900")" no
ok "protect-underscore-term-keeps-hyphen-unit" "$(yn test -e "$UD/px-keep-0101-0900.service")" yes
has "reap-local-orphan-young-skipped" "$out" "SKIPPED young/unknown-age orphan unit: px-orphanyoung-0101-0900.service"
ok "reap-local-orphan-young-unit-kept" "$(yn test -e "$UD/px-orphanyoung-0101-0900.service")" yes
ok "reap-local-orphan-young-start-kept" "$(yn test -e "$HOME/.local/bin/px-orphanyoung-0101-0900-start.sh")" yes
ok "reap-local-orphan-unit-removed" "$(yn test -e "$UD/px-orphan-0101-0900.service")" no
ok "reap-local-orphan-start-removed" "$(yn test -e "$HOME/.local/bin/px-orphan-0101-0900-start.sh")" no
arch="$HOME/backups/reaped-worktree-ignored"  # one archive dir per run, shared by all items reaped in it
ok "reap-local-orphan-unit-archived" "$(yn bash -c 'compgen -G "$1/*/unit/.config/systemd/user/px-orphan-0101-0900.service"' _ "$arch")" yes
ok "reap-local-orphan-start-archived" "$(yn bash -c 'compgen -G "$1/*/unit/.local/bin/px-orphan-0101-0900-start.sh"' _ "$arch")" yes
out="$(doctor reap-local --force --allow-young)"
ok "reap-local-allow-young-kills-young" "$(yn test -e "$FIX/tmux/px_deadyoung-0101-0900")" no
sleep 1   # archive dir is <base>-<second>; a same-second same-base rerun would (safely) refuse to archive
touch "$FIX/tmux/px_deadnolog-0101-0900"
out="$(CRSS_REAP_MIN_AGE_H=0 doctor reap-local --force)"
ok "reap-local-env0-kills-unknown" "$(yn test -e "$FIX/tmux/px_deadnolog-0101-0900")" no

# ── reap-merged: the age gate is checked before any gh/worktree work ──
touch "$FIX/tmux/px_mergedyoung-0101-0900"; spawn px_mergedyoung-0101-0900 2
out="$(doctor reap-merged --apply)"
has "reap-merged-young-skipped" "$out" "skipped    px_mergedyoung-0101-0900  min-age gate: age 2h"
hasnt "reap-merged-young-not-reaped" "$out" "reaped     px_mergedyoung"
ok "reap-merged-young-tmux-kept" "$(yn test -e "$FIX/tmux/px_mergedyoung-0101-0900")" yes
out="$(CRSS_REAP_MIN_AGE_H=0 doctor reap-merged)"
hasnt "reap-merged-env0-passes-gate" "$out" "min-age gate"

finish "reap-min-age"
