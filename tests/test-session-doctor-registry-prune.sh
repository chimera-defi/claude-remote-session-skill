#!/usr/bin/env bash
# Tests for session-doctor.sh's `registry-prune` mode and `reap`'s new
# registry-cleanup step. Both talk to the real Anthropic session registry in
# production, so nothing here may do that: `curl` is PATH-shimmed with a
# fake (below) that logs every call and answers from a fixture JSON file / a
# per-id HTTP-code map, and HOME points at a throwaway .claude/.credentials.json
# + .claude.json so registry_json()'s token/org extraction (same mechanism as
# registry-stale — see session-doctor.sh ~line 105) reads a fake token, never
# a real one. No external test framework.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DOCTOR="$HERE/../scripts/session-doctor.sh"
# shellcheck disable=SC1090
source "$DOCTOR"   # must NOT run dispatch (source-guard)
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }
has(){ if printf '%s' "$2" | grep -qF "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — pattern not found: $3 in: $2"; fi; }
hasnt(){ if printf '%s' "$2" | grep -qF "$3"; then fail=$((fail+1)); echo "FAIL: $1 — pattern unexpectedly present: $3"; else pass=$((pass+1)); fi; }

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

# ── fake curl: logs "METHOD URL" per call to $FAKE_CURL_LOG, answers GET
# .../v1/sessions from $FAKE_REGISTRY_JSON, and DELETE .../v1/sessions/<id>
# with the code from $FAKE_DELETE_CODES ("<id> <code>" per line; default 200
# for an unlisted id) — mirrors curl -s -o /dev/null -w '%{http_code}' by
# printing only the code, nothing else, on a DELETE. Also honors a GET's
# -o <file> (registry_json() now paginates by writing each page to a file —
# see registry_json's header comment in session-doctor.sh) by writing the
# body there instead of stdout; every fixture here is a bare JSON array
# (no has_more), so registry_json() always stops after this one page.
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

# ── fixture registry: covers every skip reason + a plain deletable candidate.
# DAYS defaults to 30 (registry-prune, like registry-stale, is not idle-report
# — see the per-mode DAYS default near the top of session-doctor.sh), so
# 2xDAYS=60 for the requires_action-age cases below.
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
    row("sess_old_normal", 40, "idle", "ah-old-normal-0101-0100"),
    row("sess_old_hermes", 40, "idle", "ah-hermes-bridge-0101-0100"),
    row("sess_old_clauderemote", 40, "idle", "Agenthost Direct Claude Remote"),
    row("sess_old_livetmux", 40, "idle", "ah-livetmux-0101-0100"),
    row("sess_reqaction_fresh", 40, "requires_action", "ah-reqaction-fresh-0101-0100"),
    row("sess_reqaction_old", 70, "requires_action", "ah-reqaction-old-0101-0100"),
    row("sess_too_fresh", 10, "idle", "ah-too-fresh-0101-0100"),
    row("sess_connected_old", 90, "idle", "ah-connectedold-0101-0100", "connected"),
]
json.dump(rows, open(sys.argv[1], "w"))
PYEOF

RUN() {  # RUN <mode-and-args...> — common env for every registry-prune call below
  FAKE_CURL_LOG="$CURL_LOG" FAKE_REGISTRY_JSON="$REG" FAKE_DELETE_CODES="${DELETE_CODES:-}" \
    PATH="$STUBBIN:$PATH" HOME="$FIXHOME" bash "$DOCTOR" "$@"
}

# ── dry run: no --apply => zero DELETE calls, every non-skipped candidate
# printed as would-delete ─────────────────────────────────────────────────
CURL_LOG="$(mktemp -d)/curl.log"; : > "$CURL_LOG"
dry_out="$(RUN registry-prune 2>&1)"; dry_rc=$?
ok  "dryrun-exit0"                 "$dry_rc" "0"
hasnt "dryrun-no-delete-calls"     "$(cat "$CURL_LOG")" "DELETE"
has "dryrun-would-delete-normal"   "$dry_out" "sess_old_normal"
has "dryrun-skips-hermes"          "$dry_out" "sess_old_hermes"
has "dryrun-skips-clauderemote"    "$dry_out" "sess_old_clauderemote"
has "dryrun-skips-reqaction-fresh" "$dry_out" "sess_reqaction_fresh"
has "dryrun-flags-reqaction-old"   "$dry_out" "sess_reqaction_old"
hasnt "dryrun-omits-too-fresh"     "$dry_out" "sess_too_fresh"
hasnt "dryrun-omits-connected-old" "$dry_out" "sess_connected_old"
hasnt "dryrun-no-token-leak"       "$dry_out" "$FAKE_TOKEN"

# hermes/claude-remote-title/reqaction rows must never appear as "would-delete"
# (they're skip reasons, not deletion candidates) — check the exact row, not
# just substring presence of the id anywhere in the output.
has "dryrun-hermes-is-skipped-not-would-delete" \
  "$(printf '%s' "$dry_out" | grep -F 'sess_old_hermes')" "skipped"
