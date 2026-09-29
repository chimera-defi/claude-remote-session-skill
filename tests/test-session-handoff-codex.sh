#!/usr/bin/env bash
# Codex TUI pane classifier fixtures derived from live Codex CLI 0.158.0
# captures. Keep these host-path-free; test-no-host-leaks scans tracked files.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1090
source "$HERE/../scripts/session-handoff.sh"

pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }

CODEX_READY='  >_ OpenAI Codex (v0.158.0)
     /tmp/example-codex-workdir

  There is a perfectly good prompt with your name on it.

›

  GPT-5.5 medium · /tmp/example-codex-workdir
  ← for agents · ? for shortcuts'

CODEX_BUSY='  >_ OpenAI Codex (v0.158.0)
     /tmp/example-codex-workdir

› Reply with exactly: PROBE-ONE.

• Working (0s • esc to interrupt)

›

  GPT-5.5 medium · /tmp/example-codex-workdir'

CODEX_TRUST_MENU='  Folder access
  /tmp/example-codex-workdir

  Trust this folder? Codex can read, edit, and run files here, subject to your permission settings.

› 1. Trust and continue
  2. Back to Agent Command Center

  enter continue · esc back'

CODEX_MODEL_MENU='  GPT-5.5 retires on October 14, 2026. Switch to GPT-5.6 Sol to continue working in Codex.

› 1. Try new model
  2. Use existing model

  enter/esc confirm · ctrl+c quit'

CODEX_APPROVAL_MENU='  Would you like to run the following command?

  Environment: local

  Reason: Do you want to allow writing approval-probe.txt in the current workspace?

  $ printf APPROVAL-PROBE > approval-probe.txt

› 1. Yes, proceed (y)
  2. No, and tell Codex what to do differently (esc)

  Press enter to confirm or esc to cancel'

CODEX_BUFFERED='  >_ OpenAI Codex (v0.158.0)

› Reply with exactly: MULTILINE-OK
  Line two should not submit separately.
  Line three confirms bracketed paste behavior.

  GPT-5.5 medium · /tmp/example-codex-workdir'

CODEX_SUBMITTED='  >_ OpenAI Codex (v0.158.0)

› Reply with exactly: MULTILINE-OK
  Line two should not submit separately.
  Line three confirms bracketed paste behavior.

• MULTILINE-OK

  9:23 PM

›

  GPT-5.5 medium · /tmp/example-codex-workdir'

CODEX_REPLY_WORKING_READY='  >_ OpenAI Codex (v0.158.0)
     /tmp/example-codex-workdir

› Explain status text.

• Working through the checklist is complete.

›

  GPT-5.5 medium · /tmp/example-codex-workdir'

CODEX_REPLY_APPROVAL_WORD_READY='  >_ OpenAI Codex (v0.158.0)
     /tmp/example-codex-workdir

› What did the user choose?

• The reply included the words "Yes, proceed", but no approval widget is open.

›

  GPT-5.5 medium · /tmp/example-codex-workdir'

ok "codex-working-busy" "$(_is_working "$CODEX_BUSY" && echo yes || echo no)" "yes"
ok "codex-working-ready" "$(_is_working "$CODEX_READY" && echo yes || echo no)" "no"
ok "codex-working-reply-ready" "$(_is_working "$CODEX_REPLY_WORKING_READY" && echo yes || echo no)" "no"

ok "codex-trust-menu" "$(_is_on_menu "$CODEX_TRUST_MENU" && echo yes || echo no)" "yes"
ok "codex-model-menu" "$(_is_on_menu "$CODEX_MODEL_MENU" && echo yes || echo no)" "yes"
ok "codex-approval-menu" "$(_is_on_menu "$CODEX_APPROVAL_MENU" && echo yes || echo no)" "yes"
ok "codex-ready-not-menu" "$(_is_on_menu "$CODEX_READY" && echo yes || echo no)" "no"
ok "codex-approval-word-reply-not-menu" "$(_is_on_menu "$CODEX_REPLY_APPROVAL_WORD_READY" && echo yes || echo no)" "no"

ok "codex-has-prompt-ready" "$(_has_prompt "$CODEX_READY" && echo yes || echo no)" "yes"
ok "codex-working-reply-safe" "$(_safety_reason "$CODEX_REPLY_WORKING_READY")" "safe"
ok "codex-approval-word-reply-safe" "$(_safety_reason "$CODEX_REPLY_APPROVAL_WORD_READY")" "safe"

FRAG="Reply with exactly: MULTILINE-OK"
ok "codex-oninput-buffered" "$(_on_input_line "$FRAG" "$CODEX_BUFFERED" && echo yes || echo no)" "yes"
ok "codex-oninput-submitted" "$(_on_input_line "$FRAG" "$CODEX_SUBMITTED" && echo yes || echo no)" "no"
ok "codex-transcript-submitted" "$(_in_transcript "$FRAG" "$CODEX_SUBMITTED" && echo yes || echo no)" "yes"
ok "codex-verdict-buffered" "$(_verdict "$FRAG" "$CODEX_BUFFERED")" "buffered"
ok "codex-verdict-landed" "$(_verdict "$FRAG" "$CODEX_SUBMITTED")" "landed"

echo "session-handoff-codex: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
