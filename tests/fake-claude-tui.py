#!/usr/bin/env python3
"""fake-claude-tui.py — throwaway fixture standing in for a Claude Code TUI
pane in tests/test-session-handoff-paste-race.sh (see that file for the full
incident writeup: the dropped-first-paste race, 2026-09-24).

Renders a minimal claude-like screen — a "-" status line, a bordered
❯-prompt input box, a "[Sonnet 5] <name>" footer — shaped so session-
handoff.sh's real classifiers (_has_prompt / _input_box_empty / _is_working /
_in_transcript / _on_input_line / _safety_reason) read it the same way they'd
read a real captured pane. Renders are full clear+redraw (`ESC[2J ESC[H`) so
`tmux capture-pane` always reflects current state, not a scrollback smear.

Declares bracketed-paste support (`ESC[?2004h`) before switching the tty to
raw mode — confirmed empirically (2026-09-24, this task) that tmux's
`paste-buffer -p` only wraps content in the `ESC[200~ ... ESC[201~` bracket
markers when the foreground app has asked for bracketed paste; skipping this
would make our own paste-vs-keystroke split untestable, not just unrealistic.
Enter arrives as a raw `\r` (0x0d) in raw mode — also confirmed empirically
(a canonical-mode read sees `\n` via ICRNL, which is a DIFFERENT byte and
would silently break Enter-detection if assumed instead of checked).

Every paste and Enter this fixture receives is appended to FAKE_TUI_LOG (env
var) regardless of whether the mode chooses to render it. That log is the
test's independent oracle of what was actually DELIVERED, separate from what
made it onto the simulated screen — load-bearing for the "silent-accept" mode
below, which models a case session-handoff.sh cannot tell apart from a
genuine drop (see that mode's docstring and the test file's case 2 comment).

Usage: fake-claude-tui.py <mode>
  drop-first      Paste #1 is discarded outright: the input box never shows
                   it and it never reaches the transcript — this is the
                   observed bug (a freshly-booted TUI silently eats the first
                   bracketed paste). Paste #2+ is accepted normally, and
                   Enter on a non-empty input box submits it to the
                   transcript. Models the incident this fix targets.
  silent-accept   Every paste is logged (i.e. genuinely "delivered" to the
                   app) but NEVER changes the input box or transcript — the
                   screen stays exactly as idle/"safe" as it started, and
                   Enter is always a no-op (nothing was ever on the input
                   line for it to submit, so no evidence of processing shows
                   up on screen). Models a TUI that received bytes but
                   stalled its own repaint — from a pane-capture vantage
                   point this is bit-for-bit identical to drop-first, and the
                   fix's retry cannot distinguish them (see test case 2).
  busy-after-send Paste #1 is accepted normally (rendered on the input
                   line). Enter immediately submits it to the transcript,
                   clears the input box, and switches to a busy/working
                   render (matches session-handoff.sh's _is_working pattern)
                   — i.e. the ordinary "it just worked" case. Used to prove
                   the new retry path does NOT fire when the first attempt
                   already succeeded.
  trust-dialog    Renders Claude Code's first-launch workspace-trust dialog
                   ("Yes, I trust this folder / No, exit · Enter to confirm
                   · Esc to cancel") ONCE at startup and never changes —
                   there is no ❯ prompt at all, modeling the real dialog,
                   which replaces the normal screen rather than sitting
                   inside it. Any paste or Enter received is still logged
                   (so a test can assert NOTHING was sent into it), but
                   never rendered or acted on — this fixture cannot itself
                   pick "Yes"/"No"; it's here to prove session-handoff.sh
                   refuses to type into it at all, not to model what
                   happens after an answer is picked. See the 2026-09-24
                   incident in _is_on_menu's comment (session-handoff.sh).
  collapsed-paste Paste #1 is accepted, but rendered as Claude Code's
                   collapsed-multiline-paste placeholder ("[Pasted text #1
                   +17 lines]") rather than the literal text — this is real
                   Claude Code behavior for large/multi-line pastes, which is
                   exactly the shape a --task-file kickoff takes. The FIRST
                   Enter received while that placeholder is showing is
                   deliberately ignored (logged, not acted on) — modeling the
                   observed flakiness where an automated Enter didn't
                   register the first time — and only the SECOND Enter
                   actually submits it (clears the input box, goes busy).
                   Proves send's retry loop must classify the placeholder as
                   "still buffered" (re-press Enter) rather than "unverified"
                   (give up after only one try). See the 2026-09-24
                   ah_qt-gate-0924-0802 incident in _is_collapsed_paste_in_input's
                   comment (session-handoff.sh).
"""
import os
import sys
import tty
import termios

MODE = sys.argv[1]
LOGFILE = os.environ["FAKE_TUI_LOG"]

BORDER = "─" * 40
PROMPT = "❯"  # ❯
BULLET = "●"  # ●

transcript = []
input_box = ""
paste_count = 0
busy = False
collapsed_enter_count = 0  # collapsed-paste mode only: Enters seen since the placeholder showed


def log(line):
    with open(LOGFILE, "a") as f:
        f.write(line + "\n")


