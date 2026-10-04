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
# The stub systemctl plays the start script's part: on `enable` it appends the verdict line the
# real script's log_start writes (a FRESH timestamp, since the spawn only trusts lines at or
# after its own t0). KSTUB_EVENT overrides the event; KSTUB_RAW supplies whole lines (tokens
# @NOW@ @OLD@ @SESS@ @UNIT@); KSTUB_NONE=1 writes nothing.
cat > "$BIN/systemctl" <<'CTLEOF'
#!/usr/bin/env bash
case " $* " in *" enable "*)
  [ -z "${KSTUB_NONE:-}" ] || exit 0
  unit="${!#}"; unit="${unit%.service}"; sess="${unit/#px-/px_}"; now="$(/usr/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$HOME/.sessions" 2>/dev/null
  if [ -n "${KSTUB_RAW:-}" ]; then
    printf '%s\n' "$KSTUB_RAW" | sed "s/@NOW@/$now/g; s/@OLD@/2020-01-01T00:00:00Z/g; s/@SESS@/$sess/g; s/@UNIT@/$unit/g" >> "$HOME/.sessions/session-starts.log" 2>/dev/null
  else
    printf '[%s] host=h session=%s remote=%s backend=codex workdir=w model=m profile=p event=%s\n' \
      "$now" "$sess" "$unit" "${KSTUB_EVENT:-started}" >> "$HOME/.sessions/session-starts.log" 2>/dev/null
  fi ;;
esac
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
  *) exec /usr/bin/date "$@" ;;
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

# K2: a codex spawn is reported created only from a fresh, well-formed `event=started` line.
CMD_LINE='[@NOW@] host=h session=@SESS@ remote=@UNIT@ backend=codex workdir=w model=m profile=p event'
k2() { # <label> <raw-lines or ''> [extra env assignments...]; sets kout/krc; the log may be pre-made in $KHOME
  local lbl="$1" raw="$2"; shift 2
  kout="$(env HOME="$KHOME" KSTUB_RAW="$raw" "$@" PATH="$DATESTUB:$PATH" CRSS_CODEX_BIN="$CODEX_STUB" CRSS_CODEX_ARGS='-m m -s read-only' bash "$NS" --backend codex "k-$lbl" sessions --alias "k$lbl" 2>&1)"; krc=$?
}
newk() { KHOME="$(mktemp -d)"; mkdir -p "$KHOME/.sessions/k-$1"; }
OLDL="${CMD_LINE/\[@NOW@\]/[@OLD@]}"
newk a; k2 a "${CMD_LINE}=started"
ok "K2: a fresh started exits 0" "$krc" "0"; has "K2: ...and says created" "$kout" 'Session created: px-ka-0101-0000'
newk b; k2 b "${OLDL}=started-FAIL-CLOSED reason=pin-invalid"$'\n'"${CMD_LINE}=started"
ok "K2: an older fail-closed plus a fresh started exits 0" "$krc" "0"
newk c; k2 c "${OLDL}=started"
ok "K2: only an older started exits 3" "$krc" "3"; has "K2: ...NOT verified" "$kout" 'start NOT verified for px-kc-0101-0000'
newk d; k2 d "[ts] host=h session=@SESS@ remote=@UNIT@ backend=codex workdir=w model=m profile=p event=started"
ok "K2: a malformed timestamp exits 3" "$krc" "3"; has "K2: ...NOT verified (malformed timestamp)" "$kout" 'start NOT verified'
newk e; k2 e "${CMD_LINE}=started-FAIL-CLOSED reason=helper-missing"
ok "K2: a fresh fail-closed exits 3" "$krc" "3"; has "K2: ...names the reason" "$kout" 'FAIL-CLOSED \(reason=helper-missing\)'; has "K2: ...and the session" "$kout" 'px-ke-0101-0000'
newk f; k2 f "${CMD_LINE}=started-UNVERIFIED-codex-not-running"
ok "K2: a fresh UNVERIFIED exits 3" "$krc" "3"
newk g; mkdir "$KHOME/.sessions/session-starts.log"; k2 g "${CMD_LINE}=started"
ok "K2: a log that is a directory exits 3" "$krc" "3"; has "K2: ...NOT verified, names journalctl" "$kout" 'NOT verified.*journalctl --user -u px-kg-0101-0000.service'
newk h; k2 h "${CMD_LINE}=already-running"
ok "K2: only already-running exits 3" "$krc" "3"
not_has "K2: a not-verified start never says is running" "$kout" 'is running'
newk i; mkdir -p "$KHOME/.sessions/k-claude"
kcl_out="$(HOME="$KHOME" KSTUB_NONE=1 PATH="$DATESTUB:$PATH" bash "$NS" k-claude sessions --alias kclaude 2>&1)"; kcl_rc=$?
ok "K2: a claude spawn with no verdict line is unchanged (exit 0)" "$kcl_rc" "0"
not_has "K2: ...and never says NOT verified" "$kcl_out" 'NOT verified'

