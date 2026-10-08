#!/usr/bin/env bash
# codex-resume-pin + the Codex start loop: an explicitly pinned thread is resumed only when
# every read proves it (canonical UUID, exactly one rollout, this lane's cwd, codex-tui);
# any doubt fails closed (no launch, reason logged); EVERY launch carries exactly one explicit
# sandbox; argv reaches codex byte-identical. Hermetic: stub codex/sleep/mv, temp HOME and
# CODEX_HOME; no real codex, no lane.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
isolate_overlay
RP="$HERE/../scripts/codex-resume-pin.sh"
NS="$HERE/../scripts/new-session.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"; kill $(jobs -p) 2>/dev/null' EXIT
export HOME="$WORK/home" CODEX_HOME="$WORK/codex"; mkdir -p "$HOME"

U1=11111111-1111-4111-8111-111111111111
U2=22222222-2222-4222-8222-222222222222
U3=33333333-3333-4333-8333-333333333333
ROLL="$CODEX_HOME/sessions/2026/10/03"; mkdir -p "$ROLL"

# mk_rollout <uuid> <cwd> <originator> [sessions-day-dir]
mk_rollout() {
  local d="${4:-$ROLL}"; mkdir -p "$d"
  printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s","originator":"%s"}}\n' "$1" "$2" "$3" \
    > "$d/rollout-2026-10-03T10-00-00-$1.jsonl"
}
rc() { "$@" >/dev/null 2>&1; echo $?; }

# ---------------------------------------------------------------- sandbox-of
ok "sandbox -s"            "$(bash "$RP" sandbox-of -m x -s workspace-write -a never)" "workspace-write"
ok "sandbox --sandbox"     "$(bash "$RP" sandbox-of --sandbox read-only)" "read-only"
ok "sandbox -c form"       "$(bash "$RP" sandbox-of -c 'sandbox_mode="workspace-write"')" "workspace-write"
ok "sandbox default"       "$(bash "$RP" sandbox-of -m x -a never)" "read-only"
ok "sandbox --flag none" "$(bash "$RP" sandbox-of --flag -m x -a never)" ""
ok "sandbox flag and config agreeing is fine" "$(bash "$RP" sandbox-of -s read-only -c sandbox_mode=read-only)" "read-only"
ok "sandbox profile + -c: effective is the -c value" "$(bash "$RP" sandbox-of -p lab -c sandbox_mode=read-only)" "read-only"
ok "sandbox sandbox_workspace_write.* keeps default" "$(bash "$RP" sandbox-of -c sandbox_workspace_write.network_access=true)" "read-only"
ok "sandbox awkward values ok" "$(bash "$RP" sandbox-of -m 'two words' -c $'note=line1\nline2' --add-dir '' -c "q='a b'")" "read-only"
# D: everything below must fail closed (exit 1) -- 1c91bbc accepted several of these
while IFS= read -r line; do
  eval "set -- $line"
  ok "sandbox rejects: $line" "$(rc bash "$RP" sandbox-of "$@")" "1"
done <<'REJ'
-m m -- --sandbox=danger-full-access
-s read-only -s read-only
-s read-only --sandbox=read-only
-s=read-only
-sread-only -s=x
-m -leading
-m m --bogus
-m m positional
-
-C /x
--cd /x
--worktree w
--full-auto
--dangerously-bypass-approvals-and-sandbox
--approve-for-me
-i img.png
--image img.png
--remote ws://x
--remote-auth-token-env X
--dangerously-bypass-hook-trust
--last
--all
-h
--help
-V
--version
-c sandbox_mode=read-only -c sandbox_mode=read-only
-c sandbox_mode=read-only --config=sandbox_mode=read-only
-s read-only -c sandbox_mode=workspace-write
-c noequals
-c sandbox_foo=x
-c sandboxfoo=x
-m
--sandbox
--search=1
-s bogus
-c sandbox_mode=bogus
-s -x
REJ

# ---------------------------------------------------------------- read-pin
P="$WORK/pins"; mkdir -p "$P"
ok "read-pin absent => 10" "$(rc bash "$RP" read-pin "$P/none")" "10"
printf '%s\n' "$U1" > "$P/ok";       ok "read-pin ok" "$(bash "$RP" read-pin "$P/ok")" "$U1"
mkdir "$P/dir";                      ok "read-pin directory => 2" "$(rc bash "$RP" read-pin "$P/dir")" "2"
: > "$P/empty";                      ok "read-pin empty => 2" "$(rc bash "$RP" read-pin "$P/empty")" "2"
printf '%s\n%s\n' "$U1" "$U2" > "$P/two"; ok "read-pin two lines => 2" "$(rc bash "$RP" read-pin "$P/two")" "2"
ln -s "$P/ok" "$P/link";             ok "read-pin symlink => 2" "$(rc bash "$RP" read-pin "$P/link")" "2"
ln -s "$P/nowhere" "$P/dangling";    ok "read-pin dangling symlink => 2 (present, not absent)" "$(rc bash "$RP" read-pin "$P/dangling")" "2"

