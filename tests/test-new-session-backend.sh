#!/usr/bin/env bash
# Backend selection coverage for new-session.sh. Codex support must be a
# first-class backend, not a Claude profile variant.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
NS="$HERE/../scripts/new-session.sh"

has(){ if grep -qE -- "$3" <<<"$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — pattern not found: $3 in: $2"; fi; }
not_has(){ if grep -qE -- "$3" <<<"$2"; then fail=$((fail+1)); echo "FAIL: $1 — unexpected pattern: $3 in: $2"; else pass=$((pass+1)); fi; }

isolate_overlay
export CRSS_SESSION_PREFIX=px
export CRSS_LEGACY_PREFIXES=oldhost

BIN="$(mktemp -d)"
WORKHOME="$(mktemp -d)"
trap 'rm -rf "$BIN" "$WORKHOME"' EXIT
export TMPDIR="$WORKHOME"   # every later mktemp lands under $WORKHOME, so the trap removes it
ln -sf "$HERE/../scripts/session-alias.sh" "$BIN/session-alias"
# The stub systemctl plays the start script's part: on `enable` it appends the verdict line the
# real script's log_start writes (a FRESH timestamp, since the spawn only trusts lines at or
# after its own t0). KSTUB_EVENT overrides the event; KSTUB_RAW supplies whole lines (tokens
# @NOW@ @OLD@ @SESS@ @UNIT@ @ID@); KSTUB_NONE=1 writes nothing. @ID@ and the default line carry the
# START_ID read from the generated start script, as the real log_start would.
cat > "$BIN/systemctl" <<'CTLEOF'
#!/usr/bin/env bash
echo "$*" >> "${STUBLOG:-/dev/null}"
case " $* " in *" enable "*)
  [ -z "${KSTUB_NONE:-}" ] || exit 0
  unit="${!#}"; unit="${unit%.service}"; sess="${unit/#px-/px_}"
  sid="$(sed -n 's/^START_ID=//p' "$HOME/.local/bin/${unit}-start.sh" 2>/dev/null | head -1)"; now="$(/usr/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$HOME/.sessions" 2>/dev/null
  if [ -n "${KSTUB_RAW:-}" ]; then
    printf '%s\n' "$KSTUB_RAW" | sed "s/@NOW@/$now/g; s/@OLD@/2020-01-01T00:00:00Z/g; s/@SESS@/$sess/g; s/@UNIT@/$unit/g; s/@ID@/$sid/g" >> "$HOME/.sessions/session-starts.log" 2>/dev/null
  else
    printf '[%s] host=h session=%s remote=%s backend=codex workdir=w model=m profile=p start_id=%s event=%s\n' \
      "$now" "$sess" "$unit" "$sid" "${KSTUB_EVENT:-started}" >> "$HOME/.sessions/session-starts.log" 2>/dev/null
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
CMD_LINE='[@NOW@] host=h session=@SESS@ remote=@UNIT@ backend=codex workdir=w model=m profile=p start_id=@ID@ event'
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
newk e; k2 e "${CMD_LINE}=started-FAIL-CLOSED reason=helper-missing"
ok "K2: a fresh fail-closed exits 3" "$krc" "3"; has "K2: ...names the reason" "$kout" 'FAIL-CLOSED \(reason=helper-missing\)'; has "K2: ...and the session" "$kout" 'px-ke-0101-0000'
newk g; mkdir "$KHOME/.sessions/session-starts.log"; k2 g "${CMD_LINE}=started"
ok "K2: a log that is a directory exits 3" "$krc" "3"; has "K2: ...NOT verified, names journalctl" "$kout" 'NOT verified.*journalctl --user -u px-kg-0101-0000.service'

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

