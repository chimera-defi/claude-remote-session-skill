#!/usr/bin/env bash
# Tests for session-doctor.sh's `idle-report --minutes/--tsv` extension:
# minute-granularity threshold, machine-readable TSV output, the last-GENUINE-
# user-turn fix (a /compact summary write must not itself count as activity —
# see docs/idle-report.md and the idle-report case block comment for why),
# the compacted_since_last_turn detection, and reuse of _wt_landed/_wt_dirty
# for the TSV landed/dirty columns. No external test framework.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DOCTOR="$HERE/../scripts/session-doctor.sh"
# shellcheck disable=SC1090
source "$DOCTOR"   # must NOT run dispatch (source-guard)
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }
has(){ if printf '%s' "$2" | grep -qF "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — pattern not found: $3 in: $2"; fi; }

# ── flag parsing: --minutes/--days validation and mutual exclusion (no live
# process needed — these fail before any scanning happens) ───────────────────
mx_out="$(bash "$DOCTOR" idle-report --days 2 --minutes 5 2>&1)"; mx_rc=$?
ok  "days-and-minutes-exit2"    "$mx_rc" "2"
has "days-and-minutes-message"  "$mx_out" "mutually exclusive"

nm_out="$(bash "$DOCTOR" idle-report --minutes abc 2>&1)"; nm_rc=$?
ok  "minutes-nonnumeric-exit2"    "$nm_rc" "2"
# NB: has()'s pattern arg goes straight to `grep -qF`, so a pattern starting
# with "-" is misread as a flag (see test-session-doctor-history.sh's same
# note) — trimmed to not start with "--minutes".
has "minutes-nonnumeric-message"  "$nm_out" "requires a non-negative integer, got 'abc'"

# ── _tsv_git_status: reuse of _wt_landed/_wt_dirty (not reimplemented),
# no-worktree/unknown for a missing or non-git path, and per-cwd caching
# (mirrors the _DEFBR_CACHE idiom above _default_branch) ─────────────────────
if command -v git >/dev/null 2>&1; then
  GSBASE="$(mktemp -d)"
  GSREPO="$GSBASE/repo"; mkdir -p "$GSREPO"
  git -C "$GSREPO" init -q -b main
  git -C "$GSREPO" config user.email t@t.com; git -C "$GSREPO" config user.name t
  git -C "$GSREPO" commit -q --allow-empty -m init

  status="$(_tsv_git_status "$GSREPO")"
  ok "tsv-git-status-landed" "${status%%$'\t'*}" "yes"
  ok "tsv-git-status-dirty"  "${status#*$'\t'}"  "clean"

  # Caching: a repeated cwd must not re-shell git — call once, delete the
  # directory, call again for the SAME cwd, and confirm the second call still
  # returns the FIRST (cached) answer rather than flipping to
  # no-worktree/unknown once the directory is actually gone. Both calls have
  # to run in the SAME subshell for this to prove anything: _TSV_STATUS_CACHE
  # is an in-process associative array, so capturing each call via its own
  # separate `$(...)` would fork a fresh subshell per call and the cache
  # write from call 1 would never be visible to call 2.
  cache_pair="$(
    _tsv_git_status "$GSREPO"
    rm -rf "$GSREPO"
    _tsv_git_status "$GSREPO"
  )"
  cache_first="$(printf '%s\n' "$cache_pair" | sed -n '1p')"
  cache_second="$(printf '%s\n' "$cache_pair" | sed -n '2p')"
  ok "tsv-git-status-cache-first-correct" "$cache_first" "$status"
  ok "tsv-git-status-cached" "$cache_second" "$cache_first"

  # A path that never existed -> no-worktree/unknown, not a crash.
  gone="$(_tsv_git_status "$GSBASE/never-existed-$$")"
  ok "tsv-git-status-missing-landed" "${gone%%$'\t'*}" "no-worktree"
  ok "tsv-git-status-missing-dirty"  "${gone#*$'\t'}"  "unknown"

  # An existing directory that is not a git working tree at all.
  NOTGIT="$GSBASE/plain-dir"; mkdir -p "$NOTGIT"
  notgit="$(_tsv_git_status "$NOTGIT")"
  ok "tsv-git-status-notgit-landed" "${notgit%%$'\t'*}" "no-worktree"
  ok "tsv-git-status-notgit-dirty"  "${notgit#*$'\t'}"  "unknown"

  rm -rf "$GSBASE"
fi

