#!/usr/bin/env bash
# session-handoff.sh — mechanics for handing a task to a live Claude session.
# The JUDGMENT (which session, how to phrase the task) stays with the caller /
# the `/handoff` skill; this codifies the deterministic parts:
#
#   session-handoff targets                     # live sessions + health + model
#   session-handoff check <tmux-session>        # one session's health (exit 0 = ready)
#   session-handoff ready <tmux-session>        # positive injection-safety check (exit 0 = safe)
#   session-handoff send  <tmux-session> <msg>  # relay a message + verify it landed
#   session-handoff send  <tmux-session> --file <path>
#
# `send` pastes the message (bracketed paste, so a multi-line prompt does not
# submit line-by-line), presses Enter, and VERIFIES the session actually started
# working — retrying Enter if the input stayed buffered — instead of trusting
# that the keys were sent. It prints one of: landed | unverified.
#
# `ready` is a separate, POSITIVE predicate: not-busy is not the same as
# safe-to-inject. If a human (or another agent) left an unsubmitted draft
# sitting in the pane's input box, the pane shows no spinner — but pasting
# into it would concatenate onto their draft and Enter would submit the
# corrupted merge. `ready` also refuses when the pane is on an interactive
# menu widget (arrow-key only; plain text sent into it is silently dropped —
# see SKILL.md "Detecting a stuck-on-a-menu session") or has no visible
# prompt at all. `send` does not consult `ready` yet — see the predicate's
# comment for adoption notes.
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

