#!/usr/bin/env bash
# test-session-resume.sh — session-resume must bring a dead session back on its
# OWN unit, resuming its OWN transcript by uuid with the unit's ORIGINAL launch
# flags, and refuse while anything still holds the session.
#
# systemctl and tmux are stubbed. The stubbed `systemctl start` really runs the
# start script's supervisor-loop payload (the text the script would type into
# the tmux pane) against a fake claude that records its argv — so the pin
# patch is exercised end to end, not just grepped for.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SR="$HERE/../scripts/session-resume.sh"
NS="$HERE/../scripts/new-session.sh"
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }
has(){ if grep -qF -- "$3" <<<"$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — '$3' not in: $2"; fi; }
not_has(){ if grep -qF -- "$3" <<<"$2"; then fail=$((fail+1)); echo "FAIL: $1 — unexpected '$3' in: $2"; else pass=$((pass+1)); fi; }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
T="$(mktemp -d)"
# Defined before the EXIT trap below (not alongside PATH/ARGV_LOG further down):
# under `set -u`, a cleanup() that runs before that later export — e.g. this
# script killed by a signal while still in setup — would abort on an unbound
# $STUB_STATE and skip its own pkill/rm -rf entirely.
export STUB_STATE="$T/state"
# Per-run unique suffix for remote names and transcript UUIDs: session-resume's
# liveness checks pgrep host-wide, so concurrent runs must not share fixture names.
UID12="$(printf '%012x' $$)"
# Every backgrounded supervisor loop below records its setsid session leader's
# pid to $STUB_STATE/all.sids (one per line, appended — several fixtures reuse
# the same unit name across test cases, so this must never be overwritten).
# `pkill -f <pattern>` below only matches CURRENTLY-ALIVE processes whose own
# argv contains the pattern: killing the matched loop process does not reach a
# child it has ALREADY forked (the fake-claude stub's sleep, or the loop's own
# post-exit `sleep 300` backoff) if that child happens to be running at the
# moment of the kill — that child is immediately orphaned and keeps running
# to completion (up to 300s) with nothing left anywhere that will ever signal
# it again. `pkill -s <sid>` instead signals every process in the recorded
# session (leader + every descendant, regardless of which one is currently
# running), which setsid guarantees stay in that one session since nothing
# inside the loop calls setsid() again.
cleanup() {
  if [ -f "$STUB_STATE/all.sids" ]; then
    while read -r sid; do [ -n "$sid" ] && pkill -s "$sid" 2>/dev/null; done < "$STUB_STATE/all.sids"
  fi
  pkill -f -- "$T/" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT
export CRSS_CLAUDE_HOME="$T/claude" CRSS_UNIT_DIR="$T/units" CRSS_SESSIONS_DIR="$T/sessions"
export CRSS_RESUME_BACKUP_DIR="$T/backups" CRSS_RESUME_WAIT=10
# Prefix config is explicit (no overlay file): current prefix "px", one legacy prefix.
export CRSS_HOME="$T/no-overlay" CRSS_SESSION_PREFIX=px CRSS_LEGACY_PREFIXES=oldhost
mkdir -p "$CRSS_CLAUDE_HOME/sessions" "$CRSS_UNIT_DIR" "$CRSS_SESSIONS_DIR" "$T/bin" "$T/state" "$T/scripts"

# ── stubs ────────────────────────────────────────────────────────────────────
# fake claude: records argv + whether the sentinel existed at launch, registers
# itself in Claude's session registry like the real CLI, then idles.
cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$ARGV_LOG"
[ -n "${FAKE_CLAUDE_EXIT:-}" ] && exit 0
ls .sessions-init-* >/dev/null 2>&1 && echo yes > "$ARGV_LOG.sentinel" || echo no > "$ARGV_LOG.sentinel"
sid=""; prev=""
for a in "$@"; do [ "$prev" = --resume ] && sid="$a"; prev="$a"; done
[ -n "$sid" ] && [ -z "${FAKE_CLAUDE_NOREG:-}" ] && printf '{"pid": %s, "sessionId": "%s"}\n' "$$" "$sid" > "$CRSS_CLAUDE_HOME/sessions/$$.json"
sleep "${FAKE_CLAUDE_SLEEP:-20}"
EOF
cat > "$T/bin/tmux" <<'EOF'
#!/usr/bin/env bash
[ "$1" = has-session ] && { [ -f "$STUB_STATE/tmux-live" ]; exit $?; }
exit 0
EOF
# systemctl: per-unit state files; `start` runs the start script's loop payload
# in the run dir recorded in $STUB_STATE/rundir.
cat > "$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
[ "$1" = --user ] && shift
q=0; [ "${2:-}" = --quiet ] && { q=1; set -- "$1" "$3"; }
echo "$*" >> "$STUB_STATE/systemctl.log"
u="${2:-}"
case "$1" in
  is-active)  s="$(cat "$STUB_STATE/$u.active" 2>/dev/null || echo failed)"; [ $q = 1 ] || echo "$s"; [ "$s" = active ] ;;
  is-enabled) s="$(cat "$STUB_STATE/$u.enabled" 2>/dev/null || echo disabled)"; echo "$s"; [ "$s" = enabled ] ;;
  enable)     echo enabled > "$STUB_STATE/$u.enabled" ;;
  reset-failed) : ;;
  start)
    script="$(sed -n 's/^ExecStart=//p' "$CRSS_UNIT_DIR/$u")"
    payload="$(python3 -c 'import re,sys
