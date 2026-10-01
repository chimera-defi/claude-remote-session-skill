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
has(){ if printf '%s' "$2" | grep -q "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }

# Name-first, date last: px-<alias>-<MMDD-HHMM>.
out="$(bash "$NS" --dry-run some-very-long-project-name 2>/dev/null)"
has "remote-alias-id" "$out" 'REMOTE_NAME=px-svlpn-[0-9]\{4\}-[0-9]\{4\}'
has "tmux-underscore" "$out" 'SESSION=px_svlpn-[0-9]\{4\}-[0-9]\{4\}'
has "service-name"    "$out" 'SERVICE=.*/px-svlpn-[0-9]\{4\}-[0-9]\{4\}\.service'
out2="$(bash "$NS" --dry-run some-proj --alias myproj 2>/dev/null)"
has "explicit-alias"  "$out2" 'REMOTE_NAME=px-myproj-[0-9]\{4\}-[0-9]\{4\}'
# this repo's folder contains "claude-remote" but is NOT alias-protected (only CRSS_ALIAS_PROTECT_NAMES matches are): it shortens
out3="$(bash "$NS" --dry-run claude-remote-session-skill 2>/dev/null)"
has "claude-remote-substring-shortens" "$out3" 'REMOTE_NAME=px-crss-[0-9]\{4\}-[0-9]\{4\}'
# regression: a folder named `sessions`/`workspace`/`auto` must be spawnable (the keyword is a TYPE only as the 2nd positional)
out4="$(bash "$NS" --dry-run sessions 2>/dev/null)"
has "folder-named-sessions" "$out4" 'REMOTE_NAME=px-sessions-[0-9]\{4\}-[0-9]\{4\}'
# and the type positional still works after the folder
out5="$(bash "$NS" --dry-run myproj workspace 2>/dev/null)"
has "type-positional-after-folder" "$out5" 'REMOTE_NAME=px-myproj-[0-9]\{4\}-[0-9]\{4\}'

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

# ── Real (non-dry-run) collision suffix must also be "-2", not "-3" ──────────
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
  if printf '%s' "$rout" | grep -q -- '-0101-0000-3'; then fail=$((fail+1)); echo "FAIL: real-collision-skipped-minus-2 — got -3 instead of -2"; else pass=$((pass+1)); fi
fi

# ── CLAUDE_SESSION_PROFILE: selects the tool footprint AND a default model. builder/copywriter use a bare alias
# (auto-tracks the tier); orchestrator is pinned (see new-session.sh Model selection). Explicit CLAUDE_SESSION_MODEL
# always overrides. Unknown profile -> orchestrator + warning. ──
outp="$(bash "$NS" --dry-run profile-default 2>/dev/null)"
has "profile-default-orchestrator"   "$outp" 'PROFILE=orchestrator'
has "orchestrator-default-model-opus5-5" "$outp" '^MODEL=claude-opus-5-5$'
has "orchestrator-model-src-profile"  "$outp" '^MODEL_SRC=profile-default$'
has "orchestrator-cache-flag-only"   "$outp" 'CLAUDE_EXTRA_FLAGS=--exclude-dynamic-system-prompt-sections$'
# a role-default bare alias is intended (auto-upgrade): no warning
errp="$(bash "$NS" --dry-run profile-default 2>&1 1>/dev/null)"
if printf '%s' "$errp" | grep -q 'moving model alias'; then fail=$((fail+1)); echo "FAIL: role-default-model-should-not-warn"; else pass=$((pass+1)); fi

outb="$(CLAUDE_SESSION_PROFILE=builder bash "$NS" --dry-run profile-builder 2>/dev/null)"
has "profile-builder"               "$outb" 'PROFILE=builder'
has "builder-default-model-sonnet"  "$outb" '^MODEL=sonnet$'
has "builder-has-tools-allowlist"   "$outb" 'CLAUDE_EXTRA_FLAGS=.*--tools Bash,Read,'

outc="$(CLAUDE_SESSION_PROFILE=copywriter bash "$NS" --dry-run profile-copywriter 2>/dev/null)"
has "profile-copywriter"             "$outc" 'PROFILE=copywriter'
has "copywriter-default-model-haiku" "$outc" '^MODEL=haiku$'
has "copywriter-has-tools-allowlist" "$outc" 'CLAUDE_EXTRA_FLAGS=.*--tools Bash,Read,'

# explicit CLAUDE_SESSION_MODEL overrides the profile default; a PINNED id must not warn
outo="$(CLAUDE_SESSION_MODEL=claude-opus-4-8 CLAUDE_SESSION_PROFILE=builder bash "$NS" --dry-run profile-override 2>/dev/null)"
has "explicit-model-overrides-default" "$outo" '^MODEL=claude-opus-4-8$'
has "explicit-model-src-explicit"      "$outo" '^MODEL_SRC=explicit$'
erro="$(CLAUDE_SESSION_MODEL=claude-opus-4-8 bash "$NS" --dry-run profile-override 2>&1 1>/dev/null)"
if printf '%s' "$erro" | grep -q 'moving model alias'; then fail=$((fail+1)); echo "FAIL: pinned-id-should-not-warn"; else pass=$((pass+1)); fi
# an EXPLICIT bare alias (one-off spawn) SHOULD warn
erra="$(CLAUDE_SESSION_MODEL=opus bash "$NS" --dry-run profile-explicit-alias 2>&1 1>/dev/null)"
has "explicit-bare-alias-warns"        "$erra" 'moving model alias'

# unknown value: stdout falls back to orchestrator, stderr carries the warning
outu="$(CLAUDE_SESSION_PROFILE=bogus bash "$NS" --dry-run profile-bogus 2>/dev/null)"
has "unknown-profile-falls-back"   "$outu" 'PROFILE=orchestrator'
erru="$(CLAUDE_SESSION_PROFILE=bogus bash "$NS" --dry-run profile-bogus 2>&1 1>/dev/null)"
has "unknown-profile-warns"        "$erru" 'unknown CLAUDE_SESSION_PROFILE'

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

# ── Unknown TYPE positional must warn and fall back, not silently redirect ──
# ── Unknown TYPE positional must warn and fall back (review): a typo like `workspce` was silently treated as
# `sessions`, redirecting a repo spawn into .sessions/ (cf. CLAUDE_SESSION_PROFILE validation). ──
outty="$(bash "$NS" --dry-run type-typo-test workspce 2>/dev/null)"
has "unknown-type-falls-back-to-sessions" "$outty" 'SCRIPT=.*/.local/bin/px-type-typo-test-'
erty="$(bash "$NS" --dry-run type-typo-test workspce 2>&1 1>/dev/null)"
has "unknown-type-warns" "$erty" "unknown session type 'workspce'"
# a recognized TYPE must NOT warn
ertyok="$(bash "$NS" --dry-run type-ok-test workspace 2>&1 1>/dev/null)"
if printf '%s' "$ertyok" | grep -q 'unknown session type'; then fail=$((fail+1)); echo "FAIL: known-type-should-not-warn"; else pass=$((pass+1)); fi

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
# Guard the rationale too, so the comment can't contradict the code.
ok "builder-tools-comment-not-stale" \
  "$(grep -c 'SendUserFile, advisor, ReportFindings' "$NS")" "0"

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
if printf '%s' "$recA" | grep -q -- '--set-default'; then
  fail=$((fail+1)); echo "FAIL: alias-alone-must-not-request-persist — got '$recA'"
else pass=$((pass+1)); fi

# --set-default-alias IS the opt-in and must forward --set-default.
recB="$(rec_args_for --alias renamed --set-default-alias)"
has "set-default-alias-forwards-flag" "$recB" 'set-default'

finish "new-session names"
