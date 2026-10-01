#!/usr/bin/env bash
# CRSS_SESSION_PREFIX / CRSS_LEGACY_PREFIXES across every session-name parse/generate site in the six scripts that
# carry the CRSS-PREFIX-RE block (the block's own byte-identity/fallback rules are pinned by test-crss-overlay-config.sh).
# Each site is exercised under: configured (px + legacy oldhost), generic default (cs), custom (zz), foreign names
# (never recognised), and invalid prefix values (fall back safely, never match everything).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
REPO="$HERE/.."

ISO_HOME="/tmp/crss-test-isolation.$$.$RANDOM/does-not-exist"

# One cleanup trap for the whole file: kills tmux sessions carrying this PID's marker, removes temp dirs.
_CLEANUP_DIRS=()
_crss_test_cleanup() {
  tmux ls -F '#{session_name}' 2>/dev/null | grep -F -- "-$$-" | while read -r s; do tmux kill-session -t "$s" 2>/dev/null || true; done
  tmux ls -F '#{session_name}' 2>/dev/null | grep -F -- "_$$" | while read -r s; do tmux kill-session -t "$s" 2>/dev/null || true; done
  for d in "${_CLEANUP_DIRS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done
}
trap _crss_test_cleanup EXIT

# ── 1. session-doctor.sh: tmux_to_base / svc_to_tmux (sourced in-process) ──

# 1a. host shape: byte-identical for the current and legacy prefix.
out="$(CRSS_HOME="$ISO_HOME" CRSS_SESSION_PREFIX=px CRSS_LEGACY_PREFIXES=oldhost bash -c "
  source '$REPO/scripts/session-doctor.sh'
  echo \"legacy-base=\$(tmux_to_base oldhost_foo-20260101-0900)\"
  echo \"new-base=\$(tmux_to_base px_0101-0900-foo)\"
  echo \"foreign-base=[\$(tmux_to_base codexhost_x)]\"
  echo \"legacy-svc=\$(svc_to_tmux oldhost-foo-20260101-0900)\"
  echo \"new-svc=\$(svc_to_tmux px-0101-0900-foo)\"
")"
has "doctor-host-legacy-tmux2base" "$out" "legacy-base=oldhost-foo-20260101-0900"
has "doctor-host-new-tmux2base"    "$out" "new-base=px-0101-0900-foo"
has "doctor-host-foreign-tmux2base" "$out" "foreign-base=[]"
has "doctor-host-legacy-svc2tmux"  "$out" "legacy-svc=oldhost_foo-20260101-0900"
has "doctor-host-new-svc2tmux"     "$out" "new-svc=px_0101-0900-foo"

# 1b. generic default: "cs_foo" parses, "px_foo" does NOT (a fresh host never inherits another host's sessions).
out="$(CRSS_HOME="$ISO_HOME" bash -c "
  source '$REPO/scripts/session-doctor.sh'
  echo \"generic-base=\$(tmux_to_base cs_foo-0101-0900)\"
  echo \"px-under-generic=[\$(tmux_to_base px_foo-0101-0900)]\"
")"
has "doctor-generic-default-parses" "$out" "generic-base=cs-foo-0101-0900"
has "doctor-generic-default-rejects-px" "$out" "px-under-generic=[]"

# 1c. custom prefix (CRSS_SESSION_PREFIX=zz, no legacy).
out="$(CRSS_HOME="$ISO_HOME" CRSS_SESSION_PREFIX=zz bash -c "
  source '$REPO/scripts/session-doctor.sh'
  echo \"zz-base=\$(tmux_to_base zz_foo-0101-0900)\"
")"
has "doctor-custom-prefix-parses" "$out" "zz-base=zz-foo-0101-0900"

