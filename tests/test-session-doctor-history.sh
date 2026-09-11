#!/usr/bin/env bash
# Plain-bash tests for session-doctor.sh's `history` mode (NOW + PAST report
# for a worktree folder). No external test framework.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1090
source "$HERE/../scripts/session-doctor.sh"   # must NOT run dispatch (source-guard)
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }
has(){ if printf '%s' "$2" | grep -qF "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — pattern not found: $3 in: $2"; fi; }

# ── _encode_cwd: pure string transform, order matters ('.' before '/') ───────
ok "encode-basic" "$(_encode_cwd "/home/agents/.claude/worktrees/ah-x-1")" "-home-agents--claude-worktrees-ah-x-1"
ok "encode-no-path-required" "$(_encode_cwd "/does/not/exist.d/here")" "-does-not-exist-d-here"

# ── _history_matches: pure logic over synthetic wt_base/proj_base dirs ───────
# (function takes wt_base/proj_base as explicit params — this is the "HOME/
# projects root overridable" seam: tests point straight at a tmpdir, no need
# to fake a whole $HOME/.claude tree just to exercise the matching logic.)
MBASE="$(mktemp -d)"
WTB="$MBASE/worktrees"; PROJB="$MBASE/projects"
mkdir -p "$WTB/ah-foo-0101-0100" "$WTB/ah-bar-0101-0200" "$PROJB"
# A worktree that's been removed from disk but still has transcript history —
# the common PAST case. Recovered from proj_base by stripping the deterministic
# encode(wt_base)+"-" prefix, so it's discoverable even though nothing exists
# under $WTB for it.
GONE_PREFIX="$(_encode_cwd "$WTB")-"
mkdir -p "$PROJB/${GONE_PREFIX}ah-gone-0101-0300"

ok "match-exact-name" "$(_history_matches "ah-foo-0101-0100" "$WTB" "$PROJB")" "$WTB/ah-foo-0101-0100"
ok "match-exact-abspath" "$(_history_matches "$WTB/ah-foo-0101-0100/" "$WTB" "$PROJB")" "$WTB/ah-foo-0101-0100"
ok "match-exact-gone-worktree-via-transcript" "$(_history_matches "ah-gone-0101-0300" "$WTB" "$PROJB")" "$WTB/ah-gone-0101-0300"

sub_out="$(_history_matches "ah" "$WTB" "$PROJB")"
ok "match-substring-count" "$(printf '%s\n' "$sub_out" | grep -c .)" "3"
has "match-substring-has-foo"  "$sub_out" "$WTB/ah-foo-0101-0100"
has "match-substring-has-bar"  "$sub_out" "$WTB/ah-bar-0101-0200"
has "match-substring-has-gone" "$sub_out" "$WTB/ah-gone-0101-0300"

no_out="$(_history_matches "zzz-totally-unmatched" "$WTB" "$PROJB")"; no_rc=$?
ok "match-none-empty-output" "$no_out" ""
ok "match-none-nonzero-rc" "$no_rc" "1"

rm -rf "$MBASE"

# ── _history_report: PAST parsing (turn counting, ordering, zero-user files) ─
RBASE="$(mktemp -d)"
WT_R="$RBASE/wt/ah-histtest-0101-0400"; mkdir -p "$WT_R"
WT_R="$(cd "$WT_R" && pwd -P)"   # canonicalize, same as the cwd /proc would report
PROJB_R="$RBASE/projects"
ENC_R="$(_encode_cwd "$WT_R")"
mkdir -p "$PROJB_R/$ENC_R"

# Older session: 2 type:user turns, both before the newer session's turn.
UUID_A="aaaaaaaa-0000-0000-0000-000000000001"
cat > "$PROJB_R/$ENC_R/$UUID_A.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-01-01T09:00:00.000Z"}
{"type":"assistant","timestamp":"2026-01-01T09:00:05.000Z"}
{"type":"user","timestamp":"2026-01-01T09:05:00.000Z"}
EOF

