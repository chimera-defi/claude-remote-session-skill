#!/usr/bin/env bash
# session-resume <session> [--uuid <transcript-uuid>] [--model <alias-or-id>] [--dry-run]
#
# Bring a dead Claude session back ON ITS OWN systemd unit, resuming ITS OWN
# transcript by explicit uuid. This is the supported replacement for
# hand-relaunching (`claude --resume <uuid> ...` typed into a fresh tmux pane),
# which on 2026-09-29 silently dropped --dangerously-skip-permissions, swapped
# /usr/bin/claude for the npm-global CLI and left the unit failed+disabled, so
# every relaunched owner stalled on approval prompts nobody could see.
#
# What it does (every step is printed; --dry-run stops before any change):
#   1. Reads the unit's ExecStart -> the generated start script, and from that
#      script SESSION / REMOTE_NAME / WORKDIR and the exact claude launch line
#      (binary + flags). Nothing about the launch is re-typed from memory.
#   2. Refuses if anything still holds the session: the tmux session exists,
#      the unit is active, a process runs `--remote-control <remote>`, or a
#      live Claude process has the transcript uuid open.
#   3. Resolves the run directory the unit will start in and the transcript
#      uuid to resume (--uuid, which must live in that same cwd's transcript dir;
#      omitted, it is taken only when exactly ONE transcript exists — with
#      several it refuses and lists them, never guessing "newest").
#   4. If the start script predates resume pins, patches its supervisor loop
#      once (backup kept): a one-shot pin file makes the loop launch the SAME
#      binary+flags with `--resume <uuid>` instead of `--continue`/fresh.
#      --model rewrites the script's model (MODEL= and every --model "...").
#   5. Writes the pin, then `systemctl --user reset-failed/enable/start` the unit.
#   6. Verifies the relaunched claude process: same binary, skip-permissions,
#      --remote-control <remote>, --resume <uuid>, and Claude's own session
#      registry showing that sessionId. A missing registry entry is a WARN and
#      exit 3, never OK.
#
# Exit: 0 resumed+verified (or dry-run with nothing blocking); 1 refused or
# failed BEFORE the unit start (nothing is running); 2 usage error; 3 the unit
# started but the relaunched process failed verification (something IS running
# — inspect it before retrying).
set -uo pipefail

usage() { sed -n '2,3p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

CLAUDE_HOME="${CRSS_CLAUDE_HOME:-$HOME/.claude}"
UNIT_DIR="${CRSS_UNIT_DIR:-$HOME/.config/systemd/user}"
SESSIONS_DIR="${CRSS_SESSIONS_DIR:-$HOME/.sessions}"
BACKUP_DIR="${CRSS_RESUME_BACKUP_DIR:-$HOME/backups/session-resume}"
WAIT_SECS="${CRSS_RESUME_WAIT:-60}"
REG_WAIT="${CRSS_RESUME_REG_WAIT:-15}"
LOG_FILE="$SESSIONS_DIR/session-starts.log"
PIN_DIR="$SESSIONS_DIR/resume"

TARGET="" UUID="" NEW_MODEL="" DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --uuid)    UUID="${2:-}"; shift 2 || usage ;;
    --model)   NEW_MODEL="${2:-}"; shift 2 || usage ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage ;;
    -*)        echo "session-resume: unknown flag $1" >&2; usage ;;
    *)         [ -z "$TARGET" ] || usage; TARGET="$1"; shift ;;
  esac
done
[ -n "$TARGET" ] || usage
if [ -n "$UUID" ] && ! [[ "$UUID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
  echo "session-resume: --uuid must be a lowercase transcript uuid" >&2; exit 2
fi
if [ -n "$NEW_MODEL" ] && ! [[ "$NEW_MODEL" =~ ^[a-z0-9][a-z0-9.-]*$ ]]; then
  echo "session-resume: --model must match ^[a-z0-9][a-z0-9.-]*\$ (e.g. sonnet, claude-opus-5-5)" >&2; exit 2
fi

REFUSE=()
refuse() { REFUSE+=("$1"); }
say() { printf '%s\n' "$*"; }

# ── 1. unit -> start script -> fields ────────────────────────────────────────
# Accept the tmux name (ah_x), the remote/unit name (ah-x) or the unit file name.
base="${TARGET%.service}"
case "$base" in
  ah_*)        base="ah-${base#ah_}" ;;
  agenthost_*) base="agenthost-${base#agenthost_}" ;;