s=open(sys.argv[1]).read()
m=re.search(r"tmux send-keys -t \"[^\"]+\" \x27(.*?\ndone)\x27", s, re.S)
print(m.group(1))' "$script")"
    ( cd "$(cat "$STUB_STATE/rundir")" || exit 1
      exec setsid timeout 25 bash -c "$payload" >/dev/null 2>&1 ) &
    echo $! >> "$STUB_STATE/all.sids"
    echo active > "$STUB_STATE/$u.active" ;;
esac
EOF
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" ARGV_LOG="$T/state/argv"

# ── fixture: a session whose unit died, after a crash ─────────────────────
# Old (pre-pin) start-script shape, copied from a real generated script.
mk_session() {  # $1 = remote name (px-...) -> repo, own worktree, unit, script, 2 transcripts
  local r="$1" s="px_${1#px-}" repo="$T/repo-$1" wt="$CRSS_CLAUDE_HOME/worktrees/$1"
  git init -q -b main "$repo"; git -C "$repo" commit -q --allow-empty -m init
  echo dirty > "$repo/dirty.txt"
  mkdir -p "$CRSS_CLAUDE_HOME/worktrees"; git -C "$repo" worktree add -q -b "session/$r" "$wt"
  local sc="$T/scripts/$r-start.sh" flags
  flags="--dangerously-skip-permissions --model \"claude-opus-5-5\" --exclude-dynamic-system-prompt-sections --effort low --advisor opus --settings $T/claude/rc-firstparty.settings.json --remote-control $r"
  cat > "$sc" <<SCRIPT
#!/usr/bin/env bash
# Generated by new-session.sh — do not edit by hand.
SESSION="$s"
WORKDIR="$repo"
REMOTE_NAME="$r"
MODEL="claude-opus-5-5"
PROFILE="orchestrator"
tmux new-session -d -s "$s" -x 220 -y 50 -c "\$RUNDIR"
tmux send-keys -t "$s" 'LOG_FILE="$T/sessions/session-starts.log"
SESSION="$s"
SENTINEL="\$PWD/.sessions-init-$r"
while true; do
  START=\$(date +%s)
  if [ -f "\$SENTINEL" ]; then
    $T/bin/claude $flags --continue
  else
    $T/bin/claude $flags
    touch "\$SENTINEL"
  fi
  RUNTIME=\$(( \$(date +%s) - START ))
  echo "[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] session=\$SESSION event=exit runtime=\${RUNTIME}s" | tee -a "\$LOG_FILE"
  sleep 300
done'
SCRIPT
  chmod +x "$sc"
  printf '[Unit]\nDescription=x\n[Service]\nType=oneshot\nExecStart=%s\nExecStop=/usr/bin/tmux kill-session -t %s\n' "$sc" "$s" > "$CRSS_UNIT_DIR/$r.service"
  echo "[2026-01-01T01:01:01Z] session=$s rundir=$wt" >> "$CRSS_SESSIONS_DIR/session-starts.log"
  local proj
  proj="$CRSS_CLAUDE_HOME/projects/$(printf '%s' "$wt" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$proj"
  if [ "${2:-}" != one ]; then
    echo '{}' > "$proj/11111111-1111-4111-8111-$UID12.jsonl"; touch -d '2 days ago' "$proj/11111111-1111-4111-8111-$UID12.jsonl"
  fi
  echo '{}' > "$proj/22222222-2222-4222-8222-$UID12.jsonl"
  echo "$wt" > "$STUB_STATE/rundir"
}
NEW=22222222-2222-4222-8222-$UID12
OLD=11111111-1111-4111-8111-$UID12