# ---------------------------------------------------------------- exists / verify-lane
mkdir -p "$WORK/laneA" "$WORK/laneB"
mk_rollout "$U1" "$WORK/laneA" codex-tui
ok "exists: one rollout" "$(rc bash "$RP" exists "$U1")" "0"
ok "exists: proven absence => 11" "$(rc bash "$RP" exists "$U2")" "11"
mk_rollout "$U1" "$WORK/laneA" codex-tui "$CODEX_HOME/sessions/2026/10/04"
ok "exists: two matches => 2" "$(rc bash "$RP" exists "$U1")" "2"
rm -rf "$CODEX_HOME/sessions/2026/10/04"
ok "verify-lane ok" "$(rc bash "$RP" verify-lane "$U1" "$WORK/laneA")" "0"
ok "verify-lane foreign cwd => 1" "$(rc bash "$RP" verify-lane "$U1" "$WORK/laneB")" "1"
mk_rollout "$U2" "$WORK/laneA" codex_exec
ok "verify-lane wrong originator => 1" "$(rc bash "$RP" verify-lane "$U2" "$WORK/laneA")" "1"
printf 'not json\n' > "$ROLL/rollout-2026-10-03T10-00-00-$U3.jsonl"
ok "verify-lane unreadable rollout => 2" "$(rc bash "$RP" verify-lane "$U3" "$WORK/laneA")" "2"
rm -f "$ROLL"/rollout-*

# ---- A: symlinks never count as proven absence; a stray valid symlink must not block
mkch() { CH="$(mktemp -d "$WORK/ch.XXXXXX")"; mkdir -p "$CH/sessions/2026/10/03"; }
chrc() { CODEX_HOME="$CH" rc bash "$RP" exists "$1"; }
mkch; mkdir -p "$WORK/realday"; mk_rollout "$U1" "$WORK/laneA" codex-tui "$WORK/realday"; ln -s "$WORK/realday" "$CH/sessions/2026/10/05"
ok "A: symlinked subdirectory holding the rollout => 0" "$(chrc "$U1")" "0"
has "A: ...and its path is printed" "$(CODEX_HOME="$CH" bash "$RP" exists "$U1")" "rollout-2026-10-03T10-00-00-$U1.jsonl"
mkch; mkdir -p "$WORK/unrelated"; ln -s "$WORK/unrelated" "$CH/sessions/stray"
ok "A: valid stray symlink, no match => 11 (one symlink must not stop a lane)" "$(chrc "$U1")" "11"
mkch; ln -s "$WORK/gone-dir" "$CH/sessions/dangling-dir"
ok "A: dangling subdirectory symlink, no match => 2" "$(chrc "$U1")" "2"
mkch; ln -s "$WORK/gone-file" "$CH/sessions/2026/10/03/rollout-2026-10-03T10-00-00-$U1.jsonl"
ok "A: dangling rollout link => 2" "$(chrc "$U1")" "2"
mkch; ln -s "$CH/sessions" "$CH/sessions/2026/loop"
ok "A: symlink loop under the root => 2" "$(chrc "$U1")" "2"
mkch; mkdir -p "$CH/sessions/locked"; mk_rollout "$U2" "$WORK/laneA" codex-tui "$CH/sessions/locked"; chmod 000 "$CH/sessions/locked"
if [ "$(id -u)" = 0 ]; then echo "SKIP: A unreadable subdirectory (root ignores chmod)"; else
  ok "A: unreadable subdirectory => 2" "$(chrc "$U1")" "2"
fi
chmod 755 "$CH/sessions/locked"
mkch; mkdir -p "$CH/sessions/nl$(printf '\nx')"; mk_rollout "$U1" "$WORK/laneA" codex-tui "$CH/sessions/nl$(printf '\nx')"
ok "A: a path containing a newline fails closed, never miscounted" "$(chrc "$U1")" "2"

# ---- B: verify-lane needs a real, absolute session_meta cwd
vl() { # <first-line-json> -> verify-lane rc against laneA
  mkch; printf '%s\n' "$1" > "$CH/sessions/2026/10/03/rollout-2026-10-03T10-00-00-$U1.jsonl"
  CODEX_HOME="$CH" rc bash "$RP" verify-lane "$U1" "$WORK/laneA"
}
ok "B: baseline ok" "$(vl '{"type":"session_meta","payload":{"id":"x","cwd":"'"$WORK"'/laneA","originator":"codex-tui"}}')" "0"
ok "B: cwd missing => 2" "$(vl '{"type":"session_meta","payload":{"originator":"codex-tui"}}')" "2"
ok "B: cwd relative => 2" "$(vl '{"type":"session_meta","payload":{"cwd":"rel/dir","originator":"codex-tui"}}')" "2"
ok "B: first line not JSON => 2" "$(vl 'garbage')" "2"
ok "B: other cwd => 1 (foreign)" "$(vl '{"type":"session_meta","payload":{"cwd":"'"$WORK"'/laneB","originator":"codex-tui"}}')" "1"
ok "B: other originator => 1 (foreign)" "$(vl '{"type":"session_meta","payload":{"cwd":"'"$WORK"'/laneA","originator":"codex_exec"}}')" "1"