# _is_on_menu — is the pane sitting on an interactive AskUserQuestion-style
# widget (numbered options + checkboxes, arrow-key navigation)? Free text sent
# into it is not a valid input and is silently dropped — see SKILL.md
# "Detecting a stuck-on-a-menu session". Prefer the distinctive hint strings
# over trying to parse the numbered option list / checkbox glyphs, which are
# too generic to grep for reliably on their own.
_is_on_menu() {
  printf '%s' "$1" | grep -qE '↑/↓ to navigate|Enter to select|Esc to cancel|☐ Next direction|✔ Submit'
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

# _has_prompt — is there a real ❯ input line visible anywhere in the capture?
# Absent during startup (still in the supervisor loop / model not yet in a TUI
# frame) or if the capture is empty/garbled.
_has_prompt() { printf '%s' "$1" | grep -qF '❯'; }

# _strip_ansi — drop ANSI CSI sequences (ESC '[' params letter), e.g. color /
# bold / dim SGR codes from `tmux capture-pane -e`. Used to make the busy /
# menu / prompt checks immune to styling, since those grep for literal
# substrings that must survive regardless of which colors wrap them.
_strip_ansi() {
  local esc; esc=$'\x1b'
  printf '%s' "$1" | sed -E "s/${esc}\\[[0-9;]*[A-Za-z]//g"
}

# _is_dim_span — is $1 (raw, ANSI-preserving) ENTIRELY a "dim" (SGR 2) styled
# run, optionally reset with ESC[0m at the end? This is how Claude Code's TUI
# renders its auto-suggested "next action" ghost text in an otherwise-empty
# input box — it is NOT a user draft (confirmed empirically 2026-09-11:
# `tmux capture-pane -p -e` on live sessions shows `ESC[2m<suggestion>ESC[0m`
# after the ❯ marker on idle panes, vs. no such wrapping when real text is
# there). The terminal's cursor cell can split the run — if the cursor sits on
# the first character of the ghost text, that one glyph renders reverse-video
# (`ESC[7m`) and the rest resumes dim (`ESC[0;2m…`) — so both the plain-dim and
# cursor-split shapes are matched. A real user draft is rendered without the
# dim attribute, so it will not match this and correctly falls through to
# "not a dim span" -> treated as a genuine draft.
#
# The opener is matched EXACTLY as `2m` or `0;2m` (not `[0-9;]*2m`) on
# purpose: a wildcard there would also match 256-color codes that merely
# happen to end in digit 2 (e.g. `38;5;12m`, `38;5;22m` — ordinary colors, not
# the dim attribute), which would misclassify real colored draft text as safe.
#
# The load-bearing assumption here — that a genuine user-typed draft renders
# WITHOUT the dim attribute — was VERIFIED empirically on 2026-09-11 against a
# disposable session (`ah-draft-probe-0911-0630`, CC v2.1.206), not assumed.
# A real unsubmitted draft captures as `ESC[39m❯ <NBSP>this is a real
# unsubmitted draft` — no `ESC[2m` anywhere — while that same pane's organic
# ghost text captures as `ESC[39m❯ <NBSP>ESC[2mmark the rest complete tooESC[0m`.
# All six probed cases classified correctly, including the adversarial ones:
#   - single-char draft (`x`)                     -> draft  (short drafts not missed)
#   - draft containing the literal text `[2m`     -> draft  (matches the real ESC
#                                                    byte, not the substring)
#   - draft typed over existing ghost text        -> draft  (typing REPLACES the
#                                                    placeholder; they never coexist)
#   - box cleared with C-u, ghost text resurfaces -> safe
# Re-verify if Claude Code's TUI changes how it styles placeholder text; that is
# the one upstream change that would silently invert this predicate.
_is_dim_span() {
  local s="$1" esc nbsp; esc=$'\x1b'; nbsp=$'\xc2\xa0'
  printf '%s' "$s" | grep -Eq \
    "^[[:space:]${nbsp}]*((${esc}\\[0;2m)|(${esc}\\[2m)|(${esc}\\[7m.${esc}\\[0;2m))[^${esc}]*${esc}\\[0m[[:space:]${nbsp}]*\$"
}

# _input_box_empty — reuses _input_region, whose output always starts AT the
# pane's last ❯ line. Take just that line and check whether anything other
# than the ❯ glyph and surrounding whitespace remains — and if there IS
# visible text, whether it's entirely a dim ghost suggestion (_is_dim_span)
# rather than a real unsubmitted draft. Accepts either a plain capture (no
# escapes — dim detection is then simply unavailable, so any leftover text
# reads as a draft) or an ANSI-preserving one (`capture-pane -e`), which is
# what `ready` passes so dim ghost text can be told apart from a real draft.
# (Caller must confirm _has_prompt first; with no ❯ at all this reports
# "empty" vacuously, which is the wrong signal to act on — that case should be
# diagnosed as no-prompt instead.)
#
# tmux pads the cell right after the `❯` glyph with U+00A0 (NO-BREAK SPACE,
# not a plain 0x20 space) rather than an ordinary space — confirmed against
# live captures. POSIX `[[:space:]]` does NOT match NBSP (by design, in any
# locale), so the trim below strips it explicitly alongside real whitespace;
# without this, every pane — including genuinely empty ones — reads as
# "1 leftover byte" and gets misclassified as a draft.
_input_box_empty() {
  local cap="$1" region stripped nbound box rest visible nbsp
  nbsp=$'\xc2\xa0'
  region="$(_input_region "" "$cap")"
  stripped="$(_strip_ansi "$region")"
  # The input BOX is bounded above by the ❯ line and below by the next
  # border/separator line (a row that is ENTIRELY '─' once ANSI styling is
  # stripped) — NOT "everything to end of buffer", which is _input_region's
  # broader definition (it also sweeps in the border line itself plus the
  # status line(s) below the box, e.g. "[Sonnet 5] session-name"; treating
  # those as draft content would make every pane look non-empty and break
  # the SAFE case entirely). Find that boundary first.
  #
  # This is a plain bash loop with LITERAL (non-regex) substring stripping,
  # not an awk/grep `/^─+$/`-style quantified regex: '─' is a multi-byte
  # UTF-8 character, and a quantified regex over it only matches when the
  # tool is both running in a UTF-8 locale AND is itself multibyte-aware
  # (GNU grep/gawk are, but only under a UTF-8 locale; mawk — Debian/
  # Ubuntu's default `awk` — never is, in any locale). Under mawk, or any
  # awk/grep in a non-UTF-8 locale (e.g. LC_ALL=C/POSIX, common in minimal
  # containers and CI), that regex silently never matches the border line,
  # nbound falls through to "whole buffer", and the status/permission-mode
  # lines below the box get read as draft text — every idle pane then
  # misclassifies as draft-in-input-box, and `ready` never reports safe.
  # Literal substring removal (bash `${var//X/}`) is a byte-for-byte search
  # with no quantifier or char-class involved, so it is correct regardless
  # of locale or awk/grep build. Confirmed reproducing against mawk in a
  # POSIX/C locale, which is what surfaced this.
  local nbound_n=0 nbound_ln
  nbound=0
  while IFS= read -r nbound_ln; do
    nbound_n=$((nbound_n + 1))
    [ "$nbound_n" -eq 1 ] && continue
    if [ -n "$nbound_ln" ] && [ -z "${nbound_ln//─/}" ]; then
      nbound=$((nbound_n - 1))
      break
    fi
  done <<<"$stripped"
  [ "$nbound" -gt 0 ] || nbound="$nbound_n"
  [ -n "$nbound" ] && [ "$nbound" -gt 0 ] || nbound=1
  box="$(printf '%s\n' "$region" | head -n "$nbound")"
  # A genuinely multi-line unsubmitted draft can have a BLANK first line
  # (e.g. shift+enter pressed before typing, or a paste that starts with a
  # blank line) with real text on line 2+. Checking only the first line (an
  # earlier cut of this function, via `head -1`) silently read that as an
  # empty box -> SAFE — the dangerous direction, confirmed by direct
  # reproduction against this function. Strip the ❯ prefix off line 1 only
  # (line 2+ carries no such prefix) and look at the WHOLE box, not just its
  # first line.
  rest="$(printf '%s\n' "$box" | sed '1s/^[^❯]*❯//')"
  visible="$(_strip_ansi "$rest" | tr -d '\n' | sed -e "s/^[[:space:]${nbsp}]*//" -e "s/[[:space:]${nbsp}]*\$//")"
  [ -z "$visible" ] && return 0
  # Claude Code's dim "suggested next action" ghost text is always exactly
  # one line in practice (confirmed empirically — see _is_dim_span's
  # comment); a box spanning more than one line is therefore never ghost
  # text, so treat it as a real draft directly rather than feeding
  # multi-line content to a regex anchored for a single span.
  if [ "$(printf '%s\n' "$box" | wc -l)" -le 1 ]; then
    _is_dim_span "$rest"
  else
    return 1
  fi
}

# _safety_reason — classify a captured pane's injection-safety in one word.
# Expects an ANSI-preserving capture (`tmux capture-pane -p -e`) so the
# draft-vs-ghost-text distinction in _input_box_empty is available; a plain
# (`-p`) capture still works for busy/menu/no-prompt, and degrades safely on
# the draft check (no dim info -> any leftover input-line text reads as a
# real draft).
#   busy                : Claude is actively generating (spinner / esc to interrupt)
#   menu                : an interactive AskUserQuestion-style widget is up —
#                          plain text sent into it is silently dropped
#   no-prompt           : no ❯ input line visible (still starting up, or an
#                          unrecognized layout)
#   draft-in-input-box  : a real ❯ prompt, but unsubmitted text is sitting on
#                          it — pasting now would concatenate onto someone's draft
#   safe                : none of the above — a message can be sent (the input
#                          box is either truly empty or only has Claude Code's
#                          own dim "suggested next action" ghost text, which a
#                          paste cleanly overwrites)
# Order matters: busy and menu are checked before the prompt/draft checks
# because both can coexist with leftover text on the input line (e.g. a menu
# widget ignores stray keystrokes rather than clearing them), and busy/menu
# are the more actionable diagnoses in that case. The busy/menu/prompt checks
# run on an ANSI-STRIPPED copy so their literal-substring greps aren't broken
# by color codes landing mid-phrase; only the draft check needs the raw form.
_safety_reason() {
  local raw="$1" stripped; stripped="$(_strip_ansi "$raw")"
  _is_working "$stripped" && { echo busy; return; }
  _is_on_menu "$stripped" && { echo menu; return; }
  _has_prompt "$stripped" || { echo no-prompt; return; }
  _input_box_empty "$raw" || { echo draft-in-input-box; return; }
  echo safe
}

# _is_safe_to_inject — the POSITIVE readiness predicate: exit 0 only when a
# message can be pasted + Enter-submitted without corrupting someone's draft,
# vanishing into a menu widget, or racing active generation. The absence of
# "busy" is NOT sufficient — see the top-of-file note. `send` does not gate on
# this yet (see its comment above). Note the `case "$st"` below in `send` has
# no `ready)` arm — a pane with a draft or a menu up is classified `ready` by
# _state_of today (it only distinguishes busy from not-busy) and falls
# straight through to the paste with zero warning; that fall-through is
# exactly what this predicate would need to gate. `busy` already has its own
# warn+proceed arm and should keep it: gating `_is_safe_to_inject` naively
# over the whole case would also swallow `busy` into a hard refusal, breaking
# the existing "message queues behind current work" contract.
_is_safe_to_inject() { [ "$(_safety_reason "$1")" = safe ]; }

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
# Mirrors session-doctor.sh's / session-preserve.sh's tmux_to_base exactly —
# same name on purpose so a fix to one copy greps up the others (scripts
# deploy standalone to ~/.local/bin, so it stays a local copy, not sourced).
tmux_to_base() { case "$1" in ah_*) echo "ah-${1#ah_}";; agenthost_*) echo "agenthost-${1#agenthost_}";; *) echo "";; esac; }