# S: the verdict needs THIS spawn's start_id. Stale lines (no id, another id, another session's line)
# never verify a start; a line carrying the generated script's id does.
# shellcheck disable=SC2034
OTHERID=0123456789abcdef0123456789abcdef
s_spawn() { # <label> <log-line or ''> [env...]: pre-write the line, then spawn with no verdict from the stub
  local lbl="$1" line="$2"; shift 2
  [ -z "$line" ] || printf '%s\n' "$line" >> "$KHOME/.sessions/session-starts.log"
  kout="$(env HOME="$KHOME" KSTUB_NONE=1 "$@" PATH="$DATESTUB:$PATH" CRSS_CODEX_BIN="$CODEX_STUB" CRSS_CODEX_ARGS='-m m -s read-only' bash "$NS" --backend codex "k-$lbl" sessions --alias "k$lbl" 2>&1)"; krc=$?
}
newk sr; s_spawn sr '[2099-01-01T00:00:00Z] host=h session=px_ksr-0101-0000 remote=px-ksr-0101-0000 backend=codex workdir=w model=m profile=p event=started'
ok "S-red: a stale same-session started line with no start_id exits 3" "$krc" "3"
has "S-red: ...NOT verified" "$kout" 'start NOT verified for px-ksr-0101-0000'
not_has "S-red: ...never says Session created" "$kout" 'Session created'
# S-other-session: the right id is only known once the script exists, so the stub writes the line (@ID@).
newk ss; k2 ss "[@NOW@] host=h session=px_other-0101-0000 remote=px-other-0101-0000 backend=codex workdir=w model=m profile=p start_id=@ID@ event=started"
ok "S-other-session: this spawn's id on another session's line exits 3" "$krc" "3"
newk sk; k2 sk "${CMD_LINE}=started"
ok "S-ok: a started line carrying this spawn's start_id exits 0" "$krc" "0"; has "S-ok: ...says created" "$kout" 'Session created: px-ksk-0101-0000'
ok "S-ok: the generated script carries a 32-hex START_ID" "$(grep -cE '^START_ID=[0-9a-f]{32}$' "$KHOME/.local/bin/px-ksk-0101-0000-start.sh")" "1"
ok "S-ok: log_start writes start_id immediately before event" "$(grep -cF 'start_id=$START_ID event=$1' "$KHOME/.local/bin/px-ksk-0101-0000-start.sh")" "1"

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
k1 capfail sleep "$FCL" KT_CAPFAIL=1
has "K1: capture-pane fails => started-UNVERIFIED-pane-unreadable" "$k1out" 'event=started-UNVERIFIED-pane-unreadable'
# The run directory is created by the start script itself: a NEW folder of type `sessions`
# (not pre-created, unlike backend-start above) used to leave tmux `-c <missing dir>`, which
# silently starts the pane in $HOME.
WD_HOME="$(mktemp -d)"; mkdir -p "$WD_HOME/.sessions"
wd_out="$(HOME="$WD_HOME" PATH="$DATESTUB:$PATH" CRSS_CODEX_BIN="$CODEX_STUB" CRSS_CODEX_ARGS='-m m -s read-only' bash "$NS" --backend codex wd-nomk sessions --alias wdnomk 2>&1)"
has "workdir-spawn-created" "$wd_out" 'Session created: px-wdnomk-0101-0000'
WD_SCRIPT="$WD_HOME/.local/bin/px-wdnomk-0101-0000-start.sh"
ok "workdir-folder-not-precreated-by-spawn" "$([ -e "$WD_HOME/.sessions/wd-nomk" ] && echo exists || echo absent)" "absent"
cat > "$WD_HOME/.local/bin/tmux" <<'WDTMUX'
#!/usr/bin/env bash
case "$1" in
  has-session) exit 1 ;;
  new-session) prev=""; for a in "$@"; do
      if [ "$prev" = -c ]; then
        printf '%s' "$a" > "$HOME/tmux.c"
        if [ -d "$a" ] && (cd "$a") 2>/dev/null; then echo usable > "$HOME/tmux.cstate"; else echo missing > "$HOME/tmux.cstate"; fi
      fi; prev="$a"; done ;;
  display-message)
    n="$(cat "$HOME/tmux.n" 2>/dev/null || echo 0)"; echo $((n+1)) > "$HOME/tmux.n"
    if [ "$n" -eq 0 ]; then echo bash; else echo codex; fi ;;