# ---- C: pin presence is decided by lstat errno
mkdir -p "$P/np"; printf '%s\n' "$U1" > "$P/np/pin"; chmod 000 "$P/np"
if [ "$(id -u)" = 0 ]; then echo "SKIP: C no-search-permission pin dir (root ignores chmod)"; else
  ok "C: pin dir without search permission => 2 (EACCES is not absence)" "$(rc bash "$RP" read-pin "$P/np/pin")" "2"
fi
chmod 755 "$P/np"
: > "$P/regfile"
ok "C: parent is a regular file => 2 (ENOTDIR)" "$(rc bash "$RP" read-pin "$P/regfile/pin")" "2"
ok "C: missing parent dir => 10 (ENOENT)" "$(rc bash "$RP" read-pin "$P/nodir/pin")" "10"

# ================================================================ start-loop harness
# One stubbed spawn yields the REAL generated Codex loop; each case runs it once (the
# `while true` becomes a single pass) against stubs.
SBIN="$WORK/sbin"; mkdir -p "$SBIN"
ln -sf "$HERE/../scripts/session-alias.sh" "$SBIN/session-alias"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SBIN/systemctl"; chmod +x "$SBIN/systemctl"
printf '#!/usr/bin/env bash\ncase "$1" in +%%m%%d-%%H%%M) echo 0101-0000 ;; *) exec /usr/bin/date "$@" ;; esac\n' > "$SBIN/date"; chmod +x "$SBIN/date"
export CRSS_SESSION_PREFIX=px SESSION_ALIAS_STORE="$WORK/alias-store"
SPAWN_HOME="$WORK/spawnhome"; mkdir -p "$SPAWN_HOME/.sessions/lp-start"
HOME="$SPAWN_HOME" PATH="$SBIN:$PATH" CRSS_CODEX_BIN=/bin/true CRSS_CODEX_ARGS='-m m -s read-only' \
  bash "$NS" --backend codex lp-start sessions --alias lp >/dev/null 2>&1
