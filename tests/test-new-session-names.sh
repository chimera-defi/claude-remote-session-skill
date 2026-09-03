#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NS="$HERE/../scripts/new-session.sh"
# Expose the helper as `session-alias` (no .sh) via a throwaway bin dir on PATH,
# so new-session's `command -v session-alias` resolves it — WITHOUT polluting the
# repo's scripts/ dir with a stray symlink.
BIN="$(mktemp -d)"; trap 'rm -rf "$BIN"' EXIT
ln -sf "$HERE/../scripts/session-alias.sh" "$BIN/session-alias"
export PATH="$BIN:$PATH"
STORE="$(mktemp)"; rm -f "$STORE"; export SESSION_ALIAS_STORE="$STORE"
pass=0; fail=0
has(){ if printf '%s' "$2" | grep -q "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }

# Name-first, date last: ah-<alias>-<MMDD-HHMM>.
out="$(bash "$NS" --dry-run some-very-long-project-name 2>/dev/null)"
has "remote-alias-id" "$out" 'REMOTE_NAME=ah-svlpn-[0-9]\{4\}-[0-9]\{4\}'
has "tmux-underscore" "$out" 'SESSION=ah_svlpn-[0-9]\{4\}-[0-9]\{4\}'
has "service-name"    "$out" 'SERVICE=.*/ah-svlpn-[0-9]\{4\}-[0-9]\{4\}\.service'
out2="$(bash "$NS" --dry-run some-proj --alias myproj 2>/dev/null)"
has "explicit-alias"  "$out2" 'REMOTE_NAME=ah-myproj-[0-9]\{4\}-[0-9]\{4\}'
# this repo's folder contains "claude-remote" but is NOT alias-protected (only
# openclaw|hermes are); it shortens to its acronym like any long dev folder.
out3="$(bash "$NS" --dry-run claude-remote-session-skill 2>/dev/null)"
has "claude-remote-substring-shortens" "$out3" 'REMOTE_NAME=ah-crss-[0-9]\{4\}-[0-9]\{4\}'
# regression: a folder literally named `sessions`/`workspace`/`auto` must be
# spawnable — the type keyword is only a TYPE as the SECOND positional.
out4="$(bash "$NS" --dry-run sessions 2>/dev/null)"
has "folder-named-sessions" "$out4" 'REMOTE_NAME=ah-sessions-[0-9]\{4\}-[0-9]\{4\}'
# and the type positional still works after the folder
out5="$(bash "$NS" --dry-run myproj workspace 2>/dev/null)"
has "type-positional-after-folder" "$out5" 'REMOTE_NAME=ah-myproj-[0-9]\{4\}-[0-9]\{4\}'

# Regression: spawning the same folder twice inside the same clock-minute must
# NOT collide on SESSION/REMOTE_NAME. Simulate the collision with a live tmux
# session under the name the first call would resolve to, then confirm a
# second resolution for the same folder disambiguates instead of reusing it
# (a silent reuse would make the second spawn's already-running guard exit
# without applying its own --alias/model, while still reporting success).
if command -v tmux >/dev/null 2>&1; then
  # Freeze `date +%m%d-%H%M` to a fixed value for both resolutions below via a
  # stub on PATH. Without this, the two `new-session.sh` calls could straddle
  # a real minute boundary and land on naturally-different IDs instead of
  # exercising the -2 suffix, making the strict assertion below flaky
  # (caught in review).
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
  has "same-minute-collision-suffixed" "$second_session" '^ah_cft-0101-0000-2$'
fi

# ── Real (non-dry-run) collision suffix must also be "-2", not "-3" ──────────
# (found by Codex review on this PR): the bounded mkdir-lock loop added above
# built the next candidate name AFTER incrementing n instead of before, so the
# first retry past a live base name jumped straight to "-2"+1="-3", skipping
# "-2" — inconsistent with the --dry-run branch (asserted above) and the
# documented collision-suffix numbering. The mkdir-lock path only runs for a
# REAL (non-dry-run) spawn, so exercise it directly: stub `date` (deterministic
# ID) and `systemctl` (no-op success — the generated script's actual tmux/
# claude kickoff runs only via a real systemd ExecStart, which this sandbox
# has no session bus for; stubbing it out tests the naming/locking logic
# in new-session.sh itself without needing a working systemd --user).
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
  # Base candidate for a 18-char-or-under folder is the folder name as-is
  # (see the short-passthrough rule), so the pre-existing live session's name
  # is deterministic without needing a --dry-run probe first.
  tmux new-session -d -s ah_collide-real-test-0101-0000 2>/dev/null
  RSTORE="$(mktemp -u)"
  rout="$(PATH="$RSTUBBIN:$PATH" HOME="$RLOCKHOME" SESSION_ALIAS_STORE="$RSTORE" bash "$NS" collide-real-test 2>&1)"
  tmux kill-session -t ah_collide-real-test-0101-0000 2>/dev/null || true
  rm -rf "$RLOCKHOME" "$RSTUBBIN"
  has "real-collision-suffixed-minus-2" "$rout" 'ah-collide-real-test-0101-0000-2'
  if printf '%s' "$rout" | grep -q -- '-0101-0000-3'; then fail=$((fail+1)); echo "FAIL: real-collision-skipped-minus-2 — got -3 instead of -2"; else pass=$((pass+1)); fi
fi

# ── Spawn profile switch + per-role model default (CLAUDE_SESSION_PROFILE) ────
# A profile selects BOTH the tool footprint AND a default model. builder/
# copywriter use a bare alias so those role defaults auto-track the latest
# release for their tier; orchestrator is pinned to claude-opus-5 (2026-08-27,
# see scripts/new-session.sh's Model selection comment for why). An explicit
# CLAUDE_SESSION_MODEL always overrides. Unknown profile → orchestrator + warning.
outp="$(bash "$NS" --dry-run profile-default 2>/dev/null)"
has "profile-default-orchestrator"   "$outp" 'PROFILE=orchestrator'
has "orchestrator-default-model-opus5" "$outp" '^MODEL=claude-opus-5$'
has "orchestrator-model-src-profile"  "$outp" '^MODEL_SRC=profile-default$'
has "orchestrator-cache-flag-only"   "$outp" 'CLAUDE_EXTRA_FLAGS=--exclude-dynamic-system-prompt-sections$'
# A role-default bare alias is INTENDED (auto-upgrade) → must NOT emit the warning.
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

# Explicit CLAUDE_SESSION_MODEL overrides the profile default; a PINNED id (not a
# bare alias) must NOT warn.
outo="$(CLAUDE_SESSION_MODEL=claude-opus-4-8 CLAUDE_SESSION_PROFILE=builder bash "$NS" --dry-run profile-override 2>/dev/null)"
has "explicit-model-overrides-default" "$outo" '^MODEL=claude-opus-4-8$'
has "explicit-model-src-explicit"      "$outo" '^MODEL_SRC=explicit$'
erro="$(CLAUDE_SESSION_MODEL=claude-opus-4-8 bash "$NS" --dry-run profile-override 2>&1 1>/dev/null)"
if printf '%s' "$erro" | grep -q 'moving model alias'; then fail=$((fail+1)); echo "FAIL: pinned-id-should-not-warn"; else pass=$((pass+1)); fi
# An EXPLICIT bare alias (a one-off spawn) SHOULD warn — the operator may want a pin.
erra="$(CLAUDE_SESSION_MODEL=opus bash "$NS" --dry-run profile-explicit-alias 2>&1 1>/dev/null)"
has "explicit-bare-alias-warns"        "$erra" 'moving model alias'

# Unknown value: stdout falls back to orchestrator, stderr carries the warning.
outu="$(CLAUDE_SESSION_PROFILE=bogus bash "$NS" --dry-run profile-bogus 2>/dev/null)"
has "unknown-profile-falls-back"   "$outu" 'PROFILE=orchestrator'
erru="$(CLAUDE_SESSION_PROFILE=bogus bash "$NS" --dry-run profile-bogus 2>&1 1>/dev/null)"
has "unknown-profile-warns"        "$erru" 'unknown CLAUDE_SESSION_PROFILE'

# ── --dry-run must bypass the preflight capacity gate (found in nightly review) ──
# --dry-run is documented as a pure, side-effect-free preview ("print the
# resolved names and exit — no session spawned, store untouched"), but the
# capacity gate ran unconditionally before DRYRUN was consulted, so a --dry-run
# on a genuinely (or artificially, via NEW_SESSION_MIN_AVAIL_MB) low-memory host
# hard-refused with no name output at all unless --force was also passed —
# defeating the "check what this would resolve to" use case --dry-run exists
# for. A dry-run spawns nothing and consumes no RAM, so it never needs this gate.
outcap="$(NEW_SESSION_MIN_AVAIL_MB=999999999 bash "$NS" --dry-run capacity-dry-run 2>/dev/null)"
has "dry-run-bypasses-capacity-gate" "$outcap" 'REMOTE_NAME=ah-capacity-dry-run-'
capexit=0; NEW_SESSION_MIN_AVAIL_MB=999999999 bash "$NS" --dry-run capacity-dry-run >/dev/null 2>&1 || capexit=$?
ok "dry-run-bypasses-capacity-gate-exit0" "$capexit" "0"
# Sanity: a real (non-dry-run) spawn on the same low-memory condition must
# still refuse — the gate itself isn't disabled, only bypassed for --dry-run.
capexit2=0; NEW_SESSION_MIN_AVAIL_MB=999999999 bash "$NS" capacity-real-run-test >/dev/null 2>&1 || capexit2=$?
ok "non-dry-run-capacity-gate-still-refuses" "$capexit2" "1"

# ── Unknown TYPE positional must warn and fall back, not silently redirect ──
# (found in nightly review): only "auto" and "workspace" were explicitly
# checked; any other value (e.g. a typo like `workspce`) fell straight into
# the `else` branch and was silently treated as `sessions`, redirecting a
# repo-intended spawn into .sessions/ with zero diagnostic — inconsistent with
# how CLAUDE_SESSION_PROFILE validates unknown values (warn + fall back).
outty="$(bash "$NS" --dry-run type-typo-test workspce 2>/dev/null)"
has "unknown-type-falls-back-to-sessions" "$outty" 'SCRIPT=.*/.local/bin/ah-type-typo-test-'
erty="$(bash "$NS" --dry-run type-typo-test workspce 2>&1 1>/dev/null)"
has "unknown-type-warns" "$erty" "unknown session type 'workspce'"
# A recognized TYPE must NOT warn (no false positive on the new validation).
ertyok="$(bash "$NS" --dry-run type-ok-test workspace 2>&1 1>/dev/null)"
if printf '%s' "$ertyok" | grep -q 'unknown session type'; then fail=$((fail+1)); echo "FAIL: known-type-should-not-warn"; else pass=$((pass+1)); fi

# ── Session-name lock loop must not hang forever on a persistent mkdir failure ──
# (found in nightly review): the mkdir-based same-minute-collision lock had no
# bound — a persistent (non-transient) mkdir failure (LOCKROOT on a read-only/
# full filesystem, or a plain file occupying that path) made every iteration
# fail identically forever, spinning with no sleep, no cap, and no diagnostic.
# Simulate a persistent failure by putting a plain FILE where LOCKROOT (a
# directory) is expected, under an isolated HOME so this can't collide with a
# real lock dir.
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

# BUILDER_TOOLS must keep `advisor`. --tools is an EXHAUSTIVE allowlist that
# gates deferred built-ins too, so dropping `advisor` here makes it unreachable
# ENTIRELY for a `--profile builder` session — which presents as "advisor is
# broken" rather than "never allowlisted", with no error and no warning.
#
# This already regressed once and was caught only in production: the DEPLOYED
# ~/.local/bin/new-session was hand-patched to re-add `advisor` (2026-08-27,
# cf. its .pre-advisor-readd backup) but the fix was never landed back here, so
# the repo stayed wrong and any redeploy-from-source would silently undo it.
# Nothing tested the allowlist, which is why the drift survived. It does now.
builder_tools_line="$(grep -m1 '^BUILDER_TOOLS=' "$NS")"
has "builder-tools-keeps-advisor" "$builder_tools_line" ',advisor"$'
# Guard the rationale too, so the comment can't contradict the code.
ok "builder-tools-comment-not-stale" \
  "$(grep -c 'SendUserFile, advisor, ReportFindings' "$NS")" "0"

# ── `new-session --alias` must NOT mutate the folder's stored default ─────────
# Operator directive 2026-09-03, after clearing 11 drifted entries: --alias is
# PER-SPAWN; persisting is opt-in via --set-default-alias.
#
# Testing this through --dry-run would be VACUOUS: --dry-run already passes
# --no-save, so the store is untouched either way and the assertion would pass
# even against the buggy auto-persist build (verified). So instead stub
# session-alias with a recorder and assert on the flags new-session actually
# hands it -- that is the plumbing that decides persistence on a real spawn.
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

echo "new-session names: pass=$pass fail=$fail"; [ "$fail" -eq 0 ]