# 1. usage validation
bash "$SR" >/dev/null 2>&1; ok "no-args-exit2" "$?" 2
bash "$SR" px_x --uuid 'x; rm -rf /' >/dev/null 2>&1; ok "bad-uuid-exit2" "$?" 2
bash "$SR" px_x --model 'sonnet"; x' >/dev/null 2>&1; ok "bad-model-exit2" "$?" 2
bash "$SR" '../etc' >/dev/null 2>&1; ok "unsafe-name-exit2" "$?" 2
out="$(bash "$SR" px_nounit 2>&1)"; ok "no-unit-exit1" "$?" 1
has "no-unit-message" "$out" "no unit file"

# 2. dry-run on the dead fixture (ONE transcript -> auto-picked): resolves it, plans the
# patch + unit start with the script's own flags, changes nothing.
R=px-rsm$$-a; mk_session "$R" one; SC="$T/scripts/$R-start.sh"; cp "$SC" "$T/orig-a.sh"
out="$(bash "$SR" px_rsm$$-a --dry-run 2>&1)"; rc=$?
ok  "dry-run-exit0" "$rc" 0
has "dry-run-uuid-sole" "$out" "resume uuid:  $NEW"
has "dry-run-rundir-own-wt" "$out" "run dir:      $CRSS_CLAUDE_HOME/worktrees/$R"
has "dry-run-plans-patch" "$out" "patch $SC supervisor loop"
has "dry-run-expect-own-flags" "$out" "expect: $T/bin/claude --dangerously-skip-permissions --model \"claude-opus-5-5\" --exclude-dynamic-system-prompt-sections --effort low --advisor opus --settings $T/claude/rc-firstparty.settings.json --remote-control $R --resume $NEW"
has "dry-run-says-unchanged" "$out" "dry-run: nothing changed"
cmp -s "$SC" "$T/orig-a.sh"; ok "dry-run-script-untouched" "$?" 0
ok  "dry-run-no-pin" "$(ls "$CRSS_SESSIONS_DIR/resume" 2>/dev/null | wc -l | tr -d ' ')" 0
ok  "dry-run-no-start" "$(grep -cE '^(start|enable)' "$STUB_STATE/systemctl.log" 2>/dev/null || true)" 0