GEN="$SPAWN_HOME/.local/bin/px-lp-0101-0000-start.sh"
[ -f "$GEN" ] || { echo "FAIL: loop harness — no generated script $GEN"; fail=$((fail+1)); GEN=/dev/null; }
awk "/^CODEX_LOOP=\\\$\\(cat <<'CODEX_LOOP_EOF'/{f=1;next} /^CODEX_LOOP_EOF\$/{f=0} f" "$GEN" > "$WORK/loop.src"
[ -s "$WORK/loop.src" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: loop harness — could not extract the loop"; }
has "pin path is the lane's .codex-thread" "$(grep '^CODEX_PIN=' "$WORK/loop.src")" '.codex-thread'

# stubs: sleep (no-op), codex (records argv NUL-delimited + a call line), mv that fails
STUBS="$WORK/stubs"; mkdir -p "$STUBS" "$WORK/helperbin" "$WORK/mvfail" "$WORK/mvnoop"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBS/sleep"
cat > "$STUBS/codex" <<'EOS'
#!/usr/bin/env bash
printf '%s\0' "$@" >> "$ARGV_OUT"; echo call >> "$CALLS"
[ ! -e /proc/$$/fd/9 ] || echo fd9-open >> "$CALLS.fd9"
if [ -n "${STUB_MODE:-}" ]; then
  # a lane that creates its own rollout and holds it open, with a child holding a SIBLING's rollout
  new=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
  f="$CODEX_HOME/sessions/2026/10/03/rollout-2026-10-03T10-00-00-$new.jsonl"
  printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s","originator":"codex-tui"}}\n' "$new" "$PWD" > "$f"
  exec 9< "$f"
  /usr/bin/sleep 0.4 9< "$SIBLING_ROLLOUT" &
  wait
fi
EOS
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/mvfail/mv"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/mvnoop/mv"
cat > "$STUBS/date" <<'EOS'
#!/usr/bin/env bash
if [ -n "${FAKE_EPOCH:-}" ] && [ "${1:-}" = "+%s" ]; then echo "$FAKE_EPOCH"; else exec /usr/bin/date "$@"; fi
EOS
chmod +x "$STUBS/sleep" "$STUBS/codex" "$STUBS/date" "$WORK/mvfail/mv" "$WORK/mvnoop/mv"
ln -sf "$RP" "$WORK/helperbin/codex-resume-pin"
PATH_H="$STUBS:$WORK/helperbin:/usr/bin:/bin"

# setup_case <args-literal>: fresh HOME/CODEX_HOME/lane and a single-pass copy of the loop.
# go [VAR=val ...]: run it in the lane (default PATH has the helper).
setup_case() {
  H="$(mktemp -d "$WORK/case.XXXXXX")"; LANE="$H/lane"
  mkdir -p "$LANE" "$H/hm/.sessions/resume" "$H/codex/sessions/2026/10/03" "$H/wrapbin"
  # wrapper: counts calls per subcommand and evals PRE_<sub>_<n> before / POST_<sub>_<n> after the
  # n-th call (a race in a bottle; a POST hook may set rc). WRAP_HOOK runs after every `exists`.
  cat > "$H/wrapbin/codex-resume-pin" <<'EOW'
#!/usr/bin/env bash
sub="${1//-/_}"; nf="$CASE_DIR/n.$sub"; n=$(( $(cat "$nf" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$nf"
pre="PRE_${sub}_$n"; post="POST_${sub}_$n"
[ -z "${!pre:-}" ] || eval "${!pre}"
"$RP_REAL" "$@"; rc=$?
[ "$1" != exists ] || [ -z "${WRAP_HOOK:-}" ] || eval "$WRAP_HOOK"
[ -z "${!post:-}" ] || eval "${!post}"
exit $rc
EOW
  chmod +x "$H/wrapbin/codex-resume-pin"
  ARGV="$H/argv.out"; CALLS="$H/calls"; LOG="$H/hm/.sessions/session-starts.log"; : > "$ARGV"; : > "$CALLS"
  {
    printf 'CODEX_BIN=%s\nCODEX_ARGS=(%s)\nCODEX_PIN="$HOME/%s"\n' "$STUBS/codex" "$1" "${PINREL:-lane.pin}"
    grep -vE '^(CODEX_BIN|CODEX_ARGS|CODEX_PIN)=' "$WORK/loop.src" | sed "s/^while true; do/for _once in ${PASSES:-1}; do/"
  } > "$H/loop.sh"
  LANE="$(cd "$LANE" && pwd -P)"; PIN="$H/hm/${PINREL:-lane.pin}"
}
go() { ( cd "$LANE" && env HOME="$H/hm" CODEX_HOME="$H/codex" ARGV_OUT="$ARGV" CALLS="$CALLS" RP_REAL="$RP" CASE_DIR="$H" PIN_FILE="$PIN" LOG_F="$LOG" U1="$U1" U2="$U2" PATH="$H/wrapbin:$PATH_H" "$@" bash "$H/loop.sh" ) >"$H/out" 2>&1; }
calls() { wc -l < "$CALLS" | tr -d ' '; }
# argv_is <label> <expected args...>: the stub's NUL-delimited argv must equal them exactly
argv_is() {
  local label="$1"; shift; printf '%s\0' "$@" > "$H/expected"
  if cmp -s "$H/expected" "$ARGV"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $label — argv differs"; tr '\0' '\n' < "$ARGV" | sed 's/^/   got: /'; fi
}
trust() { printf 'projects."%s".trust_level="trusted"' "$LANE"; }
closed() { # <label> <reason>: no launch, reason logged
  ok "$1: codex not launched" "$(calls)" "0"
  has "$1: fail-closed reason logged" "$(cat "$LOG" 2>/dev/null)" "event=resume-pin-fail-closed reason=$2"
}
same() { ok "$1" "$(cmp -s "$H/pin.before" "$PIN" && echo same || echo changed)" "same"; }

# 1. helper missing: codex is never invoked
setup_case "-m m -s read-only"; go PATH="$STUBS:/usr/bin:/bin"
closed "helper missing" "helper-missing"

# 2. unusable pin (directory, empty, two lines, not a uuid, glob, symlink): untouched, fail closed
for kind in dir notuuid symlink; do
  setup_case "-m m -s read-only"
  case "$kind" in
    dir) mkdir "$PIN" ;;
    empty) : > "$PIN" ;;
    twolines) printf '%s\n%s\n' "$U1" "$U2" > "$PIN" ;;
    notuuid) printf 'abc\n' > "$PIN" ;;
    glob) printf '*\n' > "$PIN" ;;
    symlink) printf '%s\n' "$U1" > "$H/real"; ln -s "$H/real" "$PIN" ;;
  esac
  [ -f "$PIN" ] && [ ! -L "$PIN" ] && cp "$PIN" "$H/pin.before"
  go
  closed "pin $kind" "pin-invalid"
  case "$kind" in
    dir) ok "pin dir untouched" "$([ -d "$PIN" ] && echo dir)" "dir" ;;
    symlink) ok "pin symlink untouched" "$([ -L "$PIN" ] && echo link)" "link" ;;
    *) same "pin $kind byte-identical" ;;
  esac
done

# 3. lookup errors: sessions dir missing; two matching rollouts. Pin untouched.
setup_case "-m m -s read-only"; printf '%s\n' "$U1" > "$PIN"; cp "$PIN" "$H/pin.before"
rm -rf "$H/codex/sessions"; go
closed "sessions dir missing" "pin-lookup-error"; same "lookup error leaves pin untouched"
setup_case "-m m -s read-only"; printf '%s\n' "$U1" > "$PIN"; cp "$PIN" "$H/pin.before"
mk_rollout "$U1" "$LANE" codex-tui "$H/codex/sessions/2026/10/03"; mk_rollout "$U1" "$LANE" codex-tui "$H/codex/sessions/2026/10/04"
go
closed "two matching rollouts" "pin-lookup-error"; same "two rollouts leave pin untouched"

