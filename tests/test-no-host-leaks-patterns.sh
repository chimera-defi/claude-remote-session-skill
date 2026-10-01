#!/usr/bin/env bash
# test-no-host-leaks-patterns.sh — positive controls for the generic checks in
# tests/test-no-host-leaks.sh. Builds a throwaway git repo, plants one leak of
# each HARD class (assembled from fragments so THIS file carries no literal
# leak and passes the scanner itself), and asserts the scanner fails on each
# and passes on a clean repo full of legitimate placeholders.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
SCANNER="$HERE/test-no-host-leaks.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# Fake `hostname` so the runtime-identity check is deterministic.
mkdir -p "$TMP/bin"
printf '#!/bin/sh\necho zorblatt\n' > "$TMP/bin/hostname"; chmod +x "$TMP/bin/hostname"

mkrepo() {  # $1 = dir; $2 = file content line
  local d="$1"
  mkdir -p "$d/tests"
  git -C "$d" init -q
  cp "$SCANNER" "$d/tests/test-no-host-leaks.sh"
  cp "$HERE/leak-allowlist.txt" "$d/tests/leak-allowlist.txt"   # scanner source self-matches its own patterns
  printf '%s\n' "$2" > "$d/doc.md"
  git -C "$d" add -A
}
scan() { PATH="$TMP/bin:$PATH" bash "$1/tests/test-no-host-leaks.sh" 2>&1; }
expect_fail() {  # $1 = label, $2 = line
  local d="$TMP/r-$1"; mkrepo "$d" "$2"
  scan "$d" >/dev/null; ok "fails-on-$1" "$?" "1"
}
expect_pass() {
  local d="$TMP/p-$1"; mkrepo "$d" "$2"
  scan "$d" >/dev/null; ok "passes-on-$1" "$?" "0"
}

S=/; H="${S}home${S}"
D1=0; D2=9   # digits for the secret-shaped bodies
body="abcdefghijklmnopqrstuvwxyz$D1$D2"

expect_fail bare-home-no-slash   "see ${H}realperson for details"
expect_fail slash-home           "cd ${H}realperson${S}work"
expect_fail openai-key           "key is sk-${body}"
expect_fail github-token         "tok gh""p_${body}"
expect_fail slack-token          "tok xo""xb-1234567890-abcdefghij"
expect_fail eth-address          "addr 0""x$(printf 'a%.0s' $(seq 40))"
expect_fail aws-key              "id AK""IA$(printf 'A%.0s' $(seq 16))"
expect_fail jwt                  "jwt ey""JhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkw.sig"
expect_fail bearer-literal       "Authorization: Bear""er ${body}"
expect_fail quoted-api-key       "api_key = \"${body}${body}\""
expect_fail bus-seq              "landed, bus se""q 1234"
expect_fail scope-claim          "post a scope_""claim first"
expect_fail operator-ruling      "Operator dir""ective, 2026-01-01"
expect_fail session-name         "see zz-mything-03""15-1200 running"
expect_fail worktree-stamp       "worktree mything-202603""15-1200"
expect_fail own-hostname         "runs on zorblatt today"

expect_pass clean-placeholders   "$(printf '%s\n' \
  "paths ${H}youruser${S} ${H}youruser ${H}user ${H}me and ${H}<name>" \
  "tok=\$tok; curl -H \"Authorization: Bearer \$tok\"; api_key = \"\$KEY\"; token = \"<your-token-here>\"" \
  "token = \"your-token-here\" and api_key = \"local-development-key\" and Bearer REPLACE_WITH_YOUR_TOKEN_HERE" \
  "TOKEN=\"FAKE-TOKEN-not-real-1234567890\" and sk-dry-run-still-resolves" \
  "session <prefix>-<alias>-<MMDD-HHMM> and fixture px-foo-0101-0100 and px-foo-MMDD-xxxx" \
  "WARN-tier only: this host, broker, ~/backups")"

# WARN tier must print but not fail.
d="$TMP/w"; mkrepo "$d" "on this host the broker ran"
out="$(scan "$d")"; rc=$?
ok "warn-tier-nonfatal" "$rc" "0"
ok "warn-tier-printed" "$(printf '%s' "$out" | grep -c '^WARN:')" "2"

finish "no-host-leaks patterns"
