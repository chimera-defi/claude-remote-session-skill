#!/usr/bin/env bash
# session-handoff.sh readiness classification: the real `ready` CLI (fake tmux shim answering has-session /
# capture-pane from an env var) over realistic pane captures, plus the same helpers re-run under every awk
# implementation and byte/UTF-8 locale (a `[❯›]` bracket class once made every idle pane read as a draft in a C locale).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
HANDOFF="$HERE/../scripts/session-handoff.sh"
# shellcheck disable=SC1090
source "$HANDOFF"   # source-guarded: must NOT run dispatch
ESC=$'\033'
RULE='────────────────────────────────────────────────────────'
NBSP=$'\xc2\xa0'

# pane <input-box lines...>: a ready-looking capture around the given input box
pane() { printf '● Ready.\n%s\n%s\n%s\n  [Sonnet 5] session-launcher-0718\n' "$RULE" "$(printf '%s\n' "$@")" "$RULE"; }
declare -A PANE WANT
add() { PANE[$1]="$2"; WANT[$1]="$3"; }   # name, capture, expected reason (safe|busy|menu|...)
add ready          "$(pane '❯')" safe
add busy           "$(printf '✢ Incubating… (esc to interrupt · 2m 5s)\n%s\n❯\n%s\n' "$RULE" "$RULE")" busy
add retry-line     "$(printf '✢ Retrying · next try in 5s · attempt 2 · esc to interrupt\n%s\n❯\n%s\n' "$RULE" "$RULE")" busy
add draft          "$(pane '❯ can you check the deployment logs and tell me why it failed')" draft-in-input-box
add quoted-draft   "$(pane '❯ remind me to navigate to settings and check how the ❯ char renders')" draft-in-input-box
add menu           "$(printf '  1. [ ] Fix the auth flow\n  2. [✔] Ship it\n\n  ↑/↓ to navigate · Enter to select · Esc to cancel\n%s\n❯\n%s\n' "$RULE" "$RULE")" menu
add starting       "Starting Claude Code…
Loading session state…" no-prompt
add dim-ghost      "$(pane "${ESC}[39m❯ ${ESC}[2mdelete the backup ref${ESC}[0m")" safe
add dim-cursor     "$(pane "${ESC}[39m❯ ${ESC}[7mc${ESC}[0;2mheck that the deployed hook is stable${ESC}[0m")" safe
add colored-draft  "$(pane "${ESC}[39m❯ ${ESC}[38;5;12mcheck on the blue deployment please${ESC}[0m")" draft-in-input-box
add dim-plus-menu  "$(printf '  1. [ ] Fix\n  2. [✔] Ship\n\n  ↑/↓ to navigate · Enter to select · Esc to cancel\n%s\n%s❯ %s[2mall good?%s[0m\n%s\n' "$RULE" "${ESC}[39m" "$ESC" "$ESC" "$RULE")" menu
add fake-escape    "$(pane '❯ my draft literally contains [2m as text, not an escape code')" draft-in-input-box
add blank-first    "$(pane '❯' '  please do not delete the production database')" draft-in-input-box
add multiline      "$(pane '❯ please look into this' '  and also this second line')" draft-in-input-box
add ws-padding     "$(pane '❯' "  ${NBSP}${NBSP}${NBSP}")" safe
add truncated      "$(printf '● Ready.\n%s\n❯ some text with no trailing border' "$RULE")" draft-in-input-box
# Codex TUI captures (live-derived, prompt glyph is ›)
CX='  >_ OpenAI Codex (v0.158.0)
     /tmp/example-codex-workdir
'
FOOT='  GPT-5.5 medium · /tmp/example-codex-workdir'
add codex-ready    "$CX
  There is a perfectly good prompt with your name on it.

›

$FOOT" safe
add codex-busy     "$CX
› Reply with exactly: PROBE-ONE.

• Working (0s • esc to interrupt)

›

$FOOT" busy
add codex-reply-mentions-working "$CX
› Explain status text.

• Working through the checklist is complete.

›

$FOOT" safe
add codex-reply-mentions-approval "$CX
› What did the user choose?

• The reply included the words \"Yes, proceed\", but no approval widget is open.

›

$FOOT" safe
add codex-trust-menu "  Folder access

  Trust this folder? Codex can read, edit, and run files here.

› 1. Trust and continue
  2. Back to Agent Command Center

  enter continue · esc back" menu
add codex-model-menu "› 1. Try new model
  2. Use existing model

  enter/esc confirm · ctrl+c quit" menu
add codex-approval-menu "  Would you like to run the following command?

  \$ printf APPROVAL-PROBE > approval-probe.txt

› 1. Yes, proceed (y)
  2. No, and tell Codex what to do differently (esc)

  Press enter to confirm or esc to cancel" menu
add codex-rate-limit-menu "  Approaching rate limits
  Switch to gpt-6-luna for lower credit usage?

› 1. Switch to gpt-6-luna                   Fast and affordable model for easier tasks.
  2. Keep current model

  enter select · esc back" menu

FAKE="$(mktemp -d)"; trap 'tmux ls -F "#{session_name}" 2>/dev/null | grep "^hoff-ready-$$-" | while read -r s; do tmux kill-session -t "$s" 2>/dev/null || true; done; rm -rf "$FAKE"' EXIT
cat > "$FAKE/tmux" <<'EOS'
#!/usr/bin/env bash
case "$1" in
  has-session)  [ -n "${FAKE_NO_SESSION:-}" ] && exit 1; exit 0 ;;
  capture-pane) printf '%s' "${FAKE_CAPTURE:-}" ;;
  display-message) printf '%s\n' "${FAKE_PANE_CMD:-claude}" ;;
  ls|list-sessions) [ -n "${FAKE_SESSIONS:-}" ] && printf '%s:\n' ${FAKE_SESSIONS} ;;
  load-buffer|paste-buffer|send-keys) exit 0 ;;
  *)            exit 1 ;;
esac
EOS
chmod +x "$FAKE/tmux"
run_ready() { FAKE_CAPTURE="$1" PATH="$FAKE:$PATH" bash "$HANDOFF" ready fake-session; }

for name in "${!PANE[@]}"; do
  out="$(run_ready "${PANE[$name]}")"; rc=$?
  if [ "${WANT[$name]}" = safe ]; then
    ok "ready[$name]" "$out/$rc" "ready: fake-session SAFE/0"
  else
    ok "ready[$name]" "$out/$rc" "ready: fake-session NOT-SAFE reason=${WANT[$name]}/1"
  fi
done
out="$(FAKE_NO_SESSION=1 PATH="$FAKE:$PATH" bash "$HANDOFF" ready ghost-session)"; rc=$?
ok "ready: missing session exits 2" "$rc" "2"; has "ready: missing session message" "$out" "no such tmux session"

# _state_of `blocked`: tail BLOCKED: marker, trailing question, quoted-high stays ready.
# `ready` (injection safety) stays SAFE. `check` exits 1. `send` is allowed.
frame() { printf '%s\n%s\n❯\n%s\n  [Sonnet 5] session-launcher-0718\n' "$1" "$RULE" "$RULE"; }
run_check() { FAKE_CAPTURE="$1" FAKE_PANE_CMD=claude CRSS_AUTONOMOUS=0 PATH="$FAKE:$PATH" bash "$HANDOFF" check fake-session; }
marker_cap="$(frame "$(printf '%s\n' '● answer the block' '● BLOCKED: need operator OK for X')")"
bullet_cap="$(frame '  ⏺ BLOCKED: need operator OK for X')"
question_cap="$(frame "$(printf '%s\n' '● earlier note' '● Should I apply the patch?   ')")"
qbody='● BLOCKED: need operator OK for an earlier step'
for i in $(seq 1 14); do
  if [ "$i" = 8 ]; then
    qbody+=$'\n● notes quote BLOCKED: from the old turn, then continued'
  else
    qbody+=$'\n● normal output line '"$i"
  fi
done
quoted_cap="$(frame "$qbody")"
edge_out() {
  local n="$1" b='● BLOCKED: edge' i
  for i in $(seq 2 "$n"); do b+=$'\n● plain '"$i"; done
  frame "$b"
}
settled_cap="$(frame "$(printf '%s\n' '● Should I apply the patch?' '● Continuing with the safe default.')")"
tip_last_cap="$(frame "$(printf '%s\n' '● answer' '  ※ Tip: want a follow-up?')")"
question_then_tip_cap="$(frame "$(printf '%s\n' '● Should I apply the patch?' 'Tip: shortcuts are in the footer')")"
busy_cap="$(printf '%s\n%s\n%s\n❯\n%s\n' '● BLOCKED: need operator OK for X' '✢ Incubating… (esc to interrupt · 2m 5s)' "$RULE" "$RULE")"

out="$(run_check "$marker_cap")"; rc=$?
has "check blocked-marker state" "$out" "state=blocked"; ok "check blocked-marker exits 1" "$rc" "1"
out="$(run_check "$bullet_cap")"; rc=$?
has "check ⏺ BLOCKED state" "$out" "state=blocked"; ok "check ⏺ BLOCKED exits 1" "$rc" "1"
out="$(run_check "$question_cap")"; rc=$?
has "check trailing-question state" "$out" "state=blocked"; ok "check trailing-question exits 1" "$rc" "1"
out="$(run_check "$quoted_cap")"; rc=$?
has "check quoted-high state" "$out" "state=ready"; ok "check quoted-high exits 0" "$rc" "0"
out="$(run_check "$(edge_out 13)")"; rc=$?
has "check BLOCKED just outside the 12-line tail stays ready" "$out" "state=ready"; ok "check edge-outside exits 0" "$rc" "0"
out="$(run_check "$(edge_out 12)")"; rc=$?
has "check BLOCKED on the tail boundary is blocked" "$out" "state=blocked"; ok "check edge-inside exits 1" "$rc" "1"
out="$(run_check "$settled_cap")"; rc=$?
has "check earlier question then a statement stays ready" "$out" "state=ready"; ok "check settled-after-question exits 0" "$rc" "0"
out="$(run_check "$tip_last_cap")"; rc=$?
has "check tip question as last line stays ready" "$out" "state=ready"; ok "check tip-last exits 0" "$rc" "0"
out="$(run_check "$question_then_tip_cap")"; rc=$?
has "check question then tip stays blocked" "$out" "state=blocked"; ok "check question-then-tip exits 1" "$rc" "1"
out="$(run_check "$busy_cap")"; rc=$?
has "check busy wins over a BLOCKED line" "$out" "state=busy"; ok "check busy-over-blocked exits 1" "$rc" "1"
out="$(run_ready "$marker_cap")"; rc=$?
ok "ready stays SAFE on a blocked pane" "$out/$rc" "ready: fake-session SAFE/0"
out="$(CRSS_AUTONOMOUS=0 FAKE_CAPTURE="$marker_cap" PATH="$FAKE:$PATH" bash "$HANDOFF" send fake-session "answer the block" 2>&1)"; rc=$?
has "send blocked notes and continues" "$out" "send: note — 'fake-session' is blocked"
has "send blocked landed" "$out" "landed on fake-session"
hasnt "send blocked is not refused" "$out" "refusing"
ok "send blocked exits 0" "$rc" "0"
iso="$(mktemp -d)"
out="$(CRSS_HOME="$iso" CRSS_SESSION_PREFIX=cs CRSS_LEGACY_PREFIXES='' FAKE_SESSIONS=cs_stalllane FAKE_CAPTURE="$marker_cap" FAKE_PANE_CMD=claude PATH="$FAKE:$PATH" bash "$HANDOFF" targets 2>&1)"
rm -rf "$iso"
ok "targets shows blocked" "$(printf '%s\n' "$out" | awk '/^cs_stalllane /{print $2}')" "blocked"

# the same classification under every awk and locale
locales=(C)
for candidate in C.UTF-8 en_US.UTF-8; do
  [ "$(LC_ALL="$candidate" locale charmap 2>/dev/null)" = UTF-8 ] && locales+=("$candidate")
done
ok utf8-locale-available "$([ "${#locales[@]}" -gt 1 ] && echo yes || echo no)" yes
for awk_impl in awk gawk mawk; do
  command -v "$awk_impl" >/dev/null 2>&1 || continue
  awk_path="$(command -v "$awk_impl")"
  for test_locale in "${locales[@]}"; do
    if (
      export LC_ALL="$test_locale"
      awk() { "$awk_path" "$@"; }
      pass=0; fail=0
      for name in ready draft quoted-draft dim-ghost menu blank-first; do
        ok "$name" "$(_safety_reason "${PANE[$name]}")" "${WANT[$name]}"
      done
      for prompt in '❯ ' '› foo' '› explain ❯'; do
        want=draft-in-input-box; [ "$prompt" = '❯ ' ] && want=safe
        ok "prompt [$prompt]" "$(_safety_reason "$prompt")" "$want"
      done
      ok "status line under empty prompt" "$(_safety_reason $'❯ \n────────────────\n  ⏵⏵ bypass permissions on (shift+tab to cycle)')" safe
      ok "working: spinner glyph" "$(yn _is_working '✽ Crafting…')" yes
      ok "working: two ellipses is not a spinner" "$(yn _is_working 'Reading… done…')" no
      [ "$fail" -eq 0 ]
    ); then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $awk_impl / $test_locale"; fi
  done
done

# _codex_live against real processes: only a foreground codex under a wrapper shell counts
if command -v tmux >/dev/null 2>&1; then
  FB="$(mktemp -d)"; cp "$(command -v sleep)" "$FB/codex"
  TS="crsslive$$"
  tmux new-session -d -s "${TS}a" "bash -c '$FB/codex 60; true'"
  tmux new-session -d -s "${TS}b" "bash -i"
  sleep 0.5; tmux send-keys -t "${TS}b" "$FB/codex 60 &" Enter; sleep 0.5
  tmux new-session -d -s "${TS}c" "bash -i"
  sleep 0.5; tmux send-keys -t "${TS}c" "$FB/codex 60" Enter; sleep 0.4; tmux send-keys -t "${TS}c" C-z; sleep 0.5
  tmux new-session -d -s "${TS}d" "bash -i"; sleep 0.5
  ok "codex live: foreground under wrapper" "$(yn _codex_live "${TS}a")" yes
  ok "codex live: backgrounded is refused" "$(yn _codex_live "${TS}b")" no
  ok "codex live: stopped is refused" "$(yn _codex_live "${TS}c")" no
  ok "codex live: bare shell is refused" "$(yn _codex_live "${TS}d")" no
  for z in a b c d; do tmux kill-session -t "${TS}$z" 2>/dev/null; done
  pkill -f "$FB/codex" 2>/dev/null; rm -rf "$FB"
fi

# Static guard: no scripts/*.sh may contain a bracket expression with a non-ASCII char (byte locales split it
# into bytes). grep -P under LC_ALL=C sees raw bytes. Comment lines and non-class literals are excluded.
has_glyph_bracket() {
  grep -vE '^[[:space:]]*#' | grep -vE '\$\{[A-Za-z_]+//[^}]*\}|\[no log entry |is LIVE now — ' |
    LC_ALL=C grep -P '\[\^?\]?(?:[^\]]|\[:[^\]]*:\])*[\x80-\xff]' >/dev/null
}
for f in "$HERE"/../scripts/*.sh; do
  if has_glyph_bracket < "$f"; then fail=$((fail+1)); echo "FAIL: no-nonascii-bracket-class in $f"; else pass=$((pass+1)); fi
done
for pat in '[❯]' '[ ❯›]' '[^❯›]' '[[:space:]❯]' '[]❯]' '[✻✽✶·]'; do
  ok "guard-rejects-$pat" "$(printf '%s\n' "grep -E 'x$pat'" | has_glyph_bracket && echo yes || echo no)" yes
done
ok guard-accepts-ascii-class "$(printf '%s\n' "grep -E 'x[[:space:]]*y'" | has_glyph_bracket && echo yes || echo no)" no
ok guard-ignores-comment "$(printf '%s\n' "# grep -E '[❯]'" | has_glyph_bracket && echo yes || echo no)" no

# Live fixture modes (fake-claude-tui.py): the same three stalls, on a real pane.
if command -v tmux >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  spawn_blocked() {
    local mode="$1" want="$2" s tries=0 cap
    s="hoff-ready-$$-$mode"
    : > "$FAKE/$s.log"
    tmux new-session -d -s "$s" -x 100 -y 40 2>/dev/null
    tmux send-keys -t "$s" "FAKE_TUI_LOG='$FAKE/$s.log' exec -a claude python3 '$HERE/fake-claude-tui.py' '$mode'" Enter
    while [ "$tries" -lt 50 ]; do
      if [ "$(tmux list-panes -t "$s" -F '#{pane_current_command}' 2>/dev/null | head -1)" = claude ] \
         && cap="$(tmux capture-pane -p -t "$s" 2>/dev/null && printf x)" && cap=${cap%x} && [ -n "$cap" ] \
         && grep -qF -- "$want" <<<"${cap%$'\n'}"; then
        printf '%s' "$s"
        return 0
      fi
      sleep 0.1; tries=$((tries + 1))
    done
    echo "FAIL: spawn $mode (last capture follows)" >&2
    tmux capture-pane -p -t "$s" >&2 || true
    printf '%s' "$s"
    return 1
  }
  S="$(spawn_blocked blocked-marker "BLOCKED: need operator OK for X")"
  out="$(bash "$HANDOFF" check "$S" 2>&1)"; rc=$?
  has "live marker state" "$out" "state=blocked"; ok "live marker exit" "$rc" "1"
  out="$(CRSS_AUTONOMOUS=0 bash "$HANDOFF" send "$S" "operator says yes" 2>&1)"; rc=$?
  hasnt "live send is not refused" "$out" "refusing"
  ok "live send exit is not 2" "$([ "$rc" -eq 2 ] && echo yes || echo no)" no
  has "live send pasted" "$(cat "$FAKE/$S.log")" "PASTE "
  S="$(spawn_blocked blocked-question "Should I apply the patch?")"
  out="$(bash "$HANDOFF" check "$S" 2>&1)"; rc=$?
  has "live question state" "$out" "state=blocked"; ok "live question exit" "$rc" "1"
  S="$(spawn_blocked blocked-quoted "normal output line 14")"
  cap="$(tmux capture-pane -p -t "$S" 2>/dev/null || true)"
  has "live quoted marker still on screen" "$cap" "BLOCKED: need operator OK for an earlier step"
  out="$(bash "$HANDOFF" check "$S" 2>&1)"; rc=$?
  has "live quoted-high state" "$out" "state=ready"; ok "live quoted-high exit" "$rc" "0"
fi

finish "session-handoff-ready"
