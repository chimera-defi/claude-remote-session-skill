#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
isolate_overlay
# Fixture shape: configured prefix "px", legacy "oldhost".
export CRSS_SESSION_PREFIX=px
export CRSS_LEGACY_PREFIXES=oldhost
NS="$HERE/../scripts/new-session.sh"
# expose the helper as `session-alias` via a throwaway bin dir on PATH (no stray symlink in scripts/)
BIN="$(mktemp -d)"; trap 'rm -rf "$BIN"' EXIT
ln -sf "$HERE/../scripts/session-alias.sh" "$BIN/session-alias"
export PATH="$BIN:$PATH"
STORE="$(mktemp)"; rm -f "$STORE"; export SESSION_ALIAS_STORE="$STORE"
has(){ if grep -q "$3" <<<"$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }

# Name-first, date last: px-<alias>-<MMDD-HHMM>.
out="$(bash "$NS" --dry-run some-very-long-project-name 2>/dev/null)"
has "remote-alias-id" "$out" 'REMOTE_NAME=px-svlpn-[0-9]\{4\}-[0-9]\{4\}'
has "tmux-underscore" "$out" 'SESSION=px_svlpn-[0-9]\{4\}-[0-9]\{4\}'
has "service-name"    "$out" 'SERVICE=.*/px-svlpn-[0-9]\{4\}-[0-9]\{4\}\.service'
# regression: a folder named `sessions`/`workspace`/`auto` must be spawnable (the keyword is a TYPE only as the 2nd positional)
out4="$(bash "$NS" --dry-run sessions 2>/dev/null)"
has "folder-named-sessions" "$out4" 'REMOTE_NAME=px-sessions-[0-9]\{4\}-[0-9]\{4\}'

# Regression: spawning the same folder twice in one clock-minute must NOT collide on SESSION/REMOTE_NAME (a reuse would
# make the already-running guard skip the second spawn's --alias/model yet report success). Simulated with a live tmux
# session under the first name.
if command -v tmux >/dev/null 2>&1; then
  # freeze `date +%m%d-%H%M` via a PATH stub so the two calls can't straddle a minute boundary (flaky -2 suffix assertion)
  DATESTUB="$(mktemp -d)"
  cat > "$DATESTUB/date" <<'DATEEOF'
#!/usr/bin/env bash
case "$1" in
  +%m%d-%H%M) echo "0101-0000" ;;
  *) exec /usr/bin/env date "$@" ;;
esac
DATEEOF
  chmod +x "$DATESTUB/date"
  first="$(PATH="$DATESTUB:$PATH" bash "$NS" --dry-run collide-folder-test 2>/dev/null)"
  first_session="$(printf '%s' "$first" | sed -n 's/^SESSION=//p')"
  tmux new-session -d -s "$first_session" 2>/dev/null
  second="$(PATH="$DATESTUB:$PATH" bash "$NS" --dry-run collide-folder-test 2>/dev/null)"
  second_session="$(printf '%s' "$second" | sed -n 's/^SESSION=//p')"
  tmux kill-session -t "$first_session" 2>/dev/null || true
  rm -rf "$DATESTUB"
  if [ "$first_session" != "$second_session" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: same-minute collision — got identical SESSION '$second_session' twice"; fi
  has "same-minute-collision-suffixed" "$second_session" '^px_cft-0101-0000-2$'
fi

# Regression (PR #72): a name whose tmux session is DEAD but whose worktree is still registered (reaped-but-uncleaned)
# must also count as taken, else a new spawn silently inherits that dirty worktree. Only the worktree dir is created.
DATESTUB2="$(mktemp -d)"
cat > "$DATESTUB2/date" <<'DATEEOF'
#!/usr/bin/env bash
case "$1" in
  +%m%d-%H%M) echo "0101-0000" ;;
  *) exec /usr/bin/env date "$@" ;;