# 3. refusals — each holder alone is enough.
touch "$STUB_STATE/tmux-live"
out="$(bash "$SR" px_rsm$$-a --dry-run 2>&1)"; ok "refuse-tmux-exit1" "$?" 1
has "refuse-tmux" "$out" "REFUSE: live: tmux session px_rsm$$-a exists"
not_has "refuse-tmux-no-dryrun-ok" "$out" "dry-run: nothing changed"
rm -f "$STUB_STATE/tmux-live"
echo active > "$STUB_STATE/$R.service.active"
out="$(bash "$SR" px_rsm$$-a 2>&1)"; ok "refuse-unit-active-exit1" "$?" 1
has "refuse-unit-active" "$out" "REFUSE: live: unit $R.service is active"
rm -f "$STUB_STATE/$R.service.active"
( exec -a "holder --remote-control $R" sleep 30 ) & hp=$!
sleep 0.3
out="$(bash "$SR" px_rsm$$-a --dry-run 2>&1)"; ok "refuse-remote-holder-exit1" "$?" 1
has "refuse-remote-holder" "$out" "already run --remote-control $R"
kill "$hp" 2>/dev/null; wait "$hp" 2>/dev/null
printf '{"pid": %s, "sessionId": "%s"}\n' "$$" "$NEW" > "$CRSS_CLAUDE_HOME/sessions/$$.json"
out="$(bash "$SR" px_rsm$$-a --dry-run 2>&1)"; ok "refuse-uuid-open-exit1" "$?" 1
has "refuse-uuid-open" "$out" "has transcript $NEW open"
rm -f "$CRSS_CLAUDE_HOME/sessions/$$.json"
out="$(bash "$SR" px_rsm$$-a --dry-run --uuid 33333333-3333-4333-8333-$UID12 2>&1)"; ok "refuse-foreign-uuid-exit1" "$?" 1
has "refuse-foreign-uuid" "$out" "is not under"
# Refusal in the real (non-dry) path must also change nothing.
touch "$STUB_STATE/tmux-live"; bash "$SR" px_rsm$$-a >/dev/null 2>&1; rm -f "$STUB_STATE/tmux-live"
cmp -s "$SC" "$T/orig-a.sh"; ok "refuse-script-untouched" "$?" 0

