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
ok "working-retry-line" "$(yn _is_working "$RETRY_PANE")" "yes"
# Collapsed paste: spinner glyph + word… with no "esc to interrupt" yet.
ok "working-glyph-only" "$(yn _is_working '✽ Crafting…')" "yes"
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
ok "safe-ready"     "$(yn _is_safe_to_inject "$READY_PANE")" "yes"
ok "safe-busy"      "$(yn _is_safe_to_inject "$BUSY_PANE")" "no"
ok "safe-draft"     "$(yn _is_safe_to_inject "$DRAFT_PANE")" "no"
ok "safe-menu"      "$(yn _is_safe_to_inject "$MENU_PANE")" "no"
ok "safe-no-prompt" "$(yn _is_safe_to_inject "$STARTING_PANE")" "no"
ok "safe-quoted"    "$(yn _is_safe_to_inject "$QUOTED_PANE")" "no"
ok "safe-empty"     "$(yn _is_safe_to_inject "$EMPTY_CAP")" "no"
ok "safe-whitespace" "$(yn _is_safe_to_inject "$WHITESPACE_CAP")" "no"
ok "safe-dim-placeholder"      "$(yn _is_safe_to_inject "$DIM_PLACEHOLDER_PANE")" "yes"
ok "safe-dim-cursor-split"     "$(yn _is_safe_to_inject "$DIM_PLACEHOLDER_CURSOR_SPLIT_PANE")" "yes"
ok "safe-non-dim-styled-draft" "$(yn _is_safe_to_inject "$NON_DIM_STYLED_DRAFT_PANE")" "no"
ok "safe-dim-plus-menu"        "$(yn _is_safe_to_inject "$DIM_PLACEHOLDER_PLUS_MENU_PANE")" "no"
ok "safe-fake-escape-text"     "$(yn _is_safe_to_inject "$FAKE_ESCAPE_TEXT_DRAFT_PANE")" "no"

# --- _is_on_menu: false-positive proofing ---------------------------------------
# "navigate" alone must not trip the menu detector; only the full distinctive hint strings do
ok "menu-false-positive-word"  "$(yn _is_on_menu "$QUOTED_PANE")" "no"
ok "menu-false-positive-draft" "$(yn _is_on_menu "$DRAFT_PANE")" "no"
ok "menu-true-positive"        "$(yn _is_on_menu "$MENU_PANE")" "yes"

# --- _input_box_empty: direct coverage of the empty/draft split ---------------
ok "inputbox-empty-on-ready" "$(yn _input_box_empty "$READY_PANE")" "yes"
ok "inputbox-empty-on-draft" "$(yn _input_box_empty "$DRAFT_PANE")" "no"
ok "inputbox-empty-on-quoted" "$(yn _input_box_empty "$QUOTED_PANE")" "no"
ok "inputbox-empty-on-dim" "$(yn _input_box_empty "$DIM_PLACEHOLDER_PANE")" "yes"
ok "inputbox-empty-on-empty-cap" "$(yn _input_box_empty "$EMPTY_CAP")" "yes"
ok "inputbox-empty-on-whitespace-cap" "$(yn _input_box_empty "$WHITESPACE_CAP")" "yes"

# (fixtures above explain each)
ok "inputbox-not-empty-on-blank-first-line-draft" \
  "$(yn _input_box_empty "$BLANK_FIRST_LINE_DRAFT_PANE")" "no"
ok "reason-blank-first-line-draft" \
  "$(_safety_reason "$BLANK_FIRST_LINE_DRAFT_PANE")" "draft-in-input-box"
ok "safe-blank-first-line-draft" \
  "$(yn _is_safe_to_inject "$BLANK_FIRST_LINE_DRAFT_PANE")" "no"

ok "inputbox-not-empty-on-multiline-line1-draft" \
  "$(yn _input_box_empty "$MULTI_LINE_DRAFT_LINE1_PANE")" "no"
ok "reason-multiline-line1-draft" \
  "$(_safety_reason "$MULTI_LINE_DRAFT_LINE1_PANE")" "draft-in-input-box"