esac
DATEEOF
chmod +x "$DATESTUB2/date"
WTHOME="$(mktemp -d)"
mkdir -p "$WTHOME/.claude/worktrees/px-retained-wt-test-0101-0000"
retained="$(HOME="$WTHOME" PATH="$DATESTUB2:$PATH" bash "$NS" --dry-run retained-wt-test 2>/dev/null)"
rm -rf "$DATESTUB2" "$WTHOME"
has "retained-worktree-not-reused" "$retained" 'REMOTE_NAME=px-retained-wt-test-0101-0000-2'

# ── Real (non-dry-run) collision suffix must be "-2", not "-3" (Codex review): the mkdir-lock loop built the next
# candidate after incrementing n. Only a REAL spawn runs that path, so stub `date` and `systemctl` (no systemd bus here). ──
if command -v tmux >/dev/null 2>&1; then
  RLOCKHOME="$(mktemp -d)"
  mkdir -p "$RLOCKHOME/.claude"
  RSTUBBIN="$(mktemp -d)"
  cat > "$RSTUBBIN/date" <<'DATEEOF'
#!/usr/bin/env bash
case "$1" in
  +%m%d-%H%M) echo "0101-0000" ;;
  *) exec /usr/bin/env date "$@" ;;
esac
DATEEOF
  cat > "$RSTUBBIN/systemctl" <<'CTLEOF'
#!/usr/bin/env bash
exit 0
CTLEOF
  chmod +x "$RSTUBBIN/date" "$RSTUBBIN/systemctl"
  # an <=18-char folder name is its own base, so the live session's name is deterministic
  tmux new-session -d -s px_collide-real-test-0101-0000 2>/dev/null
  RSTORE="$(mktemp -u)"
  rout="$(PATH="$RSTUBBIN:$PATH" HOME="$RLOCKHOME" SESSION_ALIAS_STORE="$RSTORE" bash "$NS" collide-real-test 2>&1)"
  tmux kill-session -t px_collide-real-test-0101-0000 2>/dev/null || true
  rm -rf "$RLOCKHOME" "$RSTUBBIN"
  has "real-collision-suffixed-minus-2" "$rout" 'px-collide-real-test-0101-0000-2'
  if grep -q -- '-0101-0000-3' <<<"$rout"; then fail=$((fail+1)); echo "FAIL: real-collision-skipped-minus-2 — got -3 instead of -2"; else pass=$((pass+1)); fi
fi

# ── CLAUDE_SESSION_PROFILE: selects the tool footprint AND a default model. builder/copywriter use a bare alias
# (auto-tracks the tier); orchestrator is pinned (see new-session.sh Model selection). Explicit CLAUDE_SESSION_MODEL
# always overrides. Unknown profile -> orchestrator + warning. ──
outp="$(bash "$NS" --dry-run profile-default 2>/dev/null)"
has "profile-default-orchestrator"   "$outp" 'PROFILE=orchestrator'
has "orchestrator-default-model-opus5-5" "$outp" '^MODEL=claude-opus-5-5$'
has "orchestrator-model-src-profile"  "$outp" '^MODEL_SRC=profile-default$'
has "orchestrator-cache-flag-only"   "$outp" 'CLAUDE_EXTRA_FLAGS=--exclude-dynamic-system-prompt-sections$'

# owner: full tool set (no --tools allowlist, like orchestrator) but a Sonnet default, and no alias warning
outw="$(CLAUDE_SESSION_PROFILE=owner bash "$NS" --dry-run profile-owner 2>/dev/null)"
has "profile-owner"                 "$outw" 'PROFILE=owner'
has "owner-default-model-sonnet"    "$outw" '^MODEL=sonnet$'
has "owner-model-src-profile"       "$outw" '^MODEL_SRC=profile-default$'
hasre "owner-full-tool-set"           "$outw" 'CLAUDE_EXTRA_FLAGS=--exclude-dynamic-system-prompt-sections( --effort [a-z]+)?( --advisor [a-z0-9.-]+)?$'