# Newer session: 1 type:user turn, later than session A's last turn.
UUID_B="bbbbbbbb-0000-0000-0000-000000000002"
cat > "$PROJB_R/$ENC_R/$UUID_B.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-01-01T10:00:00.000Z"}
EOF

# Session with transcript lines but ZERO type:user entries — must not crash,
# must report turns=0 and "(none)" rather than a bogus timestamp.
UUID_C="cccccccc-0000-0000-0000-000000000003"
cat > "$PROJB_R/$ENC_R/$UUID_C.jsonl" <<'EOF'
{"type":"summary","summary":"nothing user-authored here"}
{"type":"system","subtype":"init"}
EOF

rout="$(_history_report "$WT_R" "$PROJB_R")"

# NB: has()'s pattern arg goes straight to `grep -qF`, so a pattern starting
# with "-" is misread as a flag — every pattern below is chosen (or trimmed)
# to not start with "-".
has "report-header" "$rout" "$WT_R ---"
has "report-now-empty" "$rout" "(none)"   # no real process has this synthetic cwd
has "report-past-count" "$rout" "3 past session(s), 0 live session(s)"

rowA="$(printf '%s\n' "$rout" | grep -F "${UUID_A:0:8}")"
rowB="$(printf '%s\n' "$rout" | grep -F "${UUID_B:0:8}")"
rowC="$(printf '%s\n' "$rout" | grep -F "${UUID_C:0:8}")"
ok "report-turns-A" "$(printf '%s' "$rowA" | awk '{print $4}')" "2"
ok "report-turns-B" "$(printf '%s' "$rowB" | awk '{print $4}')" "1"
ok "report-turns-C-zero" "$(printf '%s' "$rowC" | awk '{print $4}')" "0"
ok "report-first-A" "$(printf '%s' "$rowA" | awk '{print $2}')" "2026-01-01T09:00:00Z"
ok "report-last-A"  "$(printf '%s' "$rowA" | awk '{print $3}')" "2026-01-01T09:05:00Z"
ok "report-nouser-shows-none" "$(printf '%s' "$rowC" | awk '{print $2}')" "(none)"

# Ordering: sorted by last type:user ascending -> A's row must come BEFORE B's.
lineA="$(printf '%s\n' "$rout" | grep -nF "${UUID_A:0:8}" | cut -d: -f1)"
lineB="$(printf '%s\n' "$rout" | grep -nF "${UUID_B:0:8}" | cut -d: -f1)"
ok "report-ordering-A-before-B" "$([ "$lineA" -lt "$lineB" ] && echo yes || echo no)" "yes"

rm -rf "$RBASE"

# ── _history_report: no transcript dir at all (never messaged / brand new) ───
EBASE="$(mktemp -d)"
WT_E="$EBASE/wt-empty"; mkdir -p "$WT_E"
eout="$(_history_report "$WT_E" "$EBASE/no-such-projects-root")"
has "report-no-transcript-dir" "$eout" "(no transcript directory"
rm -rf "$EBASE"

# ── _history_footer: worktree gone from disk vs. present (reuses _wt_dirty/
# _wt_landed — not reimplemented) ─────────────────────────────────────────────
fout_gone="$(_history_footer "/definitely/not/a/real/worktree/path-$$")"
has "footer-gone-worktree" "$fout_gone" "no longer exists on disk"

if command -v git >/dev/null 2>&1; then
  FBASE="$(mktemp -d)"
  FREPO="$FBASE/repo"; mkdir -p "$FREPO"
  git -C "$FREPO" init -q -b main
  git -C "$FREPO" config user.email t@t.com; git -C "$FREPO" config user.name t
  echo hi > "$FREPO/a.txt"; git -C "$FREPO" add a.txt; git -C "$FREPO" commit -q -m init
  WT_F="$FBASE/wt"
  git -C "$FREPO" worktree add -q -b session/ah-footertest-0101-0500 "$WT_F" main >/dev/null 2>&1

  fout="$(_history_footer "$WT_F")"
  has "footer-present-branch"  "$fout" "branch=session/ah-footertest-0101-0500"
  has "footer-present-landed"  "$fout" "landed=yes"
  has "footer-present-status"  "$fout" "status=clean"
  has "footer-present-gitlog"  "$fout" "init"
  rm -rf "$FBASE"