esac
if ! [[ "$base" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
  echo "session-resume: unsafe session name '$TARGET'" >&2; exit 2
fi
UNIT="$base.service"
UNIT_FILE="$UNIT_DIR/$UNIT"
if [ ! -f "$UNIT_FILE" ]; then
  echo "session-resume: no unit file $UNIT_FILE — this session was not spawned by new-session (or was reaped); nothing to resume through" >&2
  exit 1
fi
SCRIPT="$(sed -n 's/^ExecStart=//p' "$UNIT_FILE" | head -1)"
if [ -z "$SCRIPT" ] || [ ! -f "$SCRIPT" ]; then
  echo "session-resume: $UNIT ExecStart '$SCRIPT' is not a readable start script" >&2; exit 1
fi

# Same dual-format reader as session-handoff's _start_script_field: old scripts
# write FIELD="value", new ones FIELD=%q.
field() {
  local line
  line="$(grep -m1 -E "^$1=" "$SCRIPT" 2>/dev/null)" || return 1
  python3 -c 'import shlex,sys
p=shlex.split(sys.argv[1]); sys.exit(1) if len(p)!=1 else print(p[0])' "${line#*=}"
}
SESSION="$(field SESSION)" || { echo "session-resume: no SESSION= in $SCRIPT" >&2; exit 1; }
REMOTE="$(field REMOTE_NAME)" || { echo "session-resume: no REMOTE_NAME= in $SCRIPT" >&2; exit 1; }
WORKDIR="$(field WORKDIR)" || { echo "session-resume: no WORKDIR= in $SCRIPT" >&2; exit 1; }
MODEL="$(field MODEL)" || MODEL="?"
BACKEND="$(field BACKEND)" || BACKEND=claude

say "session:      $SESSION   (remote-control name: $REMOTE)"
say "unit:         $UNIT   [$(systemctl --user is-active "$UNIT" 2>/dev/null || true)/$(systemctl --user is-enabled "$UNIT" 2>/dev/null || true)]"
say "start script: $SCRIPT"
say "backend:      $BACKEND   model: $MODEL${NEW_MODEL:+ -> $NEW_MODEL}"

if [ "$BACKEND" != claude ]; then
  echo "session-resume: backend '$BACKEND' is not supported — the Codex supervisor loop has no resume path (every unit start is a fresh Codex session)" >&2
  exit 1
fi

# The claude launch line: the loop's no-sentinel branch (binary + flags, no
# --continue). Both loop shapes (pre-pin and pin-aware) contain it verbatim.
LAUNCH="$(python3 - "$SCRIPT" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().splitlines()
cont = [l for l in lines if re.search(r'--remote-control \S+ --continue$', l)]
fresh = [l for l in lines if re.search(r'^\s+\S*claude .*--remote-control \S+$', l)]
if len(cont) != 1 or len(fresh) != 1 or cont[0] != fresh[0] + ' --continue':
    sys.exit(1)
print(fresh[0].strip())
PY
)" || { echo "session-resume: could not find exactly one matching claude launch pair (fresh + --continue) in $SCRIPT — unknown start-script shape, refusing to guess" >&2; exit 1; }
BIN="${LAUNCH%% *}"
say "launch line:  $LAUNCH"
case " $LAUNCH " in
  *" --dangerously-skip-permissions "*) ;;
  *) refuse "start script's launch line lacks --dangerously-skip-permissions — not a new-session start script this tool can vouch for" ;;
esac

