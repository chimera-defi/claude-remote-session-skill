#!/usr/bin/env bash
# session-handoff.sh — mechanics for handing a task to a live Claude session.
# The JUDGMENT (which session, how to phrase the task) stays with the caller /
# the `/handoff` skill; this codifies the deterministic parts:
#
#   session-handoff targets                     # live sessions + health + model
#   session-handoff check <tmux-session>        # one session's health (exit 0 = ready)
#   session-handoff send  <tmux-session> <msg>  # relay a message + verify it landed
#   session-handoff send  <tmux-session> --file <path>
#
# `send` pastes the message (bracketed paste, so a multi-line prompt does not
# submit line-by-line), presses Enter, and VERIFIES the session actually started
# working — retrying Enter if the input stayed buffered — instead of trusting
# that the keys were sent. It prints one of: landed | unverified.
set -uo pipefail

# ── pure classifiers (source-guarded below so tests can exercise them) ────────

# _is_working — does the captured pane show Claude actively generating? "esc to
# interrupt" is present throughout generation and is the robust anchor. The
# spinner words vary wildly across releases (Crafting/Herding/Simmering/…), so
# rather than enumerate them, also match the generic shape: a spinner GLYPH
# followed by a word ending in the "…" ellipsis (e.g. "✽ Crafting…"). This
# matters for a collapsed multi-line paste that doesn't echo into the transcript.
_is_working() {
  printf '%s' "$1" | grep -qE 'esc to interrupt|[✻✽✶✳✢✷✦✧⋆∗·][[:space:]]*[[:alpha:]][[:alpha:]]*…'
}

# _frag — a distinctive single-line fragment of a (possibly multi-line) message,
# used to locate the message in a capture. First non-blank line, capped.
_frag() { printf '%s' "$1" | sed -n '/[^[:space:]]/{p;q}' | cut -c1-48; }

# _input_region / _transcript_region — split a capture at the LAST prompt line
# (the `❯` input box). Content on/after it is the pending input; content before
# it is the conversation transcript.
_input_region()      { printf '%s\n' "$2" | awk '/❯/{last=NR} {a[NR]=$0} END{for(i=(last?last:NR+1);i<=NR;i++)print a[i]}'; }
_transcript_region() { printf '%s\n' "$2" | awk '/❯/{last=NR} {a[NR]=$0} END{for(i=1;i<(last?last:1);i++)print a[i]}'; }

# _on_input_line — is the fragment still sitting in the input box (typed but not
# submitted)? Then another Enter is needed.
_on_input_line() { _input_region "$1" "$2" | grep -qF "$1"; }
# _in_transcript — did the fragment reach the conversation (submitted + echoed)?
_in_transcript() { _transcript_region "$1" "$2" | grep -qF "$1"; }

# _verdict — combine the signals for one capture.
#   buffered   : still on the input line -> press Enter again
#   landed     : echoed into the transcript OR the session is now working
#   unverified : sent, but no confirmation (report honestly; caller re-checks)
_verdict() {
  local frag="$1" cap="$2"
  if _on_input_line "$frag" "$cap"; then echo buffered; return; fi
  if _in_transcript "$frag" "$cap" || _is_working "$cap"; then echo landed; return; fi
  echo unverified
}

# ── live helpers ──────────────────────────────────────────────────────────────

# tmux session name -> remote-control name (ah_/agenthost_ are ours).
_remote_of() { case "$1" in ah_*) echo "ah-${1#ah_}";; agenthost_*) echo "agenthost-${1#agenthost_}";; *) echo "";; esac; }

_pane_cmd() { tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null; }
_capture()  { tmux capture-pane -p -t "$1" 2>/dev/null; }

# _model_of — best-effort resolved model for a session (from its start script,
# else the most recent session-starts.log line).
_model_of() {
  local rem sc; rem="$(_remote_of "$1")"; [ -n "$rem" ] || { echo "?"; return; }
  sc="$HOME/.local/bin/${rem}-start.sh"
  if [ -f "$sc" ]; then sed -n 's/^MODEL="\(.*\)"$/\1/p' "$sc" | head -1; return; fi
  grep -F "remote=$rem " "$HOME/.sessions/session-starts.log" 2>/dev/null | sed -n 's/.* model=\([^ ]*\) .*/\1/p' | tail -1
}

