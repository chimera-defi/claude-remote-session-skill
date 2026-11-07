#!/usr/bin/env bash
# Tests for the CRSS host-local overlay config loader (_crss_load_config) and the
# session-name prefix block (_crss_prefix_init). Both live ONCE in scripts/crss-lib.sh, which
# every script sources (no copies). This file has three jobs:
#
#   1. Prove each script sources crss-lib.sh and carries no copy of the functions.
#   2. Exercise the loader directly: garbage lines ignored, quotes stripped, a hostile
#      command-substitution value stays inert literal text, env wins over file, a missing
#      file is fine, and set -e survives a last line whose var is preset.
#   3. Exercise the prefix block: an invalid CRSS_SESSION_PREFIX falls back to the generic
#      default, an invalid CRSS_LEGACY_PREFIXES element drops the WHOLE legacy list, and a
#      valid config builds the expected alternation. Fixture-level "does an old/new-prefixed
#      name actually parse" coverage lives in tests/test-session-prefix.sh.
#
# No external test framework.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
REPO="$HERE/.."

# Every script that reads overlay config — keep this list in sync with
# the scripts if a new one gains the loader.
LOADER_FILES=(new-session.sh session-doctor.sh session-alias.sh fleet-status.sh telemetry-report.sh record-spawn-telemetry.sh session-preserve.sh session-handoff.sh session-registry.sh session-resume.sh session-spawn-server.sh session-restart.sh)

# Every script that reads CRSS_SESSION_PREFIX/CRSS_LEGACY_PREFIXES — keep in
# sync with the scripts if a new one gains the block. Deliberately a SUBSET of LOADER_FILES: fleet-status.sh,
# telemetry-report.sh and record-spawn-telemetry.sh have the config loader
# but never parse/generate a session name themselves (fleet-status delegates
# to session-doctor), so they don't need this block.
PREFIX_RE_FILES=(new-session.sh session-doctor.sh session-alias.sh session-preserve.sh session-handoff.sh session-registry.sh session-resume.sh)

LIB="$REPO/scripts/crss-lib.sh"

# ── 1. One shared copy: every script sources crss-lib.sh and carries no copy of the functions
ok "lib-exists" "$(yn test -f "$LIB")" yes
LOADER_SOURCE_LINES=(
  '_crss_lib="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/crss-lib.sh"'
  '# shellcheck source=scripts/crss-lib.sh'
  '. "$_crss_lib" || { echo "${0##*/}: missing $_crss_lib; install crss-lib.sh next to this script" >&2; exit 2; }'
  '_crss_load_config'
)
# has_loader_window FILE: the 4 loader lines appear consecutively in FILE.
has_loader_window() {
  local n
  n="$(grep -n -F -x -- "${LOADER_SOURCE_LINES[0]}" "$1" | head -1 | cut -d: -f1)"
  [ -n "$n" ] || return 1
  [ "$(sed -n "${n},$((n+3))p" "$1")" = "$(printf '%s\n' "${LOADER_SOURCE_LINES[@]}")" ]
}
for f in "${LOADER_FILES[@]}"; do
  ok "loader-sources-lib-$f" "$(has_loader_window "$REPO/scripts/$f" && echo yes || echo no)" yes
  ok "no-loader-copy-$f" "$(grep -qE '_crss_load_config\(\) \{|CRSS-CONFIG-LOADER' "$REPO/scripts/$f" && echo yes || echo no)" no
done
for f in "${PREFIX_RE_FILES[@]}"; do
  ok "prefix-init-$f" "$(grep -qx '_crss_prefix_init' "$REPO/scripts/$f" && echo yes || echo no)" yes
  ok "no-prefix-copy-$f" "$(grep -qE 'CRSS-PREFIX-RE|_crss_valid_prefix_tok\(\) \{' "$REPO/scripts/$f" && echo yes || echo no)" no
done
ok "lib-defines-each-function-once" "$(grep -cE '^_crss_(load_config|valid_prefix_tok|prefix_init)\(\) \{' "$LIB")" 3
other_defs="$(grep -lE '_crss_(load_config|prefix_init|valid_prefix_tok)\(\) \{' "$REPO"/scripts/*.sh | grep -v '/crss-lib\.sh$' || true)"
ok "no-other-file-defines-lib-functions" "$other_defs" ""

# ── 2. Loader behavior — source the lib into a fresh bash process per scenario, then call it

# missing config file is fine: CRSS_HOME still resolves, no error, nothing set.
out="$(CRSS_HOME=/tmp/crss-parser-test-missing-$$-nonexistent bash -c "set -uo pipefail; source '$LIB'; _crss_load_config; echo \"HOME=\$CRSS_HOME\"; echo \"WS=\${CRSS_WORKSPACE-UNSET}\"")"
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
out="$(CRSS_HOME="$CFG" bash -c "set -uo pipefail; source '$LIB'; _crss_load_config; rc=\$?; echo \"GOOD=\$CRSS_GOOD\"; echo \"LOWER=\${CRSS_lowercase-UNSET}\"; echo \"RC=\$rc\"")"
has "garbage-lines-ignored-good-still-loads" "$out" "GOOD=yes"
has "garbage-lines-ignored-lowercase-not-loaded" "$out" "LOWER=UNSET"
has "garbage-lines-loader-still-succeeds" "$out" "RC=0"

