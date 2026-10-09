#!/usr/bin/env bash
# idle-report --minutes/--tsv: minute threshold, TSV output, last-GENUINE-user-turn (a /compact summary write is not
# activity), compacted_since_last_turn, and _wt_landed/_wt_dirty reuse for the landed/dirty columns.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
isolate_overlay
# Fixture shape: configured prefix "px", legacy "oldhost".
export CRSS_SESSION_PREFIX=px
export CRSS_LEGACY_PREFIXES=oldhost
DOCTOR="$HERE/../scripts/session-doctor.sh"
# shellcheck disable=SC1090
source "$DOCTOR"   # must NOT run dispatch (source-guard)

# ── end-to-end through `idle-report --tsv`: HOME override, one real background process per scenario (`exec -a claude`,
# `--remote-control <name>`) so the pgrep path is exercised for real; gh stubbed to fail fast (hermetic) ──
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

  # A: newest type:user entry is a /compact summary: idle is measured from the PRIOR genuine turn
  WT_A="$TB/wt-a"; spawn "$WT_A" "px-tsv-compactsum-0101-0100"
  WT_A="$(cd "$WT_A" && pwd -P)"
  mkdir -p "$PROJB/$(_encode_cwd "$WT_A")"
  cat > "$PROJB/$(_encode_cwd "$WT_A")/sess.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-01-01T09:00:00.000Z"}
{"type":"assistant","timestamp":"2026-01-01T09:00:05.000Z"}
{"type":"user","timestamp":"2026-01-05T12:00:00.000Z","isCompactSummary":true}
EOF

  # B: compact_boundary AFTER the last genuine turn -> col8=yes; LANDED worktree -> col9=yes, col10=clean
  GREPO="$TB/grepo"; mkdir -p "$GREPO"
  git -C "$GREPO" init -q -b main
  git -C "$GREPO" config user.email t@t.com; git -C "$GREPO" config user.name t
  echo hi > "$GREPO/a.txt"; git -C "$GREPO" add a.txt; git -C "$GREPO" commit -q -m init
  WT_B="$TB/wt-b"
  git -C "$GREPO" worktree add -q -b session/px-tsv-boundary-0101-0200 "$WT_B" main >/dev/null 2>&1
  spawn "$WT_B" "px-tsv-boundary-0101-0200"
  WT_B="$(cd "$WT_B" && pwd -P)"
  mkdir -p "$PROJB/$(_encode_cwd "$WT_B")"
  cat > "$PROJB/$(_encode_cwd "$WT_B")/sess.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-01-01T09:00:00.000Z"}
{"type":"system","subtype":"compact_boundary","timestamp":"2026-01-01T09:30:00.000Z","version":"2.1.206"}
EOF

  # C: no compact_boundary, version-bearing build -> col8=no; UNLANDED worktree -> col9=no
  WT_C="$TB/wt-c"
  git -C "$GREPO" worktree add -q -b session/px-tsv-noboundary-0101-0300 "$WT_C" main >/dev/null 2>&1
  git -C "$WT_C" config user.email t@t.com; git -C "$WT_C" config user.name t
  echo new > "$WT_C/new.txt"; git -C "$WT_C" add new.txt; git -C "$WT_C" commit -q -m "unlanded work"
  spawn "$WT_C" "px-tsv-noboundary-0101-0300"
  WT_C="$(cd "$WT_C" && pwd -P)"
  mkdir -p "$PROJB/$(_encode_cwd "$WT_C")"
  cat > "$PROJB/$(_encode_cwd "$WT_C")/sess.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-01-01T09:00:00.000Z","version":"2.1.206"}
EOF

  # D: no version evidence -> col8=unknown; plain non-git dir -> col9/10 no-worktree/unknown
  WT_D="$TB/wt-d"; spawn "$WT_D" "px-tsv-noversion-0101-0400"
  WT_D="$(cd "$WT_D" && pwd -P)"
  mkdir -p "$PROJB/$(_encode_cwd "$WT_D")"
  cat > "$PROJB/$(_encode_cwd "$WT_D")/sess.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-01-01T09:00:00.000Z"}
