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
ok "sandbox --sandbox="    "$(bash "$RP" sandbox-of --sandbox=danger-full-access)" "danger-full-access"
ok "sandbox -c form"       "$(bash "$RP" sandbox-of -c 'sandbox_mode="workspace-write"')" "workspace-write"
ok "sandbox -c single-quoted toml" "$(bash "$RP" sandbox-of -c "sandbox_mode='read-only'")" "read-only"
ok "sandbox -c spaced toml" "$(bash "$RP" sandbox-of -c 'sandbox_mode = "workspace-write"')" "workspace-write"
ok "sandbox default"       "$(bash "$RP" sandbox-of -m x -a never)" "read-only"
ok "sandbox explicit none" "$(bash "$RP" sandbox-of --explicit -m x -a never)" ""
ok "sandbox same twice is fine" "$(bash "$RP" sandbox-of -s read-only --sandbox=read-only)" "read-only"
ok "sandbox unknown value fails" "$(rc bash "$RP" sandbox-of -s bogus)" "1"
ok "sandbox single-quoted bogus fails" "$(rc bash "$RP" sandbox-of -c "sandbox_mode='bogus'")" "1"
ok "sandbox conflict -s vs --sandbox= fails" "$(rc bash "$RP" sandbox-of -s read-only --sandbox=workspace-write)" "1"
ok "sandbox conflict -s vs -c fails" "$(rc bash "$RP" sandbox-of -s read-only -c 'sandbox_mode="workspace-write"')" "1"
ok "sandbox missing value fails" "$(rc bash "$RP" sandbox-of -m x -s)" "1"

# ---------------------------------------------------------------- read-pin
P="$WORK/pins"; mkdir -p "$P"
ok "read-pin absent => 1" "$(rc bash "$RP" read-pin "$P/none")" "1"
printf '%s\n' "$U1" > "$P/ok";       ok "read-pin ok" "$(bash "$RP" read-pin "$P/ok")" "$U1"
printf '%s'   "$U1" > "$P/nonl";     ok "read-pin ok without newline" "$(bash "$RP" read-pin "$P/nonl")" "$U1"
mkdir "$P/dir";                      ok "read-pin directory => 2" "$(rc bash "$RP" read-pin "$P/dir")" "2"
: > "$P/empty";                      ok "read-pin empty => 2" "$(rc bash "$RP" read-pin "$P/empty")" "2"
printf '%s\n%s\n' "$U1" "$U2" > "$P/two"; ok "read-pin two lines => 2" "$(rc bash "$RP" read-pin "$P/two")" "2"
printf "%s\n" "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA" > "$P/upper"; ok "read-pin uppercase => 2" "$(rc bash "$RP" read-pin "$P/upper")" "2"
printf '*\n' > "$P/glob";            ok "read-pin glob => 2" "$(rc bash "$RP" read-pin "$P/glob")" "2"
printf '%s \n' "$U1" > "$P/space";   ok "read-pin trailing space => 2" "$(rc bash "$RP" read-pin "$P/space")" "2"
ln -s "$P/ok" "$P/link";             ok "read-pin symlink => 2" "$(rc bash "$RP" read-pin "$P/link")" "2"
ln -s "$P/nowhere" "$P/dangling";    ok "read-pin dangling symlink => 2 (present, not absent)" "$(rc bash "$RP" read-pin "$P/dangling")" "2"

# ---------------------------------------------------------------- exists / verify-lane
mkdir -p "$WORK/laneA" "$WORK/laneB"
mk_rollout "$U1" "$WORK/laneA" codex-tui
ok "exists: one rollout" "$(rc bash "$RP" exists "$U1")" "0"
has "exists prints the path" "$(bash "$RP" exists "$U1")" "rollout-2026-10-03T10-00-00-$U1.jsonl"
ok "exists: proven absence => 1" "$(rc bash "$RP" exists "$U2")" "1"
mk_rollout "$U1" "$WORK/laneA" codex-tui "$CODEX_HOME/sessions/2026/10/04"
ok "exists: two matches => 2" "$(rc bash "$RP" exists "$U1")" "2"
rm -rf "$CODEX_HOME/sessions/2026/10/04"
ok "exists: non-uuid (glob) => 2" "$(rc bash "$RP" exists '*')" "2"
ok "exists: sessions dir missing => 2" "$(CODEX_HOME="$WORK/nohome" rc bash "$RP" exists "$U1")" "2"
ok "verify-lane ok" "$(rc bash "$RP" verify-lane "$U1" "$WORK/laneA")" "0"
ok "verify-lane foreign cwd => 1" "$(rc bash "$RP" verify-lane "$U1" "$WORK/laneB")" "1"
mk_rollout "$U2" "$WORK/laneA" codex_exec
ok "verify-lane wrong originator => 1" "$(rc bash "$RP" verify-lane "$U2" "$WORK/laneA")" "1"
printf 'not json\n' > "$ROLL/rollout-2026-10-03T10-00-00-$U3.jsonl"
ok "verify-lane unreadable rollout => 2" "$(rc bash "$RP" verify-lane "$U3" "$WORK/laneA")" "2"
ok "verify-lane absent rollout => 2" "$(rc bash "$RP" verify-lane 44444444-4444-4444-8444-444444444444 "$WORK/laneA")" "2"
rm -f "$ROLL"/rollout-*