# 4. real run: patches the loop once, pins the uuid, starts the unit, and the
# relaunched claude carries the ORIGINAL flags plus --resume <uuid>.
: > "$STUB_STATE/systemctl.log"
out="$(bash "$SR" px_rsm$$-a --uuid "$NEW" 2>&1)"; rc=$?
ok  "run-exit0" "$rc" 0
has "run-ok-line" "$out" "OK: pid"
ok  "run-argv" "$(cat "$ARGV_LOG" 2>/dev/null)" "--dangerously-skip-permissions --model claude-opus-5-5 --exclude-dynamic-system-prompt-sections --effort low --advisor opus --settings $T/claude/rc-firstparty.settings.json --remote-control $R --resume $NEW"
ok  "run-systemctl-order" "$(grep -E '^(reset-failed|enable|start) ' "$STUB_STATE/systemctl.log" | cut -d' ' -f1 | tr '\n' ' ')" "reset-failed enable start "
ok  "run-pin-consumed" "$([ -e "$CRSS_SESSIONS_DIR/resume/$R.uuid" ] && echo left || echo gone)" gone
ok  "run-sentinel-touched" "$([ -f "$CRSS_CLAUDE_HOME/worktrees/$R/.sessions-init-$R" ] && echo yes || echo no)" yes
has "run-script-pin-aware" "$(cat "$SC")" "RESUME_PIN=\"$CRSS_SESSIONS_DIR/resume/$R.uuid\""
bash -n "$SC"; ok "run-script-bash-n" "$?" 0
bk="$(ls "$CRSS_RESUME_BACKUP_DIR"/"$R"-start.sh.* 2>/dev/null | head -1)"
cmp -s "$bk" "$T/orig-a.sh"; ok "run-backup-is-original" "$?" 0
pkill -f -- "--remote-control $R" 2>/dev/null; pkill -f -- "$T/scripts" 2>/dev/null
rm -f "$STUB_STATE/$R.service.active"; sleep 0.3
# This sandbox's pid 1 does not reap orphaned zombies (the loop and the fake
# claude it ran can die out of order), so the pid this test just killed can
# still answer `kill -0` as alive. Drop the registry entry we know is stale
# ourselves, or the next real run's own liveness check false-refuses on it.
rm -f "$CRSS_CLAUDE_HOME"/sessions/*.json

# 5. second resume of the now pin-aware script: no re-patch, still resumes.
cp "$SC" "$T/patched-a.sh"
out="$(bash "$SR" px_rsm$$-a --dry-run 2>&1)"
not_has "repeat-no-repatch" "$out" "supervisor loop to honour"
out="$(bash "$SR" px_rsm$$-a 2>&1)"; ok "repeat-run-exit0" "$?" 0
cmp -s "$SC" "$T/patched-a.sh"; ok "repeat-script-unchanged" "$?" 0
has "repeat-argv-resume" "$(cat "$ARGV_LOG")" "--remote-control $R --resume $NEW"
pkill -f -- "--remote-control $R" 2>/dev/null; rm -f "$STUB_STATE/$R.service.active"; sleep 0.3
rm -f "$CRSS_CLAUDE_HOME"/sessions/*.json  # see the stale-zombie-registry note above

# 6. --model rewrites MODEL= and every --model "..." — nothing else.
R=px-rsm$$-b; mk_session "$R" one; SC="$T/scripts/$R-start.sh"
out="$(bash "$SR" px_rsm$$-b --model sonnet 2>&1)"; ok "model-run-exit0" "$?" 0
ok  "model-argv" "$(cat "$ARGV_LOG")" "--dangerously-skip-permissions --model sonnet --exclude-dynamic-system-prompt-sections --effort low --advisor opus --settings $T/claude/rc-firstparty.settings.json --remote-control $R --resume $NEW"
has "model-field" "$(cat "$SC")" 'MODEL="sonnet"'
not_has "model-no-old-id" "$(cat "$SC")" "claude-opus-5-5"
pkill -f -- "--remote-control $R" 2>/dev/null; rm -f "$STUB_STATE/$R.service.active"; sleep 0.3
rm -f "$CRSS_CLAUDE_HOME"/sessions/*.json  # see the stale-zombie-registry note above

# 7. no transcript for the cwd -> refuse (nothing to resume).
R=px-rsm$$-c; mk_session "$R"
rm -f "$CRSS_CLAUDE_HOME/projects/$(printf '%s' "$CRSS_CLAUDE_HOME/worktrees/$R" | sed 's/[^A-Za-z0-9]/-/g')"/*.jsonl
out="$(bash "$SR" px_rsm$$-c --dry-run 2>&1)"; ok "no-transcript-exit1" "$?" 1
has "no-transcript-refuse" "$out" "nothing to resume"

# 7b. a configured LEGACY prefix maps <legacy>_x -> <legacy>-x -> its unit file;
# an unconfigured prefix is refused as unsafe (no literal prefix in the script).
R=px-rsm$$-l; mk_session "$R"; cp "$CRSS_UNIT_DIR/$R.service" "$CRSS_UNIT_DIR/oldhost-rsm$$-l.service"
out="$(bash "$SR" oldhost_rsm$$-l --dry-run 2>&1)"
has "legacy-prefix-reads-unit" "$out" "remote-control name: px-rsm$$-l"
not_has "legacy-prefix-maps-to-unit" "$out" "no unit file"
not_has "legacy-prefix-not-unsafe" "$out" "unsafe session name"
out="$(bash "$SR" zzz_rsm$$-l --dry-run 2>&1)"; ok "unknown-prefix-exit2" "$?" 2
has "unknown-prefix-unsafe" "$out" "unsafe session name"
out="$(CRSS_LEGACY_PREFIXES='' bash "$SR" oldhost_rsm$$-l --dry-run 2>&1)"; ok "legacy-unset-exit2" "$?" 2

# 8. codex-backend unit -> refused (session-resume does not handle Codex units; the Codex loop resumes its own pin).
R=px-rsm$$-d; mk_session "$R"; sed -i 's/^PROFILE=.*/&\nBACKEND=codex/' "$T/scripts/$R-start.sh"
out="$(bash "$SR" px_rsm$$-d --dry-run 2>&1)"; ok "codex-exit1" "$?" 1
has "codex-refused" "$out" "backend 'codex' is not supported"