# ── end-to-end: live sessions + synthetic transcripts, through the real
# `idle-report --tsv` dispatch (HOME override so this never reads the
# operator's real transcripts — same convention worktree-stale/land-check/
# history already use). A real background process per scenario (argv[0]
# renamed to "claude" via `exec -a`, "--remote-control <name>" appended as
# literal trailing argv) so pgrep -af's exact match/basename-filter/readlink
# path idle-report already uses picks each one up for real, no mocking — same
# technique test-session-doctor-history.sh already validates works. `gh` is
# stubbed to fail fast so _default_branch's real-default-branch lookup (used
# by the reused _wt_landed) never makes a network call here, keeping this
# hermetic and fast regardless of the host's `gh` auth state.
if command -v git >/dev/null 2>&1 && command -v pgrep >/dev/null 2>&1; then
  TB="$(mktemp -d)"
  TESTHOME="$TB/home"; mkdir -p "$TESTHOME/.claude/projects"
  PROJB="$TESTHOME/.claude/projects"
  GHSTUB="$TB/ghstub"; mkdir -p "$GHSTUB"
  cat > "$GHSTUB/gh" <<'STUB_EOF'
#!/usr/bin/env bash
exit 1
STUB_EOF
  chmod +x "$GHSTUB/gh"
  RUNPATH="$GHSTUB:$PATH"

  PIDS=()
  cleanup() {
    for p in "${PIDS[@]:-}"; do kill -9 "$p" 2>/dev/null; done
    for p in "${PIDS[@]:-}"; do wait "$p" 2>/dev/null; done
    rm -rf "$TB"
  }
  trap cleanup EXIT

  spawn() {  # spawn <dir> <remote-name>
    local dir="$1" rc="$2"
    mkdir -p "$dir"
    ( cd "$dir" && exec -a claude bash -c 'trap : TERM; sleep 30' ignored --remote-control "$rc" ) &
    PIDS+=("$!")
  }

  # A: headline case — newest type:user entry is a /compact summary
  # (isCompactSummary:true); idle must be measured from the PRIOR genuine
  # turn, not this one.
  WT_A="$TB/wt-a"; spawn "$WT_A" "ah-tsv-compactsum-0101-0100"
  WT_A="$(cd "$WT_A" && pwd -P)"
  mkdir -p "$PROJB/$(_encode_cwd "$WT_A")"
  cat > "$PROJB/$(_encode_cwd "$WT_A")/sess.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-01-01T09:00:00.000Z"}
{"type":"assistant","timestamp":"2026-01-01T09:00:05.000Z"}
{"type":"user","timestamp":"2026-01-05T12:00:00.000Z","isCompactSummary":true}
EOF

  # B: compact_boundary AFTER the last genuine turn -> col8=yes. Also a real
  # LANDED worktree (straight off main, no new commits) -> col9=yes, col10=clean.
  GREPO="$TB/grepo"; mkdir -p "$GREPO"
  git -C "$GREPO" init -q -b main
  git -C "$GREPO" config user.email t@t.com; git -C "$GREPO" config user.name t
  echo hi > "$GREPO/a.txt"; git -C "$GREPO" add a.txt; git -C "$GREPO" commit -q -m init
  WT_B="$TB/wt-b"
  git -C "$GREPO" worktree add -q -b session/ah-tsv-boundary-0101-0200 "$WT_B" main >/dev/null 2>&1
  spawn "$WT_B" "ah-tsv-boundary-0101-0200"
  WT_B="$(cd "$WT_B" && pwd -P)"
  mkdir -p "$PROJB/$(_encode_cwd "$WT_B")"
  cat > "$PROJB/$(_encode_cwd "$WT_B")/sess.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-01-01T09:00:00.000Z"}
{"type":"system","subtype":"compact_boundary","timestamp":"2026-01-01T09:30:00.000Z","version":"2.1.206"}
EOF

  # C: no compact_boundary, version-bearing (aware build) -> col8=no. Also an
  # UNLANDED worktree (one commit not on main) -> col9=no.
  WT_C="$TB/wt-c"
  git -C "$GREPO" worktree add -q -b session/ah-tsv-noboundary-0101-0300 "$WT_C" main >/dev/null 2>&1
  git -C "$WT_C" config user.email t@t.com; git -C "$WT_C" config user.name t
  echo new > "$WT_C/new.txt"; git -C "$WT_C" add new.txt; git -C "$WT_C" commit -q -m "unlanded work"
  spawn "$WT_C" "ah-tsv-noboundary-0101-0300"
  WT_C="$(cd "$WT_C" && pwd -P)"
  mkdir -p "$PROJB/$(_encode_cwd "$WT_C")"
  cat > "$PROJB/$(_encode_cwd "$WT_C")/sess.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-01-01T09:00:00.000Z","version":"2.1.206"}