EOF

  # E: STALE compact_boundary from before the last genuine turn -> col8=no (a "later than" comparison, not "any boundary")
  WT_E="$TB/wt-e"; spawn "$WT_E" "px-tsv-staleboundary-0101-0500"
  WT_E="$(cd "$WT_E" && pwd -P)"
  mkdir -p "$PROJB/$(_encode_cwd "$WT_E")"
  cat > "$PROJB/$(_encode_cwd "$WT_E")/sess.jsonl" <<'EOF'
{"type":"system","subtype":"compact_boundary","timestamp":"2026-01-01T08:00:00.000Z","version":"2.1.206"}
{"type":"user","timestamp":"2026-01-01T09:00:00.000Z","version":"2.1.206"}
EOF

  # F: cwd removed from disk after the process cd'ed in -> col9/10 no-worktree/unknown, still 10 columns
  WT_F="$TB/wt-f"; mkdir -p "$WT_F"; WT_F="$(cd "$WT_F" && pwd -P)"
  ( cd "$WT_F" && exec -a claude bash -c 'trap : TERM; sleep 30' ignored --remote-control px-tsv-gonecwd-0101-0600 ) &
  PIDS+=("$!")
  sleep 0.3
  rmdir "$WT_F" 2>/dev/null || true

  # G: fresh genuine turn must be FILTERED OUT by a tight --minutes
  WT_G="$TB/wt-g"; spawn "$WT_G" "px-tsv-freshts-0101-0700"
  WT_G="$(cd "$WT_G" && pwd -P)"
  mkdir -p "$PROJB/$(_encode_cwd "$WT_G")"
  NOWTS="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  printf '{"type":"user","timestamp":"%s"}\n' "$NOWTS" > "$PROJB/$(_encode_cwd "$WT_G")/sess.jsonl"

  # I: Bug A regression: the full /compact noise cascade (bare '/compact', isMeta caveat, command-name echo,
  # local-command-stdout 'Compacted') all carry RECENT timestamps; the one genuine turn is old. Pre-fix the newest noise
  # line made an 8-day-idle session look ~0 minutes idle. Includes a compact_boundary so col8 is checked end to end.
  WT_I="$TB/wt-i"; spawn "$WT_I" "px-tsv-compactnoise-0101-0900"
  WT_I="$(cd "$WT_I" && pwd -P)"
  mkdir -p "$PROJB/$(_encode_cwd "$WT_I")"
  cat > "$PROJB/$(_encode_cwd "$WT_I")/sess.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-01-01T09:00:00.000Z","version":"2.1.206"}
{"type":"user","isMeta":true,"timestamp":"2026-01-08T11:58:45.000Z","message":{"role":"user","content":"<local-command-caveat>Caveat: The messages below were generated by the user while running local commands. DO NOT respond to these messages or otherwise consider them in your response unless the user explicitly asks you to.</local-command-caveat>"}}
{"type":"user","timestamp":"2026-01-08T11:58:45.000Z","message":{"role":"user","content":"<command-name>/compact</command-name>\n            <command-message>compact</command-message>\n            <command-args></command-args>"}}
{"type":"user","timestamp":"2026-01-08T11:58:45.000Z","message":{"role":"user","content":"/compact"}}
{"type":"user","timestamp":"2026-01-08T12:00:03.693Z","message":{"role":"user","content":"<local-command-stdout>\u001b[2mCompacted (ctrl+o to see full summary)\u001b[22m</local-command-stdout>"}}
{"type":"system","subtype":"compact_boundary","timestamp":"2026-01-08T12:00:03.594Z","version":"2.1.206"}
{"type":"user","isCompactSummary":true,"timestamp":"2026-01-08T12:00:01.885Z","message":{"role":"user","content":"This session is being continued from a previous conversation that ran out of context."}}
EOF

  sleep 0.5

  tsvout="$(HOME="$TESTHOME" PATH="$RUNPATH" bash "$DOCTOR" idle-report --minutes 0 --tsv 2>&1)"

  rowA="$(printf '%s\n' "$tsvout" | grep -F 'px-tsv-compactsum-0101-0100')"
  rowB="$(printf '%s\n' "$tsvout" | grep -F 'px-tsv-boundary-0101-0200')"
  rowC="$(printf '%s\n' "$tsvout" | grep -F 'px-tsv-noboundary-0101-0300')"
  rowD="$(printf '%s\n' "$tsvout" | grep -F 'px-tsv-noversion-0101-0400')"
  rowE="$(printf '%s\n' "$tsvout" | grep -F 'px-tsv-staleboundary-0101-0500')"
  rowF="$(printf '%s\n' "$tsvout" | grep -F 'px-tsv-gonecwd-0101-0600')"
  rowI="$(printf '%s\n' "$tsvout" | grep -F 'px-tsv-compactnoise-0101-0900')"

  ok "tsv-a-idle-from-genuine-turn" "$(printf '%s' "$rowA" | awk -F'\t' '{print $6}')" "2026-01-01T09:00:00Z"
  # Bug A: idle comes from the pre-compact genuine turn (2026-01-01), not the noise artifacts (2026-01-08)
  ok "tsv-i-idle-from-pre-compact-genuine-turn" "$(printf '%s' "$rowI" | awk -F'\t' '{print $6}')" "2026-01-01T09:00:00Z"
  # col8 reads 'yes': the compact_boundary is newer than the pinned genuine turn
  ok "tsv-i-compacted-since-last-turn-yes" "$(printf '%s' "$rowI" | awk -F'\t' '{print $8}')" "yes"
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


  # exactly 10 tab-separated columns per row (pgrep is host-wide, so noisy host rows too)
  badcols="$(printf '%s\n' "$tsvout" | awk -F'\t' 'NF!=10{print NR": "NF" cols"}')"
  ok "tsv-all-rows-10-cols" "$badcols" ""

  # --tsv: data rows only
  ok "tsv-no-banner"         "$(printf '%s\n' "$tsvout" | grep -c '^===')"          "0"
  ok "tsv-no-column-header"  "$(printf '%s\n' "$tsvout" | grep -c 'tmux_session')"  "0"
  ok "tsv-no-summary-footer" "$(printf '%s\n' "$tsvout" | grep -c 'idle session(s)')" "0"

  # --minutes filters: excludes G's fresh turn, includes D's ancient one
  tightout="$(HOME="$TESTHOME" PATH="$RUNPATH" bash "$DOCTOR" idle-report --minutes 45 --tsv 2>&1)"
  ok  "tsv-minutes-excludes-fresh" "$(printf '%s\n' "$tightout" | grep -c 'px-tsv-freshts-0101-0700')" "0"
  has "tsv-minutes-includes-old"   "$tightout" "px-tsv-noversion-0101-0400"

fi

finish "session-doctor-tsv"