_pane_cmd() { tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null; }
_capture()  { tmux capture-pane -p -t "$1" 2>/dev/null; }
# _capture_ansi — like _capture, but keeps SGR escape codes (`-e`). `ready`
# uses this so _safety_reason / _input_box_empty can tell a real draft apart
# from Claude Code's dim "suggested next action" ghost text (see _is_dim_span).
_capture_ansi() { tmux capture-pane -p -e -t "$1" 2>/dev/null; }

# _model_of — best-effort resolved model for a session (from its start script,
# else the most recent session-starts.log line).
_model_of() {
  local rem sc; rem="$(tmux_to_base "$1")"; [ -n "$rem" ] || { echo "?"; return; }
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
    st="$(_state_of "$S")"; rem="$(tmux_to_base "$S")"
    active=no; [ -n "$rem" ] && systemctl --user is-active --quiet "${rem}.service" 2>/dev/null && active=yes
    echo "check: $S  state=$st  unit-active=$active  model=$(_model_of "$S")"
    [ "$st" = ready ] && exit 0 || exit 1
    ;;

  ready)
    S="${1:?usage: session-handoff ready <tmux-session>}"
    if ! tmux has-session -t "$S" 2>/dev/null; then echo "ready: '$S' — no such tmux session"; exit 2; fi
    reason="$(_safety_reason "$(_capture_ansi "$S")")"
    if [ "$reason" = safe ]; then
      echo "ready: $S SAFE"
      exit 0
    else
      echo "ready: $S NOT-SAFE reason=$reason"
      exit 1
    fi
    ;;

  send)
    S="${1:?usage: session-handoff send <tmux-session> (<msg> | --file <path>)}"; shift
    tmux has-session -t "$S" 2>/dev/null || { echo "send: '$S' — no such tmux session" >&2; exit 2; }
    if [ "${1:-}" = "--file" ]; then
      FILE="${2:?--file needs a path}"
      # A missing/unreadable path must be reported as such, not silently
      # swallowed into an empty MSG — that used to surface as the unrelated
      # "message is empty or whitespace-only" refusal below, hiding the real
      # cause (cat's own stderr line is easy to miss/strip by a caller).
      MSG="$(cat "$FILE")" || { echo "send: could not read --file path: $FILE" >&2; exit 2; }
    else
      MSG="${1:?message required}"
    fi
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

  *) echo "usage: session-handoff (targets | check <s> | ready <s> | send <s> <msg>|--file <p>)" >&2; exit 2;;
esac
fi
