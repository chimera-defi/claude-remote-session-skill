#!/usr/bin/env bash
# new-session.sh --dry-run prints "overlay: <CRSS_HOME> (config: found|absent, rules: found|absent)".
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
NS="$HERE/../scripts/new-session.sh"

# session-alias on PATH so --dry-run alias resolution doesn't take the sanitize-only fallback.
BIN="$(mktemp -d)"; GOOD="$(mktemp -d)"; PARTIAL="$(mktemp -d)"
trap 'rm -rf "$BIN" "$GOOD" "$PARTIAL"' EXIT
ln -sf "$HERE/../scripts/session-alias.sh" "$BIN/session-alias"
export PATH="$BIN:$PATH"
STORE="$(mktemp)"; rm -f "$STORE"; export SESSION_ALIAS_STORE="$STORE"

# overlay_line DIR NAME: the dry-run output with CRSS_HOME and CRSS_CLAUDE_HOME both pinned to DIR.
overlay_line() { CRSS_HOME="$1" CRSS_CLAUDE_HOME="$1" bash "$NS" --dry-run "$2" 2>&1; }

ABSENT="/tmp/crss-newsession-overlay-absent-$$-nonexistent"
has "absent-overlay-line" "$(overlay_line "$ABSENT" overlay-test-absent)" "overlay: $ABSENT (config: absent, rules: absent)"

mkdir -p "$GOOD/rules"; touch "$GOOD/config.sh" "$GOOD/rules/crss-host.md"
has "good-overlay-line" "$(overlay_line "$GOOD" overlay-test-good)" "overlay: $GOOD (config: found, rules: found)"

touch "$PARTIAL/config.sh"
has "partial-overlay-line" "$(overlay_line "$PARTIAL" overlay-test-partial)" "overlay: $PARTIAL (config: found, rules: absent)"

finish "test-new-session-overlay"