# ── 2. run directory + transcript ────────────────────────────────────────────
# Where the unit will start: session-git-prep reuses this session's own
# registered worktree (<claude-home>/worktrees/<remote>) first, else runs in
# the canonical WORKDIR when it is clean and unclaimed.
OWN_WT="$CLAUDE_HOME/worktrees/$REMOTE"
LOGGED_RUNDIR="$(grep -F "session=$SESSION rundir=" "$LOG_FILE" 2>/dev/null | tail -1 | sed 's/.* rundir=//')"
# (Capture, then grep: `git … | grep -q` under pipefail reads a SIGPIPE'd git
# as "not found".)
WT_LIST="$(git -C "$WORKDIR" worktree list --porcelain 2>/dev/null || true)"
if [ -d "$OWN_WT" ] && grep -qxF "worktree $OWN_WT" <<<"$WT_LIST"; then
  RUNDIR="$OWN_WT"
elif ! git -C "$WORKDIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  RUNDIR="$WORKDIR"
else
  RUNDIR="$WORKDIR"
  # (A herestring of empty status is one empty line, which `grep -v` matches.)
  st="$(git -C "$WORKDIR" status --porcelain 2>/dev/null)"
  if [ -n "$st" ] && grep -qvE '^.. (\.claude(/|$)|\.sessions-init)' <<<"$st"; then
    refuse "run directory: the canonical tree $WORKDIR is dirty and there is no own worktree $OWN_WT, so the unit would start in a NEW worktree — not where this session's transcript lives (commit or WIP-commit the canonical tree's changes first, or spawn fresh with new-session)"
  fi
  # session-git-prep also treats the canonical tree as busy while its owner lock
  # (same key derivation, current and legacy format) names another live tmux
  # session; then it would put this session in a new worktree too.
  flat="$(printf '%s' "$WORKDIR" | tr '/ ' '__')"
  for lk in "${flat}_$(printf '%s' "$WORKDIR" | cksum | cut -d' ' -f1)" "$flat"; do
    owner="$(cat "$CLAUDE_HOME/session-locks/$lk.owner" 2>/dev/null || true)"
    if [ -n "$owner" ] && [ "$owner" != "$SESSION" ] && tmux has-session -t "=$owner" 2>/dev/null; then
      refuse "run directory: live session $owner holds the canonical tree $WORKDIR, so the unit would start in a NEW worktree — not where this session's transcript lives"
    fi
  done
fi
say "run dir:      $RUNDIR${LOGGED_RUNDIR:+   (last logged: $LOGGED_RUNDIR)}"
if [ -n "$LOGGED_RUNDIR" ] && [ "$LOGGED_RUNDIR" != "$RUNDIR" ]; then
  refuse "run directory: the unit would start in $RUNDIR but the session last ran in $LOGGED_RUNDIR"
fi

# ~/.claude/projects/<cwd with every non-alphanumeric char -> '-'>
PROJ="$CLAUDE_HOME/projects/$(printf '%s' "$RUNDIR" | sed 's/[^A-Za-z0-9]/-/g')"
say "transcripts:  $PROJ"
if [ -d "$PROJ" ]; then
  # shellcheck disable=SC2012
  ls -t "$PROJ" 2>/dev/null | grep -E '^[0-9a-f-]{36}\.jsonl$' | head -5 | while read -r f; do
    say "  $(date -u -r "$PROJ/$f" +%Y-%m-%dT%H:%MZ)  $(du -h "$PROJ/$f" | cut -f1)  ${f%.jsonl}"
  done