# 4. proven absence: pin set aside, fresh launch with an explicit -s
setup_case "-m m -a never"; printf '%s\n' "$U2" > "$PIN"; go
ok "stale pin: moved aside, original gone" "$(ls "$H"/hm/lane.pin.stale.* 2>/dev/null | wc -l | tr -d ' ')/$([ -e "$PIN" ] && echo present || echo gone)" "1/gone"
ok "stale pin: content kept" "$(cat "$H"/hm/lane.pin.stale.* 2>/dev/null)" "$U2"
ok "stale pin: fresh launch once" "$(calls)" "1"
argv_is "stale pin: fresh with explicit -s" -c "$(trust)" -m m -a never -s read-only
has "stale pin logged" "$(cat "$LOG")" "event=pin-stale thread=$U2"

# 5. archive mv fails => fail closed, pin intact, no launch
setup_case "-m m -a never"; printf '%s\n' "$U2" > "$PIN"; cp "$PIN" "$H/pin.before"
go PATH="$WORK/mvfail:$PATH_H"
closed "archive mv fails" "pin-archive-failed"; same "archive failure leaves pin intact"

# 6. rollout found but foreign cwd / wrong originator => fail closed
setup_case "-m m -s read-only"; printf '%s\n' "$U1" > "$PIN"; cp "$PIN" "$H/pin.before"
mk_rollout "$U1" "$H/elsewhere" codex-tui "$H/codex/sessions/2026/10/03"; go
closed "foreign cwd" "pin-foreign"; same "foreign cwd leaves pin untouched"
setup_case "-m m -s read-only"; printf '%s\n' "$U1" > "$PIN"
mk_rollout "$U1" "$LANE" codex_exec "$H/codex/sessions/2026/10/03"; go
closed "wrong originator" "pin-foreign"

# 7/8. valid pin: exact argv, awkward elements byte-identical, on resume and on fresh
AWK_LIT="-m 'two words' -c \$'note=line1\nline2' --add-dir '' -c \"q='a b'\""
setup_case "$AWK_LIT"; printf '%s\n' "$U1" > "$PIN"; mk_rollout "$U1" "$LANE" codex-tui "$H/codex/sessions/2026/10/03"; go
ok "valid pin: one launch" "$(calls)" "1"
argv_is "valid pin: resume argv, awkward elements intact" -c "$(trust)" resume "$U1" -m 'two words' -c $'note=line1\nline2' --add-dir '' -c "q='a b'" -s read-only
has "resume logged" "$(cat "$LOG")" "event=resume thread=$U1 sandbox=read-only"
setup_case "$AWK_LIT"; go
argv_is "no pin: fresh argv, awkward elements intact" -c "$(trust)" -m 'two words' -c $'note=line1\nline2' --add-dir '' -c "q='a b'" -s read-only
ok "fresh launch writes no pin" "$([ -e "$PIN" ] || [ -L "$PIN" ] && echo present || echo absent)" "absent"

# 9. sandbox spellings: exactly one effective sandbox, never a duplicate -s
setup_case "-m m -s workspace-write"; go;           argv_is "-s X kept, nothing appended" -c "$(trust)" -m m -s workspace-write
setup_case "-m m --sandbox workspace-write"; go;    argv_is "--sandbox X kept" -c "$(trust)" -m m --sandbox workspace-write
setup_case "-m m -c 'sandbox_mode=\"workspace-write\"'"; go; argv_is "-c sandbox_mode=X gets -s X appended" -c "$(trust)" -m m -c 'sandbox_mode="workspace-write"' -s workspace-write
setup_case "-m m --config=sandbox_mode=workspace-write"; go; argv_is "--config=sandbox_mode=X gets -s appended" -c "$(trust)" -m m --config=sandbox_mode=workspace-write -s workspace-write
setup_case "-p lab -c sandbox_mode=read-only"; go;  argv_is "profile + -c: exactly one -s read-only appended" -c "$(trust)" -p lab -c sandbox_mode=read-only -s read-only
setup_case "-c sandbox_workspace_write.network_access=true"; go; argv_is "sandbox_workspace_write.* does not set the mode: -s read-only" -c "$(trust)" -c sandbox_workspace_write.network_access=true -s read-only
setup_case "-m m"; go;                              argv_is "none: -s read-only appended" -c "$(trust)" -m m -s read-only
ok "one -s only (none case)" "$(tr '\0' '\n' < "$ARGV" | grep -cx -- '-s')" "1"

# 10. unknown / conflicting sandbox => fail closed
setup_case "-m m -s bogus"; go;                                closed "unknown sandbox" "sandbox-invalid"
setup_case "-m m -s read-only --sandbox=workspace-write"; go;  closed "conflicting sandboxes" "sandbox-invalid"

# 11. a lane rollout held open + a child holding a sibling's rollout: the loop never writes a pin
mkdir -p "$WORK/sibling-roll"; mk_rollout "$U3" "$WORK/other" codex-tui "$WORK/sibling-roll"
SIB="$WORK/sibling-roll/rollout-2026-10-03T10-00-00-$U3.jsonl"
setup_case "-m m -s read-only"; go STUB_MODE=1 SIBLING_ROLLOUT="$SIB"
ok "no pin: stub ran" "$(calls)" "1"
ok "no pin: pin file still absent" "$([ -e "$PIN" ] || [ -L "$PIN" ] && echo present || echo absent)" "absent"
setup_case "-m m -s read-only"; printf '%s\n' "$U1" > "$PIN"; cp "$PIN" "$H/pin.before"
mk_rollout "$U1" "$LANE" codex-tui "$H/codex/sessions/2026/10/03"; go STUB_MODE=1 SIBLING_ROLLOUT="$SIB"
same "pinned lane: pin unchanged after a run that held rollouts"