ok "inputbox-empty-on-multiline-whitespace-only" \
  "$(yn _input_box_empty "$MULTI_LINE_WHITESPACE_ONLY_PANE")" "yes"
ok "reason-multiline-whitespace-only" \
  "$(_safety_reason "$MULTI_LINE_WHITESPACE_ONLY_PANE")" "safe"

ok "inputbox-empty-on-dim-then-immediate-border" \
  "$(yn _input_box_empty "$DIM_THEN_IMMEDIATE_BORDER_PANE")" "yes"
ok "reason-dim-then-immediate-border" \
  "$(_safety_reason "$DIM_THEN_IMMEDIATE_BORDER_PANE")" "safe"

ok "inputbox-not-empty-on-truncated-no-border" \
  "$(yn _input_box_empty "$TRUNCATED_NO_BORDER_PANE")" "no"
ok "reason-truncated-no-border" \
  "$(_safety_reason "$TRUNCATED_NO_BORDER_PANE")" "draft-in-input-box"

# --- _is_dim_span: direct coverage of the exact-opener matching ---------------
# a 256-color code merely ending in 2 ("38;5;12m") is NOT dim
NOT_DIM_COLOR_ONLY="${ESC}[38;5;12mcheck on the blue deployment please${ESC}[0m"
ok "dimspan-true-plain"  "$(yn _is_dim_span "${ESC}[2mdelete the backup ref${ESC}[0m")" "yes"
ok "dimspan-true-cursor" "$(yn _is_dim_span "${ESC}[7mc${ESC}[0;2mheck it${ESC}[0m")" "yes"
ok "dimspan-false-color" "$(yn _is_dim_span "$NOT_DIM_COLOR_ONLY")" "no"

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

# --- pipefail + grep -q: detection must not depend on how big the capture is ---
# `producer | grep -q` under pipefail fails when grep exits on the first match and the producer's
# next chunk hits a closed pipe (only for output over ~4 KiB). A 64 KiB capture with the marker
# on its FIRST line is the worst case; every call must still detect.
BIGPAD="$(head -c 65536 /dev/zero | tr '\0' 'x' | fold -w 80)"
BIG_TRANSCRIPT="$(printf 'MARKER-LINE-ONE\n%s\n❯\n' "$BIGPAD")"
BIG_BUSY="$(printf '✢ Incubating… (esc to interrupt)\n%s\n❯\n' "$BIGPAD")"
BIG_BYTES=${#BIG_TRANSCRIPT}
ok "big-capture-is-over-64KiB" "$([ "$BIG_BYTES" -ge 65536 ] && echo yes || echo no)" yes
# marker on the FIRST line of the producer's output (the prompt line), before the padding: grep -q
# exits at once and a piped producer would take SIGPIPE. Marker-last would pass the old code too.
BIG_INPUT="$(printf '❯ MARKER-LINE-ONE\n%s\n' "$BIGPAD")"
BIG_COLLAPSED="$(printf '❯ [Pasted text #1 +17 lines]\n%s\n' "$BIGPAD")"
miss_t=0; miss_w=0; miss_i=0; miss_c=0
for _ in $(seq 1 200); do
  _in_transcript "MARKER-LINE-ONE" "$BIG_TRANSCRIPT" || miss_t=$((miss_t+1))
  _is_working "$BIG_BUSY" || miss_w=$((miss_w+1))
  _on_input_line "MARKER-LINE-ONE" "$BIG_INPUT" || miss_i=$((miss_i+1))
  _is_collapsed_paste_in_input "$BIG_COLLAPSED" || miss_c=$((miss_c+1))
done
ok "big-capture-_in_transcript-200-of-200" "$miss_t" 0
ok "big-capture-_is_working-200-of-200" "$miss_w" 0
ok "big-capture-_on_input_line-200-of-200" "$miss_i" 0
ok "big-capture-_is_collapsed_paste_in_input-200-of-200" "$miss_c" 0

finish "session-handoff-ready"