# 1d. unrelated tmux names are never recognised, under any config.
out="$(CRSS_HOME="$ISO_HOME" CRSS_SESSION_PREFIX=px CRSS_LEGACY_PREFIXES=oldhost bash -c "
  source '$REPO/scripts/session-doctor.sh'
  echo \"random-base=[\$(tmux_to_base random_foo)]\"
  echo \"otherbot-base=[\$(tmux_to_base otherbot-gateway)]\"
")"
has "doctor-random-foo-rejected" "$out" "random-base=[]"
has "doctor-otherbot-gateway-rejected" "$out" "otherbot-base=[]"

# 1e. invalid prefix values fall back safely and never match everything, checked against reap-local's real orphan-unit
# enumeration (the dangerous path), not just the regex.
for badval in 'a|' '.*' ''; do
  out="$(CRSS_HOME="$ISO_HOME" CRSS_SESSION_PREFIX="$badval" bash -c "
    source '$REPO/scripts/session-doctor.sh'
    echo \"cs-base=\$(tmux_to_base cs_fallback-0101-0900)\"
    echo \"random-base=[\$(tmux_to_base totally_unrelated)]\"
  " 2>/dev/null)"
  has "doctor-invalid-prefix-falls-back-to-cs[$badval]" "$out" "cs-base=cs-fallback-0101-0900"
  has "doctor-invalid-prefix-never-catchall[$badval]" "$out" "random-base=[]"
done

