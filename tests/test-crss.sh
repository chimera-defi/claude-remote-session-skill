#!/usr/bin/env bash
# End-to-end test for scripts/crss.sh: real tmux on a private socket, fake HOME, fake claude.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); C=$ROOT/scripts/crss.sh
T=$(mktemp -d); SOCK=crss-test-$$; F=0
export HOME=$T/home CRSS_STATE=$T/state CRSS_TMUX="tmux -L $SOCK" CRSS_CLAUDE=$T/claude CRSS_CONFIG=$T/none
export CRSS_BACKOFF=1 CRSS_PAUSE=1 CRSS_NO_SYSTEMD=1 FAKE_LOG=$T/log TERM=xterm
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
unset TMUX; mkdir -p "$HOME" "$T/work"; echo '{}' >"$HOME/.claude.json"
trap 'tmux -L $SOCK kill-server 2>/dev/null; rm -rf "$T"' EXIT

cat >"$T/claude" <<'PY'
#!/usr/bin/env python3
import json, os, sys, threading, tty
a = sys.argv
sid = next(a[i + 1] for i, x in enumerate(a) if x in ("--session-id", "--resume"))
rec = os.environ["HOME"] + "/.claude/sessions/%d.json" % os.getpid()
def w(st):
    os.makedirs(os.path.dirname(rec), exist_ok=True)
    open(rec + ".t", "w").write(json.dumps({"pid": os.getpid(), "sessionId": sid, "status": st, "version": "fake"}))
    os.replace(rec + ".t", rec)
w("idle")
open(os.environ["FAKE_LOG"] + ".args", "a").write(json.dumps(a[1:]) + "\n")
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
            open(os.environ["FAKE_LOG"], "a").write(json.dumps(msg) + "\n")
            os.makedirs(os.environ["HOME"] + "/.claude/projects/p", exist_ok=True)
            open(os.environ["HOME"] + "/.claude/projects/p/%s.jsonl" % sid, "a").write(json.dumps(msg) + "\n")
            w("busy"); threading.Timer(2, w, ["idle"]).start()
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
S0=$(sid a1); P0=$(ls "$HOME/.claude/sessions")
idle a1
out=$("$C" restart a1)
check "restart: same sessionId, new pid" bash -c "[ \"\$(ls '$HOME/.claude/sessions')\" != '$P0' ] && [ \"\$(jq -r .sessionId '$HOME'/.claude/sessions/*.json)\" = '$S0' ] && [[ '$out' == *'sessionId=$S0'* ]]"

# 2. killed tmux session comes back on the same session id with --resume
tmux -L "$SOCK" kill-session -t ah_a1
"$C" up >/dev/null
check "up: back up on same sid" idle a1
check "up: relaunched with --resume" bash -c "tail -1 '$FAKE_LOG.args' | grep -q '\"--resume\", \"$S0\"'"
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
check "reap: ignored files archived first" bash -c "tar -tzf '$HOME'/backups/reaped-worktree-ignored/r3-*.tgz | grep -qx art/x"
exit $F