has "dryrun-clauderemote-is-skipped-not-would-delete" \
  "$(printf '%s' "$dry_out" | grep -F 'sess_old_clauderemote')" "skipped"
has "dryrun-reqaction-old-not-deleted-outcome" \
  "$(printf '%s' "$dry_out" | grep -F 'sess_reqaction_old')" "skipped"

# ── live-tmux protection: a candidate whose title matches a currently-live
# tmux session must be skipped, --apply or not ───────────────────────────
if command -v tmux >/dev/null 2>&1; then
  tmux new-session -d -s ah_livetmux-0101-0100 -c "$FIXHOME" 'sleep 60' 2>/dev/null
  CURL_LOG="$(mktemp -d)/curl.log"; : > "$CURL_LOG"
  lt_out="$(RUN registry-prune --apply 2>&1)"
  tmux kill-session -t ah_livetmux-0101-0100 2>/dev/null || true
  has "livetmux-skipped" "$(printf '%s' "$lt_out" | grep -F 'sess_old_livetmux')" "skipped"
  hasnt "livetmux-no-delete-call" "$(cat "$CURL_LOG")" "sessions/sess_old_livetmux"
fi

# ── --apply: deletes only the non-protected, non-skipped candidate(s) ──────
CURL_LOG="$(mktemp -d)/curl.log"; : > "$CURL_LOG"
apply_out="$(RUN registry-prune --apply 2>&1)"; apply_rc=$?
ok  "apply-exit0" "$apply_rc" "0"
has "apply-deletes-normal-call"     "$(cat "$CURL_LOG")" "DELETE https://api.anthropic.com/v1/sessions/sess_old_normal"
hasnt "apply-no-delete-hermes"      "$(cat "$CURL_LOG")" "sessions/sess_old_hermes"
hasnt "apply-no-delete-clauderemote" "$(cat "$CURL_LOG")" "sessions/sess_old_clauderemote"
hasnt "apply-no-delete-reqaction-fresh" "$(cat "$CURL_LOG")" "sessions/sess_reqaction_fresh"
hasnt "apply-no-delete-reqaction-old"   "$(cat "$CURL_LOG")" "sessions/sess_reqaction_old"
hasnt "apply-no-delete-too-fresh"       "$(cat "$CURL_LOG")" "sessions/sess_too_fresh"
hasnt "apply-no-delete-connected-old"   "$(cat "$CURL_LOG")" "sessions/sess_connected_old"
has "apply-reports-deleted"         "$apply_out" "deleted"
hasnt "apply-no-token-leak"         "$apply_out" "$FAKE_TOKEN"

# ── failed delete: one row's DELETE comes back non-2xx => reported
# failed(code), other rows still processed, and the whole run exits non-zero.
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
rows = [row("sess_ok", 40, "idle", "ah-ok-0101-0100"), row("sess_bad", 40, "idle", "ah-bad-0101-0100")]
json.dump(rows, open(sys.argv[1], "w"))
PYEOF
DC="$(mktemp -d)/codes.txt"; echo "sess_bad 500" > "$DC"
CURL_LOG="$(mktemp -d)/curl.log"; : > "$CURL_LOG"
fail_out="$(FAKE_CURL_LOG="$CURL_LOG" FAKE_REGISTRY_JSON="$FAILREG" FAKE_DELETE_CODES="$DC" PATH="$STUBBIN:$PATH" HOME="$FIXHOME" bash "$DOCTOR" registry-prune --apply 2>&1)"; fail_rc=$?
ok  "faildelete-exit-nonzero" "$([ "$fail_rc" -ne 0 ] && echo yes || echo no)" "yes"
has "faildelete-reports-failed-code" "$fail_out" "failed(500)"
has "faildelete-still-deletes-ok-row" "$fail_out" "deleted"
has "faildelete-ok-row-was-called" "$(cat "$CURL_LOG")" "DELETE https://api.anthropic.com/v1/sessions/sess_ok"

# ── registry unavailable: no traceback, graceful, non-crashing ────────────
BADHOME_RP="$(mktemp -d)"
noreg_out="$(PATH="$STUBBIN:$PATH" HOME="$BADHOME_RP" bash "$DOCTOR" registry-prune 2>&1)"
hasnt "noregistry-no-traceback" "$noreg_out" "Traceback"

# ── _registry_delete_one: protect-check is defense-in-depth even when called
# directly. registry-prune's loop already filters protected rows before ever
# calling this helper, and reap's registry lookup can never produce a
# protected title (NAME itself would already have been refused at the top of
# `reap` — see PROTECT there), so neither higher-level path can exercise the
# helper's own guard; call it directly (it's a sourced shell function).
CURL_LOG="$(mktemp -d)/curl.log"; : > "$CURL_LOG"
prot_del_out="$(FAKE_CURL_LOG="$CURL_LOG" HOME="$FIXHOME" PATH="$STUBBIN:$PATH" _registry_delete_one sess_x "Agenthost Direct Claude Remote" 2>&1)"; prot_del_rc=$?
ok  "helper-protects-clauderemote-exit0" "$prot_del_rc" "0"
has "helper-protects-clauderemote-msg"   "$prot_del_out" "skipped(protected)"
hasnt "helper-protects-clauderemote-no-delete-call" "$(cat "$CURL_LOG")" "DELETE"