def render():
    out = "\x1b[2J\x1b[H"
    if transcript:
        for line in transcript[-6:]:
            out += BULLET + " " + line + "\r\n"
    else:
        out += BULLET + " Ready.\r\n"
    if busy:
        out += "✵ Working… (esc to interrupt)\r\n"
    out += BORDER + "\r\n"
    out += PROMPT + " " + input_box + "\r\n"
    out += BORDER + "\r\n"
    out += "  [Sonnet 5] fake-claude-tui\r\n"
    os.write(1, out.encode("utf-8"))


def render_trust_dialog():
    # No ❯ box at all — the real dialog REPLACES the normal screen, it
    # doesn't sit inside it. Text matches the live incident transcript
    # (session-handoff.sh's _is_on_menu comment) closely enough to exercise
    # the same "trust this folder" / "Enter to confirm" / "Esc to cancel"
    # substrings that classifier greps for.
    out = "\x1b[2J\x1b[H"
    out += "Do you trust the files in this folder?\r\n\r\n"
    out += "  1. Yes, I trust this folder\r\n"
    out += "  2. No, exit\r\n\r\n"
    out += "  Enter to confirm · Esc to cancel\r\n"
    os.write(1, out.encode("utf-8"))


def handle_paste(data):
    global paste_count, input_box, collapsed_enter_count
    paste_count += 1
    text = data.decode("utf-8", "replace")
    first_line = text.splitlines()[0][:60] if text else ""
    log("PASTE %d: %s" % (paste_count, first_line))
    if MODE == "trust-dialog":
        return  # logged for the test oracle, but the dialog never reacts
    if MODE == "drop-first" and paste_count == 1:
        return  # dropped: matches the observed bug, nothing rendered
    if MODE == "silent-accept":
        return  # "delivered" (logged above) but deliberately never rendered
    if MODE == "collapsed-paste":
        collapsed_enter_count = 0
        input_box = "[Pasted text #%d +17 lines]" % paste_count
        render()
        return
    input_box = text
    render()


def handle_enter():
    global input_box, busy, collapsed_enter_count
    log("ENTER")
    if MODE == "trust-dialog":
        return  # logged for the test oracle; this fixture cannot pick an
        # option and must not pretend to — see the mode's own docstring
    if MODE == "collapsed-paste" and input_box:
        collapsed_enter_count += 1
        if collapsed_enter_count == 1:
            return  # first Enter deliberately ignored — see mode docstring
    if not input_box:
        return  # empty input box: Enter is a no-op, as on real Claude Code
    log("SUBMIT: %s" % input_box.splitlines()[0][:60])
    transcript.append(input_box)
    input_box = ""
    if MODE == "busy-after-send" or MODE == "collapsed-paste":
        busy = True
    render()


def main():
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    # Request bracketed paste BEFORE raw mode, matching how a real TUI would
    # negotiate it on startup (see module docstring for the empirical check).
    os.write(1, b"\x1b[?2004h")
    tty.setraw(fd)
    render_trust_dialog() if MODE == "trust-dialog" else render()

    PASTE_START = b"\x1b[200~"
    PASTE_END = b"\x1b[201~"
    buf = b""
    in_paste = False

    try:
        while True:
            chunk = os.read(fd, 4096)
            if not chunk:
                break
            buf += chunk
            progressed = True
            while progressed:
                progressed = False
                if in_paste:
                    idx = buf.find(PASTE_END)
                    if idx == -1:
                        # END marker not complete yet — wait for more bytes.
                        # Do NOT guess/consume; a split read here must not
                        # corrupt or truncate the paste payload.
                        break
                    handle_paste(buf[:idx])
                    buf = buf[idx + len(PASTE_END):]
                    in_paste = False
                    progressed = True
                    continue

                idx = buf.find(PASTE_START)
                if idx != -1:
                    # Full START marker found — everything before it is
                    # plain keystrokes, safe to flush in full.
                    for b in buf[:idx]:
                        if b in (13, 10):
                            handle_enter()
                    buf = buf[idx + len(PASTE_START):]
                    in_paste = True
                    progressed = True
                    continue

                # No START marker anywhere in buf. It may still end with a
                # PROPER PREFIX of PASTE_START if os.read() handed us a
                # chunk that split the marker mid-sequence — flushing that
                # tail as "plain keystrokes" would permanently destroy the
                # marker (the rest arrives next read(), but PASTE_START can
                # then never be found because its own prefix is already
                # gone). Hold back the longest such suffix and re-scan once
                # more data arrives; flush everything else now.
                hold = 0
                max_check = min(len(PASTE_START) - 1, len(buf))
                for k in range(max_check, 0, -1):
                    if buf[-k:] == PASTE_START[:k]:
                        hold = k
                        break
                safe_len = len(buf) - hold
                if safe_len > 0:
                    for b in buf[:safe_len]:
                        if b in (13, 10):
                            handle_enter()
                    buf = buf[safe_len:]
                break
    except KeyboardInterrupt:
        pass
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


if __name__ == "__main__":
    main()
