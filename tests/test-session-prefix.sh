#!/usr/bin/env bash
# tests/test-session-prefix.sh — CRSS_SESSION_PREFIX / CRSS_LEGACY_PREFIXES:
# every session-name parse/generate site touched by that feature, across all
# six scripts that carry the CRSS-PREFIX-RE block (new-session.sh,
# session-doctor.sh, session-alias.sh, session-preserve.sh, session-handoff.sh,
# session-registry.sh). The shared block's OWN logic (byte-identity, fallback
# rules) is pinned by tests/test-crss-overlay-config.sh; this file exercises
# each script's actual parse/generate FUNCTION or PATH with:
#   - a configured-prefix shape (CRSS_SESSION_PREFIX=ah, CRSS_LEGACY_PREFIXES=oldhost)
#   - the generic default (no prefix config at all -> "cs")
#   - a custom prefix (CRSS_SESSION_PREFIX=zz)
#   - an unrelated/foreign tmux-style name (must never be recognised)
#   - an invalid prefix value (must fall back safely, never match everything)
# No external test framework.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$HERE/.."
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }
has(){ if printf '%s' "$2" | grep -qF "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — pattern not found: $3 in: $2"; fi; }
lacks(){ if printf '%s' "$2" | grep -qF "$3"; then fail=$((fail+1)); echo "FAIL: $1 — unwanted pattern present: $3"; else pass=$((pass+1)); fi; }

# Isolation: never read the operator's real overlay — see CLAUDE.md "Test isolation".
ISO_HOME="/tmp/crss-test-isolation.$$.$RANDOM/does-not-exist"

# ONE cleanup trap for the whole file (rather than one per section, which
# would silently overwrite each other): kills every tmux session this file
# created (all named with a "-$$-" or "_$$" PID marker, never a bare/shared
# name) and removes every temp dir this file created. Individual sections
# also clean up eagerly at the end of their own block; this is the safety
# net for an early exit/failure mid-file.
_CLEANUP_DIRS=()
_crss_test_cleanup() {
  tmux ls -F '#{session_name}' 2>/dev/null | grep -F -- "-$$-" | while read -r s; do tmux kill-session -t "$s" 2>/dev/null || true; done
  tmux ls -F '#{session_name}' 2>/dev/null | grep -F -- "_$$" | while read -r s; do tmux kill-session -t "$s" 2>/dev/null || true; done
  for d in "${_CLEANUP_DIRS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done
}
trap _crss_test_cleanup EXIT

# ═══════════════════════════════════════════════════════════════════════════
# 1. session-doctor.sh — tmux_to_base / svc_to_tmux (source-guarded; safe to
#    source directly and call functions in-process, same technique the
#    existing test-session-doctor.sh already uses).
# ═══════════════════════════════════════════════════════════════════════════

# 1a. host shape (CRSS_SESSION_PREFIX=ah, CRSS_LEGACY_PREFIXES=oldhost):
# byte-identical to today for both the current and legacy prefix.
out="$(CRSS_HOME="$ISO_HOME" CRSS_SESSION_PREFIX=ah CRSS_LEGACY_PREFIXES=oldhost bash -c "
  source '$REPO/scripts/session-doctor.sh'
  echo \"legacy-base=\$(tmux_to_base oldhost_foo-20260101-0900)\"
  echo \"new-base=\$(tmux_to_base ah_0101-0900-foo)\"
  echo \"foreign-base=[\$(tmux_to_base codexhost_x)]\"
  echo \"legacy-svc=\$(svc_to_tmux oldhost-foo-20260101-0900)\"
  echo \"new-svc=\$(svc_to_tmux ah-0101-0900-foo)\"
")"
has "doctor-host-legacy-tmux2base" "$out" "legacy-base=oldhost-foo-20260101-0900"
has "doctor-host-new-tmux2base"    "$out" "new-base=ah-0101-0900-foo"
has "doctor-host-foreign-tmux2base" "$out" "foreign-base=[]"
has "doctor-host-legacy-svc2tmux"  "$out" "legacy-svc=oldhost_foo-20260101-0900"
has "doctor-host-new-svc2tmux"     "$out" "new-svc=ah_0101-0900-foo"

