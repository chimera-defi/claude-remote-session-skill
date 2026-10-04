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
export TMPDIR="$WORKHOME"   # every later mktemp lands under $WORKHOME, so the trap removes it
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

# The run directory is created by the start script itself: a NEW folder of type `sessions`
# (not pre-created, unlike backend-start above) used to leave tmux `-c <missing dir>`, which
# silently starts the pane in $HOME.
WD_HOME="$(mktemp -d)"; mkdir -p "$WD_HOME/.sessions"
wd_out="$(HOME="$WD_HOME" PATH="$DATESTUB:$PATH" CRSS_CODEX_BIN="$CODEX_STUB" CRSS_CODEX_ARGS='-m m -s read-only' bash "$NS" --backend codex wd-nomk sessions --alias wdnomk 2>&1)"
has "workdir-spawn-created" "$wd_out" 'Session created: px-wdnomk-0101-0000'
WD_SCRIPT="$WD_HOME/.local/bin/px-wdnomk-0101-0000-start.sh"
ok "workdir-folder-not-precreated-by-spawn" "$([ -e "$WD_HOME/.sessions/wd-nomk" ] && echo exists || echo absent)" "absent"
mk_line="$(grep -n '^if ! mkdir -p "\$RUNDIR"; then' "$WD_SCRIPT" | head -1 | cut -d: -f1)"
tmux_line="$(grep -n '^tmux new-session' "$WD_SCRIPT" | head -1 | cut -d: -f1)"
ok "workdir-static-mkdir-before-tmux" "$([ -n "$mk_line" ] && [ -n "$tmux_line" ] && [ "$mk_line" -lt "$tmux_line" ] && echo before || echo missing-or-after)" "before"
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
# claude backend: the common-section mkdir must not disturb it
WDC_HOME="$(mktemp -d)"; mkdir -p "$WDC_HOME/.sessions"
wdc_out="$(HOME="$WDC_HOME" PATH="$DATESTUB:$PATH" bash "$NS" wd-claude sessions --alias wdclaude 2>&1)"
has "workdir-claude-spawn-created" "$wdc_out" 'Session created: px-wdclaude-0101-0000'
has "workdir-claude-script-has-mkdir" "$(cat "$WDC_HOME/.local/bin/px-wdclaude-0101-0000-start.sh")" '^if ! mkdir -p "\$RUNDIR"; then'
# A failed mkdir fails closed: the start script exits non-zero before any tmux session is created.
WB_HOME="$(mktemp -d)"; mkdir -p "$WB_HOME/.sessions"
wb_out="$(HOME="$WB_HOME" PATH="$DATESTUB:$PATH" CRSS_CODEX_BIN="$CODEX_STUB" CRSS_CODEX_ARGS='-m m -s read-only' bash "$NS" --backend codex wd-blk sessions --alias wdblk 2>&1)"
has "workdir-blocked-spawn-created" "$wb_out" 'Session created: px-wdblk-0101-0000'
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

# ── Lane helpers (brief 3b). Homes live under $WORKHOME so the EXIT trap removes them. ──
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
}
# lane_run HOME [CWD]: run the generated start script, sets LANE_RC.
lane_run() { ( cd "${2:-$1}" && HOME="$1" bash "$LANE_SCRIPT" >/dev/null 2>&1 ); LANE_RC=$?; }
tmux_calls_other_than_has() { grep -cv '^has-session' "$1/tmux.calls" 2>/dev/null || true; }

