#!/usr/bin/env bash
# Tests for scripts/session-restart.sh: fake HOME, stub tmux/claude/session-send first on PATH, hand-written start script.
# No real tmux session, ~/.claude, ~/.local/bin or systemd unit is touched.
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
SCRIPT="$HERE/../scripts/session-restart.sh"
F="$(mktemp -d)"
export HOME="$F/home" STATE="$F/state" STUBS="$F/stubs" S=fx-main R=fx-rc
export CRSS_CLAUDE_HOME="$F/claude" CRSS_UNIT_DIR="$F/units" CRSS_BIN_DIR="$F/bin"
export CRSS_RESTART_POLL=0.2 CRSS_RESTART_WAIT=10 CRSS_RESTART_MIN_AGE=0 CRSS_RESTART_NUDGE_DELAY=0
export CRSS_RESTART_INTERVAL=1 CRSS_RESTART_IDLE_POLLS=2 CRSS_RESTART_MAX_WAIT=2
unset XDG_CONFIG_HOME CRSS_PROTECT_NAMES
isolate_overlay
mkdir -p "$HOME" "$STUBS" "$CRSS_CLAUDE_HOME/sessions" "$CRSS_UNIT_DIR" "$CRSS_BIN_DIR" "$HOME/pins"
export PATH="$STUBS:$PATH"

# Stub tmux: pane text in $STATE/<session>.pane; @PROMPT@ becomes the prompt glyph plus the typed text.
cat > "$STUBS/tmux" <<'EOT'
#!/bin/bash
cmd=$1; shift; t=""; keys=(); lit=0
while [ $# -gt 0 ]; do case $1 in -t) t=$2; shift ;; -l) lit=1 ;; -*) ;; *) keys+=("$1") ;; esac; shift; done
s=${t#=}; s=${s%:}
typed=$(cat "$STATE/typed" 2>/dev/null)
case $cmd in
  has-session) [ -f "$STATE/$s.pane" ] ;;
  display-message) cat "$STATE/$s.panepid" ;;
  capture-pane) while IFS= read -r l; do printf '%s\n' "${l//@PROMPT@/$(printf '\342\235\257') $typed}"; done < "$STATE/$s.pane" ;;
  send-keys)
    if [ "$lit" = 1 ]; then printf '%s' "${keys[0]}" > "$STATE/typed"; exit 0; fi
    for k in "${keys[@]}"; do
      case $k in
        Enter) [ "$typed" = /exit ] && { [ -f "$STATE/dialog" ] && echo "Exit and stop tasks" >> "$STATE/$s.pane" || touch "$STATE/exit-$(cat "$STATE/claudepid")"; }; : > "$STATE/typed" ;;
        Escape) sed -i '/Exit and stop tasks/d' "$STATE/$s.pane" ;;
      esac
    done ;;