EOF

  # D: no version evidence anywhere in the transcript -> col8=unknown. Plain
  # non-git directory -> col9/10 also no-worktree/unknown (covers "not a
  # worktree", alongside F's "gone from disk" below).
  WT_D="$TB/wt-d"; spawn "$WT_D" "ah-tsv-noversion-0101-0400"
  WT_D="$(cd "$WT_D" && pwd -P)"
  mkdir -p "$PROJB/$(_encode_cwd "$WT_D")"
  cat > "$PROJB/$(_encode_cwd "$WT_D")/sess.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-01-01T09:00:00.000Z"}
EOF

  # E: a STALE compact_boundary from BEFORE the last genuine turn (session was
  # compacted once, then kept working) -> col8 must be "no", not "yes" —
  # proves this is a "later than the last genuine turn" comparison, not "any
  # compact_boundary exists anywhere".
  WT_E="$TB/wt-e"; spawn "$WT_E" "ah-tsv-staleboundary-0101-0500"
  WT_E="$(cd "$WT_E" && pwd -P)"
  mkdir -p "$PROJB/$(_encode_cwd "$WT_E")"
  cat > "$PROJB/$(_encode_cwd "$WT_E")/sess.jsonl" <<'EOF'
{"type":"system","subtype":"compact_boundary","timestamp":"2026-01-01T08:00:00.000Z","version":"2.1.206"}
{"type":"user","timestamp":"2026-01-01T09:00:00.000Z","version":"2.1.206"}
EOF

  # F: cwd removed from disk AFTER the process cd'ed into it — the common
  # "transcript outlives the worktree" case — -> col9/10 no-worktree/unknown,
  # row still has all 10 columns.
  WT_F="$TB/wt-f"; mkdir -p "$WT_F"; WT_F="$(cd "$WT_F" && pwd -P)"
  ( cd "$WT_F" && exec -a claude bash -c 'trap : TERM; sleep 30' ignored --remote-control ah-tsv-gonecwd-0101-0600 ) &
  PIDS+=("$!")
  sleep 0.3
  rmdir "$WT_F" 2>/dev/null || true

  # G: a FRESH genuine turn (timestamp = now) -> must be FILTERED OUT under a
  # tight --minutes threshold (proves --minutes actually filters, not just
  # parses).
  WT_G="$TB/wt-g"; spawn "$WT_G" "ah-tsv-freshts-0101-0700"
  WT_G="$(cd "$WT_G" && pwd -P)"
  mkdir -p "$PROJB/$(_encode_cwd "$WT_G")"
  NOWTS="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  printf '{"type":"user","timestamp":"%s"}\n' "$NOWTS" > "$PROJB/$(_encode_cwd "$WT_G")/sess.jsonl"

  # H: a version OLDER than the one build empirically verified to emit
  # compact_boundary, no compact_boundary present -> col8=unknown (a real
  # absence-of-evidence case, not just "no version field at all" like D).
  WT_H="$TB/wt-h"; spawn "$WT_H" "ah-tsv-oldversion-0101-0800"
  WT_H="$(cd "$WT_H" && pwd -P)"
  mkdir -p "$PROJB/$(_encode_cwd "$WT_H")"
  cat > "$PROJB/$(_encode_cwd "$WT_H")/sess.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-01-01T09:00:00.000Z","version":"2.0.50"}