# C (loop): presence is decided by lstat errno
PINREL=sub/lane.pin setup_case "-m m -s read-only"; : > "$H/hm/sub"; go
closed "C: pin parent is a regular file (ENOTDIR)" "pin-invalid"
PINREL=nodir/lane.pin setup_case "-m m -s read-only"; go
ok "C: no pin and no resume/ dir: fresh launch" "$(calls)" "1"
argv_is "C: no resume/ dir: fresh argv" -c "$(trust)" -m m -s read-only
PINREL=np/lane.pin setup_case "-m m -s read-only"; mkdir "$H/hm/np"; printf '%s\n' "$U1" > "$H/hm/np/lane.pin"; cp "$H/hm/np/lane.pin" "$H/pin.before"; chmod 000 "$H/hm/np"
if [ "$(id -u)" = 0 ]; then echo "SKIP: C no-search-permission pin dir in the loop (root ignores chmod)"; else
  go; chmod 755 "$H/hm/np"
  closed "C: unsearchable pin dir" "pin-invalid"; same "C: unsearchable pin dir leaves the pin byte-identical"
fi
chmod 755 "$H/hm/np" 2>/dev/null

# A (loop): a dangling symlink under sessions/ is not proven absence
setup_case "-m m -s read-only"; printf '%s\n' "$U1" > "$PIN"; cp "$PIN" "$H/pin.before"
ln -s "$H/gone" "$H/codex/sessions/dangling"; go
closed "A: dangling symlink under sessions" "pin-lookup-error"; same "A: pin untouched"

# B (loop): unverifiable rollout is pin-unverifiable, not pin-foreign
setup_case "-m m -s read-only"; printf '%s\n' "$U1" > "$PIN"; cp "$PIN" "$H/pin.before"
RF="$H/codex/sessions/2026/10/03/rollout-2026-10-03T10-00-00-$U1.jsonl"
printf '{"type":"session_meta","payload":{"originator":"codex-tui"}}\n' > "$RF"; go
closed "B: session_meta without cwd" "pin-unverifiable"; same "B: pin untouched"
setup_case "-m m -s read-only"; printf '%s\n' "$U1" > "$PIN"; cp "$PIN" "$H/pin.before"
RF="$H/codex/sessions/2026/10/03/rollout-2026-10-03T10-00-00-$U1.jsonl"
mk_rollout "$U1" "$LANE" codex-tui "$H/codex/sessions/2026/10/03"; go WRAP_HOOK='rm -f "$ROLLOUT_FILE"' ROLLOUT_FILE="$RF"
closed "B: rollout disappears between exists and verify-lane" "pin-unverifiable"; same "B: pin untouched"

# F: a logging failure never changes a decision or its reason
# scenario <name> <expected reason or LAUNCH>; each runs with a working log, then a blocked one
f_run() { # <blocked 0|1> <scenario>
  local blocked="$1" sc="$2"
  setup_case "-m m -s read-only"; FENV=()
  case "$sc" in
    helper-missing) FENV=(PATH="$STUBS:/usr/bin:/bin") ;;
    sandbox-invalid) setup_case "-m m -s bogus" ;;
    pin-invalid) mkdir "$PIN" ;;
    pin-lookup-error) printf '%s\n' "$U1" > "$PIN"; rm -rf "$H/codex/sessions" ;;
    pin-foreign) printf '%s\n' "$U1" > "$PIN"; mk_rollout "$U1" "$H/elsewhere" codex-tui "$H/codex/sessions/2026/10/03" ;;
    stale) printf '%s\n' "$U2" > "$PIN" ;;
    resume) printf '%s\n' "$U1" > "$PIN"; mk_rollout "$U1" "$LANE" codex-tui "$H/codex/sessions/2026/10/03" ;;
  esac
  if [ "$blocked" = 1 ]; then rm -rf "$H/hm/.sessions"; : > "$H/hm/.sessions"; fi
  go "${FENV[@]}"
}
for sc in helper-missing pin-foreign stale resume; do
  f_run 0 "$sc"; c0="$(calls)"; r0="$(grep -o 'resume-pin-fail-closed reason=[a-z-]*' "$LOG" | head -1)"
  f_run 1 "$sc"; c1="$(calls)"; r1="$(grep -o 'resume-pin-fail-closed reason=[a-z-]*' "$H/out" | head -1)"
  ok "F[$sc]: same launch decision with a blocked log" "$c1" "$c0"
  ok "F[$sc]: same reason with a blocked log" "$r1" "$r0"
  ok "F[$sc]: exactly one log-unavailable line" "$(grep -c 'event=log-unavailable' "$H/out")" "1"
done

