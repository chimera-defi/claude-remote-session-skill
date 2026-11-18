#!/usr/bin/env bash
# End-to-end test for scripts/crss.sh: real tmux on a private socket, fake HOME, fake claude.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); C=$ROOT/scripts/crss.sh
T=$(mktemp -d); SOCK=crss-test-$$; F=0
export HOME=$T/home CRSS_STATE=$T/state CRSS_TMUX="tmux -L $SOCK" CRSS_CLAUDE=$T/claude CRSS_CONFIG=$T/none
export CRSS_BACKOFF=1 CRSS_PAUSE=1 CRSS_NO_SYSTEMD=1 FAKE_LOG=$T/log TERM=xterm
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
unset TMUX CLAUDE_CODE_SESSION_ID CRSS_BY CLAUDE_CODE_EXPERIMENTAL_CODE_MODE; export CRSS_CGROUP=/dev/null; mkdir -p "$HOME/.claude" "$T/work" "$T/proj"; echo '{}' >"$HOME/.claude.json"
ln -s "$T/proj" "$HOME/.claude/projects" # a symlink, as on a host that keeps transcripts elsewhere
trap 'tmux -L $SOCK kill-server 2>/dev/null; rm -rf "$T"' EXIT

cat >"$T/claude" <<'PY'
#!/usr/bin/env python3
import json, os, sys, threading, tty, uuid
a = sys.argv
sid = next(a[i + 1] for i, x in enumerate(a) if x in ("--session-id", "--resume"))
rec = os.environ["HOME"] + "/.claude/sessions/%d.json" % os.getpid()
def w(st):
    os.makedirs(os.path.dirname(rec), exist_ok=True)
    open(rec + ".t", "w").write(json.dumps({"pid": os.getpid(), "sessionId": sid, "status": st, "version": "fake"}))
    os.replace(rec + ".t", rec)
w("idle")
open(os.environ["FAKE_LOG"] + ".args", "a").write(json.dumps(a[1:]) + "\n")
open(os.environ["FAKE_LOG"] + ".cm", "a").write(os.environ.get("CLAUDE_CODE_EXPERIMENTAL_CODE_MODE", "-") + " " + json.dumps(a[1:]) + "\n")
sys.stdout.write("\x1b[?2004h"); sys.stdout.flush()  # enable bracketed paste, as the real TUI does
tty.setraw(0)
buf, paste, d = "", False, ""
while True:
    d += os.read(0, 4096).decode()
    while d:
        if d.startswith("\x1b[200~"): paste, d = True, d[6:]
        elif d.startswith("\x1b[201~"): paste, d = False, d[6:]
        elif d[0] in "\r\n" and not paste:
            msg, buf, d = buf, "", d[1:]
            if msg == "/exit": os.remove(rec); sys.exit(0)
            if msg == "/clear": sid = str(uuid.uuid4()); w("idle"); continue  # handled in the TUI: a new session id, no turn
            if msg.startswith("/rename "):  # handled in the TUI: a title line (trimmed), no turn, status stays idle
                open(os.environ["HOME"] + "/.claude/projects/p/%s.jsonl" % sid, "a").write(json.dumps({"type": "custom-title", "customTitle": msg[8:].strip(), "sessionId": sid}, separators=(",", ":")) + "\n")
                continue
            if msg.startswith("/local"):  # a local command: lines in the transcript, status unchanged (user shape, or system/local_command)
                tr = open(os.environ["HOME"] + "/.claude/projects/p/%s.jsonl" % sid, "a"); sysf = msg.startswith("/localsys")
                def line(c): return json.dumps({"type": "system", "subtype": "local_command", "content": c} if sysf else {"type": "user", "message": {"content": c}}) + "\n"
                if "none" in msg: tr.close(); continue  # a command that leaves nothing in the transcript
                if "other" in msg: tr.write(line("<command-name>/zzz</command-name>")); tr.close(); continue  # some other command's lines
                tr.write(line("<command-name>%s</command-name>\n<command-args>x</command-args>" % msg.split()[0]))
                if "quiet" not in msg: tr.write(line("<local-command-stdout>\n\x1b[1mMCP server \"x\" not found\x1b[22m\nsecond</local-command-stdout>"))
                tr.close(); continue
            open(os.environ["FAKE_LOG"], "a").write(json.dumps(msg) + "\n")
            os.makedirs(os.environ["HOME"] + "/.claude/projects/p", exist_ok=True)
            tr = open(os.environ["HOME"] + "/.claude/projects/p/%s.jsonl" % sid, "a")
            tr.write(json.dumps(msg) + "\n" + json.dumps({"type": "user", "message": {"content": msg}}) + "\n")
            if msg == "park":  # the turn ends and leaves a background command: status stays shell, as the real CLI reports it
                tr.write(json.dumps({"type": "assistant", "message": {"stop_reason": "end_turn"}}) + "\n" + json.dumps({"type": "user", "isMeta": True, "message": {"content": "note"}}) + "\n")
                tr.close(); w("shell"); continue
            if msg == "midturn":  # a turn in progress with a command running, and a sub-agent that has finished
                tr.write(json.dumps({"type": "assistant", "message": {"stop_reason": "tool_use"}}) + "\n" + json.dumps({"type": "assistant", "isSidechain": True, "message": {"stop_reason": "end_turn"}}) + "\n")
                tr.close(); w("shell"); continue
            tr.close()
            w("shell" if msg == "run-shell" else "busy"); threading.Timer(2, w, ["idle"]).start()
        else: buf, d = buf + ("\n" if d[0] == "\r" else d[0]), d[1:]
