#!/usr/bin/env bash
# session-doctor.sh `history` mode (NOW + PAST report for a worktree folder).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
isolate_overlay
# Fixture shape: configured prefix "px", legacy "oldhost".
export CRSS_SESSION_PREFIX=px
export CRSS_LEGACY_PREFIXES=oldhost
# shellcheck disable=SC1090
source "$HERE/../scripts/session-doctor.sh"   # must NOT run dispatch (source-guard)


# ── _history_matches: pure logic over synthetic wt_base/proj_base dirs ───────
# (takes wt_base/proj_base as params, so tests point at a tmpdir instead of faking $HOME/.claude)
MBASE="$(mktemp -d)"
WTB="$MBASE/worktrees"; PROJB="$MBASE/projects"
mkdir -p "$WTB/px-foo-0101-0100" "$WTB/px-bar-0101-0200" "$PROJB"
# A worktree removed from disk but with transcript history (the common PAST case) is recovered from proj_base by
# stripping the encode(wt_base)+"-" prefix.
GONE_PREFIX="$(_encode_cwd "$WTB")-"
mkdir -p "$PROJB/${GONE_PREFIX}px-gone-0101-0300"

ok "match-exact-name" "$(_history_matches "px-foo-0101-0100" "$WTB" "$PROJB")" "$WTB/px-foo-0101-0100"
ok "match-exact-abspath" "$(_history_matches "$WTB/px-foo-0101-0100/" "$WTB" "$PROJB")" "$WTB/px-foo-0101-0100"
ok "match-exact-gone-worktree-via-transcript" "$(_history_matches "px-gone-0101-0300" "$WTB" "$PROJB")" "$WTB/px-gone-0101-0300"

sub_out="$(_history_matches "px" "$WTB" "$PROJB")"
ok "match-substring-count" "$(printf '%s\n' "$sub_out" | grep -c .)" "3"
has "match-substring-has-foo"  "$sub_out" "$WTB/px-foo-0101-0100"
has "match-substring-has-bar"  "$sub_out" "$WTB/px-bar-0101-0200"
has "match-substring-has-gone" "$sub_out" "$WTB/px-gone-0101-0300"

no_out="$(_history_matches "zzz-totally-unmatched" "$WTB" "$PROJB")"; no_rc=$?
ok "match-none-empty-output" "$no_out" ""
ok "match-none-nonzero-rc" "$no_rc" "1"

# ── regression: a real path OUTSIDE wt_base must win over a same-basename substring decoy INSIDE it (the old code
# reduced any slash-containing query to its basename first, so a decoy like a long-deleted "oldhost-<name>-<date>"
# worktree hijacked it) ──
EXT_DIR="$MBASE/external/claude-remote-session-skill"
mkdir -p "$EXT_DIR"
mkdir -p "$WTB/oldhost-some-repo-20260101-0101"
EXT_CANON="$(cd "$EXT_DIR" && pwd)"

ok "match-real-outside-path-wins-over-decoy" \
  "$(_history_matches "$EXT_DIR" "$WTB" "$PROJB")" "$EXT_CANON"

rm -rf "$MBASE"

# ── _history_report: PAST parsing (turn counting, ordering, zero-user files) ─
RBASE="$(mktemp -d)"
WT_R="$RBASE/wt/px-histtest-0101-0400"; mkdir -p "$WT_R"
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

# transcript lines but ZERO type:user entries: no crash, turns=0 and "(none)"
UUID_C="cccccccc-0000-0000-0000-000000000003"
cat > "$PROJB_R/$ENC_R/$UUID_C.jsonl" <<'EOF'
{"type":"summary","summary":"nothing user-authored here"}
{"type":"system","subtype":"init"}
EOF

rout="$(_history_report "$WT_R" "$PROJB_R")"

# has() needle must not start with "-" (grep -F would read it as a flag)
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
ok "report-ordering-A-before-B" "$(yn test "$lineA" -lt "$lineB")" "yes"

rm -rf "$RBASE"

# ── _history_report: no transcript dir at all (never messaged / brand new) ───
EBASE="$(mktemp -d)"
WT_E="$EBASE/wt-empty"; mkdir -p "$WT_E"
eout="$(_history_report "$WT_E" "$EBASE/no-such-projects-root")"
has "report-no-transcript-dir" "$eout" "(no transcript directory"
rm -rf "$EBASE"

