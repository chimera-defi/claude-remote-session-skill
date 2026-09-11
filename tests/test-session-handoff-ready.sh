#!/usr/bin/env bash
# Plain-bash tests for the _is_safe_to_inject / _safety_reason positive
# readiness predicate. No live tmux needed: like test-session-handoff.sh, the
# logic is factored into pure functions that take a captured-pane string, so
# it can be tested against realistic fixtures.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1090
source "$HERE/../scripts/session-handoff.sh"   # source-guarded: must NOT run dispatch
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }
has(){ if printf '%s' "$2" | grep -qF "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — pattern not found: $3 in: $2"; fi; }

# --- realistic claude-TUI captures (trimmed from live panes) ------------------

# clean ready pane, empty input box -> SAFE
READY_PANE='● Ready.
────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────
  [Sonnet 5] session-launcher-0718
  ⏵⏵ bypass permissions on (shift+tab to cycle)'

# spinner / "esc to interrupt" -> not safe, reason=busy
BUSY_PANE='● Working on the survey…
✢ Incubating… (esc to interrupt · 2m 5s · ↓ 9.6k tokens)
────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────
  [Opus 4.8] portfolio-ssot'

# headline case: unsubmitted, multi-word draft sitting in the input box ->
# not safe, reason=draft-in-input-box
DRAFT_PANE='● Ready.
────────────────────────────────────────────────────────
❯ can you check the deployment logs and tell me why it failed
────────────────────────────────────────────────────────
  [Sonnet 5] session-launcher-0718'

# sitting on a checkbox / ↑/↓-to-navigate menu widget -> not safe, reason=menu
MENU_PANE='● Where should I point the next iteration?

  1. [ ] Fix the auth flow
  2. [✔] Ship the dashboard redesign
  3. [ ] Refactor the API client

  ↑/↓ to navigate · Enter to select · Esc to cancel
────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────
  [Opus 4.8] portfolio-ssot'

# no ❯ prompt at all (e.g. still starting up) -> not safe, reason=no-prompt
STARTING_PANE='Starting Claude Code…
Loading session state…
'

# a draft that merely MENTIONS "navigate" and contains a literal ❯ character
# in quoted text — must NOT be misclassified as a menu, and the embedded ❯
# must not confuse the input-box split. Should still be draft-in-input-box
# (there is real unsubmitted text on the prompt line).
QUOTED_PANE='● Ready.
────────────────────────────────────────────────────────
❯ remind me to navigate to settings and check how the ❯ char renders
────────────────────────────────────────────────────────
  [Sonnet 5] session-launcher-0718'

# --- ANSI-preserving fixtures (tmux `capture-pane -p -e`) ---------------------
# Claude Code renders an auto-suggested "next action" as dim (SGR 2) ghost
# text sitting in an otherwise-empty input box — confirmed empirically against
# live sessions on 2026-09-11. It is NOT a user draft, and _is_safe_to_inject
# must tell the two apart using the ANSI-preserving capture `ready` passes.
ESC=$'\033'

