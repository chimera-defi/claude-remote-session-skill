#!/usr/bin/env bash
# Tests for the CRSS host-local overlay config loader (_crss_load_config).
# The loader is copied VERBATIM into every script that reads overlay config
# (no shared lib — scripts are deployed as flat standalone copies to
# ~/.local/bin), so this file has two jobs:
#
#   1. Prove every copy is byte-identical (extracted between the
#      "# CRSS-CONFIG-LOADER-START" / "# CRSS-CONFIG-LOADER-END" marker
#      comments) — a single source of truth for the parsing logic.
#   2. Exercise that logic directly (garbage lines ignored, quotes stripped,
#      a hostile command-substitution value stays inert literal text, env
#      wins over file, a missing file is fine).
#
# No external test framework.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$HERE/.."
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }
has(){ if printf '%s' "$2" | grep -qF "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — pattern not found: $3 in: $2"; fi; }

# Every script that reads overlay config — keep this list in sync with
# CLAUDE.md's overlay-config instructions if a new script gains the loader.
LOADER_FILES=(new-session.sh session-doctor.sh session-alias.sh fleet-status.sh telemetry-report.sh record-spawn-telemetry.sh session-preserve.sh)

extract_loader() {  # $1 = script path -> loader block (markers inclusive) on stdout
  sed -n '/# CRSS-CONFIG-LOADER-START/,/# CRSS-CONFIG-LOADER-END/p' "$1"
}

# ── 1. Byte-identical across every copy ─────────────────────────────────────
ref="$(extract_loader "$REPO/scripts/${LOADER_FILES[0]}")"
if [ -z "$ref" ]; then
  echo "FAIL: no CRSS-CONFIG-LOADER block found in ${LOADER_FILES[0]} — cannot compare copies"
  fail=$((fail+1))
else
  pass=$((pass+1))
fi
for f in "${LOADER_FILES[@]}"; do
  got="$(extract_loader "$REPO/scripts/$f")"
  ok "loader-identical-$f" "$got" "$ref"
done

# ── 2. Functional behavior — source the extracted (canonical) block into a
#      fresh bash process per scenario, so state never leaks between cases.
LOADER_FILE="$(mktemp)"; trap 'rm -f "$LOADER_FILE"' EXIT
extract_loader "$REPO/scripts/${LOADER_FILES[0]}" > "$LOADER_FILE"

# missing config file is fine: CRSS_HOME still resolves, no error, nothing set.
out="$(CRSS_HOME=/tmp/crss-parser-test-missing-$$-nonexistent bash -c "set -uo pipefail; source '$LOADER_FILE'; echo \"HOME=\$CRSS_HOME\"; echo \"WS=\${CRSS_WORKSPACE-UNSET}\"")"
has "missing-file-resolves-home" "$out" "HOME=/tmp/crss-parser-test-missing-$$-nonexistent"
has "missing-file-sets-nothing" "$out" "WS=UNSET"

CFG="$(mktemp -d)"

# garbage lines (comments, blank, no-equals, lowercase name, wrong prefix) —
# silently ignored, function still returns success and CRSS_HOME resolves.
cat > "$CFG/config.sh" <<'EOF'
# a comment
CRSS_lowercase=nope
notCRSS_X=1
garbage line no equals

CRSS_GOOD=yes
EOF
out="$(CRSS_HOME="$CFG" bash -c "set -uo pipefail; source '$LOADER_FILE'; rc=\$?; echo \"GOOD=\$CRSS_GOOD\"; echo \"LOWER=\${CRSS_lowercase-UNSET}\"; echo \"RC=\$rc\"")"
has "garbage-lines-ignored-good-still-loads" "$out" "GOOD=yes"
has "garbage-lines-ignored-lowercase-not-loaded" "$out" "LOWER=UNSET"
has "garbage-lines-loader-still-succeeds" "$out" "RC=0"

# The last CRSS_ line names a var already set in the env: the loader must still
# return 0, or `set -e` callers (new-session) die silently before doing anything.
printf 'CRSS_A=1\nCRSS_LAST=file\n' > "$CFG/config.sh"
out="$(CRSS_HOME="$CFG" CRSS_LAST=env bash -c "set -euo pipefail; source '$LOADER_FILE'; echo \"ALIVE LAST=\$CRSS_LAST A=\$CRSS_A\"" 2>&1)"
has "set-e-last-line-preset-survives" "$out" "ALIVE LAST=env A=1"

# CRLF line endings: the trailing CR is stripped from the value.
printf 'CRSS_CR=val\r\n' > "$CFG/config.sh"
out="$(CRSS_HOME="$CFG" bash -c "source '$LOADER_FILE'; printf 'CR=[%s]' \"\$CRSS_CR\"")"
has "crlf-value-stripped" "$out" "CR=[val]"

# hostile line: a command-substitution value stays LITERAL text, never
# eval'd/expanded — must create no file.
PWNED="$CFG/pwned-marker-$$"
rm -f "$PWNED"
cat > "$CFG/config.sh" <<EOF
CRSS_HOSTILE=\$(touch $PWNED)
EOF
out="$(CRSS_HOME="$CFG" bash -c "set -uo pipefail; source '$LOADER_FILE'; echo \"H=\$CRSS_HOSTILE\"")"
has "hostile-value-kept-literal" "$out" 'H=$(touch'
if [ -e "$PWNED" ]; then
  echo "FAIL: hostile-value-creates-no-file — $PWNED WAS CREATED"
  fail=$((fail+1))
else
  pass=$((pass+1))
fi

# quotes: one layer of matching single/double quotes stripped; mismatched
# quotes are left alone.
cat > "$CFG/config.sh" <<'EOF'
CRSS_DQ="double quoted value"
CRSS_SQ='single quoted value'
CRSS_MISMATCH="unterminated
EOF
out="$(CRSS_HOME="$CFG" bash -c "set -uo pipefail; source '$LOADER_FILE'; echo \"DQ=[\$CRSS_DQ]\"; echo \"SQ=[\$CRSS_SQ]\"")"
has "double-quotes-stripped" "$out" 'DQ=[double quoted value]'
has "single-quotes-stripped" "$out" 'SQ=[single quoted value]'

# env wins over file: a var already set before sourcing is never overwritten
# by config.sh's value.
cat > "$CFG/config.sh" <<'EOF'
CRSS_WORKSPACE=/from/file
EOF
out="$(CRSS_HOME="$CFG" CRSS_WORKSPACE=/from/env bash -c "set -uo pipefail; source '$LOADER_FILE'; echo \"WS=\$CRSS_WORKSPACE\"")"
has "env-wins-over-file" "$out" "WS=/from/env"

# and the inverse: with no env override, the file's value IS loaded.
out="$(CRSS_HOME="$CFG" bash -c "set -uo pipefail; source '$LOADER_FILE'; echo \"WS=\$CRSS_WORKSPACE\"")"
has "file-value-loaded-when-env-unset" "$out" "WS=/from/file"

rm -rf "$CFG"

echo "test-crss-overlay-config: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
