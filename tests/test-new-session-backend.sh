#!/usr/bin/env bash
# Backend selection coverage for new-session.sh. Codex support must be a
# first-class backend, not a Claude profile variant.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
NS="$HERE/../scripts/new-session.sh"

has(){ if printf '%s' "$2" | grep -qE -- "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — pattern not found: $3 in: $2"; fi; }
not_has(){ if printf '%s' "$2" | grep -qE -- "$3"; then fail=$((fail+1)); echo "FAIL: $1 — unexpected pattern: $3 in: $2"; else pass=$((pass+1)); fi; }

isolate_overlay
export CRSS_SESSION_PREFIX=px
export CRSS_LEGACY_PREFIXES=oldhost

BIN="$(mktemp -d)"
WORKHOME="$(mktemp -d)"
trap 'rm -rf "$BIN" "$WORKHOME"' EXIT
ln -sf "$HERE/../scripts/session-alias.sh" "$BIN/session-alias"
cat > "$BIN/systemctl" <<'CTLEOF'
#!/usr/bin/env bash
exit 0
CTLEOF
chmod +x "$BIN/systemctl"
export PATH="$BIN:$PATH"
STORE="$(mktemp)"; rm -f "$STORE"; export SESSION_ALIAS_STORE="$STORE"

# Default remains Claude unless overridden.
out="$(HOME="$WORKHOME" bash "$NS" --dry-run backend-default 2>/dev/null)"
has "default-backend-claude" "$out" '^BACKEND=claude$'
has "default-model-claude" "$out" '^MODEL=claude-opus-5-5$'

# Generic config/env default can select Codex.
out_env="$(HOME="$WORKHOME" CRSS_SESSION_BACKEND=codex bash "$NS" --dry-run backend-env 2>/dev/null)"
has "env-backend-codex" "$out_env" '^BACKEND=codex$'
has "env-codex-model-generic" "$out_env" '^MODEL=codex$'
has "env-codex-model-src" "$out_env" '^MODEL_SRC=backend-default$'

# --backend overrides CRSS_SESSION_BACKEND for a single spawn.
out_flag="$(HOME="$WORKHOME" CRSS_SESSION_BACKEND=claude bash "$NS" --dry-run backend-flag --backend codex 2>/dev/null)"
has "flag-backend-codex" "$out_flag" '^BACKEND=codex$'

# Unknown backend values are rejected, not silently reinterpreted as folders,
# types, profiles, or Claude.
bad="$(HOME="$WORKHOME" bash "$NS" --dry-run backend-bad --backend llama 2>&1)"; bad_rc=$?
has "unknown-backend-message" "$bad" "unknown backend 'llama'"
ok  "unknown-backend-exit2" "$bad_rc" "2"
not_has "unknown-backend-no-dryrun-output" "$bad" '^SESSION='

# Codex model display comes from CRSS_CODEX_ARGS when -m/--model is present.
out_model="$(HOME="$WORKHOME" CRSS_CODEX_ARGS='-m test-codex-model -s read-only -a never' bash "$NS" --dry-run backend-model --backend codex 2>/dev/null)"
has "codex-model-from-short-m" "$out_model" '^MODEL=test-codex-model$'
has "codex-args-visible" "$out_model" '^CODEX_ARGS=-m test-codex-model -s read-only -a never$'

out_model2="$(HOME="$WORKHOME" CRSS_CODEX_ARGS='--model other-codex-model --sandbox read-only --ask-for-approval never' bash "$NS" --dry-run backend-model2 --backend codex 2>/dev/null)"
has "codex-model-from-long-model" "$out_model2" '^MODEL=other-codex-model$'

# Real (stubbed-systemd) spawn writes a Codex start script with Codex command
# plumbing and without Claude-only flags or project-skill symlink setup.
CODEX_STUB="$BIN/codex-stub"
cat > "$CODEX_STUB" <<'CODEXEOF'
#!/usr/bin/env bash
printf 'stub codex %s\n' "$*"
CODEXEOF
chmod +x "$CODEX_STUB"

SPAWN_HOME="$(mktemp -d)"
mkdir -p "$SPAWN_HOME/.sessions/backend-start"
DATESTUB="$(mktemp -d)"
cat > "$DATESTUB/date" <<'DATEEOF'
#!/usr/bin/env bash
case "$1" in
  +%m%d-%H%M) echo "0101-0000" ;;
  *) exec /usr/bin/env date "$@" ;;
esac
DATEEOF
chmod +x "$DATESTUB/date"
TOUCH_LOG="$SPAWN_HOME/touch.log"
export TOUCH_LOG
cat > "$DATESTUB/touch" <<'TOUCHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TOUCH_LOG"
exit 0
TOUCHEOF
chmod +x "$DATESTUB/touch"