# dim ghost "suggested next action" placeholder, no real draft -> SAFE
DIM_PLACEHOLDER_PANE="● Ready.
────────────────────────────────────────────────────────
${ESC}[39m❯ ${ESC}[2mdelete the backup ref${ESC}[0m
────────────────────────────────────────────────────────
  [Sonnet 5] session-launcher-0718"

# same, but the terminal cursor sits on the ghost text's first character,
# splitting the dim run into a reverse-video glyph + a resumed dim tail
# (observed live: `ESC[7mc ESC[0;2mheck that the deployed hook is stable`) ->
# still SAFE — this is the same ghost text, just cursor-highlighted.
DIM_PLACEHOLDER_CURSOR_SPLIT_PANE="● Ready.
────────────────────────────────────────────────────────
${ESC}[39m❯ ${ESC}[7mc${ESC}[0;2mheck that the deployed hook is stable${ESC}[0m
────────────────────────────────────────────────────────
  [Sonnet 5] session-launcher-0718"

# real draft, but styled (a plain foreground color, NOT the dim attribute) ->
# still NOT safe, reason=draft-in-input-box. Also proves the dim-opener match
# is exact (`2m`/`0;2m`), not a `2m`-suffix wildcard that would misfire on an
# ordinary 256-color code like `38;5;12m` (ends in "2m" but isn't dim).
NON_DIM_STYLED_DRAFT_PANE="● Ready.
────────────────────────────────────────────────────────
${ESC}[39m❯ ${ESC}[38;5;12mcheck on the blue deployment please${ESC}[0m
────────────────────────────────────────────────────────
  [Sonnet 5] session-launcher-0718"

# dim placeholder ghost text PLUS a menu widget on screen at the same time ->
# NOT safe, reason=menu — menu must win over the dim-placeholder allowance.
DIM_PLACEHOLDER_PLUS_MENU_PANE="● Where should I point the next iteration?

  1. [ ] Fix the auth flow
  2. [✔] Ship the dashboard redesign

  ↑/↓ to navigate · Enter to select · Esc to cancel
────────────────────────────────────────────────────────
${ESC}[39m❯ ${ESC}[2mall good?${ESC}[0m
────────────────────────────────────────────────────────
  [Opus 4.8] portfolio-ssot"

# a real draft that happens to contain the literal characters "[2m" as text,
# with no actual ESC byte in front of it -> must still be NOT safe. Proves
# the matcher requires a genuine SGR escape, not a "[2m" substring.
FAKE_ESCAPE_TEXT_DRAFT_PANE='● Ready.
────────────────────────────────────────────────────────
❯ my draft literally contains [2m as text, not an escape code
────────────────────────────────────────────────────────
  [Sonnet 5] session-launcher-0718'

# empty / whitespace-only capture -> not safe, reason=no-prompt
EMPTY_CAP=''
WHITESPACE_CAP='

   '

# --- _safety_reason: one-word diagnosis ---------------------------------------
ok "reason-ready"       "$(_safety_reason "$READY_PANE")"      "safe"
ok "reason-busy"        "$(_safety_reason "$BUSY_PANE")"       "busy"
ok "reason-draft"       "$(_safety_reason "$DRAFT_PANE")"      "draft-in-input-box"
ok "reason-menu"        "$(_safety_reason "$MENU_PANE")"       "menu"
ok "reason-no-prompt"   "$(_safety_reason "$STARTING_PANE")"   "no-prompt"
ok "reason-quoted-draft" "$(_safety_reason "$QUOTED_PANE")"    "draft-in-input-box"
ok "reason-empty"       "$(_safety_reason "$EMPTY_CAP")"       "no-prompt"
ok "reason-whitespace"  "$(_safety_reason "$WHITESPACE_CAP")"  "no-prompt"

# --- _safety_reason: ANSI-aware dim-ghost-text vs. real-draft split -----------
ok "reason-dim-placeholder"       "$(_safety_reason "$DIM_PLACEHOLDER_PANE")"              "safe"
ok "reason-dim-cursor-split"      "$(_safety_reason "$DIM_PLACEHOLDER_CURSOR_SPLIT_PANE")"  "safe"
ok "reason-non-dim-styled-draft"  "$(_safety_reason "$NON_DIM_STYLED_DRAFT_PANE")"          "draft-in-input-box"
ok "reason-dim-plus-menu"         "$(_safety_reason "$DIM_PLACEHOLDER_PLUS_MENU_PANE")"     "menu"
ok "reason-fake-escape-text"      "$(_safety_reason "$FAKE_ESCAPE_TEXT_DRAFT_PANE")"        "draft-in-input-box"

# --- _is_safe_to_inject: exit-status predicate, no echo ------------------------
ok "safe-ready"     "$(_is_safe_to_inject "$READY_PANE"     && echo yes || echo no)" "yes"
ok "safe-busy"      "$(_is_safe_to_inject "$BUSY_PANE"      && echo yes || echo no)" "no"
ok "safe-draft"     "$(_is_safe_to_inject "$DRAFT_PANE"     && echo yes || echo no)" "no"
ok "safe-menu"      "$(_is_safe_to_inject "$MENU_PANE"      && echo yes || echo no)" "no"
ok "safe-no-prompt" "$(_is_safe_to_inject "$STARTING_PANE"  && echo yes || echo no)" "no"
ok "safe-quoted"    "$(_is_safe_to_inject "$QUOTED_PANE"    && echo yes || echo no)" "no"
ok "safe-empty"     "$(_is_safe_to_inject "$EMPTY_CAP"      && echo yes || echo no)" "no"
ok "safe-whitespace" "$(_is_safe_to_inject "$WHITESPACE_CAP" && echo yes || echo no)" "no"
ok "safe-dim-placeholder"      "$(_is_safe_to_inject "$DIM_PLACEHOLDER_PANE"             && echo yes || echo no)" "yes"
ok "safe-dim-cursor-split"     "$(_is_safe_to_inject "$DIM_PLACEHOLDER_CURSOR_SPLIT_PANE" && echo yes || echo no)" "yes"
ok "safe-non-dim-styled-draft" "$(_is_safe_to_inject "$NON_DIM_STYLED_DRAFT_PANE"         && echo yes || echo no)" "no"
ok "safe-dim-plus-menu"        "$(_is_safe_to_inject "$DIM_PLACEHOLDER_PLUS_MENU_PANE"    && echo yes || echo no)" "no"
ok "safe-fake-escape-text"     "$(_is_safe_to_inject "$FAKE_ESCAPE_TEXT_DRAFT_PANE"       && echo yes || echo no)" "no"

# --- _is_on_menu: false-positive proofing ---------------------------------------
# "navigate" alone (no arrows, no "Enter to select"/"Esc to cancel") must not
# trip the menu detector — only the full distinctive hint strings should.
ok "menu-false-positive-word"  "$(_is_on_menu "$QUOTED_PANE" && echo yes || echo no)" "no"
ok "menu-false-positive-draft" "$(_is_on_menu "$DRAFT_PANE"  && echo yes || echo no)" "no"
ok "menu-true-positive"        "$(_is_on_menu "$MENU_PANE"   && echo yes || echo no)" "yes"

# --- _input_box_empty: direct coverage of the empty/draft split ---------------
ok "inputbox-empty-on-ready" "$(_input_box_empty "$READY_PANE" && echo yes || echo no)" "yes"
ok "inputbox-empty-on-draft" "$(_input_box_empty "$DRAFT_PANE" && echo yes || echo no)" "no"
ok "inputbox-empty-on-quoted" "$(_input_box_empty "$QUOTED_PANE" && echo yes || echo no)" "no"
ok "inputbox-empty-on-dim" "$(_input_box_empty "$DIM_PLACEHOLDER_PANE" && echo yes || echo no)" "yes"

# --- _is_dim_span: direct coverage of the exact-opener matching ---------------
# The false-positive-proofing case that matters most: a 256-color code that
# merely ends in digit 2 (e.g. "38;5;12m") is NOT the dim attribute and must
# not be treated as one.
NOT_DIM_COLOR_ONLY="${ESC}[38;5;12mcheck on the blue deployment please${ESC}[0m"
ok "dimspan-true-plain"  "$(_is_dim_span "${ESC}[2mdelete the backup ref${ESC}[0m" && echo yes || echo no)" "yes"
ok "dimspan-true-cursor" "$(_is_dim_span "${ESC}[7mc${ESC}[0;2mheck it${ESC}[0m"   && echo yes || echo no)" "yes"
ok "dimspan-false-color" "$(_is_dim_span "$NOT_DIM_COLOR_ONLY" && echo yes || echo no)" "no"

# --- `ready` CLI mode: exercise the real dispatch via a fake `tmux` shim ------
# No real tmux session is touched: `tmux` on PATH is a throwaway script that
# answers has-session/capture-pane from an env var, so the actual CLI code
# path in session-handoff.sh (not a hand-built string) is what gets checked.
FAKE_TMUX_DIR="$(mktemp -d)"
trap 'rm -rf "$FAKE_TMUX_DIR"' EXIT
cat > "$FAKE_TMUX_DIR/tmux" <<'EOS'
#!/usr/bin/env bash
case "$1" in
  has-session)  [ -n "${FAKE_NO_SESSION:-}" ] && exit 1; exit 0 ;;
  capture-pane) printf '%s' "${FAKE_CAPTURE:-}" ;;
  *)            exit 1 ;;
esac
EOS
chmod +x "$FAKE_TMUX_DIR/tmux"

_run_ready() {
  FAKE_CAPTURE="$1" PATH="$FAKE_TMUX_DIR:$PATH" bash "$HERE/../scripts/session-handoff.sh" ready fake-session
}

out="$(_run_ready "$READY_PANE")";    rc=$?
ok "cli-ready-safe-line" "$out" "ready: fake-session SAFE"
ok "cli-ready-safe-exit" "$rc" "0"

out="$(_run_ready "$BUSY_PANE")";     rc=$?
ok "cli-ready-busy-line" "$out" "ready: fake-session NOT-SAFE reason=busy"
ok "cli-ready-busy-exit" "$rc" "1"

out="$(_run_ready "$DRAFT_PANE")";    rc=$?
ok "cli-ready-draft-line" "$out" "ready: fake-session NOT-SAFE reason=draft-in-input-box"
ok "cli-ready-draft-exit" "$rc" "1"

out="$(_run_ready "$MENU_PANE")";     rc=$?
ok "cli-ready-menu-line" "$out" "ready: fake-session NOT-SAFE reason=menu"
ok "cli-ready-menu-exit" "$rc" "1"

out="$(_run_ready "$STARTING_PANE")"; rc=$?
ok "cli-ready-noprompt-line" "$out" "ready: fake-session NOT-SAFE reason=no-prompt"
ok "cli-ready-noprompt-exit" "$rc" "1"

out="$(_run_ready "$DIM_PLACEHOLDER_PANE")"; rc=$?
ok "cli-ready-dim-placeholder-line" "$out" "ready: fake-session SAFE"
ok "cli-ready-dim-placeholder-exit" "$rc" "0"

out="$(_run_ready "$NON_DIM_STYLED_DRAFT_PANE")"; rc=$?
ok "cli-ready-non-dim-draft-line" "$out" "ready: fake-session NOT-SAFE reason=draft-in-input-box"
ok "cli-ready-non-dim-draft-exit" "$rc" "1"

out="$(FAKE_NO_SESSION=1 FAKE_CAPTURE='' PATH="$FAKE_TMUX_DIR:$PATH" bash "$HERE/../scripts/session-handoff.sh" ready ghost-session)"; rc=$?
ok "cli-ready-no-session-exit" "$rc" "2"
has "cli-ready-no-session-msg" "$out" "no such tmux session"

echo "session-handoff-ready: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