fi
if [ -z "$UUID" ]; then
  # shellcheck disable=SC2012
  UUID="$(ls -t "$PROJ" 2>/dev/null | grep -E '^[0-9a-f-]{36}\.jsonl$' | head -1)"
  UUID="${UUID%.jsonl}"
  [ -n "$UUID" ] || refuse "transcript: no <uuid>.jsonl under $PROJ — nothing to resume (pass --uuid, or spawn fresh with new-session)"
  # Never guess between transcripts: the newest one is not necessarily the real
  # one (ah-spx-successor 2026-09-30: a bare restart had made a fresh, newest
  # transcript sitting over the conversation to recover). Auto-pick only when
  # exactly one exists; otherwise the caller names the uuid.
  # shellcheck disable=SC2012
  all="$(ls -t "$PROJ" 2>/dev/null | grep -E '^[0-9a-f-]{36}\.jsonl$' | sed 's/\.jsonl$//' || true)"
  if [ "$(printf '%s\n' "$all" | grep -c .)" -gt 1 ]; then
    refuse "transcript: $(printf '%s\n' "$all" | grep -c .) transcripts under $PROJ (newest first: $(printf '%s' "$all" | head -5 | tr '\n' ' ')) — pass --uuid <the one to resume>; the newest is not necessarily the real conversation"
    UUID=""
  fi
elif [ ! -f "$PROJ/$UUID.jsonl" ]; then
  refuse "transcript: $UUID.jsonl is not under $PROJ — resuming it would move the conversation to a different cwd"
fi
say "resume uuid:  ${UUID:-<none>}"

# ── 3. is anything still holding the session? ────────────────────────────────
if tmux has-session -t "=$SESSION" 2>/dev/null; then
  refuse "live: tmux session $SESSION exists (attach to it, or reap it first)"
fi
if systemctl --user is-active --quiet "$UNIT" 2>/dev/null; then
  refuse "live: unit $UNIT is active (if its tmux session is gone, stop it first: systemctl --user stop $UNIT)"
