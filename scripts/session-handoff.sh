#!/usr/bin/env bash
# session-handoff.sh — hand a task to a live Claude or Codex tmux session.
#   targets                              live sessions with state and model
#   check <tmux-session>                 one session's state (exit 0 = ready)
#   ready <tmux-session>                 injection-safety check (exit 0 = SAFE)
#   send  <tmux-session> (<msg>|--file <path>)   paste, Enter, verify it landed
# `send` prints landed (exit 0) or UNVERIFIED (exit 1; check the session).
# Ready is not idle: `ready` also refuses a pane with a draft in its input box.
set -uo pipefail

# ── Host-local overlay config ────────────────────────────────────────────────
# Host overlay config: see crss-lib.sh.
_crss_lib="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/crss-lib.sh"
# shellcheck source=scripts/crss-lib.sh
. "$_crss_lib" || { echo "${0##*/}: missing $_crss_lib; install crss-lib.sh next to this script" >&2; exit 2; }
declare -F _crss_admit tmux_to_base >/dev/null || { echo "${0##*/}: $_crss_lib is out of date; install crss-lib.sh next to this script" >&2; exit 2; }
_crss_load_config

# ── Session-name prefix recognition ─────────────────────────────────────────
# Session-name prefix: see crss-lib.sh.
_crss_prefix_init

# ── pure classifiers (source-guarded below so tests can exercise them) ────────

# _is_working — is Claude or Codex generating? Anchor on "esc to interrupt",
# plus a spinner glyph followed by a word ending in "…" (spinner words vary by
# release). Codex's "•" bullet is not a spinner glyph: replies start with it.
_is_working() {
  grep -qE 'esc to interrupt|(✻|✽|✶|✳|✢|✷|✦|✧|⋆|∗|·)[[:space:]]*[[:alpha:]][[:alpha:]]*…' <<<"$1"
}

_is_codex_selection_widget() {
  printf '%s\n' "$1" | tail -n 12 | awk '
    /^[[:space:]]*›[[:space:]]*1[.)][[:space:]]/ { one=1 }
    /^[[:space:]]*1[.)][[:space:]]/ { one=1 }
    /^[[:space:]]*2[.)][[:space:]]/ { two=1 }
    /enter select/ && /esc back/ { footer=1 }
    END { exit !(one && two && footer) }
  '
}

# _is_on_menu — is the pane on an interactive widget (arrow-key menu, or the
# first-launch folder-trust dialog)? Text sent there is dropped or answers the
# default choice. Incident: a kickoff paste sent into the trust dialog had its
# Enter select the default "No, exit", so Claude exited (reported as UNVERIFIED).
_is_on_menu() {
  _is_codex_selection_widget "$1" && return 0
  grep -qE '↑/↓ to navigate|Enter to select|Esc to cancel|☐ Next direction|✔ Submit|trust this folder|Trust this folder|Folder access|Enter to confirm|enter continue|enter/esc confirm|Would you like to run the following command|Press enter to confirm|Back to Agent Command Center' <<<"$1"
}

# _frag — a distinctive single-line fragment of a message, to find it in a capture.
_frag() { printf '%s' "$1" | sed -n '/[^[:space:]]/{p;q}' | cut -c1-48; }

# _input_region / _transcript_region — split a capture at the last prompt line
# (`❯`, or Codex's `›`): below it is the pending input, above it the transcript.
# Use alternation `❯|›`, not `[❯›]`: under a C locale a bracket class splits
# these multi-byte glyphs into bytes and false-matches other TUI symbols.
_input_region()      { printf '%s\n' "$2" | awk '/❯|›/{last=NR} {a[NR]=$0} END{for(i=(last?last:NR+1);i<=NR;i++)print a[i]}'; }
_transcript_region() { printf '%s\n' "$2" | awk '/❯|›/{last=NR} {a[NR]=$0} END{for(i=1;i<(last?last:1);i++)print a[i]}'; }

# _on_input_line — is the fragment still in the input box (typed, not submitted)?
# Capture first, then match: a pipe into grep -q can SIGPIPE under pipefail.
_on_input_line() {
  local r
  r="$(_input_region "$1" "$2" && printf x)" || return 1
  r=${r%x}
  [ -n "$r" ] && grep -qF -- "$1" <<<"${r%$'\n'}"
}
# _in_transcript — did the fragment reach the conversation (submitted + echoed)?
_in_transcript() {
  local r
  r="$(_transcript_region "$1" "$2" && printf x)" || return 1
  r=${r%x}
  [ -n "$r" ] && grep -qF -- "$1" <<<"${r%$'\n'}"
}