# 9. new-session now GENERATES the pin-aware loop (session-resume sees nothing
# to patch), and its fresh branch touches the sentinel BEFORE launching claude,
# so a session killed from outside still restarts with --continue.
NH="$T/nshome"; mkdir -p "$NH/.sessions/ns-resume"
ln -sf "$HERE/../scripts/session-alias.sh" "$T/bin/session-alias"
HOME="$NH" SESSION_ALIAS_STORE="$T/alias-store" CRSS_HOME="$T/no-overlay" CRSS_SESSION_PREFIX=px \
  CRSS_CLAUDE_BIN="$T/bin/claude" bash "$NS" ns-resume sessions --alias nsr >/dev/null 2>&1
NSC="$(ls "$NH"/.local/bin/px-nsr-*-start.sh 2>/dev/null | head -1)"
ok "ns-script-generated" "$([ -f "$NSC" ] && echo yes || echo no)" yes
has "ns-script-pin" "$(cat "$NSC" 2>/dev/null)" "RESUME_PIN=\"$NH/.sessions/resume/"
payload="$(python3 -c 'import re,sys
s=open(sys.argv[1]).read()
print(re.search(r"tmux send-keys -t \"[^\"]+\" \x27(.*?\ndone)\x27", s, re.S).group(1))' "$NSC" 2>/dev/null)"
FRESH="$T/fresh"; mkdir -p "$FRESH"; rm -f "$ARGV_LOG" "$ARGV_LOG.sentinel"
( cd "$FRESH" || exit 1
  exec setsid timeout 5 bash -c "$payload" >/dev/null 2>&1 ) &
echo $! >> "$STUB_STATE/all.sids"
for _ in $(seq 1 30); do [ -f "$ARGV_LOG.sentinel" ] && break; sleep 0.2; done
ok "ns-sentinel-before-first-launch" "$(cat "$ARGV_LOG.sentinel" 2>/dev/null)" yes
not_has "ns-first-launch-fresh" "$(cat "$ARGV_LOG" 2>/dev/null)" "--continue"
NU="$(ls "$NH"/.config/systemd/user/px-nsr-*.service 2>/dev/null | head -1)"
if [ -n "$NU" ]; then
  out="$(CRSS_UNIT_DIR="$(dirname "$NU")" bash "$SR" "$(basename "$NU")" --dry-run 2>&1)"
  not_has "ns-no-patch-needed" "$out" "supervisor loop to honour"
  has "ns-launch-line-parsed" "$out" "launch line:  $T/bin/claude --dangerously-skip-permissions"
else
  fail=$((fail+1)); echo "FAIL: ns-unit-generated"
fi

