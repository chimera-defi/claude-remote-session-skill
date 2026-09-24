#!/usr/bin/env bash
# Tests for session-doctor.sh's registry_json() pagination.
#
# Bug (2026-09-24): registry_json() fetched only the FIRST page of
# GET https://api.anthropic.com/v1/sessions. Live-API evidence: a bare GET
# returns {data, first_id, has_more, last_id}; has_more=true once the
# registry holds more than one page (page size 200 in production, confirmed
# by a live two-page walk with after_id=<last_id> — zero id overlap between
# pages, has_more flips to false once exhausted). Because registry_json()
# never followed has_more/after_id, registry-stale, registry-prune, report's
# registry summary, and reap's title lookup all silently saw only the first
# page — this is what made `registry-prune --apply` need 6 repeated passes
# to exhaust a real stale backlog.
#
# This test stubs curl to serve exactly 2 pages (page 1: has_more=true +
# last_id; page 2, requested via ?after_id=<page1 last_id>: has_more=false)
# and asserts that BOTH pages' stale entries surface via `registry-stale`.
# Talks only to a fake curl on $PATH — never the real registry.
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

# ── page fixtures: 2 pages, disjoint ids, page1.has_more=true + last_id
# pointing at the id that must appear as ?after_id=<id> on the next GET;
# page2.has_more=false so a correct implementation stops after 2 calls.
PAGEDIR="$(mktemp -d)"
cat > "$PAGEDIR/page1.json" <<'EOF'
{"first_id":"sess_p1_stale","has_more":true,"last_id":"sess_p1_last",
 "data":[
   {"id":"sess_p1_stale","updated_at":"2020-01-01T00:00:00Z","created_at":"2020-01-01T00:00:00Z","connection_status":"disconnected","session_status":"idle","title":"ah-p1-stale-0101-0100"},
   {"id":"sess_p1_last","updated_at":"2026-09-20T00:00:00Z","created_at":"2026-09-20T00:00:00Z","connection_status":"disconnected","session_status":"idle","title":"ah-p1-fresh-0101-0100"}
 ]}
EOF
cat > "$PAGEDIR/page2.json" <<'EOF'
{"first_id":"sess_p2_stale","has_more":false,"last_id":"sess_p2_stale",
 "data":[
   {"id":"sess_p2_stale","updated_at":"2020-01-01T00:00:00Z","created_at":"2020-01-01T00:00:00Z","connection_status":"disconnected","session_status":"idle","title":"ah-p2-stale-0101-0100"}
 ]}
EOF
# ages above are far in the past (well beyond any --days window) so both
# stale rows are unambiguous candidates regardless of "now" at test time.

# ── fake curl: logs "METHOD URL" per call to $FAKE_CURL_LOG; a GET whose URL
# contains "after_id=sess_p1_last" gets page2, any other GET gets page1. A
# GET with an unrecognized after_id (implementation bug) gets an empty page
# so a broken loop degrades to "missing data" rather than looping forever.
# Must honor -o <file> (registry_json() writes each page to a file, unlike
# a plain unredirected curl call) — write the body there, not to stdout.
STUBBIN="$(mktemp -d)"
cat > "$STUBBIN/curl" <<STUB_EOF
#!/usr/bin/env bash
set -u
url="" outfile=""
args=("\$@"); i=0
while [ "\$i" -lt "\${#args[@]}" ]; do
  a="\${args[\$i]}"
  case "\$a" in
    -o) i=\$((i+1)); outfile="\${args[\$i]}" ;;
    http*) url="\$a" ;;
  esac
  i=\$((i+1))
done
[ -n "\${FAKE_CURL_LOG:-}" ] && printf 'GET %s\n' "\$url" >> "\$FAKE_CURL_LOG"
body() {
  case "\$url" in
    *after_id=sess_p1_last*) cat "$PAGEDIR/page2.json" ;;
    *after_id=*) echo '{"data":[],"has_more":false}' ;;
    *) cat "$PAGEDIR/page1.json" ;;
  esac
}
if [ -n "\$outfile" ]; then body > "\$outfile"; else body; fi
STUB_EOF
chmod +x "$STUBBIN/curl"

CURL_LOG="$(mktemp -d)/curl.log"; : > "$CURL_LOG"
out="$(FAKE_CURL_LOG="$CURL_LOG" PATH="$STUBBIN:$PATH" HOME="$FIXHOME" bash "$DOCTOR" registry-stale 2>&1)"

has  "page1-stale-entry-present" "$out" "sess_p1_stale"
has  "page2-stale-entry-present" "$out" "sess_p2_stale"
has  "second-curl-call-made"     "$(cat "$CURL_LOG")" "after_id=sess_p1_last"
hasnt "no-token-leak"            "$out" "$FAKE_TOKEN"