esac
exit 0
WDTMUX
printf '#!/usr/bin/env bash\nexit 0\n' > "$WD_HOME/.local/bin/session-git-prep"
chmod +x "$WD_HOME/.local/bin/tmux" "$WD_HOME/.local/bin/session-git-prep"
HOME="$WD_HOME" bash "$WD_SCRIPT" >/dev/null 2>&1
ok "workdir-created-by-start-script" "$([ -d "$WD_HOME/.sessions/wd-nomk" ] && echo dir || echo missing)" "dir"
ok "workdir-tmux-got-existing-dir" "$(cat "$WD_HOME/tmux.c" 2>/dev/null)" "$WD_HOME/.sessions/wd-nomk"
# the path alone also matches at origin/main (tmux was handed a dir that did not exist yet): assert it was enterable
ok "workdir-tmux-dir-usable-at-call-time" "$(cat "$WD_HOME/tmux.cstate" 2>/dev/null)" "usable"
# A failed mkdir fails closed: the start script exits non-zero before any tmux session is created.
WB_HOME="$(mktemp -d)"; mkdir -p "$WB_HOME/.sessions"
wb_out="$(HOME="$WB_HOME" PATH="$DATESTUB:$PATH" CRSS_CODEX_BIN="$CODEX_STUB" CRSS_CODEX_ARGS='-m m -s read-only' bash "$NS" --backend codex wd-blk sessions --alias wdblk 2>&1)"
has "workdir-blocked-spawn-created" "$wb_out" 'Session created: px-wdblk-0101-0000'
: > "$WB_HOME/.sessions/session-starts.log"   # drop the stub systemctl's spawn-time verdict line
: > "$WB_HOME/.sessions/wd-blk"   # a file where the run directory must go: mkdir -p fails even as root
cat > "$WB_HOME/.local/bin/tmux" <<'WBTMUX'
#!/usr/bin/env bash
echo "$*" >> "$HOME/tmux.calls"
case "$1" in has-session) exit 1 ;; display-message) echo bash ;; esac
exit 0
WBTMUX
printf '#!/usr/bin/env bash\nexit 0\n' > "$WB_HOME/.local/bin/session-git-prep"
chmod +x "$WB_HOME/.local/bin/tmux" "$WB_HOME/.local/bin/session-git-prep"
HOME="$WB_HOME" bash "$WB_HOME/.local/bin/px-wdblk-0101-0000-start.sh" >/dev/null 2>&1; wb_rc=$?
ok "workdir-mkdir-failure-exits-nonzero" "$([ "$wb_rc" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
ok "workdir-mkdir-failure-no-tmux-session" "$(grep -cv '^has-session' "$WB_HOME/tmux.calls" 2>/dev/null)" "0"
wb_log="$(cat "$WB_HOME/.sessions/session-starts.log" 2>/dev/null)"
has "workdir-mkdir-failure-logged" "$wb_log" 'event=rundir-mkdir-FAILED rundir='
not_has "workdir-mkdir-failure-not-reported-started" "$wb_log" 'event=started'

# ── Lane helpers. Homes live under $WORKHOME so the EXIT trap removes them. ──
# The start script resets PATH to $HOME/.local/bin:…:/usr/bin, so stubs go in <home>/.local/bin.
mkhome() { local h; h="$(mktemp -d "$WORKHOME/h.XXXXXX")"; mkdir -p "$h/.sessions" "$h/.local/bin"; echo "$h"; }
# stub tmux: logs every call; for new-session records the -c dir and whether it is enterable NOW.
stub_tmux() {
  cat > "$1/.local/bin/tmux" <<'STUBTMUX'
#!/usr/bin/env bash
echo "$*" >> "$HOME/tmux.calls"
case "$1" in
  has-session) exit 1 ;;
  new-session) prev=""; for a in "$@"; do
      if [ "$prev" = -c ]; then
        printf '%s' "$a" > "$HOME/tmux.c"
        if [ -d "$a" ] && (cd "$a") 2>/dev/null; then echo usable > "$HOME/tmux.cstate"; else echo missing > "$HOME/tmux.cstate"; fi
      fi; prev="$a"; done ;;
  display-message)
    n="$(cat "$HOME/tmux.n" 2>/dev/null || echo 0)"; echo $((n+1)) > "$HOME/tmux.n"
    if [ "$n" -eq 0 ]; then echo bash; else echo codex; fi ;;