# _is_collapsed_paste_in_input — is the input box showing Claude Code's
# "[Pasted text #1 +17 lines]" placeholder instead of the pasted text? The
# fragment match cannot see the placeholder, so without this a buffered
# multi-line paste reads as lost.
_is_collapsed_paste_in_input() {
  local r
  r="$(_input_region "" "$1" && printf x)" || return 1
  r=${r%x}
  [ -n "$r" ] && grep -qE '\[Pasted text #[0-9]+ \+[0-9]+ lines?\]' <<<"${r%$'\n'}"
}

# _has_prompt — is a ❯/› input line visible? Absent during startup.
_has_prompt() { grep -qE '❯|›' <<<"$1"; }

# _strip_ansi — drop ANSI CSI sequences (color/dim codes from capture-pane -e).
_strip_ansi() {
  local esc; esc=$'\x1b'
  printf '%s' "$1" | sed -E "s/${esc}\\[[0-9;]*[A-Za-z]//g"
}

# _is_dim_span — is $1 entirely a dim (SGR 2) run? That is Claude Code's
# ghost-text suggestion in an empty input box, not a user draft. A real draft
# has no dim attribute. Re-verify if the TUI changes how it styles placeholders.
_is_dim_span() {
  local s="$1" esc nbsp; esc=$'\x1b'; nbsp=$'\xc2\xa0'
  grep -Eq \
    "^[[:space:]${nbsp}]*((${esc}\\[0;2m)|(${esc}\\[2m)|(${esc}\\[7m.${esc}\\[0;2m))[^${esc}]*${esc}\\[0m[[:space:]${nbsp}]*\$" <<<"$s"
}

# _input_box_empty — is the input box empty, or holding only ghost text? Needs
# an ANSI-preserving capture to tell ghost text from a draft. Caller must
# confirm _has_prompt first. tmux pads after ❯ with U+00A0 (NBSP), which
# POSIX [[:space:]] misses, so the trim strips it explicitly.
_input_box_empty() {
  local cap="$1" region stripped nbound box rest visible nbsp
  nbsp=$'\xc2\xa0'
  region="$(_input_region "" "$cap")"
  stripped="$(_strip_ansi "$region")"
  # The box ends at the next all-'─' border line (not the end of the buffer,
  # which would sweep in the status line). Use literal substring stripping,
  # not a regex over '─': mawk and non-UTF-8 locales never match it.
  local nbound_n=0 nbound_ln
  nbound=0
  while IFS= read -r nbound_ln; do
    nbound_n=$((nbound_n + 1))
    [ "$nbound_n" -eq 1 ] && continue
    if [ -n "$nbound_ln" ] && [ -z "${nbound_ln//─/}" ]; then
      nbound=$((nbound_n - 1))
      break
    fi
    if [ "$nbound_n" -gt 1 ] && grep -q '›' <<<"${stripped%%$'\n'*}" \
       && [ -z "$(printf '%s' "$nbound_ln" | tr -d '[:space:]')" ]; then
      nbound=$((nbound_n - 1))
      break
    fi
  done <<<"$stripped"
  [ "$nbound" -gt 0 ] || nbound="$nbound_n"
  [ -n "$nbound" ] && [ "$nbound" -gt 0 ] || nbound=1
  box="$(printf '%s\n' "$region" | head -n "$nbound")"
  # Check the WHOLE box: a draft can start with a blank line. Strip only the
  # first prompt glyph on line 1 (a greedy strip would hide `❯ explain ›`).
  rest="$(printf '%s\n' "$box" | awk '
    NR == 1 {
      p = index($0, "❯"); glyph = "❯"
      q = index($0, "›")
      if (q && (!p || q < p)) { p = q; glyph = "›" }
      if (p) $0 = substr($0, p + length(glyph))
    }
    { print }
  ')"
  visible="$(_strip_ansi "$rest" | tr -d '\n' | sed -e "s/^[[:space:]${nbsp}]*//" -e "s/[[:space:]${nbsp}]*\$//")"
  [ -z "$visible" ] && return 0
  # Ghost text is one line; a multi-line box is always a real draft.
  if [ "$(printf '%s\n' "$box" | wc -l)" -le 1 ]; then
    _is_dim_span "$rest"
  else
    return 1
  fi
}