# K'-task: an unverified start never gets a task delivered
newk t; mkdir -p "$KHOME/.local/bin"
cat > "$KHOME/.local/bin/tmux" <<'TT'
#!/usr/bin/env bash
echo "$*" >> "$HOME/tmux.calls"
case "$1" in has-session) exit 1 ;; esac
exit 0
TT
chmod +x "$KHOME/.local/bin/tmux"
kt_out="$(HOME="$KHOME" KSTUB_RAW="${CMD_LINE}=started-UNVERIFIED-codex-not-running" PATH="$KHOME/.local/bin:$DATESTUB:$PATH" CRSS_CODEX_BIN="$CODEX_STUB" CRSS_CODEX_ARGS='-m m -s read-only' bash "$NS" --backend codex k-t sessions --alias kt --task 'do the thing' 2>&1)"; kt_rc=$?
ok "K'-task: exit 3" "$kt_rc" "3"
ok "K'-task: no readiness polling or send reached tmux" "$(grep -cE 'send-keys|paste-buffer|load-buffer|capture-pane|display-message' "$KHOME/tmux.calls" 2>/dev/null)" "0"
has "K'-task: says the task was not sent and why" "$kt_out" 'task NOT sent: the lane.s start was not verified'
not_has "K'-task: never says is running" "$kt_out" 'is running'

# M: a verified start whose tmux session vanishes during task readiness
for mb in codex claude; do
  newk "m$mb"; mkdir -p "$KHOME/.local/bin"
  cat > "$KHOME/.local/bin/tmux" <<'TT'
#!/usr/bin/env bash
case "$1" in has-session) exit 1 ;; esac
exit 0
TT
  chmod +x "$KHOME/.local/bin/tmux"
  mkdir -p "$KHOME/.sessions/k-m$mb"
  mout="$(HOME="$KHOME" PATH="$KHOME/.local/bin:$DATESTUB:$PATH" CRSS_CODEX_BIN="$CODEX_STUB" CRSS_CODEX_ARGS='-m m -s read-only' KSTUB_RAW="${CMD_LINE}=started" bash "$NS" --backend "$mb" "k-m$mb" sessions --alias "km$mb" --task 'do the thing' 2>&1)"; mrc=$?
  ok "M($mb): a vanished tmux session exits 3" "$mrc" "3"
  has "M($mb): the message says was spawned" "$mout" 'was spawned, but the task was NOT delivered'
  not_has "M($mb): ...and never says is running" "$mout" 'is running'
  has "M($mb): the vanish names the backend" "$mout" "vanished while waiting for $mb"
done

# K1: run the generated start script against a stub tmux that plays the pane. display-message
# reports a shell, then $KT_CMD; capture-pane prints the file $KT_PANE (or fails if KT_CAPFAIL).
mkdir -p "$KHOME/.local/bin"
newk s; k1home="$KHOME"
HOME="$k1home" KSTUB_NONE=1 PATH="$DATESTUB:$PATH" CRSS_CODEX_BIN="$CODEX_STUB" CRSS_CODEX_ARGS='-m m -s read-only' bash "$NS" --backend codex k-s sessions --alias kfc >/dev/null 2>&1
KSCRIPT="$k1home/.local/bin/px-kfc-0101-0000-start.sh"
cat > "$k1home/.local/bin/tmux" <<'KTMUX'
#!/usr/bin/env bash
case "$1" in
  has-session) exit 1 ;;
  display-message)
    n="$(cat "$HOME/tmux.n" 2>/dev/null || echo 0)"; echo $((n+1)) > "$HOME/tmux.n"
    if [ "$n" -eq 0 ]; then echo bash; else echo "${KT_CMD:-bash}"; fi ;;
  capture-pane) [ -z "${KT_CAPFAIL:-}" ] || exit 1; cat "${KT_PANE:-/dev/null}" ;;