esac
exit 0
STUBTMUX
  chmod +x "$1/.local/bin/tmux"
}
# stub session-git-prep: prints $2 (nothing when empty).
stub_prep() { printf '#!/usr/bin/env bash\n[ -n "%s" ] && echo "%s"\nexit 0\n' "$2" "$2" > "$1/.local/bin/session-git-prep"; chmod +x "$1/.local/bin/session-git-prep"; }
# lane_spawn HOME BACKEND FOLDER TYPE ALIAS: real new-session (stub systemctl), sets LANE_OUT, LANE_SCRIPT.
lane_spawn() {
  LANE_OUT="$(HOME="$1" PATH="$DATESTUB:$PATH" CRSS_CODEX_BIN="$CODEX_STUB" CRSS_CODEX_ARGS='-m m -s read-only' bash "$NS" --backend "$2" "$3" "$4" --alias "$5" 2>&1)"
  LANE_SCRIPT="$1/.local/bin/px-$5-0101-0000-start.sh"
  # the stub systemctl logged a spawn-time verdict line; these tests inspect only what the START SCRIPT logs
  : > "$1/.sessions/session-starts.log" 2>/dev/null || true
}
# lane_run HOME [CWD]: run the generated start script, sets LANE_RC.
lane_run() { ( cd "${2:-$1}" && HOME="$1" bash "$LANE_SCRIPT" >/dev/null 2>&1 ); LANE_RC=$?; }
tmux_calls_other_than_has() { grep -cv '^has-session' "$1/tmux.calls" 2>/dev/null || true; }

# N(a): the overlay is read literally, so a `~`/`$HOME`/relative root is refused at spawn (exit 2),
# before any start script or unit exists.
for nv in CRSS_SESSIONS_DIR CRSS_WORKSPACE; do
  # shellcheck disable=SC2088  # the literal ~ is the point: the overlay never expands it
  for nval in '~/.sessions' 'rel'; do
    nh="$(mkhome)"; ncfg="$(mktemp -d "$WORKHOME/c.XXXXXX")"; printf '%s=%s\n' "$nv" "$nval" > "$ncfg/config.sh"
    nout="$(env -u CRSS_SESSIONS_DIR -u CRSS_WORKSPACE HOME="$nh" CRSS_HOME="$ncfg" PATH="$DATESTUB:$PATH" bash "$NS" na-lane sessions --alias na 2>&1)"; nrc=$?
    ok "N(a) $nv=$nval exits 2" "$nrc" "2"
    ok "N(a) $nv=$nval names the variable and literal value" "$(grep -cF -- "$nv='$nval' must be an absolute path" <<<"$nout")" "1"
  done
done
# control: absolute roots spawn as before
nh="$(mkhome)"; ncfg="$(mktemp -d "$WORKHOME/c.XXXXXX")"; printf 'CRSS_SESSIONS_DIR=%s/.sessions\nCRSS_WORKSPACE=%s/ws\n' "$nh" "$nh" > "$ncfg/config.sh"
nout="$(env -u CRSS_SESSIONS_DIR -u CRSS_WORKSPACE HOME="$nh" CRSS_HOME="$ncfg" PATH="$DATESTUB:$PATH" bash "$NS" na-ctl sessions --alias nactl 2>&1)"; nrc=$?
ok "N(a) control: absolute overlay roots spawn" "$nrc" "0"
has "N(a) control: session created" "$nout" 'Session created: px-nactl-0101-0000'

# N(b): a relative run directory (here from session-git-prep) aborts the start script and creates nothing.
nh="$(mkhome)"; lane_spawn "$nh" codex nb-lane sessions nb; stub_tmux "$nh"; stub_prep "$nh" "rel/dir"
has "N(b) spawn created" "$LANE_OUT" 'Session created: px-nb-0101-0000'
ncwd="$(mktemp -d "$WORKHOME/w.XXXXXX")"; lane_run "$nh" "$ncwd"
ok "N(b) relative RUNDIR exits non-zero" "$([ "$LANE_RC" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
ok "N(b) no tmux call but has-session" "$(tmux_calls_other_than_has "$nh")" "0"
nlog="$(cat "$nh/.sessions/session-starts.log" 2>/dev/null)"
has "N(b) logs rundir-not-absolute" "$nlog" 'event=rundir-not-absolute rundir=rel/dir'
hasnt "N(b) not reported started" "$nlog" 'event=started'
ok "N(b) rel/dir not created under the cwd" "$([ -e "$ncwd/rel" ] && echo exists || echo absent)" "absent"