EOF

  sleep 0.5

  tsvout="$(HOME="$TESTHOME" PATH="$RUNPATH" bash "$DOCTOR" idle-report --minutes 0 --tsv 2>&1)"

  rowA="$(printf '%s\n' "$tsvout" | grep -F 'ah-tsv-compactsum-0101-0100')"
  rowB="$(printf '%s\n' "$tsvout" | grep -F 'ah-tsv-boundary-0101-0200')"
  rowC="$(printf '%s\n' "$tsvout" | grep -F 'ah-tsv-noboundary-0101-0300')"
  rowD="$(printf '%s\n' "$tsvout" | grep -F 'ah-tsv-noversion-0101-0400')"
  rowE="$(printf '%s\n' "$tsvout" | grep -F 'ah-tsv-staleboundary-0101-0500')"
  rowF="$(printf '%s\n' "$tsvout" | grep -F 'ah-tsv-gonecwd-0101-0600')"
  rowH="$(printf '%s\n' "$tsvout" | grep -F 'ah-tsv-oldversion-0101-0800')"

  ok "tsv-a-idle-from-genuine-turn" "$(printf '%s' "$rowA" | awk -F'\t' '{print $6}')" "2026-01-01T09:00:00Z"
  ok "tsv-b-compacted-yes"          "$(printf '%s' "$rowB" | awk -F'\t' '{print $8}')" "yes"
  ok "tsv-b-landed-yes"             "$(printf '%s' "$rowB" | awk -F'\t' '{print $9}')" "yes"
  ok "tsv-b-dirty-clean"            "$(printf '%s' "$rowB" | awk -F'\t' '{print $10}')" "clean"
  ok "tsv-c-compacted-no"           "$(printf '%s' "$rowC" | awk -F'\t' '{print $8}')" "no"
  ok "tsv-c-landed-no"              "$(printf '%s' "$rowC" | awk -F'\t' '{print $9}')" "no"
  ok "tsv-d-compacted-unknown"      "$(printf '%s' "$rowD" | awk -F'\t' '{print $8}')" "unknown"
  ok "tsv-d-no-worktree"            "$(printf '%s' "$rowD" | awk -F'\t' '{print $9}')" "no-worktree"
  ok "tsv-d-dirty-unknown"          "$(printf '%s' "$rowD" | awk -F'\t' '{print $10}')" "unknown"
  ok "tsv-e-stale-boundary-not-yes" "$(printf '%s' "$rowE" | awk -F'\t' '{print $8}')" "no"
  ok "tsv-f-gone-cwd-no-worktree"   "$(printf '%s' "$rowF" | awk -F'\t' '{print $9}')" "no-worktree"
  ok "tsv-f-gone-cwd-dirty-unknown" "$(printf '%s' "$rowF" | awk -F'\t' '{print $10}')" "unknown"
  ok "tsv-f-gone-cwd-10-cols"       "$(printf '%s' "$rowF" | awk -F'\t' '{print NF}')" "10"
  ok "tsv-h-old-version-unknown"    "$(printf '%s' "$rowH" | awk -F'\t' '{print $8}')" "unknown"

  # idle_minutes is numeric for a real timestamp (the literal 'never' is only
  # for true never-messaged sessions — not exercised by name here, this just
  # confirms the format contract on a real row).
  ok "tsv-d-idle-minutes-numeric" "$(printf '%s' "$rowD" | awk -F'\t' '{print $5}' | grep -qE '^[0-9]+$' && echo yes || echo no)" "yes"

  # Every row present must have exactly 10 tab-separated columns — no ragged
  # rows, including the noisy real-host rows this scan also picks up (pgrep
  # is host-wide, not scoped by the HOME override).
  badcols="$(printf '%s\n' "$tsvout" | awk -F'\t' 'NF!=10{print NR": "NF" cols"}')"
  ok "tsv-all-rows-10-cols" "$badcols" ""

  # No header, no banner, no summary/footer lines with --tsv — only data rows.
  ok "tsv-no-banner"         "$(printf '%s\n' "$tsvout" | grep -c '^===')"          "0"
  ok "tsv-no-column-header"  "$(printf '%s\n' "$tsvout" | grep -c 'tmux_session')"  "0"
  ok "tsv-no-summary-footer" "$(printf '%s\n' "$tsvout" | grep -c 'idle session(s)')" "0"

  # --minutes actually filters (not just parses): a tight window must exclude
  # G's fresh turn but still include D's ancient one.
  tightout="$(HOME="$TESTHOME" PATH="$RUNPATH" bash "$DOCTOR" idle-report --minutes 45 --tsv 2>&1)"
  ok  "tsv-minutes-excludes-fresh" "$(printf '%s\n' "$tightout" | grep -c 'ah-tsv-freshts-0101-0700')" "0"
  has "tsv-minutes-includes-old"   "$tightout" "ah-tsv-noversion-0101-0400"

  # --days behavior unchanged: default (no --minutes) still uses the
  # day-granularity header text verbatim, and the last-genuine-turn fix
  # applies to the human format too, not just --tsv.
  daysout="$(HOME="$TESTHOME" PATH="$RUNPATH" bash "$DOCTOR" idle-report 2>&1)"
  has "days-default-header-unchanged"     "$daysout" "NO type:user message in the last 2 day(s)"
  arow="$(printf '%s\n' "$daysout" | grep -F 'ah_tsv-compactsum-0101-0100')"
  has "days-mode-also-skips-compact-summary" "$arow" "2026-01-01T09:00:00Z"
fi

echo "session-doctor-tsv: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