outb="$(CLAUDE_SESSION_PROFILE=builder bash "$NS" --dry-run profile-builder 2>/dev/null)"
has "profile-builder"               "$outb" 'PROFILE=builder'
has "builder-default-model-sonnet"  "$outb" '^MODEL=sonnet$'
has "builder-has-tools-allowlist"   "$outb" 'CLAUDE_EXTRA_FLAGS=.*--tools Bash,Read,'


# explicit CLAUDE_SESSION_MODEL overrides the profile default; a PINNED id must not warn
outo="$(CLAUDE_SESSION_MODEL=claude-opus-4-8 CLAUDE_SESSION_PROFILE=builder bash "$NS" --dry-run profile-override 2>/dev/null)"
has "explicit-model-overrides-default" "$outo" '^MODEL=claude-opus-4-8$'
has "explicit-model-src-explicit"      "$outo" '^MODEL_SRC=explicit$'
# an EXPLICIT bare alias (one-off spawn) SHOULD warn
erra="$(CLAUDE_SESSION_MODEL=opus bash "$NS" --dry-run profile-explicit-alias 2>&1 1>/dev/null)"
has "explicit-bare-alias-warns"        "$erra" 'moving model alias'

# unknown value: stdout falls back to orchestrator, stderr carries the warning
outu="$(CLAUDE_SESSION_PROFILE=bogus bash "$NS" --dry-run profile-bogus 2>/dev/null)"
has "unknown-profile-falls-back"   "$outu" 'PROFILE=orchestrator'
erru="$(CLAUDE_SESSION_PROFILE=bogus bash "$NS" --dry-run profile-bogus 2>&1 1>/dev/null)"
has "unknown-profile-warns"        "$erru" 'unknown CLAUDE_SESSION_PROFILE'

# Hub launchers must carry the consult prompt in every Claude path: pinned resume,
# --continue relaunch, and fresh launch. Owner/orchestrator keep their existing
# full-tool flag shape and do not inherit the hub append prompt.
GEN_HOME="$(mktemp -d)"
GEN_BIN="$(mktemp -d)"
cat > "$GEN_BIN/date" <<'DATEEOF'
#!/usr/bin/env bash
case "$1" in
  +%m%d-%H%M) echo "0101-0000" ;;
  *) exec /usr/bin/env date "$@" ;;
esac
DATEEOF
cat > "$GEN_BIN/systemctl" <<'CTLEOF'
#!/usr/bin/env bash
exit 0
CTLEOF
chmod +x "$GEN_BIN/date" "$GEN_BIN/systemctl"
GEN_STORE="$(mktemp -u)"
gen_out="$(HOME="$GEN_HOME" PATH="$GEN_BIN:$PATH" SESSION_ALIAS_STORE="$GEN_STORE" CLAUDE_SESSION_PROFILE=hub bash "$NS" hub-script sessions --alias hubscript 2>&1)"
has "hub-script-spawn-created" "$gen_out" 'Session created: px-hubscript-0101-0000'
hub_script="$GEN_HOME/.local/bin/px-hubscript-0101-0000-start.sh"
isfile "hub-start-script-created" "$hub_script"
hub_script_text="$(cat "$hub_script" 2>/dev/null)"
has "hub-script-records-profile" "$hub_script_text" 'PROFILE=hub'
has "hub-script-records-model" "$hub_script_text" 'MODEL=sonnet'
ok "hub-script-has-append-in-three-claude-invocations" "$(printf '%s\n' "$hub_script_text" | grep -c -- '--append-system-prompt')" "3"
ok "hub-script-has-resume-append" "$(printf '%s\n' "$hub_script_text" | grep -- '--resume "$RESUME_ID"' | grep -c -- '--append-system-prompt')" "1"
ok "hub-script-has-continue-append" "$(printf '%s\n' "$hub_script_text" | grep -- '--continue' | grep -c -- '--append-system-prompt')" "1"
ok "hub-script-has-fresh-append" "$(printf '%s\n' "$hub_script_text" | grep -v -- '--resume' | grep -v -- '--continue' | grep -c -- '--append-system-prompt')" "1"
has "hub-prompt-written-next-to-script" "$(ls "$GEN_HOME/.local/bin" 2>/dev/null)" 'px-hubscript-0101-0000-start-hub-consult-prompt.txt'

