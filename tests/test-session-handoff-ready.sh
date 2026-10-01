#!/usr/bin/env bash
# _is_safe_to_inject / _safety_reason readiness predicate: pure functions over a captured-pane string, no live tmux.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
# shellcheck disable=SC1090
source "$HERE/../scripts/session-handoff.sh"   # source-guarded: must NOT run dispatch

# --- realistic claude-TUI captures (trimmed from live panes) ---

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
  [Opus 4.8] my-project'

# unsubmitted multi-word draft in the input box -> draft-in-input-box
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
  [Opus 4.8] my-project'

# no ❯ prompt at all (e.g. still starting up) -> not safe, reason=no-prompt
STARTING_PANE='Starting Claude Code…
Loading session state…
'

# a draft that merely MENTIONS "navigate" and contains a literal ❯ is NOT a menu and the ❯ must not confuse the
# input-box split -> draft-in-input-box
QUOTED_PANE='● Ready.
────────────────────────────────────────────────────────
❯ remind me to navigate to settings and check how the ❯ char renders
────────────────────────────────────────────────────────
  [Sonnet 5] session-launcher-0718'

# --- ANSI-preserving fixtures (capture-pane -e): Claude's dim (SGR 2) ghost "next action" text is NOT a draft ---
ESC=$'\033'

