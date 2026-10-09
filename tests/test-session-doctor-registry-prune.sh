#!/usr/bin/env bash
# session-doctor.sh `registry-prune` mode and reap's registry-cleanup step. Nothing here may touch the real registry:
# `curl` is PATH-shimmed (logs every call, answers from fixtures) and HOME holds fake credentials.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
DOCTOR="$HERE/../scripts/session-doctor.sh"
isolate_overlay
export CRSS_REAP_MIN_AGE_H=0   # min-age gate is pinned in tests/test-reap-min-age.sh; this suite tests other reap behavior
# Fixture shape: configured prefix "px", legacy "oldhost".
export CRSS_SESSION_PREFIX=px
export CRSS_LEGACY_PREFIXES=oldhost
# shellcheck disable=SC1090
source "$DOCTOR"   # must NOT run dispatch (source-guard)

FAKE_TOKEN="FAKE-TOKEN-DO-NOT-LEAK-9f8e7d6c"

# ── fixture: throwaway HOME with fake creds (never real ones) ───────────────
FIXHOME="$(mktemp -d)"
mkdir -p "$FIXHOME/.claude"
cat > "$FIXHOME/.claude/.credentials.json" <<EOF
{"claudeAiOauth":{"accessToken":"$FAKE_TOKEN"}}
EOF
cat > "$FIXHOME/.claude.json" <<'EOF'
{"oauthAccount":{"organizationUuid":"fake-org-uuid"}}
EOF

# ── fake curl: logs "METHOD URL" to $FAKE_CURL_LOG; GET .../v1/sessions answers from $FAKE_REGISTRY_JSON; DELETE
# .../v1/sessions/<id> prints only the code from $FAKE_DELETE_CODES ("<id> <code>" lines, default 200). Honors a GET's
# -o <file>; fixtures are bare arrays (no has_more), so registry_json() stops after one page. ──
STUBBIN="$(mktemp -d)"
cat > "$STUBBIN/curl" <<'STUB_EOF'
#!/usr/bin/env bash
set -u
method="GET"; url=""; outfile=""
args=("$@"); i=0
while [ "$i" -lt "${#args[@]}" ]; do
  a="${args[$i]}"
  case "$a" in
    -X) i=$((i+1)); method="${args[$i]}" ;;
    -o) i=$((i+1)); outfile="${args[$i]}" ;;
    http*) url="$a" ;;
  esac
  i=$((i+1))
done
[ -n "${FAKE_CURL_LOG:-}" ] && printf '%s %s\n' "$method" "$url" >> "$FAKE_CURL_LOG"
if [ "$method" = "DELETE" ]; then
  id="${url##*/}"
  code=200
  if [ -n "${FAKE_DELETE_CODES:-}" ] && [ -f "$FAKE_DELETE_CODES" ]; then
    found="$(awk -v id="$id" '$1==id{print $2}' "$FAKE_DELETE_CODES" | tail -1)"
    [ -n "$found" ] && code="$found"
  fi
  printf '%s' "$code"
  exit 0
fi
body() {
  if [ -n "${FAKE_REGISTRY_JSON:-}" ] && [ -f "$FAKE_REGISTRY_JSON" ]; then
    cat "$FAKE_REGISTRY_JSON"
  else
    echo '[]'
  fi
}
if [ -n "$outfile" ]; then body > "$outfile"; else body; fi
STUB_EOF
chmod +x "$STUBBIN/curl"

# ── fixture registry: every skip reason + a plain deletable candidate. DAYS defaults to 30, so 2xDAYS=60 for the
# requires_action-age cases. ──
REG="$(mktemp -d)/registry.json"
python3 - "$REG" <<'PYEOF'
import json, sys, datetime
now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
def ts(days_ago):
    return (now - datetime.timedelta(days=days_ago)).strftime('%Y-%m-%dT%H:%M:%S')
def row(id, days_ago, status, title, conn="disconnected"):
    t = ts(days_ago)
    return {"id": id, "updated_at": t+"Z", "created_at": t+"Z",
            "connection_status": conn, "session_status": status, "title": title}
rows = [
    row("sess_old_normal", 40, "idle", "px-old-normal-0101-0100"),
    row("sess_old_thirdbot", 40, "idle", "px-thirdbot-bridge-0101-0100"),
    row("sess_old_clauderemote", 40, "idle", "Legacy Direct Claude Remote"),
    row("sess_old_livetmux", 40, "idle", "px-livetmux-0101-0100"),
    row("sess_reqaction_fresh", 40, "requires_action", "px-reqaction-fresh-0101-0100"),
    row("sess_reqaction_old", 70, "requires_action", "px-reqaction-old-0101-0100"),
    row("sess_too_fresh", 10, "idle", "px-too-fresh-0101-0100"),
    row("sess_connected_old", 90, "idle", "px-connectedold-0101-0100", "connected"),
]
json.dump(rows, open(sys.argv[1], "w"))
PYEOF

