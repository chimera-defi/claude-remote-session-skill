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
# has_loader_window FILE [no-config]: the 3 lookup lines appear consecutively in FILE, then the
# optional `declare -F` helper check, then _crss_load_config. With no-config the last line is not
# checked: session-compact.sh loads no config, and session-resume.sh loads it after its admission
# gate (checked below).
has_loader_window() {
  local n next
  n="$(grep -n -F -x -- "${LOADER_SOURCE_LINES[0]}" "$1" | head -1 | cut -d: -f1)"
  [ -n "$n" ] || return 1
  [ "$(sed -n "${n},$((n+2))p" "$1")" = "$(printf '%s\n' "${LOADER_SOURCE_LINES[@]:0:3}")" ] || return 1
  [ "${2:-}" = no-config ] && return 0
  next=$((n+3)); [[ "$(sed -n "${next}p" "$1")" == "declare -F "* ]] && next=$((next+1))
  [ "$(sed -n "${next}p" "$1")" = "${LOADER_SOURCE_LINES[3]}" ]
}
ok "loader-sources-lib-session-compact.sh" "$(has_loader_window "$REPO/scripts/session-compact.sh" no-config && echo yes || echo no)" yes
admit_n="$(grep -n '_crss_admit restart' "$REPO/scripts/session-resume.sh" | head -1 | cut -d: -f1)"
load_n="$(grep -nx '_crss_load_config' "$REPO/scripts/session-resume.sh" | head -1 | cut -d: -f1)"
ok "resume-admits-before-config" "$([ -n "$admit_n" ] && [ -n "$load_n" ] && [ "$admit_n" -lt "$load_n" ] && echo yes || echo no)" yes
for f in "${LOADER_FILES[@]}"; do
  mode=""; [ "$f" = session-resume.sh ] && mode=no-config
  ok "loader-sources-lib-$f" "$(has_loader_window "$REPO/scripts/$f" "$mode" && echo yes || echo no)" yes
  ok "no-loader-copy-$f" "$(grep -qE '_crss_load_config\(\) \{|CRSS-CONFIG-LOADER' "$REPO/scripts/$f" && echo yes || echo no)" no
done
for f in "${PREFIX_RE_FILES[@]}"; do
  ok "prefix-init-$f" "$(grep -qx '_crss_prefix_init' "$REPO/scripts/$f" && echo yes || echo no)" yes
  ok "no-prefix-copy-$f" "$(grep -qE 'CRSS-PREFIX-RE|_crss_valid_prefix_tok\(\) \{' "$REPO/scripts/$f" && echo yes || echo no)" no
done
ok "lib-defines-each-function-once" "$(grep -cE '^_crss_(load_config|valid_prefix_tok|prefix_init)\(\) \{' "$LIB")" 3
other_defs="$(grep -lE '_crss_(load_config|prefix_init|valid_prefix_tok)\(\) \{' "$REPO"/scripts/*.sh | grep -v '/crss-lib\.sh$' || true)"
ok "no-other-file-defines-lib-functions" "$other_defs" ""
# Shared helpers (admission, lookup, tmux naming, cwd encoding, protection) live once, in the lib.
ok "lib-defines-shared-helpers-once" "$(grep -cE '^(_crss_admit|_find_helper|tmux_to_base|_encode_cwd|_is_protected)\(\) \{' "$LIB")" 5
shared_defs="$(grep -lE '^(_crss_admit|_find_helper|tmux_to_base|_encode_cwd|_is_protected|protected)\(\) \{' "$REPO"/scripts/*.sh | grep -v '/crss-lib\.sh$' || true)"
ok "no-other-file-defines-shared-helpers" "$shared_defs" ""
# A script that calls a shared helper checks it right after sourcing (declare -F), so an out-of-date
# lib exits 2 instead of each call returning 127 (which _is_protected callers read as "not protected").
SHARED_HELPERS=(_crss_admit _find_helper tmux_to_base _encode_cwd _is_protected)
unchecked=""
for f in "$REPO"/scripts/*.sh; do
  [ "${f##*/}" = crss-lib.sh ] && continue
  src_n="$(grep -n -F -x -- "${LOADER_SOURCE_LINES[2]}" "$f" | head -1 | cut -d: -f1)"
  check=""; [ -n "$src_n" ] && check="$(sed -n "$((src_n+1))p" "$f")"
  for h in "${SHARED_HELPERS[@]}"; do
    # grep -c, not -q: with pipefail, -q exiting early SIGPIPEs the first grep on a big file.
    [ "$(grep -v '^[[:space:]]*#' "$f" | grep -cE "(^|[^[:alnum:]_])$h([^[:alnum:]_]|\$)")" -gt 0 ] || continue
    [[ "$check" == "declare -F "* && " $check " == *" $h "* ]] || unchecked+=" ${f##*/}:$h"
  done