esac
EOT
# Stub claude: registers $$ in the fake registry, then idles on a fifo with builtins only (a shell child only when asked).
cat > "$STUBS/claude" <<'EOT'
#!/bin/bash
[ "$1" = --version ] && { echo "2.9.9 (Claude Code)"; exit 0; }
sid="sid-$$"; res=""
while [ $# -gt 0 ]; do case $1 in --resume) res=$2; shift ;; esac; shift; done
[ -n "$res" ] && sid=$res
printf '{"sessionId":"%s","version":"%s","status":"idle"}\n' "$sid" "$(cat "$STATE/launch-version")" > "$CRSS_CLAUDE_HOME/sessions/$$.json"
echo $$ > "$STATE/claudepid"
exec 3<>"$STATE/fifo"
while :; do
  [ -e "$STATE/exit-$$" ] && { rm -f "$CRSS_CLAUDE_HOME/sessions/$$.json"; exit 0; }
  if [ -e "$STATE/want-child" ] && [ ! -e "$STATE/has-child" ]; then touch "$STATE/has-child"; bash -c 'sleep 300; : mcp' & fi
  read -r -t 0.2 -u 3 _
done
EOT
# Stub session-send: logs the target and the message body.
cat > "$STUBS/session-send" <<'EOT'
#!/bin/bash
{ echo "to=$1"; cat "$3"; } >> "$STATE/sent.log"
EOT
chmod +x "$STUBS/tmux" "$STUBS/claude" "$STUBS/session-send"
for c in tmux claude session-send; do [ "$(command -v "$c")" = "$STUBS/$c" ] || { echo "FAIL: $c is not the stub"; exit 1; }; done

cleanup() {
  local sess; sess="$(ps -o sid= -p "$(cat "$STATE/$S.panepid" 2>/dev/null)" 2>/dev/null | tr -d ' ')"
  [ -n "$sess" ] && pkill -s "$sess" 2>/dev/null; true
}
trap cleanup EXIT
# start_case: fresh state, a supervisor pane running the start script, and a registered claude (OLD, SID).
start_case() {
  cleanup
  rm -rf "$STATE" "$CRSS_CLAUDE_HOME/sessions" "$HOME/pins"
  mkdir -p "$STATE" "$CRSS_CLAUDE_HOME/sessions" "$HOME/pins"
  mkfifo "$STATE/fifo"; echo 2.9.9 > "$STATE/launch-version"
  printf 'transcript line\n@PROMPT@\n' > "$STATE/$S.pane"
  cat > "$CRSS_BIN_DIR/$R-start.sh" <<EOT
#!/bin/bash
RESUME_PIN="\$HOME/pins/$R.uuid"
echo \$\$ > "$STATE/$S.panepid"
while :; do
  a=(--remote-control $R)
  [ -s "\$RESUME_PIN" ] && a+=(--resume "\$(cat "\$RESUME_PIN")")
  claude "\${a[@]}"
  sleep 0.2
done
EOT
  setsid bash "$CRSS_BIN_DIR/$R-start.sh" >/dev/null 2>&1 &
  for _ in $(seq 100); do [ -s "$STATE/claudepid" ] && [ -s "$STATE/$S.panepid" ] && break; sleep 0.1; done
  OLD="$(cat "$STATE/claudepid")"
  SID="$(jq -r .sessionId "$CRSS_CLAUDE_HOME/sessions/$OLD.json")"
}
run() { OUT="$(bash "$SCRIPT" "$S" "$@" 2>&1)"; RC=$?; }

# 1. Refusals send nothing; dry-run only reports.
start_case
run --dry-run; ok "dry-run rc" "$RC" 0
has "dry-run line" "$OUT" "DRY-RUN would restart pid $OLD sessionId $SID version 2.9.9 -> 2.9.9"
printf 'esc to interrupt\n' >> "$STATE/$S.pane"
run; ok "busy footer rc" "$RC" 1; has "busy footer" "$OUT" "REFUSED(busy) footer shows 'esc to interrupt'"
sed -i '/esc to interrupt/d' "$STATE/$S.pane"
echo draft > "$STATE/typed"
run; has "typed input" "$OUT" "REFUSED(busy) typed input on the prompt"
rm -f "$STATE/typed"
touch "$STATE/want-child"; for _ in $(seq 50); do [ -e "$STATE/has-child" ] && break; sleep 0.1; done; sleep 0.3
run; has "shell child" "$OUT" "REFUSED(busy) shell child"
mkdir -p "$F/crss"; echo 'CRSS_PROTECT_NAMES=fx-other|fx-guard' > "$F/crss/config.sh"
OUT="$(CRSS_HOME="$F/crss" bash "$SCRIPT" fx-guard-1 2>&1)"; RC=$?
ok "protected rc" "$RC" 1; has "protected" "$OUT" "REFUSED(protected)"; hasnt "config not executed" "$OUT" "command not found"
ok "claude still alive" "$(yn kill -0 "$OLD")" yes
ok "pin untouched" "$(yn test -e "$HOME/pins/$R.uuid")" no

# 2. Restart with --nudge: pin written, /exit sent, relaunch verified, nudge logged.
start_case; run --nudge; ok "restart rc" "$RC" 0
has "ok line" "$OUT" "OK pid $OLD -> "
has "verified fields" "$OUT" "version 2.9.9 sessionId $SID remote-control $R"
has "nudge sent" "$OUT" "nudge=sent"
ok "pin holds sid" "$(head -1 "$HOME/pins/$R.uuid")" "$SID"
ok "claude relaunched" "$(yn test "$(cat "$STATE/claudepid")" != "$OLD")" yes
has "nudge body" "$(cat "$STATE/sent.log")" "Fleet maintenance"

# 3. Scheduled-tasks exit dialog: cancelled, pin removed, claude untouched.
start_case; touch "$STATE/dialog"
run; ok "dialog rc" "$RC" 1; has "dialog skip" "$OUT" "SKIPPED(scheduled-tasks)"
ok "pin removed" "$(yn test -e "$HOME/pins/$R.uuid")" no
ok "old claude alive" "$(yn kill -0 "$OLD")" yes
ok "no relaunch" "$(cat "$STATE/claudepid")" "$OLD"

# 4. Verify failure after /exit: exit 3, pin left in place for inspection.
start_case; echo 2.9.7 > "$STATE/launch-version"
run; ok "verify rc" "$RC" 3
has "verify fail" "$OUT" "FAIL(verify) version 2.9.7 (want 2.9.9)"
ok "pin left" "$(head -1 "$HOME/pins/$R.uuid")" "$SID"

# 5. --wait-idle restarts once the footer clears; a session that stays busy hits the deadline and is refused.
start_case; printf 'esc to interrupt\n' >> "$STATE/$S.pane"
( sleep 1; sed -i '/esc to interrupt/d' "$STATE/$S.pane" ) & W=$!
run --wait-idle; ok "wait rc" "$RC" 0
has "waited" "$OUT" "waiting: footer shows"
has "ok after wait" "$OUT" "OK pid $OLD -> "
wait "$W"
start_case; printf 'esc to interrupt\n' >> "$STATE/$S.pane"
run --wait-idle; ok "deadline rc" "$RC" 1; has "deadline" "$OUT" "REFUSED(deadline) still busy after 2s"

finish "test-session-restart"