# ── registry_json() directly: merged output must carry both pages' entries
# and stay in the {sessions|data: [...]}-or-bare-list shape every caller
# already parses (arr=arr if isinstance(arr,list) else arr.get('sessions',
# arr.get('data',[]))).
json_out="$(FAKE_CURL_LOG="$CURL_LOG" PATH="$STUBBIN:$PATH" HOME="$FIXHOME" registry_json)"
count="$(printf '%s' "$json_out" | python3 -c "
import json,sys
d=json.load(sys.stdin)
arr=d if isinstance(d,list) else d.get('sessions',d.get('data',[]))
print(len(arr))
" 2>/dev/null)"
ok "registry_json-merges-both-pages-count" "$count" "3"

rm -rf "$STUBBIN" "$PAGEDIR"

# ── MAX_PAGES hard cap: an adversarial/malformed registry that always
# answers has_more:true must not loop forever. Each GET returns exactly one
# new entry and a fresh last_id, so a correctly-capped registry_json() stops
# at exactly MAX_PAGES (50) calls/entries instead of hanging or growing
# without bound.
CAPSTUB="$(mktemp -d)"
CAPCOUNTER="$(mktemp -d)/counter"; echo 0 > "$CAPCOUNTER"
cat > "$CAPSTUB/curl" <<STUB_EOF
#!/usr/bin/env bash
set -u
outfile=""
args=("\$@"); i=0
while [ "\$i" -lt "\${#args[@]}" ]; do
  a="\${args[\$i]}"
  case "\$a" in -o) i=\$((i+1)); outfile="\${args[\$i]}" ;; esac
  i=\$((i+1))
done
n=\$(( \$(cat "$CAPCOUNTER") + 1 )); echo "\$n" > "$CAPCOUNTER"
[ -n "\${FAKE_CURL_LOG:-}" ] && echo GET >> "\${FAKE_CURL_LOG}"
body="{\"data\":[{\"id\":\"sess_inf_\$n\",\"updated_at\":\"2020-01-01T00:00:00Z\",\"connection_status\":\"disconnected\",\"session_status\":\"idle\",\"title\":\"ah-inf-\$n\"}],\"has_more\":true,\"last_id\":\"sess_inf_\$n\"}"
if [ -n "\$outfile" ]; then printf '%s' "\$body" > "\$outfile"; else printf '%s' "\$body"; fi
STUB_EOF
chmod +x "$CAPSTUB/curl"
CAPLOG="$(mktemp -d)/curl.log"; : > "$CAPLOG"
cap_out="$(timeout 30 env FAKE_CURL_LOG="$CAPLOG" PATH="$CAPSTUB:$PATH" HOME="$FIXHOME" bash -c 'source "'"$DOCTOR"'"; registry_json' 2>&1)"; cap_rc=$?
ok "maxpages-completes-without-hanging" "$cap_rc" "0"
ok "maxpages-stops-at-exactly-50-calls" "$(wc -l < "$CAPLOG" | tr -d ' ')" "50"
cap_count="$(printf '%s' "$cap_out" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(len(d if isinstance(d,list) else d.get('sessions',d.get('data',[]))))
except Exception:
    print('PARSE_ERROR')
" 2>/dev/null)"
ok "maxpages-returns-collected-50-entries" "$cap_count" "50"
rm -rf "$CAPSTUB"

# ── page 2+ fetch/parse failure: registry_json() must not discard page 1's
# already-fetched entries just because a later page came back empty/broken —
# it returns everything successfully collected rather than erroring the
# whole call (only a page-1 failure is total, matching credentials-missing
# behavior above).
PF_PAGEDIR="$(mktemp -d)"
cat > "$PF_PAGEDIR/page1.json" <<'EOF'
{"first_id":"sess_pf1_a","has_more":true,"last_id":"sess_pf1_a",
 "data":[{"id":"sess_pf1_a","updated_at":"2020-01-01T00:00:00Z","connection_status":"disconnected","session_status":"idle","title":"ah-pf1-a"}]}
EOF
PFSTUB="$(mktemp -d)"
cat > "$PFSTUB/curl" <<STUB_EOF
#!/usr/bin/env bash
set -u
url="" outfile=""
args=("\$@"); i=0
while [ "\$i" -lt "\${#args[@]}" ]; do
  a="\${args[\$i]}"
  case "\$a" in
    -o) i=\$((i+1)); outfile="\${args[\$i]}" ;;
    http*) url="\$a" ;;
  esac
  i=\$((i+1))
done
case "\$url" in
  *after_id=sess_pf1_a*) content="" ;;  # simulated page-2 fetch failure: empty body
  *) content="\$(cat "$PF_PAGEDIR/page1.json")" ;;
esac
if [ -n "\$outfile" ]; then printf '%s' "\$content" > "\$outfile"; else printf '%s' "\$content"; fi
STUB_EOF
chmod +x "$PFSTUB/curl"
pf_out="$(PATH="$PFSTUB:$PATH" HOME="$FIXHOME" bash -c 'source "'"$DOCTOR"'"; registry_json')"; pf_rc=$?
ok "page2fail-registry_json-still-succeeds" "$pf_rc" "0"
has "page2fail-keeps-page1-entry" "$pf_out" "sess_pf1_a"
rm -rf "$PFSTUB" "$PF_PAGEDIR"

rm -rf "$FIXHOME"
echo "session-doctor-registry-pagination: pass=$pass fail=$fail"; [ "$fail" -eq 0 ]
