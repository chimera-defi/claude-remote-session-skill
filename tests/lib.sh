#!/usr/bin/env bash
# Shared assertion helpers for tests/test-*.sh (sourced, not run; CI only runs test-*.sh).
# Usage: source "$HERE/lib.sh"; ...assertions...; finish "suite-name"
pass=0; fail=0
# All script tests inherit a private telemetry sink, including indirect spawns.
# CRSS_TEST_SUITE makes record-spawn-telemetry write nothing if a path loses TELEMETRY_ROOT.
# Every temp dir, file and stub executable a test makes (mktemp, child scripts, fakes) lands under one private TMPDIR that
# is removed on exit, so a full run leaves no /tmp/tmp.* behind (chkrootkit flags the fake-binary stubs as malware).
CRSS_TEST_TMP="$(mktemp -d)"
export CRSS_TEST_TMP TMPDIR="$CRSS_TEST_TMP"
TELEMETRY_ROOT="$CRSS_TEST_TMP/telemetry"; mkdir -p "$TELEMETRY_ROOT"
export TELEMETRY_ROOT CRSS_TEST_SUITE=1
_crss_lib_cleanup() { rm -rf "$CRSS_TEST_TMP"; }
# shellcheck disable=SC2218  # defined on the line above; shellcheck mis-orders it against the trap() wrapper below
builtin trap _crss_lib_cleanup EXIT
# Tests install their own EXIT cleanup, which replaces the line above. Make every EXIT trap also run ours so the
# private TMPDIR is always removed last, whatever a test sets. Only set EXIT traps at top level, never in a ( ) subshell:
# the subshell would remove the shared TMPDIR while the parent test still uses it.
trap() {
  if [ "$#" -ge 2 ] && [ "${!#}" = EXIT ] && [ "$1" != -p ] && [ "$1" != - ]; then
    # shellcheck disable=SC2064  # expanding the test's handler text now is the point
    builtin trap "$1; _crss_lib_cleanup" EXIT
  else
    # shellcheck disable=SC2064
    builtin trap "$@"
  fi
}
# isolate_overlay: point CRSS_HOME at a nonexistent dir so a script's config loader never reads the operator's real overlay.
isolate_overlay() { export CRSS_HOME="/tmp/crss-test-isolation.$$.$RANDOM/does-not-exist"; }

# ok LABEL GOT WANT: exact string equality.
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }
# has LABEL TEXT NEEDLE: fixed-string substring present in TEXT.
has() { if grep -qF -- "$3" <<<"$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — pattern not found: $3 in: $2"; fi; }
# hasnt LABEL TEXT NEEDLE: substring absent from TEXT.
hasnt() { if grep -qF -- "$3" <<<"$2"; then fail=$((fail+1)); echo "FAIL: $1 — pattern unexpectedly present: $3"; else pass=$((pass+1)); fi; }
# hasre LABEL TEXT REGEX: extended regex matches TEXT.
hasre() { if grep -qE -- "$3" <<<"$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — pattern not found: $3 in: $2"; fi; }
# yn CMD...: prints yes/no for a command's success (for ok "label" "$(yn test -d X)" yes).
yn() { if "$@" >/dev/null 2>&1; then echo yes; else echo no; fi; }
# isdir/nodir/isfile/nofile/exists/gone LABEL PATH: filesystem state checks (-d, -f, -e).
isdir()  { ok "$1" "$([ -d "$2" ] && echo yes || echo no)" yes; }
nodir()  { ok "$1" "$([ -d "$2" ] && echo yes || echo no)" no; }
isfile() { ok "$1" "$([ -f "$2" ] && echo yes || echo no)" yes; }
nofile() { ok "$1" "$([ -f "$2" ] && echo yes || echo no)" no; }
exists() { ok "$1" "$([ -e "$2" ] && echo yes || echo no)" yes; }
gone()   { ok "$1" "$([ -e "$2" ] && echo yes || echo no)" no; }
# finish NAME: print the summary line; exit status is the suite's verdict.
finish() { echo "$1: pass=$pass fail=$fail"; [ "$fail" -eq 0 ]; }