# W: a workspace lane needs an existing directory; the start script never creates one.
for wb in codex claude; do
  wh="$(mkhome)"; mkdir -p "$wh/workspace/ww-repo"
  lane_spawn "$wh" "$wb" ww-repo workspace "ww$wb"; stub_tmux "$wh"; stub_prep "$wh" ""
  has "W($wb) spawn created" "$LANE_OUT" "Session created: px-ww$wb-0101-0000"
  has "W($wb) header bakes the resolved type" "$(cat "$LANE_SCRIPT")" '^LANE_TYPE=(["'\'']?)workspace\1$'
  rmdir "$wh/workspace/ww-repo"   # the repo dir vanishes before the start script runs
  lane_run "$wh"
  ok "W($wb) missing workspace dir exits non-zero" "$([ "$LANE_RC" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
  ok "W($wb) no tmux call but has-session" "$(tmux_calls_other_than_has "$wh")" "0"
  wlog="$(cat "$wh/.sessions/session-starts.log" 2>/dev/null)"
  has "W($wb) logs rundir-missing" "$wlog" 'event=rundir-missing rundir='
  hasnt "W($wb) not reported started" "$wlog" 'event=started'
  ok "W($wb) dir NOT recreated" "$([ -e "$wh/workspace/ww-repo" ] && echo exists || echo absent)" "absent"
done
# control: an existing workspace dir that is not a git repo starts (the dir is usable, started is logged)
wh="$(mkhome)"; mkdir -p "$wh/workspace/wc-plain"; lane_spawn "$wh" codex wc-plain workspace wcplain; stub_tmux "$wh"; stub_prep "$wh" ""
lane_run "$wh"
ok "W control: plain workspace dir starts" "$LANE_RC" "0"
ok "W control: tmux -c dir is usable" "$(cat "$wh/tmux.cstate" 2>/dev/null)" "usable"
has "W control: started" "$(cat "$wh/.sessions/session-starts.log" 2>/dev/null)" 'event=started$'
# control: a missing sessions lane is still created and starts
wh="$(mkhome)"; lane_spawn "$wh" codex ws-new sessions wsnew; stub_tmux "$wh"; stub_prep "$wh" ""
has "W header: a sessions lane bakes LANE_TYPE=sessions" "$(cat "$LANE_SCRIPT")" '^LANE_TYPE=(["'\'']?)sessions\1$'
lane_run "$wh"
ok "W control: missing sessions lane starts" "$LANE_RC" "0"
ok "W control: sessions dir created" "$([ -d "$wh/.sessions/ws-new" ] && echo dir || echo missing)" "dir"
ok "W control: tmux -c dir is usable (sessions)" "$(cat "$wh/tmux.cstate" 2>/dev/null)" "usable"

# U: an existing run directory that cannot be entered must not become tmux's `-c` (tmux would fall back to $HOME).
if [ "$(id -u)" -eq 0 ]; then
  echo "SKIP: U rundir chmod 000 (root)"
else
  # shellcheck disable=SC2043
  for ub in codex; do
    uh="$(mkhome)"; mkdir -p "$uh/.sessions/uu-lane"
    lane_spawn "$uh" "$ub" uu-lane sessions "uu$ub"; stub_tmux "$uh"; stub_prep "$uh" ""
    chmod 000 "$uh/.sessions/uu-lane"
    lane_run "$uh"
    chmod 755 "$uh/.sessions/uu-lane"
    ok "U($ub) unenterable RUNDIR exits non-zero" "$([ "$LANE_RC" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
    ok "U($ub) no tmux call but has-session" "$(tmux_calls_other_than_has "$uh")" "0"
    ulog="$(cat "$uh/.sessions/session-starts.log" 2>/dev/null)"
    has "U($ub) logs rundir-unusable" "$ulog" 'event=rundir-unusable rundir='
  done
fi

# C4: an enterable but read-only run directory (chmod 555), the lane's own or one supplied by session-git-prep.
if [ "$(id -u)" -eq 0 ]; then
  echo "SKIP: C4 rundir chmod 555 (root)"
