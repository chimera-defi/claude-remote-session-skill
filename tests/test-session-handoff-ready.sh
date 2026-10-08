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

FAKE="$(mktemp -d)"; trap 'rm -rf "$FAKE"' EXIT
cat > "$FAKE/tmux" <<'EOS'
#!/usr/bin/env bash
case "$1" in
  has-session)  [ -n "${FAKE_NO_SESSION:-}" ] && exit 1; exit 0 ;;
  capture-pane) printf '%s' "${FAKE_CAPTURE:-}" ;;
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

finish "session-handoff-ready"