done
ok "helper-callers-check-lib" "$unchecked" ""

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

# ── 3b. Shared helpers: behavior against the lib ─────────────────────────────
has "protected-match" "$(bash -c "source '$LIB'; CRSS_PROTECT_NAMES=claude-remote; _is_protected cs_claude_remote; echo RC=\$?")" "RC=0"
has "protected-no-match" "$(bash -c "source '$LIB'; CRSS_PROTECT_NAMES=claude-remote; _is_protected cs_other; echo RC=\$?")" "RC=1"
has "protected-bad-regex-fails-closed" "$(bash -c "source '$LIB'; CRSS_PROTECT_NAMES='bad('; _is_protected anything; echo RC=\$?")" "RC=0"
has "protected-leading-dash" "$(bash -c "source '$LIB'; CRSS_PROTECT_NAMES='-x'; _is_protected 'a-x'; echo RC=\$?")" "RC=0"

# _find_helper and _crss_admit look beside the CALLING script (BASH_SOURCE[1]), not the lib.
FH="$(mktemp -d)"
cat > "$FH/caller.sh" <<EOF
#!/usr/bin/env bash
. '$LIB'
_find_helper zzhelper
_crss_admit launch subj
EOF
: > "$FH/zzhelper.sh"
echo 'echo "ADMIT $*"' > "$FH/autonomous-admission.sh"
out="$(bash "$FH/caller.sh" 2>&1)"
ok "find-helper-beside-caller" "$(head -1 <<<"$out")" "$FH/zzhelper.sh"
ok "admit-beside-caller" "$(sed -n 2p <<<"$out")" "ADMIT launch subj"
rm -rf "$FH"

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
# An out-of-date lib (here: one without _is_protected) stops session-restart before its protection
# check; with the current lib the same run refuses the protected name.
mkdir -p "$E2E/stale"
cp "$REPO/scripts/session-restart.sh" "$E2E/stale/"
sed '/^_is_protected() {/,/^}/d' "$LIB" > "$E2E/stale/crss-lib.sh"
ok "stale-lib-fixture-lacks-helper" "$(grep -c '^_is_protected()' "$E2E/stale/crss-lib.sh")" 0
env -i HOME="$E2E" PATH=/usr/bin:/bin CRSS_HOME="$E2E/none" CRSS_PROTECT_NAMES=keep \
  bash "$E2E/stale/session-restart.sh" cs_keep --dry-run >"$E2E/stale.out" 2>&1; rc=$?
ok "stale-lib-exits-2" "$rc" 2
has "stale-lib-says-out-of-date" "$(cat "$E2E/stale.out")" "is out of date; install crss-lib.sh next to this script"
ok "stale-lib-never-reaches-plan" "$(grep -c 'REFUSED' "$E2E/stale.out")" 0
cp "$LIB" "$E2E/stale/crss-lib.sh"
env -i HOME="$E2E" PATH=/usr/bin:/bin CRSS_HOME="$E2E/none" CRSS_PROTECT_NAMES=keep \
  bash "$E2E/stale/session-restart.sh" cs_keep --dry-run >"$E2E/stale.out" 2>&1; rc=$?
ok "current-lib-refuses-protected" "$rc:$(grep -c 'REFUSED(protected)' "$E2E/stale.out")" "1:1"
rm -rf "$E2E"

finish "test-crss-overlay-config"