# ================================================================ start-loop harness
# One stubbed spawn yields the REAL generated Codex loop; each case runs it once (the
# `while true` becomes a single pass) against stubs.
SBIN="$WORK/sbin"; mkdir -p "$SBIN"
ln -sf "$HERE/../scripts/session-alias.sh" "$SBIN/session-alias"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SBIN/systemctl"; chmod +x "$SBIN/systemctl"
printf '#!/usr/bin/env bash\ncase "$1" in +%%m%%d-%%H%%M) echo 0101-0000 ;; *) exec /usr/bin/env date "$@" ;; esac\n' > "$SBIN/date"; chmod +x "$SBIN/date"
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
STUBS="$WORK/stubs"; mkdir -p "$STUBS" "$WORK/helperbin" "$WORK/mvfail"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBS/sleep"
cat > "$STUBS/codex" <<'EOS'
#!/usr/bin/env bash
printf '%s\0' "$@" >> "$ARGV_OUT"; echo call >> "$CALLS"
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
chmod +x "$STUBS/sleep" "$STUBS/codex" "$WORK/mvfail/mv"
ln -sf "$RP" "$WORK/helperbin/codex-resume-pin"
PATH_H="$STUBS:$WORK/helperbin:/usr/bin:/bin"

# setup_case <args-literal>: fresh HOME/CODEX_HOME/lane and a single-pass copy of the loop.
# go [VAR=val ...]: run it in the lane (default PATH has the helper).
setup_case() {
  H="$(mktemp -d "$WORK/case.XXXXXX")"; LANE="$H/lane"
  mkdir -p "$LANE" "$H/hm/.sessions/resume" "$H/codex/sessions/2026/10/03"
  ARGV="$H/argv.out"; CALLS="$H/calls"; LOG="$H/hm/.sessions/session-starts.log"; : > "$ARGV"; : > "$CALLS"
  {
    printf 'CODEX_BIN=%s\nCODEX_ARGS=(%s)\nCODEX_PIN="$HOME/lane.pin"\n' "$STUBS/codex" "$1"
    grep -vE '^(CODEX_BIN|CODEX_ARGS|CODEX_PIN)=' "$WORK/loop.src" | sed 's/^while true; do/for _once in 1; do/'
  } > "$H/loop.sh"
  LANE="$(cd "$LANE" && pwd -P)"; PIN="$H/hm/lane.pin"
}
go() { ( cd "$LANE" && env HOME="$H/hm" CODEX_HOME="$H/codex" ARGV_OUT="$ARGV" CALLS="$CALLS" PATH="$PATH_H" "$@" bash "$H/loop.sh" ) >"$H/out" 2>&1; }
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
for kind in dir empty twolines notuuid glob symlink; do
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
AWK_LIT="-m 'two words' \$'line1\nline2' -leading '' --flag='a b'"
setup_case "$AWK_LIT"; printf '%s\n' "$U1" > "$PIN"; mk_rollout "$U1" "$LANE" codex-tui "$H/codex/sessions/2026/10/03"; go
ok "valid pin: one launch" "$(calls)" "1"
argv_is "valid pin: resume argv, awkward elements intact" -c "$(trust)" resume "$U1" -m 'two words' $'line1\nline2' -leading '' '--flag=a b' -s read-only
has "resume logged" "$(cat "$LOG")" "event=resume thread=$U1 sandbox=read-only"
setup_case "$AWK_LIT"; go
argv_is "no pin: fresh argv, awkward elements intact" -c "$(trust)" -m 'two words' $'line1\nline2' -leading '' '--flag=a b' -s read-only
ok "fresh launch writes no pin" "$([ -e "$PIN" ] || [ -L "$PIN" ] && echo present || echo absent)" "absent"

# 9. sandbox spellings: exactly one effective sandbox, never a duplicate -s
setup_case "-m m -s workspace-write"; go;           argv_is "-s X kept, nothing appended" -c "$(trust)" -m m -s workspace-write
setup_case "-m m --sandbox workspace-write"; go;    argv_is "--sandbox X kept" -c "$(trust)" -m m --sandbox workspace-write
setup_case "-m m --sandbox=workspace-write"; go;    argv_is "--sandbox=X kept" -c "$(trust)" -m m --sandbox=workspace-write
setup_case "-m m -c 'sandbox_mode=\"workspace-write\"'"; go; argv_is "-c sandbox_mode=X gets -s X appended" -c "$(trust)" -m m -c 'sandbox_mode="workspace-write"' -s workspace-write
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

finish "codex-resume-pin"