else
  # shellcheck disable=SC2043
  for cb in codex; do
    for cw in own prep; do
      ch="$(mkhome)"; mkdir -p "$ch/.sessions/cw-lane" "$ch/prepdir"
      lane_spawn "$ch" "$cb" cw-lane sessions "cw$cb$cw"; stub_tmux "$ch"
      if [ "$cw" = prep ]; then stub_prep "$ch" "$ch/prepdir"; chmod 555 "$ch/prepdir"; else stub_prep "$ch" ""; chmod 555 "$ch/.sessions/cw-lane"; fi
      lane_run "$ch"
      chmod 755 "$ch/prepdir" "$ch/.sessions/cw-lane"
      ok "C4($cb,$cw) read-only RUNDIR exits non-zero" "$([ "$LANE_RC" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
      ok "C4($cb,$cw) no tmux call but has-session" "$(tmux_calls_other_than_has "$ch")" "0"
      clog="$(cat "$ch/.sessions/session-starts.log" 2>/dev/null)"
      has "C4($cb,$cw) logs rundir-unwritable" "$clog" 'event=rundir-unwritable rundir='
      hasnt "C4($cb,$cw) not reported started" "$clog" 'event=started'
    done
  done
fi

# T2: the claude backend aborts dynamically too (a file where the run directory goes), not just textually.
th="$(mkhome)"; lane_spawn "$th" claude t2-lane sessions t2c; stub_tmux "$th"; stub_prep "$th" ""
: > "$th/.sessions/t2-lane"
lane_run "$th"
ok "T2 claude: file at RUNDIR exits non-zero" "$([ "$LANE_RC" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
ok "T2 claude: no tmux call but has-session" "$(tmux_calls_other_than_has "$th")" "0"
tlog="$(cat "$th/.sessions/session-starts.log" 2>/dev/null)"
has "T2 claude: logs rundir-mkdir-FAILED" "$tlog" 'event=rundir-mkdir-FAILED rundir='
hasnt "T2 claude: not reported started" "$tlog" 'event=started'

# T3: a literal unwritable parent (the sessions root is read-only), so mkdir -p itself fails.
if [ "$(id -u)" -eq 0 ]; then
  echo "SKIP: T3 unwritable sessions root (root)"
else
  # shellcheck disable=SC2043
  for tb in codex; do
    th="$(mkhome)"; mkdir -p "$th/sroot"
    CRSS_SESSIONS_DIR="$th/sroot" lane_spawn "$th" "$tb" t3-lane sessions "t3$tb"; stub_tmux "$th"; stub_prep "$th" ""
    chmod 555 "$th/sroot"
    lane_run "$th"
    chmod 755 "$th/sroot"
    ok "T3 $tb: unwritable parent exits non-zero" "$([ "$LANE_RC" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
    ok "T3 $tb: no tmux call but has-session" "$(tmux_calls_other_than_has "$th")" "0"
    tlog="$(cat "$th/.sessions/session-starts.log" 2>/dev/null)"
    has "T3 $tb: logs rundir-mkdir-FAILED" "$tlog" 'event=rundir-mkdir-FAILED rundir='
    hasnt "T3 $tb: not reported started" "$tlog" 'event=started'
  done
fi

# T4: a failing `systemctl enable --now` makes new-session exit non-zero and say the session was NOT started.
# The stub logs its arguments to $STUBLOG; STUB_DISABLE_FAIL=1 makes `disable` fail too.
FAILCTL="$(mktemp -d)"
cat > "$FAILCTL/systemctl" <<'FCEOF'
#!/usr/bin/env bash
echo "$*" >> "${STUBLOG:-/dev/null}"
case "$*" in
  *enable*) echo "stub: enable failed" >&2; exit 1 ;;
  *" disable "*) [ -z "${STUB_DISABLE_FAIL:-}" ] || exit 1 ;;