# 10. canonical run dir held by ANOTHER live session's git-prep lock -> refuse
# (git-prep would start this one in a new worktree, away from its transcript).
R=px-rsm$$-e; CAN="$T/canon-e"; mkdir -p "$CAN"; git init -q -b main "$CAN"; git -C "$CAN" commit -q --allow-empty -m i
mk_session "$R"; SC="$T/scripts/$R-start.sh"
sed -i "s#^WORKDIR=.*#WORKDIR=\"$CAN\"#" "$SC"; git -C "$T/repo-$R" worktree remove --force "$CRSS_CLAUDE_HOME/worktrees/$R"
echo "[2026-01-01T01:01:02Z] session=px_rsm$$-e rundir=$CAN" >> "$CRSS_SESSIONS_DIR/session-starts.log"
mkdir -p "$CRSS_CLAUDE_HOME/projects/$(printf '%s' "$CAN" | sed 's/[^A-Za-z0-9]/-/g')"
echo '{}' > "$CRSS_CLAUDE_HOME/projects/$(printf '%s' "$CAN" | sed 's/[^A-Za-z0-9]/-/g')/$NEW.jsonl"
# A CLEAN canonical tree is not "dirty" (empty git status must not match).
out="$(bash "$SR" px_rsm$$-e --dry-run 2>&1)"; ok "canon-free-exit0" "$?" 0
not_has "canon-clean-not-dirty" "$out" "is dirty"
mkdir -p "$CRSS_CLAUDE_HOME/session-locks"
echo px_other > "$CRSS_CLAUDE_HOME/session-locks/$(printf '%s' "$CAN" | tr '/ ' '__')_$(printf '%s' "$CAN" | cksum | cut -d' ' -f1).owner"
touch "$STUB_STATE/tmux-live"   # stub: every has-session succeeds, incl. px_other...
out="$(bash "$SR" px_rsm$$-e --dry-run 2>&1)"; rm -f "$STUB_STATE/tmux-live"
has "canon-locked-refuse" "$out" "live session px_other holds the canonical tree"

# 11. unit starts but the process never shows up -> exit 3 (something may be
# running), distinct from a pre-start refusal's exit 1.
R=px-rsm$$-f; mk_session "$R" one
sed -i 's#^ExecStart=.*#ExecStart=/bin/true#' "$CRSS_UNIT_DIR/$R.service"
cp "$T/scripts/$R-start.sh" "$T/f.sh"; printf '[Unit]\n[Service]\nExecStart=%s\n' "$T/f.sh" > "$CRSS_UNIT_DIR/$R.service"
sed -i "s#tmux send-keys -t \"px_rsm$$-f\" .LOG_FILE#tmux send-keys -t \"px_rsm$$-f\" \x27exit 0\nLOG_FILE#" "$T/f.sh"
out="$(CRSS_RESUME_WAIT=2 bash "$SR" px_rsm$$-f 2>&1)"; ok "unverified-exit3" "$?" 3
has "unverified-fail-line" "$out" "FAIL: no process running"

# 12. several transcripts, no --uuid -> refuse and list them, even when one is
# clearly newest (a fresh transcript from a bad restart sits over the real one,
# as after a bad restart); --uuid names the one to resume.
R=px-rsm$$-g; mk_session "$R"
out="$(bash "$SR" px_rsm$$-g --dry-run 2>&1)"; ok "multi-transcript-exit1" "$?" 1
has "multi-transcript-refuse" "$out" "pass --uuid"
has "multi-transcript-lists-newest" "$out" "$NEW"
has "multi-transcript-lists-old" "$out" "$OLD"
not_has "multi-transcript-no-resume-uuid" "$out" "resume uuid:  $NEW"
out="$(bash "$SR" px_rsm$$-g --dry-run --uuid "$OLD" 2>&1)"; ok "multi-transcript-with-uuid-exit0" "$?" 0
has "multi-transcript-uuid-honoured" "$out" "resume uuid:  $OLD"
touch "$CRSS_CLAUDE_HOME/projects/$(printf '%s' "$CRSS_CLAUDE_HOME/worktrees/$R" | sed 's/[^A-Za-z0-9]/-/g')/$OLD.jsonl"
out="$(bash "$SR" px_rsm$$-g --dry-run 2>&1)"; ok "multi-transcript-same-minute-exit1" "$?" 1