# G: the pin must not change between read and use
setup_case "-m m -s read-only"; printf '%s\n' "$U1" > "$PIN"
mk_rollout "$U1" "$LANE" codex-tui "$H/codex/sessions/2026/10/03"
go WRAP_HOOK='printf "%s\n" "$NEWPIN" > "$PIN_FILE"' NEWPIN="$U2" PIN_FILE="$PIN"
closed "G1: pin rewritten during exists, rollout present" "pin-changed"
ok "G1: the pin still holds the new value" "$(cat "$PIN")" "$U2"
setup_case "-m m -s read-only"; printf '%s\n' "$U1" > "$PIN"
go WRAP_HOOK='printf "%s\n" "$NEWPIN" > "$PIN_FILE"' NEWPIN="$U2" PIN_FILE="$PIN"
closed "G2: pin rewritten during exists, rollout absent" "pin-changed"
ok "G2: the pin still holds the new value" "$(cat "$PIN")" "$U2"
ok "G2: no .stale file created" "$(ls "$H"/hm/lane.pin.stale.* 2>/dev/null | wc -l | tr -d ' ')" "0"

# S: a stale archive never overwrites
setup_case "-m m -a never"; printf '%s\n' "$U2" > "$PIN"; cp "$PIN" "$H/pin.before"
printf 'keep me\n' > "$H/hm/lane.pin.stale.1700000000"
go FAKE_EPOCH=1700000000
closed "S: archive name already exists" "pin-archive-failed"
ok "S: the existing file is byte-identical" "$(cat "$H/hm/lane.pin.stale.1700000000")" "keep me"
same "S: the pin was not moved"
setup_case "-m m -a never"; printf '%s\n' "$U2" > "$PIN"; cp "$PIN" "$H/pin.before"
go PATH="$WORK/mvnoop:$PATH_H"
closed "S: mv that exits 0 without moving is caught" "pin-archive-failed"; same "S: pin still in place"

# ======================================================= resume-pin edge cases
PR=".sessions/resume/lane.codex-thread"   # the production pin location, under ~/.sessions
pinarc() { ls "$H"/hm/.sessions/resume/lane.codex-thread.stale.* 2>/dev/null | wc -l | tr -d ' '; }

# ---- P: helper python is isolated, bounded, and every exception exits 2
PX="$WORK/p"; mkdir -p "$PX/lane" "$PX/hm" "$PX/codex/sessions/2026/10/03"; PXL="$(cd "$PX/lane" && pwd -P)"
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s\\u0000x","originator":"codex-tui"}}\n' "$U1" "$PXL" > "$PX/codex/sessions/2026/10/03/rollout-2026-10-03T10-00-00-$U1.jsonl"
ok "P: verify-lane with a NUL in the rollout cwd => 2" "$(CODEX_HOME="$PX/codex" rc bash "$RP" verify-lane "$U1" "$PXL")" "2"
rm -f "$PX"/codex/sessions/2026/10/03/rollout-*
if truncate -s 4G "$PX/big.pin" 2>/dev/null; then
  ok "P: a 4 GiB pin under a 1 GiB address-space cap => 2" "$( ( ulimit -v 1048576; rc bash "$RP" read-pin "$PX/big.pin" ) )" "2"
else echo "SKIP: P huge pin (cannot create a sparse file)"; fi
printf '%s\n' "$U1" > "$PX/hm/pin"; mk_rollout "$U1" "$PXL" codex-tui "$PX/codex/sessions/2026/10/03"
for m in re json; do printf 'open("%s/MARKER-%s", "w").write("x")\nraise RuntimeError("shadowed")\n' "$PX" "$m" > "$PX/lane/$m.py"; done
ok "P: read-pin with shadow modules in the CWD => 0" "$(cd "$PX/lane" && rc bash "$RP" read-pin "$PX/hm/pin")" "0"
ok "P: verify-lane with shadow modules in the CWD => 0" "$(cd "$PX/lane" && CODEX_HOME="$PX/codex" rc bash "$RP" verify-lane "$U1" "$PXL")" "0"
ok "P: sandbox-of with shadow modules in the CWD => 0" "$(cd "$PX/lane" && rc bash "$RP" sandbox-of -m x)" "0"
ok "P: no shadow module was executed" "$(ls "$PX"/MARKER-* 2>/dev/null | wc -l | tr -d ' ')" "0"

# ---- X: only an explicit 10 / 11 may lead to a fresh launch
PINREL="$PR" setup_case "-m m -s read-only"; printf '%s\n' "$U1" > "$PIN"; cp "$PIN" "$H/pin.before"
go POST_read_pin_1='rc=1'
closed "X: read-pin exits 1" "pin-invalid"; same "X: read-pin exit 1 leaves the pin untouched"
PINREL="$PR" setup_case "-m m -s read-only"; printf '%s\n' "$U1" > "$PIN"; cp "$PIN" "$H/pin.before"
go POST_exists_1='rc=1'
closed "X: exists exits 1" "pin-lookup-error"; same "X: exists exit 1 leaves the pin untouched"
ok "X: exists exit 1 archives nothing" "$(pinarc)" "0"