esac
exit 0
KTMUX
chmod +x "$k1home/.local/bin/tmux"
printf '#!/usr/bin/env bash\nexit 0\n' > "$k1home/.local/bin/session-git-prep"; chmod +x "$k1home/.local/bin/session-git-prep"
FCL='[2026-10-04T00:00:00Z] session=px_kfc-0101-0000 event=resume-pin-fail-closed reason=helper-missing'
k1() { # <label> <pane-cmd> <pane-file-content> [extra env]; prints the script's stdout; log in $k1home
  local lbl="$1" cmd="$2" pane="$3"; shift 3
  rm -f "$k1home/.sessions/session-starts.log" "$k1home/tmux.n"; printf '%s\n' "$pane" > "$k1home/pane.txt"
  k1out="$(env HOME="$k1home" KT_CMD="$cmd" KT_PANE="$k1home/pane.txt" "$@" bash "$KSCRIPT" 2>&1)"
}
k1 codex codex ''
has "K1: codex in the pane => started" "$k1out" 'event=started$'
k1 fc sleep "$FCL"
has "K1: sleep + this session's fail-closed line => started-FAIL-CLOSED with the reason" "$k1out" 'event=started-FAIL-CLOSED reason=helper-missing'
k1 typed sleep 'echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] session=$SESSION event=resume-pin-fail-closed reason=$FAIL" | tee -a "$LOG_FILE"'
has "K1: sleep + only the typed loop text => started-UNVERIFIED-codex-not-running" "$k1out" 'event=started-UNVERIFIED-codex-not-running'
k1 other sleep "${FCL/kfc-0101-0000/kfc-0101-0000x}"
has "K1: sleep + another session's line => started-UNVERIFIED-codex-not-running" "$k1out" 'event=started-UNVERIFIED-codex-not-running'
k1 capfail sleep "$FCL" KT_CAPFAIL=1
has "K1: capture-pane fails => started-UNVERIFIED-pane-unreadable" "$k1out" 'event=started-UNVERIFIED-pane-unreadable'
rm -f "$k1home/.sessions/session-starts.log" "$k1home/tmux.n"; printf '%s\n' "$FCL" > "$k1home/pane.txt"; mkdir "$k1home/.sessions/session-starts.log"
k1out="$(HOME="$k1home" KT_CMD=sleep KT_PANE="$k1home/pane.txt" bash "$KSCRIPT" 2>/dev/null)"
has "K1: log is a directory: fail-closed still reaches the script's stdout" "$k1out" 'event=started-FAIL-CLOSED reason=helper-missing'
not_has "K1: ...and it never says plain started" "$k1out" 'event=started$'
rm -rf "$k1home/.sessions/session-starts.log"
# claude backend: unchanged (sleep or claude in the pane => plain started)
mkdir -p "$k1home/.sessions/k-cl"
HOME="$k1home" KSTUB_NONE=1 PATH="$DATESTUB:$PATH" bash "$NS" k-cl sessions --alias kcl >/dev/null 2>&1
CLSCRIPT="$k1home/.local/bin/px-kcl-0101-0000-start.sh"
rm -f "$k1home/tmux.n"; printf '%s\n' "$FCL" > "$k1home/pane.txt"
clout="$(HOME="$k1home" KT_CMD=sleep KT_PANE="$k1home/pane.txt" PATH="$k1home/.local/bin:$PATH" bash "$CLSCRIPT" 2>&1)"
has "K1: claude backend with sleep in the pane => plain started" "$clout" 'event=started$'

finish "new-session-backend"
