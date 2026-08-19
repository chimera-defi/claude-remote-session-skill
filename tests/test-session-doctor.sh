#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1090
source "$HERE/../scripts/session-doctor.sh"   # must NOT run report (source-guard)
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }

ok "legacy tmux->base" "$(tmux_to_base agenthost_foo-20260101-0900)" "agenthost-foo-20260101-0900"
ok "new tmux->base"    "$(tmux_to_base ah_0101-0900-foo)"            "ah-0101-0900-foo"
ok "foreign tmux->base" "$(tmux_to_base codexhost_x)"               ""
ok "legacy svc->tmux"  "$(svc_to_tmux agenthost-foo-20260101-0900)" "agenthost_foo-20260101-0900"
ok "new svc->tmux"     "$(svc_to_tmux ah-0101-0900-foo)"            "ah_0101-0900-foo"

# registry-stale must degrade gracefully (no Python traceback) when the registry
# is unavailable (e.g. missing/expired credentials), same as `report` mode already
# does — regression for a bare `json.load(sys.stdin)` with no try/except.
NOHOME="$(mktemp -d)"; trap 'rm -rf "$NOHOME"' EXIT
out="$(HOME="$NOHOME" bash "$HERE/../scripts/session-doctor.sh" registry-stale 2>&1)"
ok "registry-stale-no-traceback" "$(printf '%s' "$out" | grep -qi 'Traceback' && echo yes || echo no)" "no"
ok "registry-stale-graceful-msg" "$(printf '%s' "$out" | grep -qF '(registry unavailable)' && echo yes || echo no)" "yes"

# --days is spliced verbatim into an embedded Python snippet as a bare identifier
# (DAYS=$DAYS) — an unvalidated non-numeric value is live Python there, not data,
# and previously threw an uncaught NameError traceback instead of a clean usage
# error. Must be rejected up front, before any registry call.
days_out="$(bash "$HERE/../scripts/session-doctor.sh" registry-stale --days abc 2>&1)"; days_rc=$?
ok "days-nonnumeric-rejected"   "$days_rc" "2"
ok "days-nonnumeric-no-traceback" "$(printf '%s' "$days_out" | grep -qi 'Traceback' && echo yes || echo no)" "no"
ok "days-nonnumeric-clean-msg"  "$(printf '%s' "$days_out" | grep -qF -- "--days requires a non-negative integer" && echo yes || echo no)" "yes"
# Exit code for a *valid* --days still depends on registry/credential availability
# (unrelated to this validation), so assert on behavior, not a specific exit code:
# no rejection message, and the same graceful degradation as the no-credentials
# case above.
numeric_out="$(bash "$HERE/../scripts/session-doctor.sh" registry-stale --days 30 2>&1)"
ok "days-numeric-not-rejected"  "$(printf '%s' "$numeric_out" | grep -qF -- "requires a non-negative integer" && echo yes || echo no)" "no"
ok "days-numeric-no-traceback"  "$(printf '%s' "$numeric_out" | grep -qi 'Traceback' && echo yes || echo no)" "no"

# A digit-only --days can still crash the embedded Python: a LEADING ZERO (e.g.
# `08`) passes the digits-only check above but Python 3 rejects `DAYS=08` as an
# integer literal (SyntaxError: leading zeros not permitted) once spliced in —
# caught in PR review (codex). Must be canonicalized to base-10, not just
# digit-validated.
leadzero_out="$(bash "$HERE/../scripts/session-doctor.sh" registry-stale --days 08 2>&1)"
ok "days-leadingzero-no-traceback" "$(printf '%s' "$leadzero_out" | grep -qi 'Traceback\|SyntaxError' && echo yes || echo no)" "no"
ok "days-leadingzero-normalized"   "$(printf '%s' "$leadzero_out" | grep -qF '> 8d' && echo yes || echo no)" "yes"

# reap-local orphan detection must NOT skip a unit just because systemd still
# reports it "active" (regression: Type=oneshot/RemainAfterExit=yes units —
# see new-session.sh's generated .service — go "active (exited)" once ExecStart
# finishes and STAY that way indefinitely, independent of whether the tmux
# session they spawned later dies. A systemctl is-active gate here would
# almost never be false and would defeat orphan reaping, the exact case this
# loop exists for). Stub systemctl to always report active and confirm the
# orphan (no live tmux) is still flagged.
STUBBIN="$(mktemp -d)"; trap 'rm -rf "$STUBBIN"' RETURN 2>/dev/null || true
cat > "$STUBBIN/systemctl" <<'STUB_EOF'
#!/usr/bin/env bash
exit 0
STUB_EOF
chmod +x "$STUBBIN/systemctl"
TESTCFG="$(mktemp -d)"; mkdir -p "$TESTCFG/systemd/user"
touch "$TESTCFG/systemd/user/ah-test-orphan-0101-0100.service"
TESTHOME="$(mktemp -d)"
orphan_out="$(PATH="$STUBBIN:$PATH" XDG_CONFIG_HOME="$TESTCFG" HOME="$TESTHOME" bash "$HERE/../scripts/session-doctor.sh" reap-local 2>&1)"
ok "reap-local-ignores-is-active" "$(printf '%s' "$orphan_out" | grep -qF 'ORPHAN unit (no tmux): ah-test-orphan-0101-0100.service' && echo yes || echo no)" "yes"
rm -rf "$STUBBIN" "$TESTCFG" "$TESTHOME"

echo "session-doctor: pass=$pass fail=$fail"; [ "$fail" -eq 0 ]