# N(a): the overlay is read literally, so a `~`/`$HOME`/relative root is refused at spawn (exit 2),
# before any start script or unit exists.
for nv in CRSS_SESSIONS_DIR CRSS_WORKSPACE; do
  # shellcheck disable=SC2088  # the literal ~ is the point: the overlay never expands it
  for nval in '~/.sessions' '$HOME/x' 'rel'; do
    nh="$(mkhome)"; ncfg="$(mktemp -d "$WORKHOME/c.XXXXXX")"; printf '%s=%s\n' "$nv" "$nval" > "$ncfg/config.sh"
    nout="$(env -u CRSS_SESSIONS_DIR -u CRSS_WORKSPACE HOME="$nh" CRSS_HOME="$ncfg" PATH="$DATESTUB:$PATH" bash "$NS" na-lane sessions --alias na 2>&1)"; nrc=$?
    ok "N(a) $nv=$nval exits 2" "$nrc" "2"
    ok "N(a) $nv=$nval names the variable and literal value" "$(grep -cF -- "$nv='$nval' must be an absolute path" <<<"$nout")" "1"
    ok "N(a) $nv=$nval wrote no start script" "$(ls "$nh/.local/bin" 2>/dev/null | grep -c -- '-start.sh$' || true)" "0"
    ok "N(a) $nv=$nval wrote no unit" "$(ls "$nh/.config/systemd/user" 2>/dev/null | wc -l)" "0"
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
# `auto` resolves to workspace for an existing dir, and bakes that
wh="$(mkhome)"; mkdir -p "$wh/workspace/wa-repo"; lane_spawn "$wh" codex wa-repo auto waauto
has "W auto->workspace bakes workspace" "$(cat "$LANE_SCRIPT")" '^LANE_TYPE=(["'\'']?)workspace\1$'
# control: an existing workspace dir that is not a git repo starts (the dir is usable, started is logged)
wh="$(mkhome)"; mkdir -p "$wh/workspace/wc-plain"; lane_spawn "$wh" codex wc-plain workspace wcplain; stub_tmux "$wh"; stub_prep "$wh" ""
lane_run "$wh"
ok "W control: plain workspace dir starts" "$LANE_RC" "0"
ok "W control: tmux -c dir is usable" "$(cat "$wh/tmux.cstate" 2>/dev/null)" "usable"
has "W control: started" "$(cat "$wh/.sessions/session-starts.log" 2>/dev/null)" 'event=started'
# control: a missing sessions lane is still created and starts
wh="$(mkhome)"; lane_spawn "$wh" codex ws-new sessions wsnew; stub_tmux "$wh"; stub_prep "$wh" ""
has "W control: sessions header" "$(cat "$LANE_SCRIPT")" '^LANE_TYPE=(["'\'']?)sessions\1$'
lane_run "$wh"
ok "W control: missing sessions lane starts" "$LANE_RC" "0"
ok "W control: sessions dir created" "$([ -d "$wh/.sessions/ws-new" ] && echo dir || echo missing)" "dir"
ok "W control: tmux -c dir is usable (sessions)" "$(cat "$wh/tmux.cstate" 2>/dev/null)" "usable"

# U: an existing run directory that cannot be entered must not become tmux's `-c` (tmux would fall back to $HOME).
if [ "$(id -u)" -eq 0 ]; then
  echo "SKIP: U rundir chmod 000 (root)"
else
  for ub in codex claude; do
    uh="$(mkhome)"; mkdir -p "$uh/.sessions/uu-lane"
    lane_spawn "$uh" "$ub" uu-lane sessions "uu$ub"; stub_tmux "$uh"; stub_prep "$uh" ""
    chmod 000 "$uh/.sessions/uu-lane"
    lane_run "$uh"
    chmod 755 "$uh/.sessions/uu-lane"
    ok "U($ub) unenterable RUNDIR exits non-zero" "$([ "$LANE_RC" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
    ok "U($ub) no tmux call but has-session" "$(tmux_calls_other_than_has "$uh")" "0"
    ulog="$(cat "$uh/.sessions/session-starts.log" 2>/dev/null)"
    has "U($ub) logs rundir-unusable" "$ulog" 'event=rundir-unusable rundir='
    hasnt "U($ub) not reported started" "$ulog" 'event=started'
    hasnt "U($ub) is not the mkdir failure" "$ulog" 'event=rundir-mkdir-FAILED'
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
  for tb in codex claude; do
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
    ok "T3 $tb: run directory not created" "$([ -e "$th/sroot/t3-lane" ] && echo exists || echo absent)" "absent"
  done
fi

# T4: a failing `systemctl enable --now` makes new-session exit non-zero and say the session was NOT started.
FAILCTL="$(mktemp -d)"
cat > "$FAILCTL/systemctl" <<'FCEOF'
#!/usr/bin/env bash
case "$*" in *enable*) echo "stub: enable failed" >&2; exit 1 ;; esac
exit 0
FCEOF
chmod +x "$FAILCTL/systemctl"
th="$(mkhome)"
t4_out="$(HOME="$th" PATH="$FAILCTL:$DATESTUB:$PATH" CRSS_CODEX_BIN="$CODEX_STUB" CRSS_CODEX_ARGS='-m m -s read-only' bash "$NS" --backend codex t4-lane sessions --alias t4 2>&1)"; t4_rc=$?
ok "T4: failing systemctl exits non-zero" "$([ "$t4_rc" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
has "T4: says the session was NOT started" "$t4_out" 'the session was NOT started'
not_has "T4: does not claim success" "$t4_out" 'Session created'

finish "new-session-backend"