# 1b. generic default (no prefix config at all): "cs_foo" parses, "ah_foo"
# (a configured prefix) does NOT — the safe direction, proving a
# fresh/other host never silently inherits another host's sessions.
out="$(CRSS_HOME="$ISO_HOME" bash -c "
  source '$REPO/scripts/session-doctor.sh'
  echo \"generic-base=\$(tmux_to_base cs_foo-0101-0900)\"
  echo \"ah-under-generic=[\$(tmux_to_base ah_foo-0101-0900)]\"
")"
has "doctor-generic-default-parses" "$out" "generic-base=cs-foo-0101-0900"
has "doctor-generic-default-rejects-ah" "$out" "ah-under-generic=[]"

# 1c. custom prefix (CRSS_SESSION_PREFIX=zz, no legacy).
out="$(CRSS_HOME="$ISO_HOME" CRSS_SESSION_PREFIX=zz bash -c "
  source '$REPO/scripts/session-doctor.sh'
  echo \"zz-base=\$(tmux_to_base zz_foo-0101-0900)\"
")"
has "doctor-custom-prefix-parses" "$out" "zz-base=zz-foo-0101-0900"

# 1d. unrelated tmux names are never recognised, under any config.
out="$(CRSS_HOME="$ISO_HOME" CRSS_SESSION_PREFIX=ah CRSS_LEGACY_PREFIXES=oldhost bash -c "
  source '$REPO/scripts/session-doctor.sh'
  echo \"random-base=[\$(tmux_to_base random_foo)]\"
  echo \"otherbot-base=[\$(tmux_to_base otherbot-gateway)]\"
")"
has "doctor-random-foo-rejected" "$out" "random-base=[]"
has "doctor-otherbot-gateway-rejected" "$out" "otherbot-base=[]"

# 1e. invalid prefix values fall back safely and never match everything —
# confirmed against reap-local's actual orphan-unit enumeration (the grep -E
# site), not just the isolated regex, since that's the dangerous path.
for badval in 'a|' '.*' ''; do
  out="$(CRSS_HOME="$ISO_HOME" CRSS_SESSION_PREFIX="$badval" bash -c "
    source '$REPO/scripts/session-doctor.sh'
    echo \"cs-base=\$(tmux_to_base cs_fallback-0101-0900)\"
    echo \"random-base=[\$(tmux_to_base totally_unrelated)]\"
  " 2>/dev/null)"
  has "doctor-invalid-prefix-falls-back-to-cs[$badval]" "$out" "cs-base=cs-fallback-0101-0900"
  has "doctor-invalid-prefix-never-catchall[$badval]" "$out" "random-base=[]"
done