fi

# ── end-to-end through the real mode dispatch (HOME override, like the
# existing worktree-stale/land-check tests) — exercises argument parsing,
# _history_matches + _history_report + _history_footer wired together, exit
# codes, and the "worktree no longer exists on disk but has transcripts" path
# through the FULL dispatch, not just the helper function in isolation.
E2EHOME="$(mktemp -d)"
mkdir -p "$E2EHOME/.claude/worktrees" "$E2EHOME/.claude/projects"

# Exact-folder match, worktree present and a real git repo (also exercises the
# footer's landed/dirty path end-to-end).
if command -v git >/dev/null 2>&1; then
  E2EREPO="$E2EHOME/srcrepo"; mkdir -p "$E2EREPO"
  git -C "$E2EREPO" init -q -b main
  git -C "$E2EREPO" config user.email t@t.com; git -C "$E2EREPO" config user.name t
  echo hi > "$E2EREPO/a.txt"; git -C "$E2EREPO" add a.txt; git -C "$E2EREPO" commit -q -m init
  WT_E2E="$E2EHOME/.claude/worktrees/ah-e2elive-0101-0600"
  git -C "$E2EREPO" worktree add -q -b session/ah-e2elive-0101-0600 "$WT_E2E" main >/dev/null 2>&1

  exactout="$(HOME="$E2EHOME" bash "$HERE/../scripts/session-doctor.sh" history ah-e2elive-0101-0600 2>&1)"; exactrc=$?
  ok  "e2e-exact-exit0"      "$exactrc" "0"
  has "e2e-exact-header"     "$exactout" "1 worktree(s) matching 'ah-e2elive-0101-0600'"
  has "e2e-exact-footer"     "$exactout" "branch=session/ah-e2elive-0101-0600"
  has "e2e-exact-landed"     "$exactout" "landed=yes"
fi

# Worktree removed from disk but transcripts remain (genuinely PAST session) —
# exercised end-to-end: no directory under .claude/worktrees/, only a
# transcript dir; exact-name lookup must still find it and the footer must say
# it's gone, not crash trying to run git against a missing path.
WT_GONE_NAME="ah-e2egone-0101-0700"
WT_GONE_PATH="$E2EHOME/.claude/worktrees/$WT_GONE_NAME"
ENC_GONE="$(_encode_cwd "$WT_GONE_PATH")"
mkdir -p "$E2EHOME/.claude/projects/$ENC_GONE"
cat > "$E2EHOME/.claude/projects/$ENC_GONE/deadbeef-0000-0000-0000-000000000009.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-02-02T08:00:00.000Z"}
{"type":"user","timestamp":"2026-02-02T08:10:00.000Z"}
EOF

goneout="$(HOME="$E2EHOME" bash "$HERE/../scripts/session-doctor.sh" history "$WT_GONE_NAME" 2>&1)"; gonerc=$?
ok  "e2e-gone-exit0"          "$gonerc" "0"
has "e2e-gone-footer-message" "$goneout" "no longer exists on disk"
has "e2e-gone-past-session"   "$goneout" "deadbeef"
# Extract the TURNS field specifically (a bare `has ... "2"` would pass
# trivially against the "2026-02-02" timestamps elsewhere in the same row).
ok "e2e-gone-turns" "$(printf '%s\n' "$goneout" | grep -F deadbeef | awk '{print $4}')" "2"