spawn_out="$(HOME="$SPAWN_HOME" PATH="$DATESTUB:$PATH" CRSS_CODEX_BIN="$CODEX_STUB" CRSS_CODEX_ARGS='-m stub-model -s read-only -a never' bash "$NS" --backend codex backend-start sessions --alias codexbe 2>&1)"
has "codex-spawn-created" "$spawn_out" 'Session created: px-codexbe-0101-0000'
SCRIPT="$SPAWN_HOME/.local/bin/px-codexbe-0101-0000-start.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: codex-start-script-created — missing $SCRIPT"; fail=$((fail+1)); SCRIPT=/dev/null; }
script_text="$(cat "$SCRIPT" 2>/dev/null)"
has "script-records-backend" "$script_text" '^BACKEND=(["'\'']?)codex\1$'
has "script-records-model" "$script_text" '^MODEL=(["'\'']?)stub-model\1$'
has "script-invokes-codex-bin" "$script_text" "$CODEX_STUB"
has "script-invokes-codex-args" "$script_text" '-m stub-model -s read-only -a never'
has "script-pins-codex-thread" "$script_text" '.codex-thread'
has "script-reads-pin-via-helper" "$script_text" 'codex-resume-pin read-pin'
has "script-verifies-lane-before-resume" "$script_text" 'codex-resume-pin verify-lane'
has "script-helper-missing-fails-closed" "$script_text" 'FAIL=helper-missing'
has "script-fails-closed-logs-reason" "$script_text" 'event=resume-pin-fail-closed'
has "script-sandbox-resolved-inside-loop" "$(printf '%s' "$script_text" | awk '/while true; do/{w=1} w && /sandbox-of/{print "in-loop"; exit}')" 'in-loop'
has "script-resume-uses-array-argv" "$script_text" 'resume "\$PIN_ID" "\$\{CODEX_ARGS\[@\]\}"'
has "script-sets-stale-pin-aside" "$script_text" 'event=pin-stale'
not_has "script-no-pin-watcher" "$script_text" 'codex-resume-pin watch'
not_has "script-no-resume-args-subcommand" "$script_text" 'resume-args'
not_has "script-no-newline-argv" "$script_text" 'mapfile'
not_has "script-no-newest-discovery" "$script_text" 'codex-resume-pin latest'
has "script-trusts-runtime-workdir" "$script_text" 'trust_level=\\"trusted\\"'
not_has "script-no-claude-remote-control" "$script_text" '--remote-control'
not_has "script-no-claude-settings" "$script_text" '--settings'
not_has "script-no-skills-symlink" "$script_text" '\.claude/skills'

malicious_out="$(HOME="$SPAWN_HOME" PATH="$DATESTUB:$PATH" CRSS_CODEX_BIN="$CODEX_STUB" CRSS_CODEX_ARGS='-m $(touch /tmp/x) "quoted' bash "$NS" --backend codex backend-mal sessions --alias codexbad 2>&1)"
has "codex-malicious-spawn-created" "$malicious_out" 'Session created: px-codexbad-0101-0000'
MAL_SCRIPT="$SPAWN_HOME/.local/bin/px-codexbad-0101-0000-start.sh"
[ -f "$MAL_SCRIPT" ] || { echo "FAIL: codex-malicious-start-script-created — missing $MAL_SCRIPT"; fail=$((fail+1)); MAL_SCRIPT=/dev/null; }
if bash -n "$MAL_SCRIPT"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: codex-malicious-script-bash-n"; fi
not_has "codex-malicious-no-double-quoted-assignment" "$(cat "$MAL_SCRIPT" 2>/dev/null)" '^CODEX_ARGS="'
PREFIX="$(mktemp)"
sed -n '1,/^export PATH=/p' "$MAL_SCRIPT" > "$PREFIX"
if bash "$PREFIX"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: codex-malicious-prefix-executes-cleanly"; fi
[ ! -s "$TOUCH_LOG" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: codex-malicious-args-executed-command-substitution"; }
rm -f "$PREFIX"

# Quoted overlay args keep their grouping: -c 'k="a b"' must stay ONE argv word.
grp_out="$(HOME="$SPAWN_HOME" PATH="$DATESTUB:$PATH" CRSS_CODEX_BIN="$CODEX_STUB" CRSS_CODEX_ARGS="-m m1 -c 'k=\"a b\"'" bash "$NS" --backend codex backend-grp sessions --alias codexgrp 2>&1)"
has "codex-grouped-spawn-created" "$grp_out" 'Session created: px-codexgrp-0101-0000'
GRP_SCRIPT="$SPAWN_HOME/.local/bin/px-codexgrp-0101-0000-start.sh"
grp_n="$(bash -c "$(grep -m1 '^CODEX_ARGS=(' "$GRP_SCRIPT" 2>/dev/null); printf '%s\\n' \"\${CODEX_ARGS[@]}\"" | wc -l)"
ok "codex-grouped-args-count" "$grp_n" "4"
ok "codex-grouped-arg-intact" "$(bash -c "$(grep -m1 '^CODEX_ARGS=(' "$GRP_SCRIPT" 2>/dev/null); printf '[%s]' \"\${CODEX_ARGS[3]}\"")" '[k="a b"]'

finish "new-session-backend"