# ── end-to-end through the real mode dispatch (HOME override): arg parsing, matches+report+footer wired together,
# exit codes, and the gone-from-disk-but-has-transcripts path ──
E2EHOME="$(mktemp -d)"
mkdir -p "$E2EHOME/.claude/worktrees" "$E2EHOME/.claude/projects"

# Exact-folder match, real git worktree (also the footer's landed/dirty path).
if command -v git >/dev/null 2>&1; then
  E2EREPO="$E2EHOME/srcrepo"; mkdir -p "$E2EREPO"
  git -C "$E2EREPO" init -q -b main
  git -C "$E2EREPO" config user.email t@t.com; git -C "$E2EREPO" config user.name t
  echo hi > "$E2EREPO/a.txt"; git -C "$E2EREPO" add a.txt; git -C "$E2EREPO" commit -q -m init
  WT_E2E="$E2EHOME/.claude/worktrees/px-e2elive-0101-0600"
  git -C "$E2EREPO" worktree add -q -b session/px-e2elive-0101-0600 "$WT_E2E" main >/dev/null 2>&1

  exactout="$(HOME="$E2EHOME" bash "$HERE/../scripts/session-doctor.sh" history px-e2elive-0101-0600 2>&1)"; exactrc=$?
  ok  "e2e-exact-exit0"      "$exactrc" "0"
  has "e2e-exact-header"     "$exactout" "1 worktree(s) matching 'px-e2elive-0101-0600'"
  has "e2e-exact-footer"     "$exactout" "branch=session/px-e2elive-0101-0600"
  has "e2e-exact-landed"     "$exactout" "landed=yes"
fi

# Worktree removed from disk, transcripts remain: still found by exact name; footer says it's gone (no git on a missing path).
WT_GONE_NAME="px-e2egone-0101-0700"
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
# extract the TURNS field (a bare `has ... "2"` would match the "2026-02-02" timestamps)
ok "e2e-gone-turns" "$(printf '%s\n' "$goneout" | grep -F deadbeef | awk '{print $4}')" "2"


# No match at all -> clear message on stderr, exit 2.
nomatchout="$(HOME="$E2EHOME" bash "$HERE/../scripts/session-doctor.sh" history zz-nope-nothing-here 2>&1)"; nomatchrc=$?
ok  "e2e-nomatch-exit2"   "$nomatchrc" "2"
has "e2e-nomatch-message" "$nomatchout" "no worktree matches"

rm -rf "$E2EHOME"

# ── live-session cross-reference: NOW and PAST must not double-count ─────────
# A real background process (`exec -a claude`, cwd = the synthetic worktree, `--remote-control <name>` as trailing argv)
# so the pgrep path idle-report uses picks it up for real. `trap : TERM; sleep N` (not a bare `sleep N`) because bash
# tail-call-execs a single last command, which would lose the argv rename.
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
  # latest last-type:user timestamp: the live process is assumed to write it -> folded into NOW, not PAST
  UUID_NEW="22222222-0000-0000-0000-000000000002"
  cat > "$PROJB_L/$ENC_L/$UUID_NEW.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-01-01T10:00:00.000Z"}
EOF

  # `trap : TERM; sleep 15` (see above); the trap ignores SIGTERM, so cleanup uses SIGKILL
  ( cd "$WT_L" && exec -a claude bash -c 'trap : TERM; sleep 15' ignored --remote-control px-histtest-live-0101-0800 ) &
  LIVEPID=$!
  sleep 0.3

  liveout="$(_history_report "$WT_L" "$PROJB_L")"
  kill -9 "$LIVEPID" 2>/dev/null; wait "$LIVEPID" 2>/dev/null

  has "live-now-shows-pid"        "$liveout" "$LIVEPID"
  has "live-now-shows-remote-name" "$liveout" "px-histtest-live-0101-0800"
  has "live-cross-ref-marks-newest" "$liveout" "${UUID_NEW:0:8} is LIVE now"
  has "live-older-still-in-past"  "$liveout" "${UUID_OLD:0:8}"
  ok  "live-past-count-excludes-newest" "$(printf '%s' "$liveout" | grep -oE -- '--- [0-9]+ past session' | grep -oE '[0-9]+')" "1"

  rm -rf "$LBASE"
fi

finish "session-doctor-history"
