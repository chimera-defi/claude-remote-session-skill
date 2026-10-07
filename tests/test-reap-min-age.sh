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
unset TMUX CRSS_REAP_MIN_AGE_H

cat > "$HOME/.local/bin/tmux" <<'STUB'
#!/usr/bin/env bash
echo "tmux $*" >> "$FIX/tmux.log"
tgt=""; args=("$@"); i=0
while [ $i -lt ${#args[@]} ]; do case "${args[$i]}" in -t) i=$((i+1)); tgt="${args[$i]}";; esac; i=$((i+1)); done
case "$1" in
  ls|list-sessions) for f in "$FIX"/tmux/*; do [ -e "$f" ] && echo "$(basename "$f"): 1 windows"; done ;;
  has-session) [ -e "$FIX/tmux/$tgt" ] ;;
  kill-session) rm -f "$FIX/tmux/$tgt"; exit 0 ;;
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
out="$(doctor report --allow-young)"; rc=$?
ok "allow-young-rejected-elsewhere" "$rc" 2

# ── reap-local: dead tmux is gated, orphan units (no tmux) are not ──
touch "$FIX/tmux/px_deadyoung-0101-0900" "$FIX/tmux/px_deadold-0101-0900" "$FIX/tmux/px_deadnolog-0101-0900"
spawn px_deadyoung-0101-0900 2; spawn px_deadold-0101-0900 30
UD="$HOME/.config/systemd/user"
echo "[Unit]" > "$UD/px-orphan-0101-0900.service"
out="$(doctor reap-local --force)"; rc=$?
ok "reap-local-exit0" "$rc" 0
has "reap-local-young-skipped" "$out" "SKIPPED young/unknown-age dead tmux: px_deadyoung-0101-0900"
has "reap-local-unknown-skipped" "$out" "SKIPPED young/unknown-age dead tmux: px_deadnolog-0101-0900"
ok "reap-local-young-tmux-kept" "$(yn test -e "$FIX/tmux/px_deadyoung-0101-0900")" yes
ok "reap-local-unknown-tmux-kept" "$(yn test -e "$FIX/tmux/px_deadnolog-0101-0900")" yes
ok "reap-local-old-tmux-killed" "$(yn test -e "$FIX/tmux/px_deadold-0101-0900")" no
ok "reap-local-orphan-unit-removed" "$(yn test -e "$UD/px-orphan-0101-0900.service")" no
out="$(doctor reap-local --force --allow-young)"
ok "reap-local-allow-young-kills-young" "$(yn test -e "$FIX/tmux/px_deadyoung-0101-0900")" no
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
