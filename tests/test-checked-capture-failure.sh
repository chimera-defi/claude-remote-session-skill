#!/usr/bin/env bash
# A process substitution (`grep -q PAT < <(producer)`) feeds grep but drops the producer's exit status:
# a producer that prints a match and then FAILS reads as a match. The old pipe under pipefail said
# "false". Every repaired site captures the producer's complete output with its status checked, then
# matches, so on producer failure it returns exactly what the old pipe returned (brief 3e2).
#
# Part A compares each repaired function with main's pipe (written without -q, so grep reads the whole
# stream and cannot take SIGPIPE; pipefail still reports a failed producer, which is the point) over the four producer
# outcomes (match, no match, failure after a match, failure with no output) plus zero bytes and real
# trailing empty lines. Part B drives session-preserve with a git stub whose for-each-ref prints a
# reachable branch and then fails. Part C checks _verdict (the handoff caller). Hermetic: no tmux
# session, systemctl or agent CLI; stubs live under a private temp dir.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
isolate_overlay
SCRIPTS="$HERE/../scripts"
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
REALGIT="$(command -v git)"

# same LABEL OLD_RC NEW_RC: both true, or both false (the exit status is only ever used as a boolean).
same() { ok "$1" "$([ "$3" -eq 0 ] && echo true || echo false)" "$([ "$2" -eq 0 ] && echo true || echo false)"; }

# ---- the producer: one stub, the mode picks the outcome ----------------------------------------
MODE=match
stub_emit() {
  case "$MODE" in
    match)      printf 'alpha\nneedle\n' ;;
    nomatch)    printf 'alpha\nbeta\n' ;;
    failmatch)  printf 'needle\nalpha\n'; return 42 ;;
    failnone)   return 42 ;;
    zero)       : ;;
    emptyline)  printf 'alpha\n\n' ;;      # a real trailing empty line
    onlyempty)  printf '\n' ;;             # one empty line
    noeol)      printf 'needle' ;;         # no final newline
  esac
}
MODES="match nomatch failmatch failnone zero emptyline onlyempty noeol"

# ---- Part A1: session-handoff.sh ----------------------------------------------------------------
# shellcheck disable=SC1090
source "$SCRIPTS/session-handoff.sh"   # source-guarded: must NOT run dispatch
_input_region()      { stub_emit; }
_transcript_region() { stub_emit; }
ref_on_input()  { _input_region "$1" "$2" | grep -F -- "$1" >/dev/null; }
ref_in_trans()  { _transcript_region "$1" "$2" | grep -F -- "$1" >/dev/null; }
ref_collapsed() { _input_region "" "$1" | grep -E '\[Pasted text #[0-9]+ \+[0-9]+ lines?\]' >/dev/null; }
for MODE in $MODES; do
  for frag in needle ""; do
    ref_on_input "$frag" cap; o=$?; _on_input_line "$frag" cap; n=$?
    same "handoff-_on_input_line[$MODE][frag='$frag']" "$o" "$n"
    ref_in_trans "$frag" cap; o=$?; _in_transcript "$frag" cap; n=$?
    same "handoff-_in_transcript[$MODE][frag='$frag']" "$o" "$n"
  done
done
stub_emit() { case "$MODE" in
  match) printf '❯ [Pasted text #1 +17 lines]\n' ;; nomatch) printf '❯ hello\n' ;;
  failmatch) printf '❯ [Pasted text #1 +17 lines]\n'; return 42 ;; failnone) return 42 ;;
  zero) : ;; emptyline) printf '❯ hello\n\n' ;; onlyempty) printf '\n' ;; noeol) printf '❯ [Pasted text #2 +3 lines]' ;;
esac; }
for MODE in $MODES; do
  ref_collapsed cap; o=$?; _is_collapsed_paste_in_input cap; n=$?
  same "handoff-_is_collapsed_paste_in_input[$MODE]" "$o" "$n"
done

# ---- Part C: the caller. A failing region must not become an inference -------------------------
# buffered => the caller presses Enter again; landed => the caller reports a confirmed submission.
stub_emit() { case "$MODE" in
  failmatch) printf 'needle\n'; return 42 ;; match) printf 'needle\n' ;; *) : ;; esac; }
CAP_PLAIN='nothing relevant on this pane'
MODE=failmatch; ok "verdict-failed-region-is-unverified" "$(_verdict needle "$CAP_PLAIN")" unverified
ok "failed-region-input-no-extra-enter" "$(_on_input_line needle cap && echo buffered || echo no)" no
ok "failed-region-transcript-no-confirmation" "$(_in_transcript needle cap && echo landed || echo no)" no
MODE=match;     ok "verdict-control-input-match-is-buffered" "$(_verdict needle "$CAP_PLAIN")" buffered
unset -f _input_region; _input_region() { return 0; }   # input side quiet, transcript side matching
MODE=match;     ok "verdict-control-transcript-match-is-landed" "$(_verdict needle "$CAP_PLAIN")" landed
MODE=failmatch; ok "verdict-failed-transcript-is-unverified" "$(_verdict needle "$CAP_PLAIN")" unverified

