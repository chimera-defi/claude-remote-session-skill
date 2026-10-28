#!/usr/bin/env bash
# Pin the delivered kickoff, rather than just grepping the launcher source.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
isolate_overlay
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
BIN="$T/bin"; mkdir -p "$BIN"
cp "$HERE/../scripts/new-session.sh" "$BIN/new-session.sh"
ln -s "$HERE/../scripts/session-alias.sh" "$BIN/session-alias"
cat > "$BIN/systemctl" <<'EOS'
#!/usr/bin/env bash
case " $* " in *" enable "*)
  unit="${!#}"; unit="${unit%.service}"; sess="${unit/#px-/px_}"
  sid="$(sed -n 's/^START_ID=//p' "$HOME/.local/bin/${unit}-start.sh")"
  mkdir -p "$HOME/.sessions"
  printf '[%s] session=%s start_id=%s event=started\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$sess" "$sid" >> "$HOME/.sessions/session-starts.log" ;;
esac
exit 0
EOS
cat > "$BIN/session-handoff.sh" <<'EOS'
#!/usr/bin/env bash
case "$1" in
  check) echo 'state=ready'; exit 0 ;;
  send) printf '%s' "$3" > "$DELIVERED" ;;
esac
EOS
chmod +x "$BIN/systemctl"
export PATH="$BIN:$PATH" CRSS_SESSION_PREFIX=px
export NEW_SESSION_MIN_AVAIL_MB=0 NEW_SESSION_TASK_SETTLE=1
export CRSS_CODEX_BIN=/bin/true CRSS_CODEX_ARGS='-m fixture -s read-only'
export SESSION_ALIAS_STORE="$T/aliases" DELIVERED="$T/delivered"
brief=$'Run the checks.\nKeep literal $(touch SHOULD_NOT_EXIST) and `printf literal`.'
guidance='Shell output: use rtk for supported noisy commands (e.g. rtk git log -20, rtk ls, rtk test <command>) when installed; use the original command if rtk is unavailable or unfiltered output is needed.'
run() {
  local label="$1" backend="$2"; shift 2
  mkdir -p "$T/$label"
  rm -f "$DELIVERED"
  HOME="$T/$label" bash "$BIN/new-session.sh" "$label" sessions --alias "$label" \
    --backend "$backend" "$@" > "$T/out" 2> "$T/err"
}

run codex-task codex --task "$brief"; rc=$?
ok 'Codex task launch succeeds' "$rc" 0
ok 'Codex receives rtk guidance and literal task' "$(cat "$DELIVERED")" "$guidance"$'\n\n'"$brief"

printf '%s\n' "$brief" > "$T/task.txt"
run codex-file codex --task-file "$T/task.txt"; rc=$?
ok 'Codex task-file launch succeeds' "$rc" 0
ok 'Codex task-file receives the same guidance' "$(cat "$DELIVERED")" "$guidance"$'\n\n'"$brief"
ok 'Task file is preserved' "$(cat "$T/task.txt")" "$brief"

run claude-task claude --task "$brief"; rc=$?
ok 'Claude task launch succeeds' "$rc" 0
ok 'Claude kickoff is unchanged' "$(cat "$DELIVERED")" "$brief"

run codex-idle codex; rc=$?
ok 'Codex without task launches normally' "$rc" 0
nofile 'No unsolicited task is sent' "$DELIVERED"
nofile 'Task content is never evaluated by the launcher' "$HERE/../SHOULD_NOT_EXIST"
finish 'new-session-rtk'
