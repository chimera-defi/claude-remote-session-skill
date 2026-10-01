#!/usr/bin/env bash
# Shared assertion helpers for tests/test-*.sh (sourced, not run; CI only runs test-*.sh).
# Usage: source "$HERE/lib.sh"; ...assertions...; finish "suite-name"
pass=0; fail=0
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
