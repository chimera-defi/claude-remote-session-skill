#!/usr/bin/env bash
# codex-resume-pin: every Codex resume passes its sandbox explicitly (a resumed thread takes the
# CONFIG default otherwise, verified live on codex-cli 0.160), the pin follows the lane's own
# interactive thread, and a wider-than-expected recorded sandbox kills the lane.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
isolate_overlay
RP="$HERE/../scripts/codex-resume-pin.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"; kill $(jobs -p) 2>/dev/null' EXIT
export HOME="$WORK/home" CODEX_HOME="$WORK/codex"; mkdir -p "$HOME" "$CODEX_HOME/sessions/2026/10/03"

# mk_rollout <id> <cwd> <originator> <sandbox|-> [mtime-offset-seconds]
mk_rollout() {
  local f="$CODEX_HOME/sessions/2026/10/03/rollout-2026-10-03T10-00-00-$1.jsonl"
  printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s","originator":"%s"}}\n' "$1" "$2" "$3" > "$f"
  [ "$4" = "-" ] || printf '{"type":"turn_context","payload":{"sandbox_policy":{"type":"%s"}}}\n' "$4" >> "$f"
  [ -n "${5:-}" ] && touch -d "@$(( $(date +%s) + $5 ))" "$f"
  return 0
}

# --- sandbox-of / resume-args: the pin never lets a resume fall back to the config default
ok "sandbox -s"          "$(bash "$RP" sandbox-of -m x -s workspace-write -a never)" "workspace-write"
ok "sandbox --sandbox"   "$(bash "$RP" sandbox-of --sandbox read-only)" "read-only"
ok "sandbox -c form"     "$(bash "$RP" sandbox-of -c 'sandbox_mode="workspace-write"')" "workspace-write"
ok "sandbox default"     "$(bash "$RP" sandbox-of -m x -a never)" "read-only"
ok "sandbox explicit none" "$(bash "$RP" sandbox-of --explicit -m x -a never)" ""
ok "sandbox explicit set"  "$(bash "$RP" sandbox-of --explicit -s workspace-write)" "workspace-write"
bash "$RP" sandbox-of -s bogus >/dev/null 2>&1; ok "sandbox bogus refused" "$?" "1"

# An UNPINNED resume (args carry no -s) is corrected to an explicit read-only, not left to the config.
ra="$(bash "$RP" resume-args T1 -m gpt-5.5 -a never | tr '\n' ' ')"
has "resume corrects missing -s" "$ra" "resume T1 -m gpt-5.5 -a never -s read-only "
ra="$(bash "$RP" resume-args T1 -m gpt-5.5 -s workspace-write -a never | tr '\n' ' ')"
has   "resume keeps explicit -s"  "$ra" "-s workspace-write"
ok    "resume adds no second -s"  "$(grep -o -- '-s' <<<"$ra" | wc -l | tr -d ' ')" "1"

# --- latest: this cwd's newest INTERACTIVE thread only
mkdir -p "$WORK/laneA" "$WORK/laneB"
mk_rollout aaaa-old  "$WORK/laneA" codex-tui workspace-write -300
mk_rollout aaaa-new  "$WORK/laneA" codex-tui workspace-write -100
mk_rollout aaaa-exec "$WORK/laneA" codex_exec read-only -10      # a helper `codex exec` must not steal the pin
mk_rollout bbbb-new  "$WORK/laneB" codex-tui workspace-write -5
ok "latest picks newest tui in cwd" "$(bash "$RP" latest "$WORK/laneA" 0)" "aaaa-new"
ok "latest other cwd"               "$(bash "$RP" latest "$WORK/laneB" 0)" "bbbb-new"
ok "latest since filter"            "$(bash "$RP" latest "$WORK/laneA" "$(( $(date +%s) - 10 ))")" ""

# --- check: asserts the rollout's recorded sandbox_policy
bash "$RP" check aaaa-new workspace-write; ok "check match"    "$?" "0"
bash "$RP" check aaaa-new read-only;       ok "check mismatch" "$?" "1"
mkdir -p "$WORK/laneC"; mk_rollout cccc-none "$WORK/laneC" codex-tui -
bash "$RP" check cccc-none read-only;      ok "check unrecorded" "$?" "3"

# --- watch: pins the thread; kills the lane when the recorded sandbox is wider than expected
sleep 60 & P1=$!
bash "$RP" watch "$WORK/pinA" "$WORK/laneA" 0 workspace-write "$P1" 1 & W1=$!
for _ in $(seq 1 30); do [ -s "$WORK/pinA" ] && break; sleep 0.2; done
ok "watch writes the pin" "$(cat "$WORK/pinA" 2>/dev/null)" "aaaa-new"
ok "matching sandbox leaves lane alive" "$(kill -0 "$P1" 2>/dev/null && echo alive || echo dead)" "alive"
kill "$P1" 2>/dev/null; wait "$W1"; ok "watch exits 0 when lane exits" "$?" "0"