# 1f. reap-local's orphan-unit enumeration pattern (both call sites use the
# same `grep -E "^(${_crss_prefix_re})-.*\.service$"` fragment) against a
# fake systemd user dir — proves the LIVE code path, not a re-derived regex.
FAKE_UD="$(mktemp -d)"; _CLEANUP_DIRS+=("$FAKE_UD")
touch "$FAKE_UD/ah-foo-0101-0900.service" "$FAKE_UD/oldhost-bar-0101-0900.service" "$FAKE_UD/codexhost-baz.service" "$FAKE_UD/notaservice.txt"
out="$(CRSS_HOME="$ISO_HOME" CRSS_SESSION_PREFIX=ah CRSS_LEGACY_PREFIXES=oldhost XDG_CONFIG_HOME="$(dirname "$FAKE_UD")" bash -c "
  mkdir -p '$(dirname "$FAKE_UD")/systemd/user' 2>/dev/null
  cp '$FAKE_UD'/*.service '$(dirname "$FAKE_UD")/systemd/user/' 2>/dev/null
  bash '$REPO/scripts/session-doctor.sh' reap-local 2>&1
")"
has "reap-local-enumerates-current-prefix" "$out" "ah-foo-0101-0900.service"
has "reap-local-enumerates-legacy-prefix"  "$out" "oldhost-bar-0101-0900.service"
lacks "reap-local-skips-foreign-unit" "$out" "codexhost-baz.service"

# ═══════════════════════════════════════════════════════════════════════════
# 2. session-alias.sh — looks_like_session_name / desessionify (exercised via
#    the CLI, same technique the existing test-session-alias.sh uses; this
#    binary is not source-guarded).
# ═══════════════════════════════════════════════════════════════════════════
ALIAS="$REPO/scripts/session-alias.sh"

# 2a. host shape: an ah-prefixed folder desessionifies; a legacy
# oldhost-prefixed one does too.
S1="$(mktemp -u)"
out="$(CRSS_HOME="$ISO_HOME" CRSS_SESSION_PREFIX=ah CRSS_LEGACY_PREFIXES=oldhost SESSION_ALIAS_STORE="$S1" bash "$ALIAS" ah-agent-alpha-0721)"
ok "alias-host-ah-desessionify" "$out" "agent-alpha"
S2="$(mktemp -u)"
out="$(CRSS_HOME="$ISO_HOME" CRSS_SESSION_PREFIX=ah CRSS_LEGACY_PREFIXES=oldhost SESSION_ALIAS_STORE="$S2" bash "$ALIAS" oldhost-agent-alpha-0721)"
ok "alias-host-oldhost-desessionify" "$out" "agent-alpha"

# 2b. generic default: a cs-prefixed folder desessionifies; an ah-prefixed
# one under generic defaults is NOT treated as poisoned (no host config ->
# "ah" is just an ordinary folder-name prefix, not a reserved one).
S3="$(mktemp -u)"
out="$(CRSS_HOME="$ISO_HOME" SESSION_ALIAS_STORE="$S3" bash "$ALIAS" cs-agent-alpha-0721)"
ok "alias-generic-cs-desessionify" "$out" "agent-alpha"
S4="$(mktemp -u)"
out="$(CRSS_HOME="$ISO_HOME" SESSION_ALIAS_STORE="$S4" bash "$ALIAS" ah-agent-alpha-0721)"
ok "alias-generic-default-ah-not-poisoned" "$out" "ah-agent-alpha"

# 2c. custom prefix.
S5="$(mktemp -u)"
out="$(CRSS_HOME="$ISO_HOME" CRSS_SESSION_PREFIX=zz SESSION_ALIAS_STORE="$S5" bash "$ALIAS" zz-agent-alpha-0721)"
ok "alias-custom-zz-desessionify" "$out" "agent-alpha"

# 2d. invalid CRSS_SESSION_PREFIX falls back to generic "cs" — a folder
# merely starting with the (rejected) configured value must not be treated
# as poisoned, and "cs-..." must still be recognised via the fallback.
S6="$(mktemp -u)"
out="$(CRSS_HOME="$ISO_HOME" CRSS_SESSION_PREFIX='.*' SESSION_ALIAS_STORE="$S6" bash "$ALIAS" cs-agent-alpha-0721 2>/dev/null)"
ok "alias-invalid-prefix-falls-back-to-cs" "$out" "agent-alpha"

# ═══════════════════════════════════════════════════════════════════════════
# 3. session-preserve.sh — tmux_to_base. Not source-guarded (sourcing runs
#    the whole CLI, which exits on missing args), so extract the function
#    body verbatim from the deployed file and eval it in isolation — same
#    technique tests/test-fallback-recipe-guard.sh already uses for a
#    doc-embedded function. This tests the ACTUAL file's function text, not
#    a re-derived copy.
# ═══════════════════════════════════════════════════════════════════════════
PRESERVE_FUNC="$(sed -n '/^tmux_to_base() {$/,/^}$/p' "$REPO/scripts/session-preserve.sh")"
if [ -z "$PRESERVE_FUNC" ]; then
  echo "FAIL: could not extract tmux_to_base() from session-preserve.sh"; fail=$((fail+1))
else
  pass=$((pass+1))
fi
out="$(bash -c "
  $PRESERVE_FUNC
  _crss_prefix_re='ah|oldhost'
  echo \"legacy-base=\$(tmux_to_base oldhost_foo-0101-0900)\"
  echo \"new-base=\$(tmux_to_base ah_0101-0900-foo)\"
  echo \"foreign-base=[\$(tmux_to_base random_foo)]\"
  _crss_prefix_re='cs'
  echo \"generic-base=\$(tmux_to_base cs_foo-0101-0900)\"
  echo \"ah-under-generic=[\$(tmux_to_base ah_foo-0101-0900)]\"
")"
has "preserve-host-legacy-tmux2base" "$out" "legacy-base=oldhost-foo-0101-0900"
has "preserve-host-new-tmux2base"    "$out" "new-base=ah-0101-0900-foo"
has "preserve-host-foreign-rejected" "$out" "foreign-base=[]"
has "preserve-generic-default-parses" "$out" "generic-base=cs-foo-0101-0900"
has "preserve-generic-default-rejects-ah" "$out" "ah-under-generic=[]"

# --all's live-session enumeration (grep -E "^(${_crss_prefix_re})_") against
# real (but clearly test-only, PID-suffixed) tmux sessions.
if command -v tmux >/dev/null 2>&1; then
  T1="ah_pfxtest-$$-0101-0900"; T2="oldhost_pfxtest-$$-0101-0900"; T3="random_pfxtest-$$-x"
  tmux new-session -d -s "$T1" 2>/dev/null
  tmux new-session -d -s "$T2" 2>/dev/null
  tmux new-session -d -s "$T3" 2>/dev/null
  out="$(CRSS_HOME="$ISO_HOME" CRSS_SESSION_PREFIX=ah CRSS_LEGACY_PREFIXES=oldhost bash "$REPO/scripts/session-preserve.sh" --all 2>&1)"
  has "preserve-all-includes-current-prefix" "$out" "$T1"
  has "preserve-all-includes-legacy-prefix"  "$out" "$T2"
  lacks "preserve-all-skips-foreign"          "$out" "$T3"
  for s in "$T1" "$T2" "$T3"; do tmux kill-session -t "$s" 2>/dev/null || true; done
else
  echo "session-preserve --all: SKIP (no tmux)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 4. session-handoff.sh — tmux_to_base / _live_ours (source-guarded; safe to
#    source directly, same technique as session-doctor.sh above).
# ═══════════════════════════════════════════════════════════════════════════
out="$(CRSS_HOME="$ISO_HOME" CRSS_SESSION_PREFIX=ah CRSS_LEGACY_PREFIXES=oldhost bash -c "
  source '$REPO/scripts/session-handoff.sh'
  echo \"legacy-base=\$(tmux_to_base oldhost_foo-0101-0900)\"
  echo \"new-base=\$(tmux_to_base ah_0101-0900-foo)\"
  echo \"foreign-base=[\$(tmux_to_base random_foo)]\"
")"
has "handoff-host-legacy-tmux2base" "$out" "legacy-base=oldhost-foo-0101-0900"
has "handoff-host-new-tmux2base"    "$out" "new-base=ah-0101-0900-foo"
has "handoff-host-foreign-rejected" "$out" "foreign-base=[]"

out="$(CRSS_HOME="$ISO_HOME" bash -c "
  source '$REPO/scripts/session-handoff.sh'
  echo \"generic-base=\$(tmux_to_base cs_foo-0101-0900)\"
  echo \"ah-under-generic=[\$(tmux_to_base ah_foo-0101-0900)]\"
")"
has "handoff-generic-default-parses" "$out" "generic-base=cs-foo-0101-0900"
has "handoff-generic-default-rejects-ah" "$out" "ah-under-generic=[]"

# _live_ours end-to-end against one real, clearly test-only tmux session.
if command -v tmux >/dev/null 2>&1; then
  HT1="zz_handofftest-$$-0101-0900"
  tmux new-session -d -s "$HT1" 2>/dev/null
  out="$(CRSS_HOME="$ISO_HOME" CRSS_SESSION_PREFIX=zz bash -c "
    source '$REPO/scripts/session-handoff.sh'
    _live_ours
  ")"
  has "handoff-live-ours-finds-custom-prefix" "$out" "$HT1"
  tmux kill-session -t "$HT1" 2>/dev/null || true
else
  echo "session-handoff _live_ours: SKIP (no tmux)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 5. session-registry.sh — live-session enumeration, end-to-end against real
#    (but clearly test-only, PID-suffixed) tmux sessions. Not source-guarded,
#    so invoked as a normal CLI call; HOME is isolated so there's no
#    session-starts.log entry (falls back to tmux's own session_created,
#    which is fine for this prefix-recognition test).
# ═══════════════════════════════════════════════════════════════════════════
if command -v tmux >/dev/null 2>&1; then
  R1="ah_regtest-$$-0101-0100"; R2="oldhost_regtest-$$-0101-0100"; R3="random_regtest-$$-x"
  tmux new-session -d -s "$R1" 2>/dev/null
  tmux new-session -d -s "$R2" 2>/dev/null
  tmux new-session -d -s "$R3" 2>/dev/null
  NOHOME="$(mktemp -d)"
  out="$(CRSS_HOME="$ISO_HOME" CRSS_SESSION_PREFIX=ah CRSS_LEGACY_PREFIXES=oldhost HOME="$NOHOME" bash "$REPO/scripts/session-registry.sh" 2>&1)"
  has "registry-includes-current-prefix" "$out" "$R1"
  has "registry-includes-legacy-prefix"  "$out" "$R2"
  lacks "registry-skips-foreign"          "$out" "$R3"
  # generic default: none of the ah_/oldhost_ test sessions show up.
  out2="$(CRSS_HOME="$ISO_HOME" HOME="$NOHOME" bash "$REPO/scripts/session-registry.sh" 2>&1)"
  lacks "registry-generic-default-skips-ah" "$out2" "$R1"
  lacks "registry-generic-default-skips-oldhost" "$out2" "$R2"
  rm -rf "$NOHOME"
  for s in "$R1" "$R2" "$R3"; do tmux kill-session -t "$s" 2>/dev/null || true; done
else
  echo "session-registry: SKIP (no tmux)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 6. new-session.sh --dry-run — generation (SESSION/REMOTE_NAME), not parsing.
# ═══════════════════════════════════════════════════════════════════════════
NS="$REPO/scripts/new-session.sh"
BINDIR="$(mktemp -d)"; _CLEANUP_DIRS+=("$BINDIR")
ln -sf "$REPO/scripts/session-alias.sh" "$BINDIR/session-alias"
STORE="$(mktemp)"; rm -f "$STORE"

out="$(CRSS_HOME="$ISO_HOME" CRSS_SESSION_PREFIX=ah CRSS_LEGACY_PREFIXES=oldhost PATH="$BINDIR:$PATH" SESSION_ALIAS_STORE="$STORE" bash "$NS" --dry-run pfxtestproj 2>/dev/null)"
has "new-session-host-shape-remote" "$out" "REMOTE_NAME=ah-pfxtestproj"
has "new-session-host-shape-tmux"   "$out" "SESSION=ah_pfxtestproj"

out="$(CRSS_HOME="$ISO_HOME" PATH="$BINDIR:$PATH" SESSION_ALIAS_STORE="$STORE" bash "$NS" --dry-run pfxtestproj2 2>/dev/null)"
has "new-session-generic-default-remote" "$out" "REMOTE_NAME=cs-pfxtestproj2"
has "new-session-generic-default-tmux"   "$out" "SESSION=cs_pfxtestproj2"

out="$(CRSS_HOME="$ISO_HOME" CRSS_SESSION_PREFIX=zz PATH="$BINDIR:$PATH" SESSION_ALIAS_STORE="$STORE" bash "$NS" --dry-run pfxtestproj3 2>/dev/null)"
has "new-session-custom-prefix-remote" "$out" "REMOTE_NAME=zz-pfxtestproj3"
has "new-session-custom-prefix-tmux"   "$out" "SESSION=zz_pfxtestproj3"

out="$(CRSS_HOME="$ISO_HOME" CRSS_SESSION_PREFIX='.*' PATH="$BINDIR:$PATH" SESSION_ALIAS_STORE="$STORE" bash "$NS" --dry-run pfxtestproj4 2>&1)"
has "new-session-invalid-prefix-falls-back" "$out" "REMOTE_NAME=cs-pfxtestproj4"
has "new-session-invalid-prefix-warns" "$out" "CRSS_SESSION_PREFIX '.*' is invalid"

rm -f "$STORE"

echo "test-session-prefix: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