# _safety_reason — one word on whether a message can be pasted now. Order
# matters: busy and menu come first, since leftover text can coexist with them.
#   busy                : generating (spinner / esc to interrupt)
#   menu                : an interactive widget is up (input would be dropped)
#   no-prompt           : no ❯ input line visible
#   draft-in-input-box  : unsubmitted text on the prompt; pasting would merge into it
#   safe                : none of the above (empty box or Claude's ghost text)
# A `blocked` lane is still `safe` here; that stall is `_state_of`'s job.
_safety_reason() {
  local raw="$1" stripped; stripped="$(_strip_ansi "$raw")"
  _is_working "$stripped" && { echo busy; return; }
  _is_on_menu "$stripped" && { echo menu; return; }
  _has_prompt "$stripped" || { echo no-prompt; return; }
  _input_box_empty "$raw" || { echo draft-in-input-box; return; }
  echo safe
}

# _is_safe_to_inject — the positive predicate behind `ready`. `send` does not
# gate on it before the first paste, so a bare draft still gets pasted into.
_is_safe_to_inject() { [ "$(_safety_reason "$1")" = safe ]; }

# _verdict — buffered (still on the input line: press Enter again) |
# landed (in the transcript, or working) | unverified (no confirmation).
_verdict() {
  local frag="$1" cap="$2"
  if _on_input_line "$frag" "$cap" || _is_collapsed_paste_in_input "$cap"; then echo buffered; return; fi
  if _in_transcript "$frag" "$cap" || _is_working "$cap"; then echo landed; return; fi
  echo unverified
}

# ── live helpers ──────────────────────────────────────────────────────────────

_start_script_field() {
  local sc="$1" name="$2" line value
  [[ "$name" =~ ^[A-Z_][A-Z0-9_]*$ ]] || return 1
  [ -r "$sc" ] || return 1
  line="$(grep -m1 -E "^${name}=" "$sc" 2>/dev/null)" || return 1
  value="${line#*=}"
  python3 - "$value" <<'PY'
import shlex
import sys

try:
    parts = shlex.split(sys.argv[1], comments=False, posix=True)
except ValueError:
    sys.exit(1)
if len(parts) != 1:
    sys.exit(1)
print(parts[0])
PY
}

_pane_cmd() { tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null; }
_capture()  { tmux capture-pane -p -t "$1" 2>/dev/null; }
# _capture_ansi — like _capture, but keeps SGR escape codes (`-e`). `ready`
# uses this so _safety_reason / _input_box_empty can tell a real draft apart
# from Claude Code's dim "suggested next action" ghost text (see _is_dim_span).
_capture_ansi() { tmux capture-pane -p -e -t "$1" 2>/dev/null; }

# _paste_and_wait <session> <frag> <msg> — bracketed paste, then Enter with
# retries; echoes the verdict. Shared with send's one dropped-paste retry.
_paste_and_wait() {
  local s="$1" frag="$2" msg="$3" verdict=unverified _try _j
  if [ "${CRSS_AUTONOMOUS:-0}" = 1 ]; then
    _crss_admit wake "${CRSS_ADMISSION_SUBJECT:-$s}" --packet-chars "${#msg}" >&2 || { echo admission-denied; return 2; }
  fi
  # Bracketed paste keeps a multi-line prompt as one input.
  printf '%s' "$msg" | tmux load-buffer -b handoff -
  tmux paste-buffer -t "$s" -b handoff -p -d
  for _try in 1 2 3; do
    tmux send-keys -t "$s" Enter
    for _j in 1 2 3 4 5 6; do
      verdict="$(_verdict "$frag" "$(_capture "$s")")"
      [ "$verdict" = landed ] && break
      sleep 0.5
    done
    [ "$verdict" = landed ] && break
    [ "$verdict" = buffered ] || break     # unverified: stop resending
  done
  echo "$verdict"
}