mk_rollout dddd-wide "$WORK/laneB" codex-tui danger-full-access 0
sleep 60 & P2=$!
bash "$RP" watch "$WORK/pinB" "$WORK/laneB" 0 workspace-write "$P2" 1 2>"$WORK/watch.err"; rc=$?
ok  "mismatch returns 1" "$rc" "1"
sleep 0.3
ok  "mismatch kills the lane" "$(kill -0 "$P2" 2>/dev/null && echo alive || echo dead)" "dead"
has "mismatch is logged" "$(cat "$WORK/watch.err")" "SANDBOX-MISMATCH"
rm -f "$CODEX_HOME"/sessions/2026/10/03/rollout-*-bbbb-new.jsonl
sleep 60 & P3=$!
bash "$RP" watch "$WORK/pinC" "$WORK/laneB" 0 - "$P3" 1 & W3=$!
for _ in $(seq 1 30); do [ -s "$WORK/pinC" ] && break; sleep 0.2; done
ok "expected '-' records the pin without enforcing" "$(kill -0 "$P3" 2>/dev/null && echo alive || echo dead)/$(cat "$WORK/pinC" 2>/dev/null)" "alive/dddd-wide"
kill "$P3" 2>/dev/null; wait "$W3" 2>/dev/null

# --- exists: a pin whose rollout is gone is detectable (the loop sets it aside, never resumes it)
bash "$RP" exists dddd-wide; ok "exists: present thread" "$?" "0"
bash "$RP" exists no-such-thread; ok "exists: deleted thread" "$?" "1"

# --- sibling lanes sharing a cwd: a thread already pinned by another lane is never taken
mkdir -p "$HOME/.sessions/resume"
mk_rollout eeee-mine  "$WORK/laneS" codex-tui workspace-write -20
mk_rollout ffff-other "$WORK/laneS" codex-tui workspace-write -5      # newer, belongs to the sibling
echo ffff-other > "$HOME/.sessions/resume/sibling.codex-thread"
ok "latest skips a sibling-pinned thread" "$(bash "$RP" latest "$WORK/laneS" 0 "$HOME/.sessions/resume/mine.codex-thread")" "eeee-mine"
ok "latest without a pin arg is unchanged" "$(bash "$RP" latest "$WORK/laneS" 0)" "ffff-other"

# --- watcher starts before codex: it waits for the target instead of exiting on the first tick
rm -f "$HOME/.sessions/resume/late.codex-thread"
CODEX_PIN_GRACE=10 bash "$RP" watch "$HOME/.sessions/resume/late.codex-thread" "$WORK/laneS" 0 - "child-of:$$" 1 & W4=$!
sleep 2                                    # no codex child yet: the watcher must still be up
ok "watcher waits for a late codex child" "$(kill -0 "$W4" 2>/dev/null && echo up || echo gone)" "up"
mkdir -p "$WORK/bin"; cp "$(command -v sleep)" "$WORK/bin/codex"; "$WORK/bin/codex" 4 & C4=$!
for _ in $(seq 1 30); do [ -s "$HOME/.sessions/resume/late.codex-thread" ] && break; sleep 0.2; done
ok "late child still gets its thread pinned" "$(cat "$HOME/.sessions/resume/late.codex-thread" 2>/dev/null)" "eeee-mine"
kill "$C4" 2>/dev/null; wait "$W4" 2>/dev/null
CODEX_PIN_GRACE=2 bash "$RP" watch "$WORK/pinE" "$WORK/laneS" 0 - "child-of:$$" 1; ok "watcher gives up when codex never starts" "$?" "0"

# --- a resumed thread's pre-restart policy is not this run's: only policies stamped at/after <since> count
TS_OLD="$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%S.000Z)"; TS_NEW="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
printf '{"timestamp":"%s","type":"session_meta","payload":{"id":"gggg-res","cwd":"%s","originator":"codex-tui"}}\n{"timestamp":"%s","type":"turn_context","payload":{"sandbox_policy":{"type":"danger-full-access"}}}\n' \
  "$TS_OLD" "$WORK/laneR" "$TS_OLD" > "$CODEX_HOME/sessions/2026/10/03/rollout-2026-10-03T10-00-00-gggg-res.jsonl"
bash "$RP" check gggg-res read-only "$(date +%s)"; ok "check: stale pre-restart policy is unrecorded, not a mismatch" "$?" "3"
bash "$RP" check gggg-res read-only 0;            ok "check: without since the old policy still reads as a mismatch" "$?" "1"
printf '{"timestamp":"%s","type":"turn_context","payload":{"sandbox_policy":{"type":"read-only"}}}\n' "$TS_NEW" >> "$CODEX_HOME/sessions/2026/10/03/rollout-2026-10-03T10-00-00-gggg-res.jsonl"
bash "$RP" check gggg-res read-only "$(( $(date +%s) - 5 ))"; ok "check: a fresh policy for this run is honoured" "$?" "0"

# (generated-start-script wiring is asserted in test-new-session-backend.sh)

finish "codex-resume-pin"