# Substring/repo-name match: both the live and the gone worktree share the
# "e2e" substring and must both be reported in one invocation.
repoout="$(HOME="$E2EHOME" bash "$HERE/../scripts/session-doctor.sh" history e2e 2>&1)"; reporc=$?
ok  "e2e-repo-exit0"        "$reporc" "0"
has "e2e-repo-finds-live"   "$repoout" "ah-e2elive-0101-0600"
has "e2e-repo-finds-gone"   "$repoout" "ah-e2egone-0101-0700"

# No match at all -> clear message on stderr, exit 2.
nomatchout="$(HOME="$E2EHOME" bash "$HERE/../scripts/session-doctor.sh" history zz-nope-nothing-here 2>&1)"; nomatchrc=$?
ok  "e2e-nomatch-exit2"   "$nomatchrc" "2"
has "e2e-nomatch-message" "$nomatchout" "no worktree matches"

rm -rf "$E2EHOME"

# ── live-session cross-reference: NOW and PAST must not double-count ─────────
# A real background process (argv[0] renamed to "claude" via `exec -a`, cwd
# set to the synthetic worktree, "--remote-control <name>" appended as literal
# trailing argv) so pgrep -af's exact same match/basename-filter/readlink path
# `_history_report` reuses from idle-report picks it up for real, no mocking.
# (`trap : TERM; sleep N` — not a bare `sleep N` — because bash tail-call-
# execs away a single simple last command in `bash -c SCRIPT`, which would
# silently replace argv[0]/argv[1:] with sleep's own and lose the rename and
# the injected --remote-control text; a trap keeps bash itself running.)
if command -v pgrep >/dev/null 2>&1; then
  LBASE="$(mktemp -d)"
  WT_L="$LBASE/wt"; mkdir -p "$WT_L"
  WT_L="$(cd "$WT_L" && pwd -P)"
  PROJB_L="$LBASE/projects"
  ENC_L="$(_encode_cwd "$WT_L")"
  mkdir -p "$PROJB_L/$ENC_L"

  UUID_OLD="11111111-0000-0000-0000-000000000001"
  cat > "$PROJB_L/$ENC_L/$UUID_OLD.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-01-01T09:00:00.000Z"}
{"type":"user","timestamp":"2026-01-01T09:05:00.000Z"}
EOF
  # This one gets the LATEST last-type:user timestamp -> the live process is
  # assumed to be writing it, so it should be folded into NOW, not PAST.
  UUID_NEW="22222222-0000-0000-0000-000000000002"
  cat > "$PROJB_L/$ENC_L/$UUID_NEW.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-01-01T10:00:00.000Z"}
EOF

  # `trap : TERM; sleep 15` (not a bare `sleep 15`) so bash itself stays
  # resident instead of tail-call-execing away into sleep — see the comment
  # above. That trap also means a plain `kill` (SIGTERM) is deliberately
  # ignored by this process, so cleanup below uses SIGKILL, not SIGTERM.
  ( cd "$WT_L" && exec -a claude bash -c 'trap : TERM; sleep 15' ignored --remote-control ah-histtest-live-0101-0800 ) &
  LIVEPID=$!
  sleep 0.3

  liveout="$(_history_report "$WT_L" "$PROJB_L")"
  kill -9 "$LIVEPID" 2>/dev/null; wait "$LIVEPID" 2>/dev/null

  has "live-now-shows-pid"        "$liveout" "$LIVEPID"
  has "live-now-shows-remote-name" "$liveout" "ah-histtest-live-0101-0800"
  has "live-cross-ref-marks-newest" "$liveout" "${UUID_NEW:0:8} is LIVE now"
  has "live-older-still-in-past"  "$liveout" "${UUID_OLD:0:8}"
  ok  "live-past-count-excludes-newest" "$(printf '%s' "$liveout" | grep -oE -- '--- [0-9]+ past session' | grep -oE '[0-9]+')" "1"

  rm -rf "$LBASE"
fi

echo "session-doctor-history: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