# _model_of — resolved model, from the start script or the session-starts log.
_model_of() {
  local rem sc; rem="$(tmux_to_base "$1")"; [ -n "$rem" ] || { echo "?"; return; }
  sc="$HOME/.local/bin/${rem}-start.sh"
  if [ -f "$sc" ]; then _start_script_field "$sc" MODEL; return; fi
  grep -F "remote=$rem " "$HOME/.sessions/session-starts.log" 2>/dev/null | sed -n 's/.* model=\([^ ]*\) .*/\1/p' | tail -1
}

_backend_of() {
  local rem sc backend
  rem="$(tmux_to_base "$1")"; [ -n "$rem" ] || { echo claude; return; }
  sc="$HOME/.local/bin/${rem}-start.sh"
  if [ -f "$sc" ]; then
    backend="$(_start_script_field "$sc" BACKEND)"
    [ -n "$backend" ] && { echo "$backend"; return; }
  fi
  backend="$(grep -F "remote=$rem " "$HOME/.sessions/session-starts.log" 2>/dev/null | sed -n 's/.* backend=\([^ ]*\) .*/\1/p' | tail -1)"
  [ -n "$backend" ] && echo "$backend" || echo claude
}

# _codex_live <session> — a foreground, non-stopped `codex` under the pane's pid.
_codex_live() {
  local root ptty kids k c comm st pg tpg ctty queue="" n=0
  read -r root ptty <<< "$(tmux display-message -p -t "$1" '#{pane_pid} #{pane_tty}' 2>/dev/null)"
  case "$root" in ''|*[!0-9]*) return 1;; esac
  ptty="${ptty#/dev/}"; [ -n "$ptty" ] || return 1
  queue="$root"
  while [ -n "$queue" ] && [ "$n" -lt 256 ]; do
    k="${queue%% *}"; case "$queue" in *" "*) queue="${queue#* }";; *) queue="";; esac
    n=$((n+1))
    kids="$(pgrep -P "$k" 2>/dev/null | tr '\n' ' ')"
    for c in $kids; do
      comm="$(ps -o comm= -p "$c" 2>/dev/null)"
      # Must be the tty's foreground group and not stopped (else not a TUI).
      if [ "$comm" = codex ]; then
        read -r st pg tpg ctty <<< "$(ps -o stat=,pgid=,tpgid=,tty= -p "$c" 2>/dev/null)"
        case "$st" in [Tt]*) : ;; *) [ "$ctty" = "$ptty" ] && [ -n "$pg" ] && [ "$pg" = "$tpg" ] && return 0 ;; esac
      fi
      queue="${queue:+$queue }$c"
    done
  done
  return 1
}

# _blocked_line_text — strip whitespace, NBSP padding and one leading ⏺/● bullet.
_blocked_line_text() {
  local s="$1" nbsp=$'\xc2\xa0'
  s="${s//$nbsp/ }"
  s="${s#"${s%%[![:space:]]*}"}"
  case "$s" in
    "⏺"*) s="${s#⏺}" ;;
    "●"*) s="${s#●}" ;;
  esac
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# _is_blocked — idle and waiting on the operator: a `BLOCKED:` line in the last
# 12 transcript lines, or the last assistant line ends with `?`. Tips (※/Tip:) are skipped.
_is_blocked() {
  local cap="$1" region line text last="" flat n start i
  local -a body=()
  region="$(_transcript_region "" "$cap")"
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "${line//[[:space:]]/}" ] && continue
    body+=("$line")
  done <<<"$region"
  # The ─ rule directly above the prompt is the top of the input footer, not
  # assistant text, so it does not consume a tail slot.
  n=${#body[@]}
  while [ "$n" -gt 0 ]; do
    line="${body[$((n - 1))]}"
    flat="${line//[[:space:]]/}"
    if [ -n "$flat" ] && [ -z "${flat//─/}" ]; then
      n=$((n - 1))
    else
      break
    fi
  done
  start=0
  [ "$n" -gt 12 ] && start=$((n - 12))
  for ((i = start; i < n; i++)); do
    text="$(_blocked_line_text "${body[$i]}")"
    [ -n "$text" ] || continue
    case "$text" in
      "※"*|Tip:*) continue ;;
    esac
    last="$text"
    case "$text" in
      BLOCKED:*) return 0 ;;
    esac
  done
  case "$last" in
    *\?) return 0 ;;
  esac
  return 1
}