# 1f. reap-local's orphan-unit grep -E against a fake systemd user dir: the LIVE code path, not a re-derived regex.
FAKE_UD="$(mktemp -d)"; _CLEANUP_DIRS+=("$FAKE_UD")
touch "$FAKE_UD/px-foo-0101-0900.service" "$FAKE_UD/oldhost-bar-0101-0900.service" "$FAKE_UD/codexhost-baz.service" "$FAKE_UD/notaservice.txt"
out="$(CRSS_HOME="$ISO_HOME" CRSS_SESSION_PREFIX=px CRSS_LEGACY_PREFIXES=oldhost XDG_CONFIG_HOME="$(dirname "$FAKE_UD")" bash -c "
  mkdir -p '$(dirname "$FAKE_UD")/systemd/user' 2>/dev/null
  cp '$FAKE_UD'/*.service '$(dirname "$FAKE_UD")/systemd/user/' 2>/dev/null
  bash '$REPO/scripts/session-doctor.sh' reap-local 2>&1
")"
has "reap-local-enumerates-current-prefix" "$out" "px-foo-0101-0900.service"
has "reap-local-enumerates-legacy-prefix"  "$out" "oldhost-bar-0101-0900.service"
hasnt "reap-local-skips-foreign-unit" "$out" "codexhost-baz.service"

# ── 2. session-alias.sh: looks_like_session_name / desessionify (via CLI; not source-guarded) ──
ALIAS="$REPO/scripts/session-alias.sh"

# 2a. host shape: px- and legacy oldhost- folders desessionify.
S1="$(mktemp -u)"
out="$(CRSS_HOME="$ISO_HOME" CRSS_SESSION_PREFIX=px CRSS_LEGACY_PREFIXES=oldhost SESSION_ALIAS_STORE="$S1" bash "$ALIAS" px-agent-alpha-0721)"
ok "alias-host-px-desessionify" "$out" "agent-alpha"
S2="$(mktemp -u)"
out="$(CRSS_HOME="$ISO_HOME" CRSS_SESSION_PREFIX=px CRSS_LEGACY_PREFIXES=oldhost SESSION_ALIAS_STORE="$S2" bash "$ALIAS" oldhost-agent-alpha-0721)"
ok "alias-host-oldhost-desessionify" "$out" "agent-alpha"

# 2b. generic default: cs- desessionifies; px- is an ordinary folder prefix, not poisoned.
S3="$(mktemp -u)"
out="$(CRSS_HOME="$ISO_HOME" SESSION_ALIAS_STORE="$S3" bash "$ALIAS" cs-agent-alpha-0721)"
ok "alias-generic-cs-desessionify" "$out" "agent-alpha"
S4="$(mktemp -u)"
out="$(CRSS_HOME="$ISO_HOME" SESSION_ALIAS_STORE="$S4" bash "$ALIAS" px-agent-alpha-0721)"
ok "alias-generic-default-px-not-poisoned" "$out" "px-agent-alpha"

# 2c. custom prefix.
S5="$(mktemp -u)"
out="$(CRSS_HOME="$ISO_HOME" CRSS_SESSION_PREFIX=zz SESSION_ALIAS_STORE="$S5" bash "$ALIAS" zz-agent-alpha-0721)"
ok "alias-custom-zz-desessionify" "$out" "agent-alpha"

# 2d. invalid CRSS_SESSION_PREFIX falls back to "cs": the rejected value is not treated as poisoned, cs-... still recognised.
S6="$(mktemp -u)"
out="$(CRSS_HOME="$ISO_HOME" CRSS_SESSION_PREFIX='.*' SESSION_ALIAS_STORE="$S6" bash "$ALIAS" cs-agent-alpha-0721 2>/dev/null)"
ok "alias-invalid-prefix-falls-back-to-cs" "$out" "agent-alpha"

# ── 3. session-preserve.sh: tmux_to_base. Not source-guarded, so extract the function text from the real file and eval it. ──
PRESERVE_FUNC="$(sed -n '/^tmux_to_base() {$/,/^}$/p' "$REPO/scripts/session-preserve.sh")"
if [ -z "$PRESERVE_FUNC" ]; then
  echo "FAIL: could not extract tmux_to_base() from session-preserve.sh"; fail=$((fail+1))
else
  pass=$((pass+1))
fi
out="$(bash -c "
  $PRESERVE_FUNC
  _crss_prefix_re='px|oldhost'
  echo \"legacy-base=\$(tmux_to_base oldhost_foo-0101-0900)\"
  echo \"new-base=\$(tmux_to_base px_0101-0900-foo)\"
  echo \"foreign-base=[\$(tmux_to_base random_foo)]\"
  _crss_prefix_re='cs'
  echo \"generic-base=\$(tmux_to_base cs_foo-0101-0900)\"
  echo \"px-under-generic=[\$(tmux_to_base px_foo-0101-0900)]\"
")"
has "preserve-host-legacy-tmux2base" "$out" "legacy-base=oldhost-foo-0101-0900"
has "preserve-host-new-tmux2base"    "$out" "new-base=px-0101-0900-foo"
has "preserve-host-foreign-rejected" "$out" "foreign-base=[]"
has "preserve-generic-default-parses" "$out" "generic-base=cs-foo-0101-0900"
has "preserve-generic-default-rejects-px" "$out" "px-under-generic=[]"

# --all's live-session enumeration against real PID-suffixed test tmux sessions.
if command -v tmux >/dev/null 2>&1; then
  T1="px_pfxtest-$$-0101-0900"; T2="oldhost_pfxtest-$$-0101-0900"; T3="random_pfxtest-$$-x"
  tmux new-session -d -s "$T1" 2>/dev/null
  tmux new-session -d -s "$T2" 2>/dev/null
  tmux new-session -d -s "$T3" 2>/dev/null
  out="$(CRSS_HOME="$ISO_HOME" CRSS_SESSION_PREFIX=px CRSS_LEGACY_PREFIXES=oldhost bash "$REPO/scripts/session-preserve.sh" --all 2>&1)"
  has "preserve-all-includes-current-prefix" "$out" "$T1"
  has "preserve-all-includes-legacy-prefix"  "$out" "$T2"
  hasnt "preserve-all-skips-foreign"          "$out" "$T3"
  for s in "$T1" "$T2" "$T3"; do tmux kill-session -t "$s" 2>/dev/null || true; done
else
  echo "session-preserve --all: SKIP (no tmux)"
fi

# ── 4. session-handoff.sh: tmux_to_base / _live_ours (sourced in-process) ──
out="$(CRSS_HOME="$ISO_HOME" CRSS_SESSION_PREFIX=px CRSS_LEGACY_PREFIXES=oldhost bash -c "
  source '$REPO/scripts/session-handoff.sh'
  echo \"legacy-base=\$(tmux_to_base oldhost_foo-0101-0900)\"
  echo \"new-base=\$(tmux_to_base px_0101-0900-foo)\"
  echo \"foreign-base=[\$(tmux_to_base random_foo)]\"
")"
has "handoff-host-legacy-tmux2base" "$out" "legacy-base=oldhost-foo-0101-0900"
has "handoff-host-new-tmux2base"    "$out" "new-base=px-0101-0900-foo"
has "handoff-host-foreign-rejected" "$out" "foreign-base=[]"

out="$(CRSS_HOME="$ISO_HOME" bash -c "
  source '$REPO/scripts/session-handoff.sh'
  echo \"generic-base=\$(tmux_to_base cs_foo-0101-0900)\"
  echo \"px-under-generic=[\$(tmux_to_base px_foo-0101-0900)]\"
")"
has "handoff-generic-default-parses" "$out" "generic-base=cs-foo-0101-0900"
has "handoff-generic-default-rejects-px" "$out" "px-under-generic=[]"

# _live_ours end-to-end against one real test tmux session.
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

# ── 5. session-registry.sh: live-session enumeration against real PID-suffixed test tmux sessions (isolated HOME) ──
if command -v tmux >/dev/null 2>&1; then
  R1="px_regtest-$$-0101-0100"; R2="oldhost_regtest-$$-0101-0100"; R3="random_regtest-$$-x"
  tmux new-session -d -s "$R1" 2>/dev/null
  tmux new-session -d -s "$R2" 2>/dev/null
  tmux new-session -d -s "$R3" 2>/dev/null
  NOHOME="$(mktemp -d)"
  out="$(CRSS_HOME="$ISO_HOME" CRSS_SESSION_PREFIX=px CRSS_LEGACY_PREFIXES=oldhost HOME="$NOHOME" bash "$REPO/scripts/session-registry.sh" 2>&1)"
  has "registry-includes-current-prefix" "$out" "$R1"
  has "registry-includes-legacy-prefix"  "$out" "$R2"
  hasnt "registry-skips-foreign"          "$out" "$R3"
  # generic default: none of the px_/oldhost_ test sessions show up.
  out2="$(CRSS_HOME="$ISO_HOME" HOME="$NOHOME" bash "$REPO/scripts/session-registry.sh" 2>&1)"
  hasnt "registry-generic-default-skips-px" "$out2" "$R1"
  hasnt "registry-generic-default-skips-oldhost" "$out2" "$R2"
  rm -rf "$NOHOME"
  for s in "$R1" "$R2" "$R3"; do tmux kill-session -t "$s" 2>/dev/null || true; done
else
  echo "session-registry: SKIP (no tmux)"
fi

# ── 6. new-session.sh --dry-run: generation (SESSION/REMOTE_NAME), not parsing ──
NS="$REPO/scripts/new-session.sh"
BINDIR="$(mktemp -d)"; _CLEANUP_DIRS+=("$BINDIR")
ln -sf "$REPO/scripts/session-alias.sh" "$BINDIR/session-alias"
STORE="$(mktemp)"; rm -f "$STORE"

out="$(CRSS_HOME="$ISO_HOME" CRSS_SESSION_PREFIX=px CRSS_LEGACY_PREFIXES=oldhost PATH="$BINDIR:$PATH" SESSION_ALIAS_STORE="$STORE" bash "$NS" --dry-run pfxtestproj 2>/dev/null)"
has "new-session-host-shape-remote" "$out" "REMOTE_NAME=px-pfxtestproj"
has "new-session-host-shape-tmux"   "$out" "SESSION=px_pfxtestproj"

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

finish "test-session-prefix"