RUN() {  # RUN <mode-and-args...> — common env for every registry-prune call below
  # PROTECT's generic default is just "claude-remote"; set thirdbot via CRSS_PROTECT_NAMES to exercise the config path
  FAKE_CURL_LOG="$CURL_LOG" FAKE_REGISTRY_JSON="$REG" FAKE_DELETE_CODES="${DELETE_CODES:-}" \
    CRSS_PROTECT_NAMES='claude-remote|thirdbot' \
    PATH="$STUBBIN:$PATH" HOME="$FIXHOME" bash "$DOCTOR" "$@"
}

# ── dry run: no --apply => zero DELETE calls, candidates printed as would-delete ──
CURL_LOG="$(mktemp -d)/curl.log"; : > "$CURL_LOG"
dry_out="$(RUN registry-prune 2>&1)"; dry_rc=$?
ok  "dryrun-exit0"                 "$dry_rc" "0"
hasnt "dryrun-no-delete-calls"     "$(cat "$CURL_LOG")" "DELETE"
has "dryrun-would-delete-normal"   "$dry_out" "sess_old_normal"
has "dryrun-skips-thirdbot"          "$dry_out" "sess_old_thirdbot"
has "dryrun-flags-reqaction-old"   "$dry_out" "sess_reqaction_old"
# ── live-tmux protection: a candidate matching a live tmux session is skipped, --apply or not ──
if command -v tmux >/dev/null 2>&1; then
  tmux new-session -d -s px_livetmux-0101-0100 -c "$FIXHOME" 'sleep 60' 2>/dev/null
  CURL_LOG="$(mktemp -d)/curl.log"; : > "$CURL_LOG"
  lt_out="$(RUN registry-prune --apply 2>&1)"
  tmux kill-session -t px_livetmux-0101-0100 2>/dev/null || true
  has "livetmux-skipped" "$(printf '%s' "$lt_out" | grep -F 'sess_old_livetmux')" "skipped"
  hasnt "livetmux-no-delete-call" "$(cat "$CURL_LOG")" "sessions/sess_old_livetmux"
fi

# ── --apply: deletes only the non-protected, non-skipped candidate(s) ──────
CURL_LOG="$(mktemp -d)/curl.log"; : > "$CURL_LOG"
apply_out="$(RUN registry-prune --apply 2>&1)"; apply_rc=$?
ok  "apply-exit0" "$apply_rc" "0"
has "apply-deletes-normal-call"     "$(cat "$CURL_LOG")" "DELETE https://api.anthropic.com/v1/sessions/sess_old_normal"
hasnt "apply-no-delete-thirdbot"      "$(cat "$CURL_LOG")" "sessions/sess_old_thirdbot"
hasnt "apply-no-delete-clauderemote" "$(cat "$CURL_LOG")" "sessions/sess_old_clauderemote"
hasnt "apply-no-delete-reqaction-old"   "$(cat "$CURL_LOG")" "sessions/sess_reqaction_old"
has "apply-reports-deleted"         "$apply_out" "deleted"

# ── failed delete: non-2xx => failed(code), other rows still processed, run exits non-zero ──
FAILREG="$(mktemp -d)/registry-fail.json"
python3 - "$FAILREG" <<'PYEOF'
import json, sys, datetime
now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
def ts(days_ago):
    return (now - datetime.timedelta(days=days_ago)).strftime('%Y-%m-%dT%H:%M:%S')
def row(id, days_ago, status, title):
    t = ts(days_ago)
    return {"id": id, "updated_at": t+"Z", "created_at": t+"Z",
            "connection_status": "disconnected", "session_status": status, "title": title}
rows = [row("sess_ok", 40, "idle", "px-ok-0101-0100"), row("sess_bad", 40, "idle", "px-bad-0101-0100")]
json.dump(rows, open(sys.argv[1], "w"))
PYEOF
DC="$(mktemp -d)/codes.txt"; echo "sess_bad 500" > "$DC"
CURL_LOG="$(mktemp -d)/curl.log"; : > "$CURL_LOG"
fail_out="$(FAKE_CURL_LOG="$CURL_LOG" FAKE_REGISTRY_JSON="$FAILREG" FAKE_DELETE_CODES="$DC" PATH="$STUBBIN:$PATH" HOME="$FIXHOME" bash "$DOCTOR" registry-prune --apply 2>&1)"; fail_rc=$?
ok  "faildelete-exit-nonzero" "$(yn test "$fail_rc" -ne 0)" "yes"
has "faildelete-reports-failed-code" "$fail_out" "failed(500)"
has "faildelete-still-deletes-ok-row" "$fail_out" "deleted"
has "faildelete-ok-row-was-called" "$(cat "$CURL_LOG")" "DELETE https://api.anthropic.com/v1/sessions/sess_ok"

