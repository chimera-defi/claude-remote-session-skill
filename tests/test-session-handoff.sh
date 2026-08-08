#!/usr/bin/env bash
# Plain-bash tests for session-handoff pure classifiers. No live tmux needed:
# the finicky "did the message land" logic is factored into pure functions that
# take a captured-pane string, so it can be tested against realistic fixtures.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1090
source "$HERE/../scripts/session-handoff.sh"   # source-guarded: must NOT run dispatch
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }

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
  [Opus 4.8] portfolio-ssot'

# message typed but Enter not yet submitted — it sits ON the input line
BUFFERED_PANE='● Ready.
────────────────────────────────────────────────────────
❯ Goal: survey the $25k tranche candidates
────────────────────────────────────────────────────────
  [Opus 4.8] portfolio-ssot'

# message submitted — it now appears in the transcript ABOVE an empty input line,
# and the session is working
SUBMITTED_PANE='● Goal: survey the $25k tranche candidates
✢ Proofing… (esc to interrupt)
────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────
  [Opus 4.8] portfolio-ssot'

# --- _is_working: working indicator present? ---------------------------------
ok "working-busy"      "$(_is_working "$BUSY_PANE"      && echo yes || echo no)" "yes"
ok "working-submitted" "$(_is_working "$SUBMITTED_PANE" && echo yes || echo no)" "yes"
ok "working-ready"     "$(_is_working "$READY_PANE"     && echo yes || echo no)" "no"

# --- _frag: distinctive single-line fragment of a (possibly multiline) msg ----
ok "frag-firstline" "$(_frag "Goal: survey the \$25k tranche candidates
1. verify the lineage list is current")" "Goal: survey the \$25k tranche candidates"

# --- _on_input_line: is the fragment still buffered at the ❯ prompt? ----------
FRAG="Goal: survey the \$25k tranche candidates"
ok "oninput-buffered"  "$(_on_input_line "$FRAG" "$BUFFERED_PANE"  && echo yes || echo no)" "yes"
ok "oninput-submitted" "$(_on_input_line "$FRAG" "$SUBMITTED_PANE" && echo yes || echo no)" "no"
ok "oninput-ready"     "$(_on_input_line "$FRAG" "$READY_PANE"     && echo yes || echo no)" "no"

# --- _in_transcript: did the fragment reach the conversation (above input)? ---
ok "transcript-submitted" "$(_in_transcript "$FRAG" "$SUBMITTED_PANE" && echo yes || echo no)" "yes"
ok "transcript-buffered"  "$(_in_transcript "$FRAG" "$BUFFERED_PANE"  && echo yes || echo no)" "no"

# --- _verdict: combine the signals into landed / buffered / unverified --------
# submitted transcript + working  -> landed
ok "verdict-landed"   "$(_verdict "$FRAG" "$SUBMITTED_PANE")" "landed"
# still on the input line          -> buffered (needs another Enter)
ok "verdict-buffered" "$(_verdict "$FRAG" "$BUFFERED_PANE")" "buffered"
# gone from input, no transcript echo, not working -> unverified
ok "verdict-unverified" "$(_verdict "$FRAG" "$READY_PANE")" "unverified"

echo "session-handoff: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