CURL_LOG="$(mktemp -d)/curl.log"; : > "$CURL_LOG"
unprot_del_out="$(FAKE_CURL_LOG="$CURL_LOG" HOME="$FIXHOME" PATH="$STUBBIN:$PATH" _registry_delete_one sess_y "ah-not-protected-0101-0100" 2>&1)"; unprot_del_rc=$?
ok  "helper-deletes-unprotected-exit0" "$unprot_del_rc" "0"
has "helper-deletes-unprotected-msg"   "$unprot_del_out" "deleted"
has "helper-delete-call-logged" "$(cat "$CURL_LOG")" "DELETE https://api.anthropic.com/v1/sessions/sess_y"

# ── reap: registry cleanup after a successful teardown ────────────────────
if command -v tmux >/dev/null 2>&1; then
  RSTUB="$(mktemp -d)"
  cat > "$RSTUB/systemctl" <<'STUB_EOF'
#!/usr/bin/env bash
exit 0
STUB_EOF
  chmod +x "$RSTUB/systemctl"
  cp "$STUBBIN/curl" "$RSTUB/curl"

  # 1. A live throwaway session whose registry title (base form) has a
  # matching, non-protected entry => reap tears it down AND deletes the
  # registry entry.
  REAPREG="$(mktemp -d)/reap-registry.json"
  python3 - "$REAPREG" <<'PYEOF'
import json, sys, datetime
t = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S')
rows = [{"id": "sess_reapme", "updated_at": t+"Z", "created_at": t+"Z",
         "connection_status": "connected", "session_status": "idle",
         "title": "ah-reaptest-0101-0900"}]
json.dump(rows, open(sys.argv[1], "w"))
PYEOF
  tmux new-session -d -s ah_reaptest-0101-0900 -c "$FIXHOME" 'sleep 60' 2>/dev/null
  CURL_LOG="$(mktemp -d)/curl.log"; : > "$CURL_LOG"
  reap_out="$(FAKE_CURL_LOG="$CURL_LOG" FAKE_REGISTRY_JSON="$REAPREG" PATH="$RSTUB:$PATH" HOME="$FIXHOME" bash "$DOCTOR" reap ah_reaptest-0101-0900 --force 2>&1)"
  tmux kill-session -t ah_reaptest-0101-0900 2>/dev/null || true
  has "reap-still-tears-down"        "$reap_out" "reaped 'ah_reaptest-0101-0900'"
  has "reap-deletes-registry-entry"  "$(cat "$CURL_LOG")" "DELETE https://api.anthropic.com/v1/sessions/sess_reapme"
  has "reap-registry-delete-message" "$reap_out" "sess_reapme"
  hasnt "reap-no-token-leak"         "$reap_out" "$FAKE_TOKEN"

  # 2. --keep-registry => no registry call of any kind for a matching entry.
  tmux new-session -d -s ah_reaptest-0101-0900 -c "$FIXHOME" 'sleep 60' 2>/dev/null
  CURL_LOG="$(mktemp -d)/curl.log"; : > "$CURL_LOG"
  keep_out="$(FAKE_CURL_LOG="$CURL_LOG" FAKE_REGISTRY_JSON="$REAPREG" PATH="$RSTUB:$PATH" HOME="$FIXHOME" bash "$DOCTOR" reap ah_reaptest-0101-0900 --force --keep-registry 2>&1)"
  tmux kill-session -t ah_reaptest-0101-0900 2>/dev/null || true
  has   "reap-keepregistry-still-tears-down" "$keep_out" "reaped 'ah_reaptest-0101-0900'"
  ok    "reap-keepregistry-no-curl-calls"    "$([ -s "$CURL_LOG" ] && echo called || echo none)" "none"

  # 3. Registry unreachable (no credentials at all) => fails soft: reap still
  # reports success (its own exit status), just notes the registry couldn't
  # be reached.
  BADHOME="$(mktemp -d)"
  tmux new-session -d -s ah_reaptest-0101-0900 -c "$FIXHOME" 'sleep 60' 2>/dev/null
  softfail_out="$(PATH="$RSTUB:$PATH" HOME="$BADHOME" bash "$DOCTOR" reap ah_reaptest-0101-0900 --force 2>&1)"; softfail_rc=$?
  tmux kill-session -t ah_reaptest-0101-0900 2>/dev/null || true
  ok  "reap-softfail-exit0"   "$softfail_rc" "0"
  has "reap-softfail-message" "$softfail_out" "reaped 'ah_reaptest-0101-0900'"
  hasnt "reap-softfail-no-traceback" "$softfail_out" "Traceback"

  rm -rf "$RSTUB"
fi

rm -rf "$FIXHOME" "$STUBBIN"
echo "session-doctor-registry-prune: pass=$pass fail=$fail"; [ "$fail" -eq 0 ]