# ---- L: the log is opened once per pass; breaking it mid-pass changes nothing
brk='rm -rf "$LOG_F"; mkdir "$LOG_F"'
for pt in POST_sandbox_of_2 POST_exists_1; do
  PINREL="$PR" setup_case "-m m -s read-only"; printf '%s\n' "$U1" > "$PIN"; cp "$PIN" "$H/pin.before"
  mk_rollout "$U1" "$LANE" codex-tui "$H/codex/sessions/2026/10/03"
  go "$pt=$brk"
  argv_is "L[$pt]: still resumes the pinned thread" -c "$(trust)" resume "$U1" -m m -s read-only
  same "L[$pt]: pin untouched"
done
PINREL="$PR" setup_case "-m m -s read-only"; printf '%s\n' "$U1" > "$PIN"; mk_rollout "$U1" "$LANE" codex-tui "$H/codex/sessions/2026/10/03"
mkdir "$LOG"; go
ok "L: log blocked before the pass: still resumes" "$(grep -c "^resume" <(tr '\0' '\n' < "$ARGV"))" "1"
has "L: log blocked before the pass: log-unavailable" "$(cat "$H/out")" "event=log-unavailable"
ok "L: codex runs with fd 9 closed" "$(cat "$CALLS.fd9" 2>/dev/null | wc -l | tr -d ' ')" "0"
for how in blocked POST_sandbox_of_2; do
  PINREL="$PR" PASSES="1 2" setup_case "-m m -s read-only"; printf '%s\n' "$U1" > "$PIN"; mk_rollout "$U1" "$LANE" codex-tui "$H/codex/sessions/2026/10/03"
  hk=(); if [ "$how" = blocked ]; then mkdir "$LOG"; else hk=("POST_sandbox_of_2=$brk"); fi
  ( cd "$LANE" && env HOME="$H/hm" CODEX_HOME="$H/codex" ARGV_OUT="$ARGV" CALLS="$CALLS" RP_REAL="$RP" CASE_DIR="$H" LOG_F="$LOG" PATH="$H/wrapbin:$PATH_H" "${hk[@]}" \
      bash --norc -i < <(cat "$H/loop.sh"; echo 'echo SHELL-ALIVE') ) >"$H/out" 2>&1
  has "L: interactive shell survives a broken log ($how)" "$(cat "$H/out")" "SHELL-ALIVE"
  ok "L: interactive ($how): automatic pass 2 is denied" "$(calls)" "1"
done

# ---- G': a pin that changes during the archive is put back
PINREL="$PR" setup_case "-m m -s read-only"; printf '%s\n' "$U1" > "$PIN"
mk_rollout "$U2" "$LANE" codex-tui "$H/codex/sessions/2026/10/03"
go POST_read_pin_2='printf "%s\n" "$U2" > "$PIN_FILE"'
closed "G': pin rewritten after the re-read" "pin-archive-failed"
ok "G': the new pin is back in place" "$(cat "$PIN" 2>/dev/null)" "$U2"
ok "G': nothing left archived" "$(pinarc)" "0"
PINREL="$PR" PASSES="1 2" setup_case "-m m -s read-only"; printf '%s\n' "$U1" > "$PIN"
mk_rollout "$U2" "$LANE" codex-tui "$H/codex/sessions/2026/10/03"
go POST_read_pin_2='printf "%s\n" "$U2" > "$PIN_FILE"'
ok "G': automatic pass 2 launches nothing" "$(calls)" "0"
has "G': automatic pass 2 is admission-denied" "$(cat "$H/out")" "autonomous admission denied"
mkdir -p "$WORK/mvdir"
cat > "$WORK/mvdir/mv" <<'EOS'
#!/usr/bin/env bash
# the ARCHIVE call (source is the pin): make the destination a directory first, then run the real mv
for a in "$@"; do last_src="$prev"; prev="$a"; done
case "$last_src" in "$PIN_FILE") mkdir -p "$prev" ;; esac
exec /usr/bin/mv "$@"
EOS
chmod +x "$WORK/mvdir/mv"
PINREL="$PR" PASSES="1 2" setup_case "-m m -s read-only"; printf '%s\n' "$U1" > "$PIN"; cp "$PIN" "$H/pin.before"
go PATH="$WORK/mvdir:$H/wrapbin:$PATH_H"
ok "G': archive destination is a directory: no codex call in either pass" "$(calls)" "0"
has "G': archive destination is a directory: pin-archive-failed" "$(cat "$LOG")" "reason=pin-archive-failed"
same "G': archive destination is a directory: pin still U1"

# ---- A': aliases are not duplicates; every 2 names its cause
mkch; mk_rollout "$U1" "$WORK/laneA" codex-tui "$CH/sessions/2026/10/03"; ln -s 10/03 "$CH/sessions/2026/latest"
ok "A': an in-root alias of the rollout's directory => 0" "$(chrc "$U1")" "0"
ok "A': ...and the printed path is the real file" "$(CODEX_HOME="$CH" bash "$RP" exists "$U1")" "$(realpath "$CH/sessions/2026/10/03/rollout-2026-10-03T10-00-00-$U1.jsonl")"


# ---- D': codex resume flags that must stay rejected
for fl in --include-non-interactive --last --all; do
  setup_case "-m m $fl"; go; closed "D': loop with $fl" "sandbox-invalid"
done


finish "codex-resume-pin"
