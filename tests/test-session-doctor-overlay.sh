#!/usr/bin/env bash
# Tests for session-doctor.sh's `overlay` mode (and the same section folded
# into the default `report`): a read-only health check for the host-local
# overlay ($CRSS_HOME). Must never fail hard on a missing/broken overlay.
# No external test framework.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
DOCTOR="$HERE/../scripts/session-doctor.sh"

# ── absent overlay: dir/config.sh/rules/local.md all missing, still exit 0 ──
ABSENT="/tmp/crss-doctor-overlay-absent-$$-nonexistent"
out="$(CRSS_HOME="$ABSENT" bash "$DOCTOR" overlay 2>&1)"; rc=$?
ok  "absent-exit0"       "$rc" "0"
has "absent-header"      "$out" "=== OVERLAY: $ABSENT ==="
has "absent-dir"         "$out" "dir: absent"
has "absent-config"      "$out" "config.sh: absent"
has "absent-local"       "$out" "local.md: absent"
hasnt "absent-no-traceback" "$out" "Traceback"

# ── good overlay: dir/config.sh/rules (with @import)/local.md all present ──
GOOD="$(mktemp -d)"; mkdir -p "$GOOD/rules"
cat > "$GOOD/config.sh" <<'EOF'
CRSS_PROTECT_NAMES=claude-remote|goodtest
EOF
cat > "$GOOD/rules/crss-host.md" <<'EOF'
A host running crss. @~/.config/crss/local.md
EOF
touch "$GOOD/local.md"
out="$(CRSS_HOME="$GOOD" CRSS_CLAUDE_HOME="$GOOD" bash "$DOCTOR" overlay 2>&1)"; rc=$?
ok  "good-exit0"     "$rc" "0"
has "good-dir"       "$out" "dir: found"
has "good-config"    "$out" "config.sh: found"
has "good-rules"     "$out" "imports local.md"
has "good-local"     "$out" "local.md: found"
hasnt "good-no-warn" "$out" "warn:"

# ── broken overlay: config.sh has a line that LOOKS like an assignment but
#    won't be loaded (warn, not fail); rules present but no @import; no
#    local.md — still never fails hard.
BROKEN="$(mktemp -d)"; mkdir -p "$BROKEN/rules"
cat > "$BROKEN/config.sh" <<'EOF'
CRSS_GOOD=yes
crss_lowercase_typo=nope
also_not_crss_prefixed=1
EOF
cat > "$BROKEN/rules/crss-host.md" <<'EOF'
no import here, just prose
EOF
out="$(CRSS_HOME="$BROKEN" CRSS_CLAUDE_HOME="$BROKEN" bash "$DOCTOR" overlay 2>&1)"; rc=$?
ok  "broken-exit0"          "$rc" "0"
has "broken-warn-lowercase" "$out" "crss_lowercase_typo=nope"
has "broken-warn-notprefix" "$out" "also_not_crss_prefixed=1"
has "broken-rules-no-import-warn" "$out" "no @import of local.md found"
has "broken-local-absent"   "$out" "local.md: absent"

# ── PROTECT from config.sh is actually honoured by the running script (not
#    just reported by `overlay`) — belt-and-suspenders alongside
#    test-session-doctor.sh's own env-based PROTECT coverage.
protect_out="$(CRSS_HOME="$GOOD" bash -c "source '$DOCTOR'; echo \"PROTECT=[\$PROTECT]\"")"
has "protect-from-config-file" "$protect_out" "PROTECT=[claude-remote|goodtest]"

# ── overlay section is folded into the default `report` output too ─────────
# Checked statically (grep on the source), not by running `report` mode: a
# live `report` run touches the HOST's real tmux sessions and the live
# Anthropic registry (see test-session-doctor.sh's registry-stale tests for
# why that needs a fake HOME + stubbed curl) — overkill just to confirm the
# call site exists.
report_case="$(sed -n '/^  report)/,/^  reap-local)/p' "$DOCTOR")"
has "report-mode-calls-overlay-report" "$report_case" "_crss_overlay_report"

# An invalid CRSS_PROTECT_NAMES regex must fail CLOSED (everything protected),
# not open: grep exits 2 on a bad ERE, which callers would read as "not protected".
BADRE="$(mktemp -d)"; printf 'CRSS_PROTECT_NAMES=claude-remote|(widget\n' > "$BADRE/config.sh"
out="$(CRSS_HOME="$BADRE" bash "$DOCTOR" overlay 2>&1)"
has "bad-protect-regex-warns"       "$out" "is not a valid regex"
has "bad-protect-regex-fails-closed" "$out" "treating EVERY session as protected"
rm -rf "$BADRE"

rm -rf "$GOOD" "$BROKEN"

finish "test-session-doctor-overlay"
