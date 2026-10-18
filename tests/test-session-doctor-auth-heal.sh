#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
isolate_overlay
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP" "$TELEMETRY_ROOT"' EXIT
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" XDG_CONFIG_HOME="$TMP/config"
mkdir -p "$TMP/bin" "$HOME/.claude/projects/-w-demo-repo"
export PATH="$TMP/bin:$PATH" CRSS_CLAUDE_BIN="$TMP/bin/claude" CRSS_SESSION_SEND="$TMP/bin/session-send"
export SEND_LOG="$TMP/sent" LOGGED_IN=true
cat > "$TMP/bin/tmux" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  ls) printf 'lane: 1 windows\nclaude-remote: 1 windows\n';;
  has-session) exit 0;;
  display-message) echo /w/demo_repo;;
  capture-pane) printf '%s\n' "${PANE:-❯ }";;
  *) exit 1;;
esac
STUB
printf '#!/usr/bin/env bash\nprintf '\''{"loggedIn":%%s}\\n'\'' "$LOGGED_IN"\n' > "$CRSS_CLAUDE_BIN"
printf '#!/usr/bin/env bash\n[ "${SEND_FAIL:-no}" = yes ] && exit 1\nprintf "%%s\\n" "$@" >> "$SEND_LOG"\n' > "$CRSS_SESSION_SEND"
chmod +x "$TMP/bin/"*
SD="$HERE/../scripts/session-doctor.sh"; TRANSCRIPT="$HOME/.claude/projects/-w-demo-repo/11111111-1111-4111-8111-111111111111.jsonl"
run() { bash "$SD" auth-heal "$@" 2>&1; }
failure() { printf '{"type":"assistant","uuid":"%s","timestamp":"%s","isApiErrorMessage":true,"message":{"content":"401 OAuth access token has expired. Re-authenticate to continue."}}\n' "$1" "$(date -u +%FT%TZ)"; }
failure first > "$TRANSCRIPT"
printf '%s\n' '{"type":"system","subtype":"informational"}' '{"type":"file-history-snapshot"}' '{"type":"summary"}' >> "$TRANSCRIPT"
out="$(run)"; ok dry-rc "$?" 0; has dry "$out" 'would-nudge lane'; has protected "$out" 'skip(protected)'
nofile dry-no-send "$SEND_LOG"; nodir dry-no-state "$XDG_STATE_HOME"
out="$(run --apply)"; ok apply-rc "$?" 0; has applied "$out" 'nudged lane'
ok send-session "$(head -1 "$SEND_LOG")" lane
has send-message "$(cat "$SEND_LOG")" 'Please continue where you left off; re-read your TASKS.md if you have one.'
out="$(run --apply)"; ok dedupe-rc "$?" 0; has dedupe "$out" 'skip(already-nudged)'
ok once "$(wc -l < "$SEND_LOG" | tr -d ' ')" 2
failure second >> "$TRANSCRIPT"
out="$(run --apply)"; ok repeat-rc "$?" 1; has repeat "$out" 'skip(repeat-failure — login likely dead; operator /login)'
printf '%s\n' '{"type":"assistant","requestId":"ok","message":{"content":"success"}}' >> "$TRANSCRIPT"
out="$(run --apply)"; ok recovered-rc "$?" 0; hasnt recovered "$out" 'nudged lane'
failure third >> "$TRANSCRIPT"
export LOGGED_IN=false
out="$(run --apply)"; ok login-rc "$?" 1; has login "$out" 'host not logged in — operator must /login'
ok no-resend "$(wc -l < "$SEND_LOG" | tr -d ' ')" 2
export LOGGED_IN=true PANE='esc to interrupt'
rm "$XDG_STATE_HOME/crss/auth-heal.tsv"
out="$(run --apply)"; has busy "$out" 'skip(busy)'
export PANE='❯ '
printf '{"type":"system","subtype":"api_error","status":401,"timestamp":"%s"}\n' "$(date -u +%FT%TZ)" > "$TRANSCRIPT"
out="$(run)"; has system-401 "$out" 'would-nudge lane'
run --days >/dev/null; ok missing-days "$?" 2
export SEND_FAIL=yes
out="$(run --apply)"; ok failed-send-rc "$?" 1; nofile failed-send-no-state "$XDG_STATE_HOME/crss/auth-heal.tsv"
export SEND_FAIL=no
out="$(run --apply)"; ok timestamp-fallback-rc "$?" 0
out="$(run --apply)"; has timestamp-dedupe "$out" 'skip(already-nudged)'
printf '%s\n' '{"type":"assistant","message":{"content":"recovered"}}' > "${TRANSCRIPT%/*}/22222222-2222-4222-8222-222222222222.jsonl"
out="$(run)"; has newest-recovered "$out" 'skip(no-auth-failure)'
finish session-doctor-auth-heal