# ── registry unavailable: no traceback, graceful, non-crashing ────────────
BADHOME_RP="$(mktemp -d)"
noreg_out="$(PATH="$STUBBIN:$PATH" HOME="$BADHOME_RP" bash "$DOCTOR" registry-prune 2>&1)"
hasnt "noregistry-no-traceback" "$noreg_out" "Traceback"

# ── _registry_delete_one: its protect-check is defense in depth; neither registry-prune (filters protected rows first)
# nor reap (NAME refused up front) can reach it, so call the sourced function directly ──
CURL_LOG="$(mktemp -d)/curl.log"; : > "$CURL_LOG"
prot_del_out="$(FAKE_CURL_LOG="$CURL_LOG" HOME="$FIXHOME" PATH="$STUBBIN:$PATH" _registry_delete_one sess_x "Legacy Direct Claude Remote" 2>&1)"; prot_del_rc=$?
ok  "helper-protects-clauderemote-exit0" "$prot_del_rc" "0"
has "helper-protects-clauderemote-msg"   "$prot_del_out" "skipped(protected)"
hasnt "helper-protects-clauderemote-no-delete-call" "$(cat "$CURL_LOG")" "DELETE"

# ── reap: registry cleanup after a successful teardown ────────────────────
if command -v tmux >/dev/null 2>&1; then
  RSTUB="$(mktemp -d)"
  cat > "$RSTUB/systemctl" <<'STUB_EOF'
#!/usr/bin/env bash
exit 0
STUB_EOF
  chmod +x "$RSTUB/systemctl"
  cp "$STUBBIN/curl" "$RSTUB/curl"

  # 1. live throwaway session with a matching non-protected registry entry => torn down AND entry deleted
  REAPREG="$(mktemp -d)/reap-registry.json"
  python3 - "$REAPREG" <<'PYEOF'
import json, sys, datetime
t = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S')
rows = [{"id": "sess_reapme", "updated_at": t+"Z", "created_at": t+"Z",
         "connection_status": "connected", "session_status": "idle",
         "title": "px-reaptest-0101-0900"}]
json.dump(rows, open(sys.argv[1], "w"))
PYEOF
  tmux new-session -d -s px_reaptest-0101-0900 -c "$FIXHOME" 'sleep 60' 2>/dev/null
  CURL_LOG="$(mktemp -d)/curl.log"; : > "$CURL_LOG"
  reap_out="$(FAKE_CURL_LOG="$CURL_LOG" FAKE_REGISTRY_JSON="$REAPREG" PATH="$RSTUB:$PATH" HOME="$FIXHOME" bash "$DOCTOR" reap px_reaptest-0101-0900 --force 2>&1)"
  tmux kill-session -t px_reaptest-0101-0900 2>/dev/null || true
  has "reap-still-tears-down"        "$reap_out" "reaped 'px_reaptest-0101-0900'"
  has "reap-deletes-registry-entry"  "$(cat "$CURL_LOG")" "DELETE https://api.anthropic.com/v1/sessions/sess_reapme"
  has "reap-registry-delete-message" "$reap_out" "sess_reapme"

  # 2. --keep-registry => no registry call for a matching entry
  tmux new-session -d -s px_reaptest-0101-0900 -c "$FIXHOME" 'sleep 60' 2>/dev/null
  CURL_LOG="$(mktemp -d)/curl.log"; : > "$CURL_LOG"
  keep_out="$(FAKE_CURL_LOG="$CURL_LOG" FAKE_REGISTRY_JSON="$REAPREG" PATH="$RSTUB:$PATH" HOME="$FIXHOME" bash "$DOCTOR" reap px_reaptest-0101-0900 --force --keep-registry 2>&1)"
  tmux kill-session -t px_reaptest-0101-0900 2>/dev/null || true
  has   "reap-keepregistry-still-tears-down" "$keep_out" "reaped 'px_reaptest-0101-0900'"
  ok    "reap-keepregistry-no-curl-calls"    "$([ -s "$CURL_LOG" ] && echo called || echo none)" "none"

  # 3. registry unreachable (no credentials) => fails soft: reap succeeds, notes the registry was unreachable
  BADHOME="$(mktemp -d)"
  tmux new-session -d -s px_reaptest-0101-0900 -c "$FIXHOME" 'sleep 60' 2>/dev/null
  softfail_out="$(PATH="$RSTUB:$PATH" HOME="$BADHOME" bash "$DOCTOR" reap px_reaptest-0101-0900 --force 2>&1)"; softfail_rc=$?
  tmux kill-session -t px_reaptest-0101-0900 2>/dev/null || true
  ok  "reap-softfail-exit0"   "$softfail_rc" "0"
  has "reap-softfail-message" "$softfail_out" "reaped 'px_reaptest-0101-0900'"

  rm -rf "$RSTUB"
fi

rm -rf "$FIXHOME" "$STUBBIN"
finish "session-doctor-registry-prune"