# 13. registry never confirms the sessionId -> WARN + exit 3, never OK; the pin
# stays (only a confirmed run, or the loop after 30s, clears it).
R=px-rsm$$-h; mk_session "$R" one
out="$(FAKE_CLAUDE_NOREG=1 CRSS_RESUME_REG_WAIT=2 bash "$SR" px_rsm$$-h 2>&1)"; ok "noreg-exit3" "$?" 3
has "noreg-warn" "$out" "WARN:"
has "noreg-not-confirmed" "$out" "NOT confirmed"
not_has "noreg-no-ok-line" "$out" "OK: pid"
ok "noreg-pin-kept" "$([ -s "$CRSS_SESSIONS_DIR/resume/$R.uuid" ] && echo kept || echo gone)" kept
pkill -f -- "--remote-control $R" 2>/dev/null; rm -f "$STUB_STATE/$R.service.active"; sleep 0.3
rm -f "$CRSS_CLAUDE_HOME"/sessions/*.json  # see the stale-zombie-registry note above
rm -f "$CRSS_SESSIONS_DIR/resume/$R.uuid"

# 14. the loop keeps the pin when claude exits at once (bad/corrupt transcript):
# after the pause the next iteration must retry --resume, not fall back to
# --continue. Uses the loop new-session generated for test 9.
PINF="$(sed -n 's/^RESUME_PIN="\(.*\)"$/\1/p' "$NSC" | head -1)"
mkdir -p "$(dirname "$PINF")"; printf '%s\n' "$NEW" > "$PINF"
QK="$T/quick"; mkdir -p "$QK"; rm -f "$ARGV_LOG"
( cd "$QK" || exit 1
  exec env FAKE_CLAUDE_EXIT=1 setsid timeout 3 bash -c "$payload" >/dev/null 2>&1 ) &
echo $! >> "$STUB_STATE/all.sids"
for _ in $(seq 1 30); do [ -s "$ARGV_LOG" ] && break; sleep 0.2; done; sleep 1
has "ns-quick-exit-resumed" "$(cat "$ARGV_LOG")" "--resume $NEW"
ok  "ns-quick-exit-pin-kept" "$([ -s "$PINF" ] && echo kept || echo gone)" kept
ok  "ns-quick-exit-sentinel" "$(ls "$QK"/.sessions-init-* >/dev/null 2>&1 && echo yes || echo no)" yes

# ...and clears it once claude has run long enough (threshold shortened here).
LP="$(printf '%s' "$payload" | sed 's/"\$RUNTIME" -ge 30/"$RUNTIME" -ge 1/')"
not_has "ns-threshold-patched" "$LP" '-ge 30'
LK="$T/long"; mkdir -p "$LK"; rm -f "$ARGV_LOG"
( cd "$LK" || exit 1
  exec env FAKE_CLAUDE_SLEEP=2 setsid timeout 4 bash -c "$LP" >/dev/null 2>&1 ) &
echo $! >> "$STUB_STATE/all.sids"
for _ in $(seq 1 40); do [ -s "$ARGV_LOG" ] && break; sleep 0.2; done; sleep 3
has "ns-long-run-resumed" "$(cat "$ARGV_LOG")" "--resume $NEW"
ok  "ns-long-run-pin-cleared" "$([ -s "$PINF" ] && echo kept || echo gone)" gone

# 15. a pre-pin script patched by session-resume gets the same keep-until-30s loop.
has "patched-loop-pinned-flag" "$(cat "$T/scripts/px-rsm$$-a-start.sh")" 'PINNED=1'
has "patched-loop-pin-cleared-after-run" "$(cat "$T/scripts/px-rsm$$-a-start.sh")" 'if [ "$PINNED" = 1 ] && [ "$RUNTIME" -ge 30 ]; then rm -f "$RESUME_PIN"; fi'
not_has "patched-loop-no-early-rm" "$(cat "$T/scripts/px-rsm$$-a-start.sh")" 'PINNED=1; rm'

echo "session-resume: pass=$pass fail=$fail"; [ "$fail" -eq 0 ]
