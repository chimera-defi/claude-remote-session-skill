#!/usr/bin/env bash
# Codex TUI pane classifier fixtures derived from live Codex CLI 0.158.0
# captures. Keep these host-path-free; test-no-host-leaks scans tracked files.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
# Keep the `px_*` metadata fixtures below independent of the operator's overlay
# and CI's generic defaults.
isolate_overlay
export CRSS_SESSION_PREFIX=px
export CRSS_LEGACY_PREFIXES=oldhost
# shellcheck disable=SC1090
source "$HERE/../scripts/session-handoff.sh"


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

CODEX_RATE_LIMIT_MENU='› Reply with exactly: CODEX-FIX-OK

• CODEX-FIX-OK

  Worked for 2s • 9:27 PM

  Approaching rate limits
  Switch to gpt-6-luna for lower credit usage?

› 1. Switch to gpt-6-luna                   Fast and affordable model for easier tasks.
  2. Keep current model
  3. Keep current model (never show again)  Hide future rate limit reminders about switching models

  enter select · esc back'

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

ok "codex-working-busy" "$(yn _is_working "$CODEX_BUSY")" "yes"
ok "codex-working-ready" "$(yn _is_working "$CODEX_READY")" "no"
ok "codex-working-reply-ready" "$(yn _is_working "$CODEX_REPLY_WORKING_READY")" "no"

ok "codex-trust-menu" "$(yn _is_on_menu "$CODEX_TRUST_MENU")" "yes"
ok "codex-model-menu" "$(yn _is_on_menu "$CODEX_MODEL_MENU")" "yes"
ok "codex-approval-menu" "$(yn _is_on_menu "$CODEX_APPROVAL_MENU")" "yes"
ok "codex-rate-limit-menu" "$(yn _is_on_menu "$CODEX_RATE_LIMIT_MENU")" "yes"
ok "codex-ready-not-menu" "$(yn _is_on_menu "$CODEX_READY")" "no"
ok "codex-approval-word-reply-not-menu" "$(yn _is_on_menu "$CODEX_REPLY_APPROVAL_WORD_READY")" "no"

ok "codex-has-prompt-ready" "$(yn _has_prompt "$CODEX_READY")" "yes"
ok "codex-working-reply-safe" "$(_safety_reason "$CODEX_REPLY_WORKING_READY")" "safe"
ok "codex-approval-word-reply-safe" "$(_safety_reason "$CODEX_REPLY_APPROVAL_WORD_READY")" "safe"

FRAG="Reply with exactly: MULTILINE-OK"
ok "codex-oninput-buffered" "$(yn _on_input_line "$FRAG" "$CODEX_BUFFERED")" "yes"
ok "codex-oninput-submitted" "$(yn _on_input_line "$FRAG" "$CODEX_SUBMITTED")" "no"
ok "codex-transcript-submitted" "$(yn _in_transcript "$FRAG" "$CODEX_SUBMITTED")" "yes"
ok "codex-verdict-buffered" "$(_verdict "$FRAG" "$CODEX_BUFFERED")" "buffered"
ok "codex-verdict-landed" "$(_verdict "$FRAG" "$CODEX_SUBMITTED")" "landed"

META_HOME="$(mktemp -d)"
trap 'rm -rf "$META_HOME"' EXIT
mkdir -p "$META_HOME/.local/bin"
cat > "$META_HOME/.local/bin/px-oldmeta-0101-0000-start.sh" <<'EOF'
#!/usr/bin/env bash
BACKEND="codex"
MODEL="gpt-5.5"
EOF
cat > "$META_HOME/.local/bin/px-newmeta-0101-0001-start.sh" <<'EOF'
#!/usr/bin/env bash
BACKEND=codex
MODEL=gpt-5.5
EOF
cat > "$META_HOME/.local/bin/px-quotedmeta-0101-0002-start.sh" <<'EOF'
#!/usr/bin/env bash
BACKEND=codex
MODEL=gpt\ 5.5
EOF
ok "start-meta-old-backend" "$(HOME="$META_HOME" _backend_of px_oldmeta-0101-0000)" "codex"
ok "start-meta-old-model" "$(HOME="$META_HOME" _model_of px_oldmeta-0101-0000)" "gpt-5.5"
ok "start-meta-new-backend" "$(HOME="$META_HOME" _backend_of px_newmeta-0101-0001)" "codex"
ok "start-meta-new-model" "$(HOME="$META_HOME" _model_of px_newmeta-0101-0001)" "gpt-5.5"
ok "start-meta-percentq-model" "$(HOME="$META_HOME" _model_of px_quotedmeta-0101-0002)" "gpt 5.5"

finish "session-handoff-codex"
