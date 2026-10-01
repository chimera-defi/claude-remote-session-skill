#!/usr/bin/env bash
# Plain-bash tests for session-handoff pure classifiers. No live tmux needed:
# the finicky "did the message land" logic is factored into pure functions that
# take a captured-pane string, so it can be tested against realistic fixtures.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
# shellcheck disable=SC1090
source "$HERE/../scripts/session-handoff.sh"   # source-guarded: must NOT run dispatch

# --- realistic claude-TUI captures (trimmed from live panes) ------------------
READY_PANE='● Ready.
────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────
  [Sonnet 5] session-launcher-0718
  ⏵⏵ bypass permissions on (shift+tab to cycle)'

BUSY_PANE='● Working on the survey…
✢ Incubating… (esc to interrupt · 2m 5s · ↓ 9.6k tokens)
────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────
  [Opus 4.8] my-project'

# message typed but Enter not yet submitted — it sits ON the input line
BUFFERED_PANE='● Ready.
────────────────────────────────────────────────────────
❯ Goal: survey the $25k tranche candidates
────────────────────────────────────────────────────────
  [Opus 4.8] my-project'

# message submitted — it now appears in the transcript ABOVE an empty input line,
# and the session is working
SUBMITTED_PANE='● Goal: survey the $25k tranche candidates
✢ Proofing… (esc to interrupt)
────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────
  [Opus 4.8] my-project'

# --- _is_working: working indicator present? ---------------------------------
ok "working-busy"      "$(yn _is_working "$BUSY_PANE")" "yes"
ok "working-submitted" "$(yn _is_working "$SUBMITTED_PANE")" "yes"
ok "working-ready"     "$(yn _is_working "$READY_PANE")" "no"

# --- _frag: distinctive single-line fragment of a (possibly multiline) msg ----
ok "frag-firstline" "$(_frag "Goal: survey the \$25k tranche candidates
1. verify the lineage list is current")" "Goal: survey the \$25k tranche candidates"
# A whitespace-only message must yield an empty frag — the `send` dispatch
# guards on this (empty frag would otherwise make grep -qF "" match every
# line unconditionally, so _on_input_line/_verdict could never report
# anything but "buffered").
ok "frag-whitespace-only-empty" "$(_frag "
	")" ""

# --- _on_input_line: is the fragment still buffered at the ❯ prompt? ----------
FRAG="Goal: survey the \$25k tranche candidates"
ok "oninput-buffered"  "$(yn _on_input_line "$FRAG" "$BUFFERED_PANE")" "yes"
ok "oninput-submitted" "$(yn _on_input_line "$FRAG" "$SUBMITTED_PANE")" "no"
ok "oninput-ready"     "$(yn _on_input_line "$FRAG" "$READY_PANE")" "no"

# --- _in_transcript: did the fragment reach the conversation (above input)? ---
ok "transcript-submitted" "$(yn _in_transcript "$FRAG" "$SUBMITTED_PANE")" "yes"
ok "transcript-buffered"  "$(yn _in_transcript "$FRAG" "$BUFFERED_PANE")" "no"

# --- _verdict: combine the signals into landed / buffered / unverified --------
# submitted transcript + working  -> landed
ok "verdict-landed"   "$(_verdict "$FRAG" "$SUBMITTED_PANE")" "landed"
# still on the input line          -> buffered (needs another Enter)
ok "verdict-buffered" "$(_verdict "$FRAG" "$BUFFERED_PANE")" "buffered"
# gone from input, no transcript echo, not working -> unverified
ok "verdict-unverified" "$(_verdict "$FRAG" "$READY_PANE")" "unverified"

finish "session-handoff"