# _state_of — dead | starting | busy | ready, from pane command + capture.
_state_of() {
  local s="$1" cmd; cmd="$(_pane_cmd "$s")"
  case "$cmd" in
    ""|-) echo dead; return;;
    claude|node) : ;;
    sleep) echo busy; return;;                 # supervisor backoff between restarts
    bash|zsh|sh) echo starting; return;;       # supervisor loop not yet in claude
    *) echo dead; return;;
  esac
  _is_working "$(_capture "$s")" && echo busy || echo ready
}

_live_ours() { tmux ls 2>/dev/null | cut -d: -f1 | grep -E '^(ah_|agenthost_)'; }

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
MODE="${1:-}"; shift || true
case "$MODE" in
  targets)
    printf '%-46s %-9s %s\n' "SESSION" "STATE" "MODEL"
    for s in $(_live_ours); do
      printf '%-46s %-9s %s\n' "$s" "$(_state_of "$s")" "$(_model_of "$s")"
    done
    ;;

  check)
    S="${1:?usage: session-handoff check <tmux-session>}"
    if ! tmux has-session -t "$S" 2>/dev/null; then echo "check: '$S' — no such tmux session"; exit 2; fi
    st="$(_state_of "$S")"; rem="$(_remote_of "$S")"
    active=no; [ -n "$rem" ] && systemctl --user is-active --quiet "${rem}.service" 2>/dev/null && active=yes
    echo "check: $S  state=$st  unit-active=$active  model=$(_model_of "$S")"
    [ "$st" = ready ] && exit 0 || exit 1
    ;;

  send)
    S="${1:?usage: session-handoff send <tmux-session> (<msg> | --file <path>)}"; shift
    if [ "${1:-}" = "--file" ]; then MSG="$(cat "${2:?--file needs a path}")"; else MSG="${1:?message required}"; fi
    tmux has-session -t "$S" 2>/dev/null || { echo "send: '$S' — no such tmux session" >&2; exit 2; }
    st="$(_state_of "$S")"
    case "$st" in
      dead)     echo "send: '$S' is $st (supervisor loop not in claude) — refusing to send" >&2; exit 2;;
      starting) echo "send: '$S' is still starting — refusing to send (retry after it reaches the prompt)" >&2; exit 2;;
      busy)     echo "send: note — '$S' is busy (working); message will queue behind current work" >&2;;
    esac
    frag="$(_frag "$MSG")"
    # A whitespace-only MSG yields an empty frag, and grep -qF "" matches every
    # line unconditionally — _on_input_line would then always report "still
    # buffered" regardless of what's on screen, so _verdict could never reach
    # "landed" even though Enter worked fine. Refuse rather than loop to a
    # false "unverified".
    [ -n "$frag" ] || { echo "send: message is empty or whitespace-only — refusing to send" >&2; exit 2; }
    # Bracketed paste so a multi-line prompt lands as one input, not N submits.
    printf '%s' "$MSG" | tmux load-buffer -b handoff -
    tmux paste-buffer -t "$S" -b handoff -p -d
    verdict=unverified
    for _try in 1 2 3; do
      tmux send-keys -t "$S" Enter
      for _j in 1 2 3 4 5 6; do
        verdict="$(_verdict "$frag" "$(_capture "$S")")"
        [ "$verdict" = landed ] && break
        sleep 0.5
      done
      [ "$verdict" = landed ] && break
      [ "$verdict" = buffered ] || break     # unverified: one Enter should have done it; stop resending
    done
    if [ "$verdict" = landed ]; then
      echo "send: landed on $S"
      exit 0
    else
      echo "send: UNVERIFIED on $S — keys were sent but I could not confirm the session started working; check it before reporting success" >&2
      exit 1
    fi
    ;;

  *) echo "usage: session-handoff (targets | check <s> | send <s> <msg>|--file <p>)"; exit 2;;
esac
fi