# ---- Part A2: session-doctor.sh -----------------------------------------------------------------
PROTECT='^$'      # the default: a here-string's lone empty line must NOT match it
eval "$(sed -n '/^_title_protected() {/,/^}/p' "$SCRIPTS/session-doctor.sh")"
eval "$(sed -n '/^_tmux_live_has() {/,/^}/p' "$SCRIPTS/session-doctor.sh")"
ref_title_protected() { printf '%s' "$1" | tr -s '[:space:]' '-' | grep -iE "$PROTECT" >/dev/null; }
for PROTECT in '^$' 'keep|secret'; do
  for t in "" "   " "a" "my secret" $'a\n' $'\n' $'keep\n' "x y"; do
    ref_title_protected "$t"; o=$?; _title_protected "$t"; n=$?
    same "doctor-_title_protected[PROTECT=$PROTECT][$(printf %q "$t")]" "$o" "$n"
  done
done
live_tmux() { stub_emit; }
ref_live_has() { live_tmux | grep -x -- "$1" >/dev/null; }
stub_emit() { case "$MODE" in
  match) printf 'alpha\nneedle\n' ;; nomatch) printf 'alpha\nbeta\n' ;;
  failmatch) printf 'needle\nalpha\n'; return 42 ;; failnone) return 42 ;; zero) : ;;
  emptyline) printf 'alpha\n\n' ;; onlyempty) printf '\n' ;; noeol) printf 'needle' ;; esac; }
for MODE in $MODES; do
  for nm in needle ""; do
    ref_live_has "$nm"; o=$?; _tmux_live_has "$nm"; n=$?
    same "doctor-_tmux_live_has[$MODE][name='$nm']" "$o" "$n"
  done
done
# a real trailing empty line: name "" matches it (-x), but not after a bare single trailing newline
MODE=emptyline; ok "doctor-trailing-empty-line-is-kept" "$(_tmux_live_has '' && echo y || echo n)" y
MODE=match;     ok "doctor-no-empty-line-no-match"       "$(_tmux_live_has '' && echo y || echo n)" n
MODE=zero;      ok "doctor-zero-bytes-never-match"       "$(_tmux_live_has '' && echo y || echo n)" n

# ---- Part B: session-preserve.sh, git for-each-ref prints a reachable branch, then fails --------
FH="$TMPD/home"; mkdir -p "$FH/.claude/worktrees" "$TMPD/bin"
WT="$FH/.claude/worktrees/px-x-0101-0000"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
"$REALGIT" init --quiet -b main "$WT"; "$REALGIT" -C "$WT" commit --quiet --allow-empty -m init
"$REALGIT" -C "$WT" checkout --quiet --detach     # HEAD is on no branch: reachable only through `main`
cat > "$TMPD/bin/git" <<GEOF
#!/usr/bin/env bash
if [ -n "\${STUB_FOR_EACH_REF:-}" ]; then
  for a in "\$@"; do
    if [ "\$a" = for-each-ref ]; then
      case "\$STUB_FOR_EACH_REF" in
        failmatch) printf 'main\n'; exit 42 ;;
        failnone)  exit 42 ;;
      esac
    fi
  done
fi
exec "$REALGIT" "\$@"
GEOF
printf '#!/bin/sh\nexit 1\n' > "$TMPD/bin/tmux"; chmod +x "$TMPD/bin/git" "$TMPD/bin/tmux"
export CRSS_SESSION_PREFIX=px CRSS_LEGACY_PREFIXES=oldhost
run_sp() { STUB_FOR_EACH_REF="$1" HOME="$FH" PATH="$TMPD/bin:$PATH" bash "$SCRIPTS/session-preserve.sh" px_x-0101-0000 2>&1; }
out="$(run_sp "")"
has   "preserve-control-reachable-yes" "$out" "HEAD reachable from a named local branch: yes"
has   "preserve-control-safe"          "$out" "VERDICT: SAFE-TO-REAP"
out="$(run_sp failmatch)"
has   "preserve-failed-listing-after-match-unreachable" "$out" "HEAD reachable from a named local branch: NO"
hasnt "preserve-failed-listing-after-match-not-safe"    "$out" "VERDICT: SAFE-TO-REAP"
has   "preserve-failed-listing-after-match-verdict"     "$out" "NOT-SAFE-TO-REAP"
out="$(run_sp failnone)"
has   "preserve-failed-listing-no-output-unreachable"   "$out" "HEAD reachable from a named local branch: NO"
hasnt "preserve-failed-listing-no-output-not-safe"      "$out" "VERDICT: SAFE-TO-REAP"
finish "checked-capture-failure"
