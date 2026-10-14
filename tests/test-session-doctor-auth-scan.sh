#!/usr/bin/env bash
# session-doctor.sh `auth-scan` mode: transcript-only tripwire for a dead CLI login (ongoing vs recovered).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
isolate_overlay
SD="$HERE/../scripts/session-doctor.sh"

FH="$(mktemp -d)"; PROJ="$FH/.claude/projects/-w-demo"; mkdir -p "$PROJ"
ok_turn()  { printf '{"type":"assistant","requestId":"req_1","timestamp":"%s","message":{"content":[{"type":"text","text":"hi"}]}}\n' "$1"; }
auth_err() { printf '{"type":"assistant","isApiErrorMessage":true,"error":"authentication_failed","timestamp":"%s","message":{"content":[{"type":"text","text":"Failed to authenticate: OAuth session expired and could not be refreshed"}]}}\n' "$1"; }
other_err(){ printf '{"type":"assistant","isApiErrorMessage":true,"timestamp":"%s","message":{"content":"API Error: Server error mid-response."}}\n' "$1"; }
run() { HOME="$FH" bash "$SD" auth-scan --days 36500 2>&1; }

# clean window: only a success and an unrelated API error
{ ok_turn 2026-10-14T10:00:00.000Z; other_err 2026-10-14T10:05:00.000Z; } > "$PROJ/a.jsonl"
out="$(run)"; rc=$?
has "clean-says-none" "$out" "no auth failures"; ok "clean-rc0" "$rc" "0"

# ongoing: newest failure is newer than every success -> rc 1, operator hint, exact error text surfaced
{ ok_turn 2026-10-13T08:00:00.000Z; auth_err 2026-10-13T09:22:51.000Z; auth_err 2026-10-14T16:24:55.000Z; } > "$PROJ/b.jsonl"
out="$(run)"; rc=$?
has "ongoing-count" "$out" "auth failures: 2 across 1 transcript"
has "ongoing-text" "$out" "OAuth session expired and could not be refreshed"
has "ongoing-last-ok" "$out" "last successful assistant turn: 2026-10-14T10:00:00Z"
has "ongoing-hint" "$out" "AUTH OUTAGE LOOKS ONGOING"
ok "ongoing-rc1" "$rc" "1"

# recovered: a success newer than the last failure -> rc 0
ok_turn 2026-10-14T19:30:00.000Z > "$PROJ/c.jsonl"
out="$(run)"; rc=$?
has "recovered-says-recovered" "$out" "recovered:"
hasnt "recovered-no-ongoing" "$out" "ONGOING"
ok "recovered-rc0" "$rc" "0"

# the default report carries the one-line tripwire and never fails because of it
out="$(HOME="$FH" bash "$SD" report 2>&1)"
has "report-has-auth-section" "$out" "=== AUTH: transcript auth-failure scan"

# a symlinked ~/.claude/projects (agent-memory layout) is followed
rm -rf "$FH/.claude/projects.real"; mv "$FH/.claude/projects" "$FH/.claude/projects.real"; ln -s "$FH/.claude/projects.real" "$FH/.claude/projects"
has "symlinked-projects-followed" "$(run)" "auth failures: 2"
# missing dir is not an error
rm -rf "$FH/.claude/projects" "$FH/.claude/projects.real"
has "missing-dir-ok" "$(run)" "no transcript dir"
# bad --days is a usage error
HOME="$FH" bash "$SD" auth-scan --days x >/dev/null 2>&1; ok "bad-days-rc2" "$?" "2"

# symlinked FILE inside projects must never be opened (would let a planted link read credentials)
mkdir -p "$FH/.claude/projects/-w-link"; printf 'SECRETSENTINEL isApiErrorMessage "requestId"\n' > "$FH/cred.txt"
ln -s "$FH/cred.txt" "$FH/.claude/projects/-w-link/leak.jsonl"
hasnt "symlinked-file-not-read" "$(run)" "SECRETSENTINEL"
# offset timestamps order chronologically, not lexicographically: 23:30-05:00 (= 04:30Z next day) is NEWER than 01:00Z
mkdir -p "$FH/.claude/projects/-w-tz"
{ ok_turn 2026-10-15T01:00:00.000+00:00; auth_err 2026-10-14T23:30:00.000-05:00; } > "$FH/.claude/projects/-w-tz/t.jsonl"
out="$(run)"; has "tz-ongoing" "$out" "ONGOING"
# malformed / non-object lines are skipped, not a crash that masquerades as rc 1
mkdir -p "$FH/.claude/projects/-w-bad"; printf '[1,2]\n{"isApiErrorMessage":true,"message":5,"timestamp":"2026-10-14T00:00:00Z"}\nnot json isApiErrorMessage\n' > "$FH/.claude/projects/-w-bad/x.jsonl"
run >/dev/null; rc=$?; ok "malformed-no-crash" "$([ "$rc" -le 1 ] && echo y)" "y"
# window by EVENT time: an old failure inside a freshly-touched file is outside --days 1
OH="$(mktemp -d)"; mkdir -p "$OH/.claude/projects/-w-old"; auth_err 2026-01-01T00:00:00.000Z > "$OH/.claude/projects/-w-old/o.jsonl"
out="$(HOME="$OH" bash "$SD" auth-scan --days 1 2>&1)"; has "old-events-ignored" "$out" "no auth failures"

finish "session-doctor-auth-scan"
