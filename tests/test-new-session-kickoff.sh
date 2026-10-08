#!/usr/bin/env bash
# new-session.sh's post-spawn kickoff (--task/--task-file) exit semantics, hermetic:
# a private copy of the script sits next to a STUB session-handoff.sh, systemctl is
# stubbed, HOME is a temp dir. Pins (1) a non-ready poll no longer kills the script
# silently under `set -e`, (2) a task that is not delivered exits 3 with a message and
# never prints "Session created", (3) a systemd failure is loud.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
isolate_overlay
export CRSS_SESSION_PREFIX=px
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
BIN="$T/bin"; mkdir -p "$BIN"
cp "$HERE/../scripts/new-session.sh" "$BIN/new-session.sh"
cat > "$BIN/systemctl" <<'EOS'
#!/usr/bin/env bash
[ -n "${STUB_SYSTEMCTL_FAIL:-}" ] && { echo "Failed to enable unit" >&2; exit 1; }
exit 0
EOS
chmod +x "$BIN/systemctl"
# Stub handoff: `check` walks STUB_CHECKS (space-separated state names; last one repeats);
# `send` succeeds unless STUB_SEND_FAIL is set.
cat > "$BIN/session-handoff.sh" <<'EOS'
#!/usr/bin/env bash
case "$1" in
  check)
    n=$(cat "$STUB_DIR/n" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$STUB_DIR/n"
    read -ra st <<<"$STUB_CHECKS"; i=$((n-1)); [ "$i" -ge "${#st[@]}" ] && i=$((${#st[@]}-1))
    echo "check: $2  state=${st[$i]}  unit-active=yes model=x"
    [ "${st[$i]}" = ready ] && exit 0
    [ "${st[$i]}" = gone ] && exit 2
    exit 1 ;;
  send) [ -n "${STUB_SEND_FAIL:-}" ] && exit 1; echo "stub send"; exit 0 ;;
esac
EOS
export STUB_DIR="$T"
export PATH="$BIN:$PATH" NEW_SESSION_MIN_AVAIL_MB=0 NEW_SESSION_TASK_READY_TRIES=6 NEW_SESSION_TASK_SETTLE=2
run() { rm -f "$T/n"; STUB_CHECKS="$1" bash "$BIN/new-session.sh" kick-$RANDOM --task "do it" >"$T/out" 2>"$T/err"; echo $?; }

# starting -> busy -> ready: previously the FIRST non-ready poll exited the script silently
ok  "recovers-after-not-ready-rc"  "$(run "starting busy ready")" "0"
has "recovers-after-not-ready-out" "$(cat "$T/out")" "Task sent to px-kick-"
has "recovers-confirms"            "$(cat "$T/out")" "Session created: px-kick-"

# trust dialog / menu: loud, non-zero, no success banner, names the session and the safe answer
ok  "menu-rc3" "$(run "starting menu")" "3"
has "menu-says-trust"  "$(cat "$T/err")" "menu/trust dialog"
has "menu-says-not-delivered" "$(cat "$T/err")" "task was NOT delivered"
has "menu-warns-default-is-exit" "$(cat "$T/err")" "'No, exit'"
hasnt "menu-no-success-banner" "$(cat "$T/out")" "Session created"
hasnt "menu-not-sent" "$(cat "$T/out")" "Task sent"

# never ready
ok  "never-ready-rc3" "$(run "starting")" "3"
has "never-ready-msg" "$(cat "$T/err")" "never reached ready state"
hasnt "never-ready-no-banner" "$(cat "$T/out")" "Session created"

# tmux session vanished mid-poll
ok  "vanished-rc3" "$(run "starting gone")" "3"
has "vanished-msg" "$(cat "$T/err")" "vanished"

# send not verified
rm -f "$T/n"; STUB_SEND_FAIL=1 STUB_CHECKS="ready" bash "$BIN/new-session.sh" kick-u --task "x" >"$T/out" 2>"$T/err"; rc=$?
ok  "unverified-rc3" "$rc" "3"
has "unverified-msg" "$(cat "$T/err")" "UNVERIFIED"
hasnt "unverified-no-banner" "$(cat "$T/out")" "Session created"

# --task-file resend hint carries the file path
printf 'hello\n' > "$T/task.txt"; rm -f "$T/n"
# Codex model-retirement menu: named distinctly (not "trust"), still exit 3, never auto-answered
mkdir -p "$T/tmuxstub"
cat > "$T/tmuxstub/tmux" <<'EOS'
#!/usr/bin/env bash
[ "$1" = capture-pane ] && { printf '%s\n' "${STUB_PANE:-}"; exit 0; }
exec "$REAL_TMUX" "$@"
EOS
chmod +x "$T/tmuxstub/tmux"
REAL_TMUX="$(command -v tmux)"; export REAL_TMUX
STUB_PANE="GPT-5.5 retires on October 14, 2026.
1. Try new model
2. Use existing model" PATH="$T/tmuxstub:$PATH" run "menu" >"$T/rc"
has "model-menu-rc3" "$(cat "$T/rc")" "3"
has "model-menu-named" "$(cat "$T/err")" "model-retirement menu"
hasnt "model-menu-not-trust" "$(cat "$T/err")" "'Yes, I trust this folder'"
has "model-menu-no-autopick" "$(cat "$T/err")" "not an auto-pick"
STUB_CHECKS="menu" bash "$BIN/new-session.sh" kick-f --task-file "$T/task.txt" >"$T/out" 2>"$T/err"
has "menu-resend-hint-file" "$(cat "$T/err")" "--file $T/task.txt"

# no task: unchanged behaviour (banner, rc 0)
rm -f "$T/n"; bash "$BIN/new-session.sh" kick-n >"$T/out" 2>"$T/err"; rc=$?
ok  "no-task-rc0" "$rc" "0"; has "no-task-banner" "$(cat "$T/out")" "Session created"

# systemd failure is loud and non-zero (no banner)
STUB_SYSTEMCTL_FAIL=1 bash "$BIN/new-session.sh" kick-s >"$T/out" 2>"$T/err"; rc=$?
ok  "systemd-fail-rc1" "$rc" "1"
has "systemd-fail-msg" "$(cat "$T/err")" "systemd failed to start"
hasnt "systemd-fail-no-banner" "$(cat "$T/out")" "Session created"

# --task validation fails loudly BEFORE anything spawns
out="$(bash "$BIN/new-session.sh" --dry-run mutex-test --task hi --task-file /etc/hostname 2>&1)"; rc=$?
ok "task+task-file mutually exclusive: exit 2" "$rc" "2"; hasnt "mutex: nothing resolved" "$out" "SESSION="
out="$(bash "$BIN/new-session.sh" --dry-run missing-file-test --task-file "/no/such/path/xyz-$$" 2>&1)"; rc=$?
ok "missing --task-file: exit 2" "$rc" "2"; has "missing --task-file: message" "$out" "missing or unreadable"
out="$(bash "$BIN/new-session.sh" --dry-run valid-task-test --task "hello world" 2>&1)"; rc=$?
ok "valid --task dry-run: exit 0" "$rc" "0"; has "valid --task dry-run resolves names" "$out" "SESSION=px_valid-task-test-"

finish "new-session-kickoff"