GEN_STORE_OWNER="$(mktemp -u)"
owner_gen="$(HOME="$GEN_HOME" PATH="$GEN_BIN:$PATH" SESSION_ALIAS_STORE="$GEN_STORE_OWNER" CLAUDE_SESSION_PROFILE=owner bash "$NS" owner-script sessions --alias ownerscript 2>&1)"
has "owner-script-spawn-created" "$owner_gen" 'Session created: px-ownerscript-0101-0000'
owner_script_text="$(cat "$GEN_HOME/.local/bin/px-ownerscript-0101-0000-start.sh" 2>/dev/null)"
hasnt "owner-script-no-hub-prompt" "$owner_script_text" '--append-system-prompt'

GEN_STORE_ORCH="$(mktemp -u)"
orch_gen="$(HOME="$GEN_HOME" PATH="$GEN_BIN:$PATH" SESSION_ALIAS_STORE="$GEN_STORE_ORCH" bash "$NS" orch-script sessions --alias orchscript 2>&1)"
has "orchestrator-script-spawn-created" "$orch_gen" 'Session created: px-orchscript-0101-0000'
orch_script_text="$(cat "$GEN_HOME/.local/bin/px-orchscript-0101-0000-start.sh" 2>/dev/null)"
hasnt "orchestrator-script-no-hub-prompt" "$orch_script_text" '--append-system-prompt'
rm -rf "$GEN_HOME" "$GEN_BIN"

# ── --dry-run must bypass the preflight capacity gate (found in review) ──
# ── --dry-run must bypass the capacity gate (review): a pure preview was hard-refusing on a low-memory host
# (NEW_SESSION_MIN_AVAIL_MB) with no name output, though it spawns nothing. ──
outcap="$(NEW_SESSION_MIN_AVAIL_MB=999999999 bash "$NS" --dry-run capacity-dry-run 2>/dev/null)"
has "dry-run-bypasses-capacity-gate" "$outcap" 'REMOTE_NAME=px-capacity-dry-run-'
capexit=0; NEW_SESSION_MIN_AVAIL_MB=999999999 bash "$NS" --dry-run capacity-dry-run >/dev/null 2>&1 || capexit=$?
ok "dry-run-bypasses-capacity-gate-exit0" "$capexit" "0"
# sanity: a real spawn under the same condition still refuses (gate bypassed only for --dry-run)
capexit2=0; NEW_SESSION_MIN_AVAIL_MB=999999999 bash "$NS" capacity-real-run-test >/dev/null 2>&1 || capexit2=$?
ok "non-dry-run-capacity-gate-still-refuses" "$capexit2" "1"

# ── Positional validation: rejected (exit 2) BEFORE any side effect, never silently reinterpreted ──
# Unknown TYPE (a typo like `workspce` used to be silently treated as `sessions`).
erty="$(bash "$NS" --dry-run type-typo-test workspce 2>&1)"; rcty=$?
has "unknown-type-rejected" "$erty" "unknown session type 'workspce'"
ok  "unknown-type-exit2" "$rcty" "2"
hasnt "unknown-type-no-names" "$erty" "SESSION="
# Exact repro of the doubled-workdir incident: a directory as the FIRST positional, a name as the second.
erdir="$(bash "$NS" --dry-run /nonexistent-crss-dir fleet-v2 --alias fleet-v2 2>&1)"; rcdir=$?
has "abs-foldername-rejected" "$erdir" "must be a bare name"
ok  "abs-foldername-exit2" "$rcdir" "2"
hasnt "abs-foldername-no-names" "$erdir" "SESSION="
for badname in "a/b" "." ".." ""; do
  erbad="$(bash "$NS" --dry-run "$badname" 2>&1)"; rcbad=$?
  ok "bad-foldername-exit2[$badname]" "$rcbad" "2"
  hasnt "bad-foldername-no-names[$badname]" "$erbad" "SESSION="