# dim ghost "suggested next action" placeholder, no real draft -> SAFE
DIM_PLACEHOLDER_PANE="● Ready.
────────────────────────────────────────────────────────
${ESC}[39m❯ ${ESC}[2mdelete the backup ref${ESC}[0m
────────────────────────────────────────────────────────
  [Sonnet 5] session-launcher-0718"

# cursor on the ghost text's first char (reverse-video glyph + resumed dim tail) -> still SAFE
DIM_PLACEHOLDER_CURSOR_SPLIT_PANE="● Ready.
────────────────────────────────────────────────────────
${ESC}[39m❯ ${ESC}[7mc${ESC}[0;2mheck that the deployed hook is stable${ESC}[0m
────────────────────────────────────────────────────────
  [Sonnet 5] session-launcher-0718"

# real draft in a plain foreground color (not dim) -> NOT safe; also proves the dim opener match is exact
# (`2m`/`0;2m`), not a `2m` suffix wildcard (256-color `38;5;12m` is not dim)
NON_DIM_STYLED_DRAFT_PANE="● Ready.
────────────────────────────────────────────────────────
${ESC}[39m❯ ${ESC}[38;5;12mcheck on the blue deployment please${ESC}[0m
────────────────────────────────────────────────────────
  [Sonnet 5] session-launcher-0718"

# dim ghost text PLUS a menu widget -> NOT safe, reason=menu (menu wins)
DIM_PLACEHOLDER_PLUS_MENU_PANE="● Where should I point the next iteration?

  1. [ ] Fix the auth flow
  2. [✔] Ship the dashboard redesign

  ↑/↓ to navigate · Enter to select · Esc to cancel
────────────────────────────────────────────────────────
${ESC}[39m❯ ${ESC}[2mall good?${ESC}[0m
────────────────────────────────────────────────────────
  [Opus 4.8] my-project"

# a draft containing the literal text "[2m" with no ESC byte -> NOT safe (needs a real SGR escape)
FAKE_ESCAPE_TEXT_DRAFT_PANE='● Ready.
────────────────────────────────────────────────────────
❯ my draft literally contains [2m as text, not an escape code
────────────────────────────────────────────────────────
  [Sonnet 5] session-launcher-0718'

# empty / whitespace-only capture -> not safe, reason=no-prompt
EMPTY_CAP=''
WHITESPACE_CAP='

   '

# --- multi-line input-box fixtures (regression: _input_box_empty must look at the WHOLE box) ---

# shift+enter / newline-leading paste leaves a BLANK line 1 with the draft on line 2; reading only line 1 said SAFE
# and `ready`/`send` would paste onto the unsent draft
BLANK_FIRST_LINE_DRAFT_PANE='● Ready.
────────────────────────────────────────────────────────
❯
  please do not delete the production database, just checking in
────────────────────────────────────────────────────────
  [Sonnet 5] session-launcher-0718'

# multi-line draft with text on lines 1 and 2 (guards that the box-wide rewrite kept the easy case)
MULTI_LINE_DRAFT_LINE1_PANE='● Ready.
────────────────────────────────────────────────────────
❯ please look into this
  and also this second line
────────────────────────────────────────────────────────
  [Sonnet 5] session-launcher-0718'

# lines past the ❯ line are only whitespace/NBSP padding (tmux pads rows) -> SAFE, not a draft
NBSP=$'\xc2\xa0'
MULTI_LINE_WHITESPACE_ONLY_PANE="● Ready.
────────────────────────────────────────────────────────
❯
  ${NBSP}${NBSP}${NBSP}
────────────────────────────────────────────────────────
  [Sonnet 5] session-launcher-0718"

# single dim ghost line directly followed by the border row (nbound boundary) -> SAFE; border must not join the box
DIM_THEN_IMMEDIATE_BORDER_PANE="● Ready.
────────────────────────────────────────────────────────
${ESC}[39m❯ ${ESC}[2mdelete the backup ref${ESC}[0m
────────────────────────────────────────────────────────
  [Sonnet 5] session-launcher-0718"

# truncated capture: ❯ line with text but NO border row -> must not crash; box runs to end, draft reads NOT empty
TRUNCATED_NO_BORDER_PANE='● Ready.
────────────────────────────────────────────────────────
❯ some text with no trailing border'

# --- _safety_reason: one-word diagnosis ---------------------------------------
ok "reason-ready"       "$(_safety_reason "$READY_PANE")"      "safe"
ok "reason-busy"        "$(_safety_reason "$BUSY_PANE")"       "busy"
# Claude's API-retry status line has no parentheses; it must still read busy.
RETRY_PANE='● Working on the survey…
✢ Retrying · next try in 5s · attempt 2 · esc to interrupt'
ok "working-retry-line" "$(_is_working "$RETRY_PANE" && echo yes || echo no)" "yes"
# Collapsed paste: spinner glyph + word… with no "esc to interrupt" yet.
ok "working-glyph-only" "$(_is_working '✽ Crafting…' && echo yes || echo no)" "yes"
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
# "navigate" alone must not trip the menu detector; only the full distinctive hint strings do
ok "menu-false-positive-word"  "$(_is_on_menu "$QUOTED_PANE" && echo yes || echo no)" "no"
ok "menu-false-positive-draft" "$(_is_on_menu "$DRAFT_PANE"  && echo yes || echo no)" "no"
ok "menu-true-positive"        "$(_is_on_menu "$MENU_PANE"   && echo yes || echo no)" "yes"

# --- _input_box_empty: direct coverage of the empty/draft split ---------------
ok "inputbox-empty-on-ready" "$(_input_box_empty "$READY_PANE" && echo yes || echo no)" "yes"
ok "inputbox-empty-on-draft" "$(_input_box_empty "$DRAFT_PANE" && echo yes || echo no)" "no"
ok "inputbox-empty-on-quoted" "$(_input_box_empty "$QUOTED_PANE" && echo yes || echo no)" "no"
ok "inputbox-empty-on-dim" "$(_input_box_empty "$DIM_PLACEHOLDER_PANE" && echo yes || echo no)" "yes"
ok "inputbox-empty-on-empty-cap" "$(_input_box_empty "$EMPTY_CAP" && echo yes || echo no)" "yes"
ok "inputbox-empty-on-whitespace-cap" "$(_input_box_empty "$WHITESPACE_CAP" && echo yes || echo no)" "yes"

# (fixtures above explain each)
ok "inputbox-not-empty-on-blank-first-line-draft" \
  "$(_input_box_empty "$BLANK_FIRST_LINE_DRAFT_PANE" && echo yes || echo no)" "no"
ok "reason-blank-first-line-draft" \
  "$(_safety_reason "$BLANK_FIRST_LINE_DRAFT_PANE")" "draft-in-input-box"
ok "safe-blank-first-line-draft" \
  "$(_is_safe_to_inject "$BLANK_FIRST_LINE_DRAFT_PANE" && echo yes || echo no)" "no"

ok "inputbox-not-empty-on-multiline-line1-draft" \
  "$(_input_box_empty "$MULTI_LINE_DRAFT_LINE1_PANE" && echo yes || echo no)" "no"
ok "reason-multiline-line1-draft" \
  "$(_safety_reason "$MULTI_LINE_DRAFT_LINE1_PANE")" "draft-in-input-box"

ok "inputbox-empty-on-multiline-whitespace-only" \
  "$(_input_box_empty "$MULTI_LINE_WHITESPACE_ONLY_PANE" && echo yes || echo no)" "yes"
ok "reason-multiline-whitespace-only" \
  "$(_safety_reason "$MULTI_LINE_WHITESPACE_ONLY_PANE")" "safe"

ok "inputbox-empty-on-dim-then-immediate-border" \
  "$(_input_box_empty "$DIM_THEN_IMMEDIATE_BORDER_PANE" && echo yes || echo no)" "yes"
ok "reason-dim-then-immediate-border" \
  "$(_safety_reason "$DIM_THEN_IMMEDIATE_BORDER_PANE")" "safe"

ok "inputbox-not-empty-on-truncated-no-border" \
  "$(_input_box_empty "$TRUNCATED_NO_BORDER_PANE" && echo yes || echo no)" "no"
ok "reason-truncated-no-border" \
  "$(_safety_reason "$TRUNCATED_NO_BORDER_PANE")" "draft-in-input-box"

# --- _is_dim_span: direct coverage of the exact-opener matching ---------------
# a 256-color code merely ending in 2 ("38;5;12m") is NOT dim
NOT_DIM_COLOR_ONLY="${ESC}[38;5;12mcheck on the blue deployment please${ESC}[0m"
ok "dimspan-true-plain"  "$(_is_dim_span "${ESC}[2mdelete the backup ref${ESC}[0m" && echo yes || echo no)" "yes"
ok "dimspan-true-cursor" "$(_is_dim_span "${ESC}[7mc${ESC}[0;2mheck it${ESC}[0m"   && echo yes || echo no)" "yes"
ok "dimspan-false-color" "$(_is_dim_span "$NOT_DIM_COLOR_ONLY" && echo yes || echo no)" "no"

# --- `ready` CLI mode: real dispatch via a fake `tmux` shim (answers has-session/capture-pane from an env var) ---
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

finish "session-handoff-ready"