fi
holders="$(pgrep -af -- "--remote-control $REMOTE( |\$)" 2>/dev/null | grep -v -- 'session-resume' || true)"
[ -n "$holders" ] && refuse "live: process(es) already run --remote-control $REMOTE: $(printf '%s' "$holders" | cut -c1-160 | tr '\n' ';')"
if [ -n "$UUID" ]; then
  byid="$(pgrep -af -- "$UUID" 2>/dev/null | grep -v -- 'session-resume' || true)"
  [ -n "$byid" ] && refuse "live: process(es) reference transcript $UUID: $(printf '%s' "$byid" | cut -c1-160 | tr '\n' ';')"
  for j in "$CLAUDE_HOME"/sessions/*.json; do
    [ -f "$j" ] || continue
    read -r jpid jsid < <(python3 -c 'import json,sys
d=json.load(open(sys.argv[1])); print(d.get("pid",""), d.get("sessionId",""))' "$j" 2>/dev/null) || continue
    if [ "$jsid" = "$UUID" ] && [ -n "$jpid" ] && kill -0 "$jpid" 2>/dev/null; then
      refuse "live: Claude pid $jpid has transcript $UUID open ($j)"
    fi
  done
fi

# ── 4. plan ──────────────────────────────────────────────────────────────────
# A pin-aware script (new-session since session-resume, or one this tool
# already patched) names its own pin path; honour it over the default.
NEEDS_PATCH=0
PIN="$(field RESUME_PIN)" || { PIN="$PIN_DIR/$REMOTE.uuid"; NEEDS_PATCH=1; }
say "plan:"
[ "$NEEDS_PATCH" = 1 ] && say "  - patch $SCRIPT supervisor loop to honour a one-shot resume pin (backup -> $BACKUP_DIR/)"
[ -n "$NEW_MODEL" ] && say "  - set model $MODEL -> $NEW_MODEL in $SCRIPT"
say "  - write $PIN = ${UUID:-<none>}"
say "  - systemctl --user reset-failed $UNIT; systemctl --user enable $UNIT; systemctl --user start $UNIT"
say "  - expect: $BIN ${LAUNCH#* } --resume ${UUID:-<none>}"
if [ -n "$NEW_MODEL" ]; then
  say "    (with --model \"$NEW_MODEL\")"
fi

if [ "${#REFUSE[@]}" -gt 0 ]; then
  for r in "${REFUSE[@]}"; do say "REFUSE: $r"; done
  exit 1
fi
if [ "$DRY" = 1 ]; then
  say "dry-run: nothing changed"
  exit 0
fi

# ── 5. act ───────────────────────────────────────────────────────────────────
if [ "$NEEDS_PATCH" = 1 ] || [ -n "$NEW_MODEL" ]; then
  mkdir -p "$BACKUP_DIR" || { echo "session-resume: cannot create $BACKUP_DIR" >&2; exit 1; }
  bk="$BACKUP_DIR/$(basename "$SCRIPT").$(date -u +%Y%m%dT%H%M%SZ)"
  cp -p "$SCRIPT" "$bk" || { echo "session-resume: backup to $bk failed" >&2; exit 1; }
  say "backup:       $bk"
  tmp="$(mktemp "$SCRIPT.XXXXXX")" || exit 1
  trap 'rm -f "$tmp"' EXIT
  if ! python3 - "$SCRIPT" "$PIN" "$NEEDS_PATCH" "$NEW_MODEL" >"$tmp" <<'PY'
import re, sys
path, pin, needs_patch, new_model = sys.argv[1], sys.argv[2], sys.argv[3] == '1', sys.argv[4]
lines = open(path).read().split('\n')
out = []
i = 0
patched = False
pin_rm = False
while i < len(lines):
    l = lines[i]
    if needs_patch and l.startswith('SENTINEL=') and not patched:
        out.append(l)
        out.append('RESUME_PIN="%s"' % pin)
        i += 1
        continue
    # pre-pin loop shape:
    #   if [ -f "$SENTINEL" ]; then / <cont> / else / <fresh> / touch "$SENTINEL" / fi
    if needs_patch and l.strip() == 'if [ -f "$SENTINEL" ]; then' and i + 5 < len(lines):
        cont, els, fresh, touch, fi = lines[i+1:i+6]
        ind = l[:len(l) - len(l.lstrip())]
        if (cont == fresh + ' --continue' and els.strip() == 'else'
                and touch.strip() == 'touch "$SENTINEL"' and fi.strip() == 'fi'):
            body = fresh[:len(fresh) - len(fresh.lstrip())]
            out += [ind + 'PINNED=0',
                    ind + 'if [ -s "$RESUME_PIN" ]; then',
                    body + 'RESUME_ID=$(cat "$RESUME_PIN"); PINNED=1; touch "$SENTINEL"',
                    fresh + ' --resume "$RESUME_ID"',
                    ind + 'elif [ -f "$SENTINEL" ]; then',
                    cont,
                    els,
                    body + 'touch "$SENTINEL"',
                    fresh,
                    fi]
            patched = True
            i += 6
            continue
    out.append(l)
    # The pin outlives the launch: it is cleared only once claude has run 30s+
    # (same threshold as the quick-exit backoff), else the next loop would fall
    # back to --continue and lose the explicit uuid.
    if needs_patch and patched and not pin_rm and l.lstrip().startswith('RUNTIME='):
        ind = l[:len(l) - len(l.lstrip())]
        out.append(ind + 'if [ "$PINNED" = 1 ] && [ "$RUNTIME" -ge 30 ]; then rm -f "$RESUME_PIN"; fi')
        pin_rm = True
    i += 1
if needs_patch and not (patched and pin_rm):
    sys.exit(3)
text = '\n'.join(out)
if new_model:
    text, n = re.subn(r'^MODEL=.*$', 'MODEL="%s"' % new_model, text, flags=re.M)
    text, m = re.subn(r'--model "[^"]*"', '--model "%s"' % new_model, text)
    if n != 1 or m < 2:
        sys.exit(4)
sys.stdout.write(text)
PY
  then
    rm -f "$tmp"
    echo "session-resume: could not rewrite $SCRIPT (unexpected loop shape); unchanged, backup at $bk" >&2
    exit 1
  fi
  if ! bash -n "$tmp"; then
    rm -f "$tmp"; echo "session-resume: rewritten script fails bash -n; $SCRIPT unchanged" >&2; exit 1
  fi
  chmod --reference="$SCRIPT" "$tmp" && mv "$tmp" "$SCRIPT" || { rm -f "$tmp"; exit 1; }
  say "patched:      $SCRIPT"
  [ -n "$NEW_MODEL" ] && BIN_MODEL="$NEW_MODEL"
fi

mkdir -p "$(dirname "$PIN")" && printf '%s\n' "$UUID" > "$PIN" || { echo "session-resume: cannot write $PIN" >&2; exit 1; }
say "pin:          $PIN"
systemctl --user reset-failed "$UNIT" 2>/dev/null || true
systemctl --user enable "$UNIT" || { echo "session-resume: enable $UNIT failed" >&2; exit 1; }
systemctl --user start "$UNIT" || { echo "session-resume: start $UNIT failed — see: journalctl --user -u $UNIT" >&2; exit 1; }
say "started:      $UNIT [$(systemctl --user is-active "$UNIT" 2>/dev/null)/$(systemctl --user is-enabled "$UNIT" 2>/dev/null)]"

# ── 6. verify ────────────────────────────────────────────────────────────────
pid="" cmd=""
for _ in $(seq 1 "$WAIT_SECS"); do
  pid="$(pgrep -f -- "--remote-control $REMOTE --resume $UUID" 2>/dev/null | head -1)"
  [ -n "$pid" ] && break
  sleep 1
done
if [ -z "$pid" ]; then
  say "FAIL: no process running '--remote-control $REMOTE --resume $UUID' after ${WAIT_SECS}s (pin left: $( [ -f "$PIN" ] && echo yes || echo no )) — check: tmux capture-pane -p -t $SESSION"
  exit 3
fi
cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || ps -o args= -p "$pid")"
bad=0
case " $cmd " in *" --dangerously-skip-permissions "*) ;; *) say "FAIL: pid $pid lacks --dangerously-skip-permissions: $cmd"; bad=1 ;; esac
exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
case "$cmd" in
  "$BIN "*|*" $BIN "*) ;;
  *) say "FAIL: pid $pid is not $BIN: $cmd"; bad=1 ;;
esac
if [ -n "${BIN_MODEL:-}" ]; then
  case "$cmd" in *"--model $BIN_MODEL "*) ;; *) say "FAIL: pid $pid is not on --model $BIN_MODEL: $cmd"; bad=1 ;; esac
fi
sid=""
for _ in $(seq 1 "$REG_WAIT"); do
  [ -f "$CLAUDE_HOME/sessions/$pid.json" ] && sid="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("sessionId",""))' "$CLAUDE_HOME/sessions/$pid.json" 2>/dev/null)"
  [ -n "$sid" ] && break
  sleep 1
done
pcwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
if [ -n "$pcwd" ] && [ "$pcwd" != "$(readlink -f "$RUNDIR")" ]; then
  say "FAIL: pid $pid runs in $pcwd, not $RUNDIR"; bad=1
fi
if [ -n "$sid" ] && [ "$sid" != "$UUID" ]; then
  say "FAIL: pid $pid registered sessionId $sid, not $UUID"; bad=1
fi
# argv proves only what we asked for; the registry proves what Claude opened.
if [ -z "$sid" ]; then
  say "WARN: pid $pid started with --resume $UUID but Claude's registry ($CLAUDE_HOME/sessions/$pid.json) has no sessionId after ${REG_WAIT}s — NOT confirmed; the pin stays until the loop clears it after a 30s run. Check: session-handoff check $SESSION"
  bad=1
fi
[ "$bad" = 0 ] || exit 3
# Confirmed: Claude accepted the uuid, so the pin has done its job. Dropping it
# now keeps a later external kill from replaying a stale uuid.
rm -f "$PIN"
say "OK: pid $pid${exe:+ ($exe)} resumed $UUID on $UNIT with its own flags; Claude registry sessionId=$sid"