done
erx="$(bash "$NS" --dry-run a workspace extra 2>&1)"; rcx=$?
has "extra-positional-rejected" "$erx" "too many positional"
ok  "extra-positional-exit2" "$rcx" "2"
# a real (non-dry-run) bad foldername must not create anything either
SIDE="$(mktemp -d)"; HOME="$SIDE" bash "$NS" /abs/dir fleet >/dev/null 2>&1; rcside=$?
ok  "bad-foldername-real-run-exit2" "$rcside" "2"
ok  "bad-foldername-no-side-effects" "$(find "$SIDE" -mindepth 1 | wc -l | tr -d ' ')" "0"
rm -rf "$SIDE"

# ── Session-name lock loop must not hang forever on a persistent mkdir failure ──
# ── Session-name lock loop must not hang on a persistent mkdir failure (review): previously unbounded, no sleep, no
# diagnostic. Simulated with a plain FILE where LOCKROOT should be, under an isolated HOME. ──
if command -v tmux >/dev/null 2>&1; then
  LOCKHOME="$(mktemp -d)"
  mkdir -p "$LOCKHOME/.claude"
  touch "$LOCKHOME/.claude/session-spawn-locks"
  lockerr=""
  lockexit=0
  lockerr="$(HOME="$LOCKHOME" SESSION_ALIAS_STORE="$(mktemp -u)" timeout 15 bash "$NS" lock-persistent-fail-test 2>&1 1>/dev/null)" || lockexit=$?
  rm -rf "$LOCKHOME"
  ok "lock-persistent-failure-bounded-exit1" "$lockexit" "1"
  has "lock-persistent-failure-diagnostic" "$lockerr" 'could not claim a session-name lock'
fi

# BUILDER_TOOLS must keep `advisor`: --tools is an exhaustive allowlist, so dropping it makes advisor unreachable for
# `--profile builder` with no error. This regressed once (deployed copy hand-patched, repo never fixed; a redeploy
# would undo it) because nothing tested the allowlist.
builder_tools_line="$(grep -m1 '^BUILDER_TOOLS=' "$NS")"
has "builder-tools-keeps-advisor" "$builder_tools_line" ',advisor"$'

# ── `new-session --alias` must NOT mutate the folder's stored default ─────────
# Policy: --alias is PER-SPAWN; persisting is opt-in via --set-default-alias. Testing via --dry-run would be VACUOUS
# (it already passes --no-save), so stub session-alias with a recorder and assert on the flags new-session hands it.
REC="$(mktemp -d)"
cat > "$REC/session-alias" <<'RECEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$REC_ARGS"
# still resolve, so new-session gets a usable alias
for a in "$@"; do case "$prev" in -a|--alias) echo "$a"; exit 0;; esac; prev="$a"; done
echo stubalias
RECEOF
chmod +x "$REC/session-alias"

rec_args_for() {  # $@ = extra new-session flags; prints the args passed to session-alias
  REC_ARGS="$(mktemp)"; export REC_ARGS
  PATH="$REC:$PATH" bash "$NS" --dry-run recorder-folder "$@" >/dev/null 2>&1
  cat "$REC_ARGS"; rm -f "$REC_ARGS"; unset REC_ARGS
}

# A bare --alias spawn must NOT ask session-alias to persist.
recA="$(rec_args_for --alias taskname)"
has "alias-passed-through"            "$recA" 'alias taskname'
if grep -q -- '--set-default' <<<"$recA"; then
  fail=$((fail+1)); echo "FAIL: alias-alone-must-not-request-persist — got '$recA'"
else pass=$((pass+1)); fi

# --set-default-alias IS the opt-in and must forward --set-default.
recB="$(rec_args_for --alias renamed --set-default-alias)"
has "set-default-alias-forwards-flag" "$recB" 'set-default'

finish "new-session names"