PY
chmod +x "$T/claude"

check() { if "${@:2}"; then echo "PASS: $1"; else echo "FAIL: $1"; F=1; fi; }
wait_for() { local _; for _ in $(seq "$1"); do eval "$2" && return 0; sleep 1; done; return 1; }
st() { "$C" ls --json | jq -r --arg n "$1" '.[]|select(.name==$n)|.status'; }
sid() { "$C" ls --json | jq -r --arg n "$1" '.[]|select(.name==$n)|.sid'; }
recsid() { jq -r .sessionId "$HOME"/.claude/sessions/*.json; }
idle() { wait_for 20 '[ "$(st '"$1"')" = idle ]'; }

# 1. spawn, ls, send a multi-line file, restart keeps the session id
"$C" spawn a1 "$T/work" -- --foo >/dev/null
check "spawn: ls reports idle" idle a1
printf 'l1\nl2\nl3' >"$T/msg"
out=$("$C" send a1 --file "$T/msg")
check "send: receipt delivered" [ "$out" = delivered ]
"$C" send nosuch hi 2>/dev/null; check "send: unknown session refused with 2" [ $? = 2 ]
check "send: 3 lines arrive as one message" wait_for 5 '[ "$(tail -1 "$FAKE_LOG")" = "\"l1\\nl2\\nl3\"" ]'
idle a1; out=$("$C" send a1 run-shell); check "send: shell status counts as delivered" [ "$out" = delivered ]
out=$("$C" send a1 behind); check "send: queued behind a shell command" [ "$out" = "queued (session shell)" ]
S0=$(sid a1); P0=$(ls "$HOME/.claude/sessions")
idle a1
out=$("$C" restart a1)
check "restart: same sessionId, new pid" bash -c "[ \"\$(ls '$HOME/.claude/sessions')\" != '$P0' ] && [ \"\$(jq -r .sessionId '$HOME'/.claude/sessions/*.json)\" = '$S0' ] && [[ '$out' == *'sessionId=$S0'* ]]"

check "loop: pane reports the claude process, not bash" [ "$(tmux -L "$SOCK" display -p -t =ah_a1: '#{pane_current_command}')" != bash ]

# 2. killed tmux session comes back on the same session id with --resume; a1-x shares the prefix
"$C" spawn a1-x "$T/work" >/dev/null; idle a1-x
tmux -L "$SOCK" kill-session -t =ah_a1
"$C" send a1 hi 2>/dev/null; check "send: down session refused with 2" [ $? = 2 ]
check "tmux targets are exact: a1-x untouched" bash -c "! grep -qx '\"hi\"' '$FAKE_LOG'"
"$C" up >/dev/null
check "up: back up on same sid" idle a1
check "up: relaunched with --resume" grep -qF "\"--resume\", \"$S0\"" <(tail -1 "$FAKE_LOG.args")
check "up: sid unchanged" [ "$(sid a1)" = "$S0" ]

# 3. reap
mkdir -p "$T/rem.git" && git -c init.defaultBranch=main init -q --bare "$T/rem.git"
git clone -q "$T/rem.git" "$T/repo" 2>/dev/null
git -C "$T/repo" checkout -q -b main && git -C "$T/repo" commit -q --allow-empty -m init && git -C "$T/repo" push -q origin main
wt() { echo "$HOME/.claude/worktrees/$1"; }
"$C" spawn r1 "$T/repo" --worktree >/dev/null; echo x >"$(wt r1)/untracked"
check "spawn: trust written for the main repo root" wait_for 10 "jq -e '.projects[\"$T/repo\"].hasTrustDialogAccepted' '$HOME/.claude.json' >/dev/null"
"$C" reap r1 >/dev/null
check "reap untracked: worktree kept, env gone" bash -c "[ -d '$(wt r1)' ] && [ ! -e '$CRSS_STATE/r1.env' ]"
"$C" spawn r2 "$T/repo" --worktree >/dev/null; git -C "$(wt r2)" commit -q --allow-empty -m local
"$C" reap r2 >/dev/null
check "reap unpushed: worktree kept" [ -d "$(wt r2)" ]
"$C" spawn r3 "$T/repo" --worktree >/dev/null; git -C "$(wt r3)" commit -q --allow-empty -m pushed
git -C "$(wt r3)" push -q origin session/r3
echo 'art/' >>"$T/repo/.git/info/exclude"; mkdir "$(wt r3)/art"; echo result >"$(wt r3)/art/x"
"$C" reap r3 >/dev/null
check "reap pushed: worktree removed, branch kept" bash -c "[ ! -d '$(wt r3)' ] && git -C '$T/repo' rev-parse -q --verify session/r3 >/dev/null"
check "reap: ignored files archived first" grep -qx art/x <(tar -tzf "$HOME"/backups/reaped-worktree-ignored/r3-*.tgz)

# 4. old command names, as outside callers use them
mkdir -p "$T/bin" "$T/ws/proj"
for x in new-session session-send session-handoff session-doctor; do ln -s "$ROOT/scripts/crss-compat.sh" "$T/bin/$x"; done
export CRSS_BIN=$C CRSS_WORKSPACE=$T/ws
out=$("$T/bin/new-session" --dry-run proj workspace --alias My_Lane)
check "new-session --dry-run: tmux name with -MMDD-HHMM" grep -qE '^SESSION=ah_my-lane-[0-9]{4}-[0-9]{4}$' <<<"$out"
printf 'go\n' >"$T/brief"
out=$("$T/bin/new-session" proj workspace --alias lane --tier light --task-file "$T/brief" --launcher ah_a1); rm "$T/brief"
S=$(sed -n 's/^SESSION=//p' <<<"$out")
check "new-session: starts log names session and rundir" grep -qF "session=$S rundir=$T/ws/proj" "$HOME/.sessions/session-starts.log"
check "new-session: haiku, brief with launcher line" wait_for 10 "grep -qE '\"haiku\".*Launcher: ah_a1[.]' '$FAKE_LOG.args'"
idle "${S#ah_}"
out=$("$T/bin/session-handoff" ready "$S"); check "session-handoff ready: idle is SAFE" [ "$out" = "ready: $S SAFE" ]
out=$("$T/bin/session-send" "$S" hello); check "session-send: tmux name accepted, delivered" [ "$out" = delivered ]
out=$("$T/bin/session-handoff" ready "$S"); check "session-handoff ready: busy gives reason=busy" grep -q 'reason=busy' <<<"$out"
d=${S##*lane-}; out=$("$T/bin/new-session" --dry-run proj workspace --alias lane)
check "new-session: a taken name gets -2" bash -c "[ '$out' = 'SESSION=ah_lane-$d-2' ] || [ '$d' != \"\$(date +%m%d-%H%M)\" ]"
tmux -L "$SOCK" new-session -d -s ah_ext -x 80 -y 20 "$T/claude --session-id 00000000-0000-4000-8000-000000000000"
check "ls: a session started by another tool is listed" wait_for 10 '[ "$(st ext)" = idle ]'
out=$("$T/bin/session-send" ah_ext hi-ext); check "session-send: reaches a session with no env file" [ "$out" = delivered ]
"$C" restart ext >/dev/null 2>&1; check "restart: refuses a session with no env file" [ $? != 0 ]
idle "${S#ah_}"; "$T/bin/session-doctor" reap "$S" >/dev/null
check "session-doctor reap: session gone" [ ! -e "$CRSS_STATE/${S#ah_}.env" ]
# 5. naming: Claude titles by default, plain on request, --title only on the first launch; peek, wait, filters
export CRSS_POLL=1
sidf() { sed -n 's/^SID=//p' "$CRSS_STATE/$1.env"; }
argv() { grep -F "$(sidf "$1")" "$FAKE_LOG.args" | tail -1; }
argq() { jq -e "$2" <<<"$(argv "$1")" >/dev/null; } # NAME JQ-FILTER over the last argv claude got
tj() { "$C" ls --json | jq -r --arg n "$1" '.[]|select(.name==$n)|.title'; }
"$C" spawn n1 "$T/work" >/dev/null; idle n1
check "names auto: bare --remote-control then --session-id, no -n" argq n1 'index("--remote-control") as $i | .[$i+1]=="--session-id" and index("-n")==null'
check "names auto: env file says so" grep -qx NAMES=auto "$CRSS_STATE/n1.env"
CRSS_NAMES=plain "$C" spawn n2 "$T/work" >/dev/null; idle n2
check "names plain: ah-N flags" argq n2 'index("--remote-control") as $i | .[$i+1]=="ah-n2" and .[$i+2]=="-n" and .[$i+3]=="ah-n2"'
printf 'DIR=%q\nSID=%s\nARGS=()\nENVS=()\n' "$T/work" "$(cat /proc/sys/kernel/random/uuid)" >"$CRSS_STATE/n3.env"; "$C" up n3 >/dev/null; idle n3
check "env file without NAMES: ah-N flags" argq n3 'index("--remote-control") as $i | .[$i+1]=="ah-n3" and .[$i+2]=="-n" and .[$i+3]=="ah-n3"'
"$C" spawn n4 "$T/work" --title "Fix the thing" --effort high >/dev/null; idle n4
check "--title: first launch names the session" argq n4 'index("--remote-control") as $i | .[$i+1]=="Fix the thing" and .[$i+2]=="-n" and .[$i+3]=="Fix the thing" and (index("--effort") as $e | .[$e+1]=="high")'
"$C" send n4 hi >/dev/null; idle n4; "$C" restart n4 >/dev/null
check "--title: resume uses the bare flag" argq n4 'index("--remote-control") as $i | .[$i+1]=="--resume" and index("-n")==null'
check "ls title: falls back to the spawn title" [ "$(tj n4)" = "Fix the thing" ]
"$C" spawn cm1 "$T/work" --code-mode --title "Worker bee" >/dev/null; idle cm1
cmv() { grep -F "$(sidf "$1")" "$FAKE_LOG.cm" | tail -1 | cut -c1-1; } # NAME: CODE_MODE value the last launch saw
check "code-mode: no --remote-control, -n title, session id kept" argq cm1 'index("--remote-control")==null and (index("-n") as $i | .[$i+1]=="Worker bee") and index("--session-id")!=null'
check "code-mode: env var set, state file remembers" bash -c "[ \"\$(echo $(cmv cm1))\" = 1 ] && grep -qx CODE_MODE=1 '$CRSS_STATE/cm1.env'"
"$C" send cm1 hi >/dev/null; idle cm1; "$C" restart cm1 >/dev/null
check "code-mode: resume keeps it" wait_for 10 '[ "$(grep -cF "$(sidf cm1)" "$FAKE_LOG.cm")" -ge 2 ] && [ "$(cmv cm1)" = 1 ]'
check "code-mode: resume has no --remote-control" argq cm1 'index("--remote-control")==null and index("--resume")!=null and index("-n")==null'
check "code-mode: ls marks it" grep -qF "[code-mode]" <("$C" ls cm1)
check "no code-mode: a row listed after a code-mode one has no marker" [ -z "$("$C" ls | grep '^n1 ' | grep code-mode)" ]
"$C" spawn cm2 "$T/work" --code-mode >/dev/null; idle cm2
check "code-mode: no title still shows the placeholder" grep -qE ' - \[code-mode\]$' <("$C" ls cm2)
check "no code-mode: env var not set" bash -c "[ \"$(cmv n1)\" != 1 ] && [ -n \"$(cmv n1)\" ]"
S1=$(sidf n1); mkdir -p "$HOME/.claude/projects/p"
echo '{"type":"ai-title","aiTitle":"Tmux session naming schemes","sessionId":"'"$S1"'"}' >>"$HOME/.claude/projects/p/$S1.jsonl"
check "ls title: ai-title shows" [ "$(tj n1)" = "Tmux session naming schemes" ]
echo '{"type":"custom-title","customTitle":"Fleet naming study","sessionId":"'"$S1"'"}' >>"$HOME/.claude/projects/p/$S1.jsonl"
check "ls title: custom-title wins" [ "$(tj n1)" = "Fleet naming study" ]
out=$("$C" ls n1); check "ls NAME: one row, title last" bash -c "[ \"\$(wc -l <<<'$out')\" = 1 ] && [[ '$out' == n1\ *'Fleet naming study' ]]"
# 5b. BY: who started a session, as the NAME of a crss session, a transcript title, or the raw value
byj() { "$C" ls "$1" --json | jq -r '.[0].by'; }
CLAUDE_CODE_SESSION_ID=$S1 "$C" spawn by1 "$T/work" >/dev/null; idle by1
check "by: caller's conversation id that is a crss session shows its NAME" [ "$(byj by1)" = n1 ]
CRSS_BY=x "$C" spawn by2 "$T/work" >/dev/null; idle by2
check "by: CRSS_BY overrides" [ "$(byj by2)" = x ]
CRSS_BY=x CLAUDE_CODE_SESSION_ID=$S1 "$C" spawn by3 "$T/work" >/dev/null
check "by: CRSS_BY beats the conversation id" [ "$(byj by3)" = x ]
"$C" spawn by4 "$T/work" >/dev/null; idle by4
check "by: nothing recorded shows empty, no BY line" bash -c "[ -z \"\$('$C' ls by4 --json | jq -r '.[0].by')\" ] && ! grep -q ^BY= '$CRSS_STATE/by4.env'"
echo '{"type":"custom-title","customTitle":"Outside caller","sessionId":"zz-1"}' >"$HOME/.claude/projects/p/zz-1.jsonl"
CRSS_BY=zz-1 "$C" spawn by5 "$T/work" >/dev/null; idle by5
check "by: a transcript title when the id is not a crss session" [ "$(byj by5)" = "Outside caller" ]
echo '0::/user.slice/user-1.slice/app.slice/nightly-job.service' >"$T/cg"; CRSS_CGROUP=$T/cg "$C" spawn by6 "$T/work" >/dev/null
check "by: the systemd unit when a timer spawns it" [ "$(byj by6)" = nightly-job.service ]
echo '0::/user.slice/user-1.slice/session-7.scope' >"$T/cg"; CRSS_CGROUP=$T/cg "$C" spawn by7 "$T/work" >/dev/null
check "by: a login shell (a scope, not a unit) records nothing" bash -c "! grep -q ^BY= '$CRSS_STATE/by7.env'"
"$C" send by1 hi >/dev/null; idle by1; "$C" restart by1 >/dev/null
check "by: restart keeps it" [ "$(byj by1)" = n1 ]
out=$("$C" ls by1 by2); check "by: plain ls rows are unchanged (no caller column)" bash -c "[[ '$out' != *@* && '$out' != *$'\t'* ]]"
CRSS_BY=-n "$C" spawn by8 "$T/work" >/dev/null; check "by: a value that looks like an echo flag is shown as is" [ "$(byj by8)" = -n ]
tmux -L "$SOCK" new-session -d -s ah_pk -x 80 -y 20 "echo peekmark-xyz; sleep 600"
check "peek: header and pane text" wait_for 10 '[[ "$("$C" peek pk 5)" == "pk "*peekmark-xyz* ]]'
"$C" peek nosuch 2>/dev/null; check "peek: unknown session refused with 2" [ $? = 2 ]
out=$("$C" wait n1); check "wait: idle session returns 0" [ $? = 0 ]
check "wait: prints NAME STATUS" [ "$out" = "n1 idle" ]
"$C" spawn w1 "$T/work" >/dev/null; "$C" wait w1 --timeout 30 >/dev/null
check "wait: after spawn, not before the session record exists" bash -c "grep -lq '$(sidf w1)' '$HOME'/.claude/sessions/*.json"
"$C" send w1 work >/dev/null; "$C" wait w1 --timeout 1 >/dev/null; check "wait: --timeout on a busy session exits 1" [ $? = 1 ]
out=$("$C" spawn --help); check "spawn --help: exit 0, not a bad-name error" [ $? = 0 ]
check "spawn --help: usage text" grep -q 'crss spawn NAME DIR' <<<"$out"
"$C" wait >/dev/null 2>&1; check "wait: no names is a usage error" [ $? = 2 ]
"$C" send w1 work >/dev/null; timeout 10 "$C" wait w1 --timeout 5m >/dev/null 2>&1
check "wait: a non-numeric --timeout is a usage error, not an endless poll" [ $? = 2 ]
echo brief >"$T/b"; "$C" spawn b1 "$T/work" --brief "$T/b" >/dev/null; idle b1
"$C" wait b1 --timeout 3 >/dev/null; check "wait: idle before the brief landed is not done" [ $? = 1 ]
echo '{}' >"$HOME/.claude/projects/p/$(sidf b1).jsonl"; "$C" wait b1 --timeout 10 >/dev/null
check "wait: done once the brief has a transcript" [ $? = 0 ]
out=$("$C" spawn n5 "$T/work" --title 2>&1); check "spawn: a flag without its value is named" grep -q 'needs a value' <<<"$out"
out=$("$C" spawn n5 "$T/work" --title --x 2>&1); check "spawn: a title starting with - is refused" grep -q 'cannot start' <<<"$out"
"$C" ls --jsno >/dev/null 2>&1; check "ls: unknown option is an error" [ $? = 1 ]
echo '{"type":"ai-title","aiTit' >>"$HOME/.claude/projects/p/$S1.jsonl"
check "ls title: a half-written last line does not lose the title" [ "$(tj n1)" = "Fleet naming study" ]
idle n1; out=$("$C" send n1 "/rename Night shift"); check "send /rename: confirmed by the new title, status stays idle" [ "$out" = delivered ]
check "send /rename: ls shows the new title" [ "$(tj n1)" = "Night shift" ]
out=$("$C" send n1 "/rename   Padded shift  "); check "send /rename: a padded title is confirmed trimmed" [ "$out" = delivered ]
S1=$(sidf n1); out=$("$C" send n1 "/clear"); check "send /clear: confirmed by the new session id" [ "$out" = delivered ]
check "send /clear: the env file follows the new id" bash -c "[ '$(sidf n1)' != '$S1' ] && grep -lq '$(sidf n1)' '$HOME'/.claude/sessions/*.json"
S1=$(sidf n1); tmux -L "$SOCK" send-keys -t =ah_n1: /clear Enter; wait_for 5 '! grep -lq "$S1" "$HOME"/.claude/sessions/*.json'
out=$("$C" send n1 "/rename After clear"); check "send /rename: confirmed after a /clear crss did not see" [ "$out" = delivered ]
check "send /rename after /clear: ls shows the new title" [ "$(tj n1)" = "After clear" ]
out=$("$C" wait nosuch n1 --timeout 20 2>&1); check "wait: unknown session refused with 2, not reported down" [ "$?/$out" = "2/crss: no such session: nosuch" ]
out=$("$C" ls nosuch 2>&1); check "ls NAME: an unknown name is named, exit 2" [ "$?/$out" = "2/crss: no such session: nosuch" ]
out=$("$C" ls n1 nosuch 2>/dev/null); check "ls NAME...: known rows still print beside an unknown name" [ "$?/${out%% *}" = "2/n1" ]
check "ls --json NAME: an unknown name gives [] and exit 2" [ "$("$C" ls --json nosuch 2>/dev/null; echo $?)" = "[]
2" ]
printf '#!/bin/sh\ntouch "%s"\nexec "%s" "$@"\n' "$T/via-config" "$T/claude" >"$T/claude2"; chmod +x "$T/claude2"
echo "CRSS_CLAUDE=$T/claude2" >"$T/cfg2"; CRSS_CONFIG=$T/cfg2 "$C" spawn c1 "$T/work" >/dev/null; idle c1
check "up: the pane loop reads the caller's CRSS_CONFIG" [ -e "$T/via-config" ]
# 6. parked: a finished turn that left a background command running reads "shell" in Claude's record
st1() { "$C" ls "$1" | awk '{print $2}'; }
"$C" spawn p1 "$T/work" >/dev/null; idle p1; "$C" send p1 park >/dev/null
check "ls: a finished turn with a background command is parked, not shell" wait_for 10 '[ "$(st1 p1)" = parked ]'
out=$("$C" wait p1 --timeout 10); check "wait: a parked session is done, exit 0" [ "$?/$out" = "0/p1 parked" ]
out=$("$C" peek p1 1 | head -1); check "peek: shows parked" [ "${out%% -*}" = "p1 parked" ]
out=$("$T/bin/session-handoff" ready ah_p1); check "session-handoff ready: parked is SAFE" [ "$out" = "ready: ah_p1 SAFE" ]
out=$("$C" restart p1); check "restart: skips a parked session and says so" [ "$out" = "p1: skipped, parked" ]
t0=$SECONDS; out=$(CRSS_BUSY_POLL=1 "$C" restart p1 --wait-idle)
check "restart --wait-idle: gives up on a parked session in seconds and leaves it running" bash -c '[[ $1 == "p1: skipped, parked:"* ]] && [ "$2" -lt 30 ] && [ "$3" = parked ]' _ "$out" "$((SECONDS - t0))" "$(st1 p1)"
out=$("$C" send p1 midturn); check "send: a parked session that takes the message is delivered, not queued" [ "$out" = delivered ]
check "ls: a turn in progress is shell, not parked, whatever a finished sub-agent wrote" [ "$(st1 p1)" = shell ]
out=$("$C" wait p1 --timeout 3); check "wait: shell in a turn in progress is not done" [ "$?/$out" = "1/p1 shell" ]
# 7. local slash commands: confirmed from the transcript, which also shows the command's output
"$C" spawn l1 "$T/work" >/dev/null; idle l1
tp() { printf '%s\n' "$@" >>"$HOME/.claude/projects/p/$(sidf l1).jsonl"; }
tp "{}"
out=$("$C" send l1 "/local x"); rc=$?
check "send local command: delivered, exit 0" [ "$rc/${out%%$'\n'*}" = 0/delivered ]
check "send local command: stdout line shown, ANSI stripped, indented" [ "${out#*$'\n'}" = '  MCP server "x" not found' ]
out=$("$C" send l1 "/localsys x"); check "send local command: system/local_command shape confirms too" [ "$?/$out" = $'0/delivered\n  MCP server "x" not found' ]
tp '{"type":"user","message":{"content":"<command-name>/localnone</command-name>"}}'
out=$("$C" send l1 "/localnone here"); check "send slash command that leaves nothing new: an older identical command does not confirm, UNVERIFIED exit 1" [ "$?/$out" = "1/UNVERIFIED: status stayed idle" ]
out=$("$C" send l1 "/localother x"); check "send local command: another command's lines do not confirm" [ "$?/$out" = "1/UNVERIFIED: status stayed idle" ]
out=$("$C" send l1 "/localquiet y"); check "send local command without stdout: a single line" [ "$?/$out" = "0/delivered" ]
"$C" spawn l2 "$T/work" >/dev/null; idle l2; check "fixture: a session that never had a message has no transcript" [ ! -e "$HOME/.claude/projects/p/$(sidf l2).jsonl" ]
out=$("$C" send l2 "/local x"); check "send local command to a session with no transcript yet: confirmed from the new file" [ "$?/$out" = $'0/delivered\n  MCP server "x" not found' ]
"$C" send p1 park >/dev/null; wait_for 10 '[ "$(st1 p1)" = parked ]'
out=$("$C" send p1 "/local z"); check "send local command to a parked session: confirmed from the transcript with its output" [ "$?/$out" = $'0/delivered\n  MCP server "x" not found' ]
check "ls: a parked session stays parked after a local command" [ "$(st1 p1)" = parked ]
tq() { printf '%s\n' "$@" >>"$HOME/.claude/projects/p/$(sidf p1).jsonl"; }
tq '{"type":"user","isMeta":true,"message":{"content":"<local-command-caveat>x</local-command-caveat>"}}' '{"type":"user","message":{"content":"<command-name>/mcp</command-name>\n<command-args>y</command-args>"}}' '{"type":"user","message":{"content":"<local-command-stdout>nope</local-command-stdout>"}}'
check "ls: local-command lines after end_turn leave a parked session parked" [ "$(st1 p1)" = parked ]
"$C" spawn h1 "$T/work" >/dev/null; idle h1
"$C" send h1 park >/dev/null; wait_for 10 '[ "$(st1 h1)" = parked ]'
f=$(compgen -G "$HOME/.claude/projects/p/$(sidf h1).jsonl"); head -c -1 "$f" >"$f.x"; mv "$f.x" "$f"
check "ls: a transcript still being written (no final newline) is shell, not parked" [ "$(st1 h1)" = shell ]
echo 'garbage (' >>"$CRSS_STATE/n1.env"; out=$("$C" send n1 hi 2>/dev/null); check "send: a broken env file does not turn a delivered send into a refusal" [ "$?/$out" = 0/delivered ]
out=$("$C" ls n1 2>&1); check "ls NAME: a broken env file is not also called no such session" bash -c '[[ $1 == *"n1: bad env file, skipped"* && $1 != *"no such session"* ]]' _ "$out"
# 8. ls --all and adopt: transcripts no crss session has. Fixture folders are made-up paths outside any temp dir.
Q=$HOME/.claude/projects/q; X=-0000-4000-8000-000000000001; mkdir -p "$Q/e0000001$X/subagents"
tx() { # SID8 WHEN CWD ENTRYPOINT MESSAGE-JSON [FILE]: append one message
  jq -cn --arg t "$(date -u -d "$2" +%Y-%m-%dT%H:%M:%S.000Z)" --arg c "$3" --arg e "$4" --argjson m "$5" '{timestamp:$t, cwd:$c, entrypoint:$e} + $m' >>"${6:-$Q/$1$X.jsonl}"
}
END='{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"done"}]}}'
USR='{"type":"user","message":{"content":"do the thing"}}'; TOOL='{"type":"assistant","message":{"stop_reason":"tool_use","content":[{"type":"tool_use"}]}}'
tx e0000001 '-3 hours' /srv/demo claude-desktop "$USR"; tx e0000001 '-2 hours' /srv/demo claude-desktop "$END"
printf '%s\n' '{"type":"custom-title","customTitle":"Desk chat"}' '{"type":"user","isMeta":true,"message":{"content":"note"}}' '{"type":"cost-state"}' >>"$Q/e0000001$X.jsonl"
tx x '-1 hours' /srv/sub cli "$END" "$Q/e0000001$X/subagents/agent-a1.jsonl"
tx c0000001 '-3 hours' /srv/demo cli "$END"; tx c0000001 '-3 hours' /srv/demo cli "$USR"; tx c0000002 '-3 hours' /srv/demo cli "$TOOL"
sleep 300 & LP=$!; true & DP=$!; wait "$DP"
tx a0000001 '-5 hours' /srv/demo claude-desktop "$END"; echo '{"pid":'"$LP"',"sessionId":"a0000001'"$X"'","status":"idle"}' >"$HOME/.claude/sessions/$LP.json"
tx d0000001 '-5 hours' /srv/demo cli "$END"; echo '{"pid":'"$DP"',"sessionId":"d0000001'"$X"'","status":"idle"}' >"$HOME/.claude/sessions/$DP.json"
tx a0000002 '-10 seconds' /srv/demo cli "$USR"; tx f0000001 '-40 hours' /srv/demo cli "$END"
tx b0000001 '-2 hours' /srv/demo/scratchpad/x cli "$END"; tx b0000002 '-2 hours' /tmp/x cli "$END"; tx b0000003 '-2 hours' /srv/demo sdk-cli "$END"
all() { "$C" ls --all "$@" 2>/dev/null | grep '^- '; }
row() { all "${@:2}" | awk -v s="$1" '$4 == s { print $2 }'; } # SID8 [ls options]: the STATE column
out=$(all)
check "ls --all: a finished turn is ended; age, folder, title and entrypoint shown" grep -qE '^- +ended +2h +e0000001 /srv/demo Desk chat \[claude-desktop\]$' <<<"$out"
check "ls --all: an unanswered prompt is cut" [ "$(row c0000001)" = cut ]
check "ls --all: a tool call with no result is cut" [ "$(row c0000002)" = cut ]
check "ls --all: a running claude that has the id makes it live, with its pid and status" grep -qE "^- +live +5h +a0000001 .*\[claude-desktop, pid $LP idle\]$" <<<"$out"
check "ls --all: a message under 2 minutes old is live" [ "$(row a0000002)" = live ]
check "ls --all: a record whose process is gone is not live" [ "$(row d0000001)" = ended ]
check "ls --all: sub-agent files, temp and scratchpad folders, headless runs and old transcripts are left out" bash -c '! grep -qE "/srv/sub|b000000[123]|f0000001" <<<"$1"' _ "$out"
check "ls --all --tmp: temp, scratchpad and headless rows show; sub-agent files never" [ "$(row b0000001 --tmp)$(row b0000002 --tmp)$(row b0000003 --tmp)$(all --tmp | grep -c /srv/sub)" = endedendedended0 ]
check "ls --all --hours: a wider window shows the older one" [ "$(row f0000001 --hours 48)" = ended ]
check "ls --all: a crss session's transcript is not listed twice" [ -z "$(row "$(sidf p1 | cut -c1-8)" --tmp)" ]
check "ls: without --all there are no extra rows or keys" bash -c "[ \"\$('$C' ls 2>/dev/null | grep -c '^- ')\" = 0 ] && '$C' ls --json 2>/dev/null | jq -e 'all(.[]; has(\"age\") | not)' >/dev/null"
check "ls --all --json: same keys plus age, entry, pid, proc" bash -c "'$C' ls --all --json 2>/dev/null | jq -e '.[] | select(.sid == \"a0000001$X\") | .name == \"-\" and .status == \"live\" and .pid == $LP and .proc == \"idle\" and .entry == \"claude-desktop\" and .age > 17000' >/dev/null"
"$C" ls --all n1 >/dev/null 2>&1; check "ls --all NAME: refused" [ $? = 1 ]
"$C" ls --hours >/dev/null 2>&1; check "ls --hours without a number: refused" [ $? = 1 ]
check "ls --hours and --tmp imply --all" [ "$("$C" ls --hours 48 2>/dev/null | grep -c '^- .* f0000001 ')$("$C" ls --tmp 2>/dev/null | grep -c '^- .* b0000003 ')" = 11 ]
out=$("$C" adopt a0000001 ad0 2>&1); check "adopt: refused while a running claude has the id, pid named" bash -c '[ "$1" = 1 ] && [[ $2 == *"live in pid '"$LP"' (idle)"* ]] && [ ! -e "$CRSS_STATE/ad0.env" ]' _ "$?" "$out"
out=$("$C" adopt 99999999 ad0 2>&1); check "adopt: no such transcript" [ "$?/$out" = "1/crss: adopt: 0 transcripts match 99999999" ]
cp "$Q/c0000001$X.jsonl" "$Q/c0000001${X%1}2.jsonl"; out=$("$C" adopt c0000001 ad0 2>&1); check "adopt: an ambiguous prefix is refused" [ "$?/$out" = "1/crss: adopt: 2 transcripts match c0000001" ]
out=$("$C" adopt e0000001 ad0 2>&1); check "adopt: a transcript written to in the last 2 minutes is refused" bash -c '[ "$1" = 1 ] && [[ $2 == *"under 2 minutes ago"* ]] && [ ! -e "$CRSS_STATE/ad0.env" ]' _ "$?" "$out"
touch -d '-10 minutes' "$Q/e0000001$X.jsonl"
out=$("$C" adopt e0000001 ad0 2>&1); check "adopt: a folder that is gone is refused, DIR offered" bash -c '[ "$1" = 1 ] && [[ $2 == *"no such dir"*"give DIR"* ]] && [ ! -e "$CRSS_STATE/ad0.env" ]' _ "$?" "$out"
out=$(CRSS_BY=boss "$C" adopt e0000001 ad1 "$T/work"); check "adopt: says what it did" grep -qF "ad1: adopted e0000001$X in $(cd "$T/work" && pwd -P)" <<<"$out"
check "adopt: comes up as a crss session" idle ad1
check "adopt: resumes the same conversation id" argq ad1 'index("--remote-control") as $i | .[$i+1]=="--resume" and .[$i+2]=="e0000001'"$X"'"'
check "adopt: ls shows it by name with its title and caller, and no longer as a loose transcript" bash -c "[ \"\$('$C' ls ad1 --json | jq -r '.[0] | .title + \"/\" + .by')\" = 'Desk chat/boss' ] && [ -z \"$(row e0000001 --tmp)\" ]"
out=$("$C" adopt d0000001 ad1 2>&1); check "adopt: a taken NAME is refused" [ "$?/$out" = "1/crss: ad1 already exists" ]
out=$("$C" adopt e0000001 ad2 "$T/work" 2>&1); check "adopt: an id a crss session has is refused" [ "$?/$out" = "1/crss: adopt: e0000001$X is already crss session ad1" ]
# the fake claude starts a second transcript file for the id on its first message, so send comes after the id checks
out=$("$C" send ad1 hello-adopted); check "adopt: crss send reaches it" [ "$out" = delivered ]
tx ad000001 '-4 hours' "$T/work" cli "$END"; touch -d '-10 minutes' "$Q/ad000001$X.jsonl"; "$C" adopt "ad000001$X" ad3 >/dev/null
check "adopt: without DIR the transcript's own folder is used" grep -qxF "DIR=$(printf %q "$(cd "$T/work" && pwd -P)")" "$CRSS_STATE/ad3.env"
kill "$LP" 2>/dev/null
exit $F
