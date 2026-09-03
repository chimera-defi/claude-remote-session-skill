#!/usr/bin/env bash
# session-send.sh is a thin passthrough to `session-handoff.sh send` — this
# confirms it forwards args/exit-codes/messages faithfully rather than
# re-implementing (and so re-risking) the type/verify/Enter dance, and that it
# resolves session-handoff in BOTH the repo layout (co-located .sh) and the
# deployed layout (flat copy on PATH, .sh dropped).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SEND="$HERE/../scripts/session-send.sh"
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }
has(){ if printf '%s' "$2" | grep -qF "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — pattern not found: $3 in: $2"; fi; }

# 1. No such tmux session -> forwarded error + exit code from session-handoff,
# not a session-send-specific message (proves it's a real passthrough).
out="$(bash "$SEND" no-such-session-send-test-$$ hello 2>&1)"; rc=$?
has "no-session-forwarded" "$out" "no such tmux session"
ok  "no-session-exit2"     "$rc" "2"

# 2. Deployed layout: session-handoff resolved via PATH (no .sh sibling next
# to session-send), matching how scripts land flat in ~/.local/bin. Copy
# session-send.sh ALONE (no session-handoff.sh next to it) so the co-located
# check can't accidentally pass this — the PATH branch has to do the work.
DEPLOY="$(mktemp -d)"; trap 'rm -rf "$DEPLOY"' EXIT
cp "$HERE/../scripts/session-send.sh" "$DEPLOY/session-send.sh"
cp "$HERE/../scripts/session-handoff.sh" "$DEPLOY/session-handoff"
chmod +x "$DEPLOY/session-handoff"
outp="$(PATH="$DEPLOY:$PATH" bash "$DEPLOY/session-send.sh" no-such-session-send-test-$$ hello 2>&1)"; rcp=$?
has "path-fallback-forwarded" "$outp" "no such tmux session"
ok  "path-fallback-exit2"     "$rcp" "2"

# 3. Neither co-located nor on PATH -> session-send must fail clearly, not
# silently do nothing. Copy session-send.sh ALONE into an empty dir (no
# session-handoff sibling) and strip PATH, so co-located resolution (which
# looks next to the script's OWN location, unaffected by PATH) also misses.
ISOLATED="$(mktemp -d)"
cp "$HERE/../scripts/session-send.sh" "$ISOLATED/session-send.sh"
outm="$(env -i PATH=/usr/bin:/bin HOME="$HOME" bash "$ISOLATED/session-send.sh" missing-helper-test hello 2>&1)"; rcm=$?
has "helper-missing-clear-error" "$outm" "could not locate session-handoff"
ok  "helper-missing-exit2"       "$rcm" "2"
rm -rf "$ISOLATED"

# 4. Whitespace-only message rejected up front (the exact false-"unverified"
# fix already in session-handoff.sh — session-send must inherit it, not
# re-derive its own weaker check). Needs a REAL (throwaway, synthetic) tmux
# session whose pane foreground command is claude/node (`exec -a claude cat`
# renames the pane's own process so _state_of sees "ready", not "starting" —
# a bare login shell would be classified "starting" and refused before the
# whitespace check is ever reached).
if command -v tmux >/dev/null 2>&1; then
  S="sendtest-$$-ws"
  tmux new-session -d -s "$S" 2>/dev/null
  tmux send-keys -t "$S" 'exec -a claude cat' Enter
  # POLL, don't sleep. A fixed `sleep 1` raced on loaded CI runners: the pane was
  # still a bare login shell, so _state_of classified it "starting" and
  # session-send refused for THAT reason before ever reaching the whitespace
  # check — failing this assertion with a misleading message
  # ("... is still starting — refusing to send"). Wait for the renamed
  # foreground command this fixture needs, which is what the comment above
  # already said was required.
  for _ in $(seq 1 50); do
    [ "$(tmux list-panes -t "$S" -F '#{pane_current_command}' 2>/dev/null | head -1)" = claude ] && break
    sleep 0.2
  done
  outw="$(bash "$SEND" "$S" "   " 2>&1)"; rcw=$?
  has "whitespace-rejected" "$outw" "message is empty or whitespace-only"
  ok  "whitespace-exit2"    "$rcw" "2"
  tmux kill-session -t "$S" 2>/dev/null || true
fi

# 5. --file passthrough on a session that doesn't exist: the has-session check
# runs before any file is read, so this only proves the flag reaches
# session-handoff unmangled (same error as plain send). A REAL file-read
# attempt is exercised in 5b against a live throwaway session.
outf="$(bash "$SEND" no-such-session-send-test-$$ --file /no/such/path-$$ 2>&1)"; rcf=$?
has "file-flag-forwarded-notfound" "$outf" "no such tmux session"
ok  "file-flag-exit2"              "$rcf" "2"

# 5b. --file content is actually read and sent (not a "no such session"/
# "--file needs a path" short-circuit) — needs a live throwaway session so
# dispatch reaches the file-read step. Outcome (landed vs UNVERIFIED) depends
# on the pane's shape (a bare tmux pane isn't a real claude TUI), so only
# assert it got PAST argument handling, not which verdict it reached.
if command -v tmux >/dev/null 2>&1; then
  S2="sendtest-$$-file"
  tmux new-session -d -s "$S2" 2>/dev/null
  tmux send-keys -t "$S2" 'exec -a claude cat' Enter
  sleep 1
  MSGFILE="$(mktemp)"; printf 'relayed via --file\n' > "$MSGFILE"
  outf2="$(bash "$SEND" "$S2" --file "$MSGFILE" 2>&1)"
  if printf '%s' "$outf2" | grep -qE 'landed on|UNVERIFIED on'; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: file-flag-content-sent — got: $outf2"; fi
  rm -f "$MSGFILE"
  tmux kill-session -t "$S2" 2>/dev/null || true
fi

echo "session-send: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