esac
exit 0
FCEOF
chmod +x "$FAILCTL/systemctl"
th="$(mkhome)"; t4log="$th/ctl.log"
t4_out="$(HOME="$th" STUBLOG="$t4log" PATH="$FAILCTL:$DATESTUB:$PATH" CRSS_CODEX_BIN="$CODEX_STUB" CRSS_CODEX_ARGS='-m m -s read-only' bash "$NS" --backend codex t4-lane sessions --alias t4 2>&1)"; t4_rc=$?
ok "T4: failing systemctl exits non-zero" "$([ "$t4_rc" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
has "T4: says the session was NOT started" "$t4_out" 'the session was NOT started'
not_has "T4: does not claim success" "$t4_out" 'Session created'
has "T4: says the unit was disabled" "$t4_out" 'The unit was disabled, so a reboot will not re-run it'
ok "T4: the log shows disable then reset-failed for the unit, in that order" "$(grep -nE '^--user (disable|reset-failed) px-t4-0101-0000.service$' "$t4log" | sed 's/^[0-9]*://' | tr '\n' '|')" "--user disable px-t4-0101-0000.service|--user reset-failed px-t4-0101-0000.service|"
ok "T4: the unit file is left on disk" "$([ -f "$th/.config/systemd/user/px-t4-0101-0000.service" ] && echo kept || echo gone)" "kept"

# L: the per-start id comes from od's own successful output. Each failing od must refuse the spawn
# (rc 1) before any script, unit or log line exists; --dry-run needs no RNG at all.
ODBIN="$(mktemp -d)"
# Each stub appends a line to $OD_MARKER before it behaves, so a case can show whether od ran at all.
printf '#!/usr/bin/env bash\necho called >> "$OD_MARKER"\nexit 0\n' > "$ODBIN/od-empty"
# shellcheck disable=SC2043
for odk in empty; do
  lbd="$ODBIN/$odk"; mkdir -p "$lbd"; cp "$ODBIN/od-$odk" "$lbd/od"; chmod +x "$lbd/od"
  lh="$(mkhome)"; lmark="$lbd/marker"
  lo="$(HOME="$lh" OD_MARKER="$lmark" PATH="$lbd:$DATESTUB:$PATH" CRSS_CODEX_BIN="$CODEX_STUB" CRSS_CODEX_ARGS='-m m -s read-only' bash "$NS" --backend codex "l-$odk" sessions --alias "l$odk" 2>&1)"; lrc=$?
  ok "L(od $odk): spawn exits 1" "$lrc" "1"
  has "L(od $odk): says it could not generate a start id" "$lo" 'could not generate a start id'
  ok "L(od $odk): no start script written" "$(ls "$lh/.local/bin" 2>/dev/null | grep -c -- '-start.sh$' || true)" "0"
  ok "L(od $odk): no unit written" "$(ls "$lh/.config/systemd/user" 2>/dev/null | grep -c . || true)" "0"
  # --dry-run needs no RNG: rc 0, the plan is printed, and od is never invoked
  dmark="$lbd/dry-marker"
  ld_out="$(HOME="$(mkhome)" OD_MARKER="$dmark" PATH="$lbd:$DATESTUB:$PATH" bash "$NS" --dry-run "l-dry-$odk" --backend codex 2>&1)"; ld_rc=$?
  ok "L(dry-run, od $odk): rc 0" "$ld_rc" "0"
  has "L(dry-run, od $odk): prints the plan" "$ld_out" '^BACKEND=codex$'
  ok "L(dry-run, od $odk): od was never invoked" "$([ -e "$dmark" ] && echo invoked || echo absent)" "absent"
done
# two spawns with the same alias get different ids
ids=""
for _ in 1 2; do
  lh="$(mkhome)"
  HOME="$lh" PATH="$DATESTUB:$PATH" CRSS_CODEX_BIN="$CODEX_STUB" CRSS_CODEX_ARGS='-m m -s read-only' bash "$NS" --backend codex l-same sessions --alias lsame >/dev/null 2>&1
  ids="$ids $(sed -n 's/^START_ID=//p' "$lh/.local/bin/px-lsame-0101-0000-start.sh" 2>/dev/null)"
done
set -- $ids
ok "L: two spawns of the same alias both carry an id" "$([ "${#1}" = 32 ] && [ "${#2}" = 32 ] && echo yes || echo no)" "yes"
ok "L: ...and the ids differ" "$([ "$1" != "$2" ] && echo differ || echo same)" "differ"
rm -rf "$ODBIN"

finish "new-session-backend"