# The last CRSS_ line names a var already set in the env: the loader must still
# return 0, or `set -e` callers (new-session) die silently before doing anything.
printf 'CRSS_A=1\nCRSS_LAST=file\n' > "$CFG/config.sh"
out="$(CRSS_HOME="$CFG" CRSS_LAST=env bash -c "set -euo pipefail; source '$LIB'; _crss_load_config; echo \"ALIVE LAST=\$CRSS_LAST A=\$CRSS_A\"" 2>&1)"
has "set-e-last-line-preset-survives" "$out" "ALIVE LAST=env A=1"

# hostile line: a command-substitution value stays LITERAL text, never
# eval'd/expanded — must create no file.
PWNED="$CFG/pwned-marker-$$"
rm -f "$PWNED"
cat > "$CFG/config.sh" <<EOF
CRSS_HOSTILE=\$(touch $PWNED)
EOF
out="$(CRSS_HOME="$CFG" bash -c "set -uo pipefail; source '$LIB'; _crss_load_config; echo \"H=\$CRSS_HOSTILE\"")"
has "hostile-value-kept-literal" "$out" 'H=$(touch'
if [ -e "$PWNED" ]; then
  echo "FAIL: hostile-value-creates-no-file — $PWNED WAS CREATED"
  fail=$((fail+1))
else
  pass=$((pass+1))
fi

# env wins over file: a var already set before sourcing is never overwritten
# by config.sh's value.
cat > "$CFG/config.sh" <<'EOF'
CRSS_WORKSPACE=/from/file
EOF
out="$(CRSS_HOME="$CFG" CRSS_WORKSPACE=/from/env bash -c "set -uo pipefail; source '$LIB'; _crss_load_config; echo \"WS=\$CRSS_WORKSPACE\"")"
has "env-wins-over-file" "$out" "WS=/from/env"

rm -rf "$CFG"

# ── 3. Prefix-recognition block (_crss_prefix_re) — functional behavior ─────
# Source the lib and call _crss_prefix_init in a fresh bash process per scenario.

# unset -> generic default "cs", no warning.
out="$(bash -c "set -uo pipefail; unset CRSS_SESSION_PREFIX CRSS_LEGACY_PREFIXES; source '$LIB'; _crss_prefix_init; echo \"RE=\$_crss_prefix_re\"" 2>&1)"
has "unset-defaults-to-cs" "$out" "RE=cs"

# valid CRSS_SESSION_PREFIX + valid CRSS_LEGACY_PREFIXES (a configured-prefix shape).
out="$(CRSS_SESSION_PREFIX=px CRSS_LEGACY_PREFIXES=oldhost bash -c "set -uo pipefail; source '$LIB'; _crss_prefix_init; echo \"RE=\$_crss_prefix_re\"" 2>&1)"
has "valid-host-shape" "$out" "RE=px|oldhost"

# invalid CRSS_SESSION_PREFIX ('a|', not ^[a-z][a-z0-9]{0,15}$) falls back to
# the generic default with a warning on stderr — never to an empty pattern.
out="$(CRSS_SESSION_PREFIX='a|' bash -c "set -uo pipefail; source '$LIB'; _crss_prefix_init; echo \"RE=\$_crss_prefix_re\"" 2>&1)"
has "invalid-session-prefix-falls-back" "$out" "RE=cs"
has "invalid-session-prefix-warns" "$out" "CRSS_SESSION_PREFIX 'a|' is invalid"

# ANY invalid element in CRSS_LEGACY_PREFIXES drops the WHOLE legacy list
# (not just the bad element) — a valid CRSS_SESSION_PREFIX survives on its own.
out="$(CRSS_SESSION_PREFIX=px CRSS_LEGACY_PREFIXES='oldhost|.*' bash -c "set -uo pipefail; source '$LIB'; _crss_prefix_init; echo \"RE=\$_crss_prefix_re\"" 2>&1)"
has "invalid-legacy-element-drops-whole-list" "$out" "RE=px"
has "invalid-legacy-element-not-oldhost" "$(grep -qF 'RE=px|oldhost' <<<"$out" && echo yes || echo no)" "no"
has "invalid-legacy-element-warns" "$out" "CRSS_LEGACY_PREFIXES 'oldhost|.*' has an invalid element"

# ── 4. Installed layout: a script without crss-lib.sh beside it exits 2; with it, it runs
E2E="$(mktemp -d)"
mkdir -p "$E2E/alone" "$E2E/beside"
cp "$REPO/scripts/session-registry.sh" "$E2E/alone/"
bash "$E2E/alone/session-registry.sh" -h >/dev/null 2>"$E2E/alone.err"; rc=$?
ok "missing-lib-exits-2" "$rc" 2
has "missing-lib-says-missing" "$(cat "$E2E/alone.err")" "missing"
has "missing-lib-names-crss-lib" "$(cat "$E2E/alone.err")" "crss-lib.sh"
cp "$REPO/scripts/session-registry.sh" "$LIB" "$E2E/beside/"
bash "$E2E/beside/session-registry.sh" -h >/dev/null 2>&1; rc=$?
ok "lib-beside-copy-works" "$rc" 0
rm -rf "$E2E"

finish "test-crss-overlay-config"