# _state_of — the pane's state, one of:
#   dead      no claude/codex process in the pane
#   starting  bare shell, or the supervisor's sleep between restarts (no claude to type into)
#   menu      on an interactive widget or the folder-trust dialog (send refuses)
#   busy      generating; send queues behind it
#   blocked   idle, waiting on the operator; check exits 1, send still answers it
#   ready     idle at the prompt
_state_of() {
  local s="$1" cmd cap backend; cmd="$(_pane_cmd "$s")"; backend="$(_backend_of "$s")"
  case "$cmd" in
    ""|-) echo dead; return;;
    claude|node) : ;;
    codex) [ "$backend" = codex ] || { echo dead; return; } ;;
    # `sleep` is the supervisor's restart backoff, not busy: a paste there lands
    # in a bare shell. Refuse it as `starting`. A wrapper bash with a live codex
    # child is a ready-capable Codex pane, so it falls through to the checks.
    sleep|bash|zsh|sh)
      if [ "$cmd" != sleep ] && [ "$backend" = codex ] && _codex_live "$s"; then
        :
      else
        echo starting; return
      fi ;;
    *) echo dead; return;;
  esac
  cap="$(_capture "$s")"
  # Match the footer only (last 4 non-blank lines): a transcript that quotes a menu hint must not refuse.
  if _is_on_menu "$(printf '%s\n' "$cap" | grep -v '^[[:space:]]*$' | tail -n 4)"; then echo menu; return; fi
  if _is_working "$cap"; then echo busy; return; fi
  if _is_blocked "$cap"; then echo blocked; return; fi
  echo ready
}

_live_ours() { tmux ls 2>/dev/null | cut -d: -f1 | grep -E "^(${_crss_prefix_re})_"; }

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
      # Report an unreadable --file as such, not as an empty message.
      MSG="$(cat "$FILE")" || { echo "send: could not read --file path: $FILE" >&2; exit 2; }
    else
      MSG="${1:?message required}"
    fi
    st="$(_state_of "$S")"
    case "$st" in
      # The messages name the actual pane command, so "claude not running in pane (<cmd>)" stays greppable.
      dead)     echo "send: claude not running in pane ($(_pane_cmd "$S")) — '$S' looks dead — refusing to send" >&2; exit 2;;
      starting) echo "send: claude not running in pane ($(_pane_cmd "$S")) — '$S' is still starting (or between supervisor restarts) — refusing to send (retry after it reaches the prompt)" >&2; exit 2;;
      # A menu is a hard refusal (unlike busy): Enter could pick an unsafe default.
      menu)     echo "send: '$S' is on a menu/dialog widget (e.g. a first-launch folder-trust prompt) — refusing to send; Enter could submit an unintended choice. Answer it by hand (on the folder-trust dialog the highlighted default is 'No, exit' — pick 'Yes, I trust this folder'; new spawns pre-seed it via session-trust-seed)" >&2; exit 2;;
      busy)     echo "send: note — '$S' is busy (working); message will queue behind current work" >&2;;
      # Not a refusal: the launcher is sending the answer to a blocked lane.
      blocked)  echo "send: note — '$S' is blocked (waiting on a question or a BLOCKED: line); sending the answer" >&2;;
    esac
    frag="$(_frag "$MSG")"
    # An empty fragment would match every line, so refuse it up front.
    [ -n "$frag" ] || { echo "send: message is empty or whitespace-only — refusing to send" >&2; exit 2; }
    verdict="$(_paste_and_wait "$S" "$frag" "$MSG")"
    [ "$verdict" != admission-denied ] || { echo "send: autonomous admission denied" >&2; exit 2; }
    # Dropped-first-paste recovery: a fresh Claude TUI can swallow the first
    # paste. Retry once, but only if the pane is safe and the fragment is
    # nowhere on screen (so nothing is duplicated). Residual risk: a TUI that
    # accepted the paste silently could get it twice (tests/test-session-handoff-tui.sh).
    if [ "$verdict" != landed ]; then
      cap_now="$(_capture_ansi "$S")"
      # Re-check the foreground process now: claude may have exited since the first paste.
      if [ "$(_safety_reason "$cap_now")" = safe ] \
         && ! _in_transcript "$frag" "$cap_now" \
         && ! _on_input_line "$frag" "$cap_now"; then
        case "$(_pane_cmd "$S")" in
      claude|node|codex)
            sleep 2
            verdict="$(_paste_and_wait "$S" "$frag" "$MSG")"
            ;;
        esac
      fi
    fi
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
