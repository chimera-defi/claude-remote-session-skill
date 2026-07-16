#!/usr/bin/env bash
# Plain-bash assertions for session-alias. No external test framework.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ALIAS="$HERE/../scripts/session-alias.sh"
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }

STORE="$(mktemp)"; rm -f "$STORE"; export SESSION_ALIAS_STORE="$STORE"

# short folder (<=18) passes through unchanged
ok "short-passthrough" "$(bash "$ALIAS" eth2-quickstart)" "eth2-quickstart"
# long folder -> initials acronym
ok "long-acronym" "$(bash "$ALIAS" some-very-long-project-name)" "svlpn"
# ALIAS_PROTECT is narrower than session-doctor's reap PROTECT: a folder that
# merely contains "claude-remote" (this repo) is NOT alias-protected — it is a
# normal dev session and SHOULD shorten. Locks in that claude-remote-session-skill
# aliases to its acronym rather than passing through unaliased.
ok "claude-remote-substring-aliases" "$(bash "$ALIAS" claude-remote-session-skill)" "crss"
# explicit --alias overrides and is sanitized
ok "explicit-alias" "$(bash "$ALIAS" some-thing --alias 'My Alias!')" "my-alias"
# stored alias is reused on the next call (no re-inference)
bash "$ALIAS" a-very-long-folder-name-here --alias keep >/dev/null
ok "store-hit" "$(bash "$ALIAS" a-very-long-folder-name-here)" "keep"
# protected folder is never aliased (token must survive), and not stored
ok "protected-passthrough" "$(bash "$ALIAS" openclaw-autoresearch)" "openclaw-autoresearch"
ok "protected-not-stored" "$(awk -F'\t' '$1=="openclaw-autoresearch"' "$STORE" | wc -l | tr -d ' ')" "0"
# --alias on a protected folder is ignored (still keeps identity token)
ok "protected-ignores-alias" "$(bash "$ALIAS" openclaw-autoresearch --alias oa)" "openclaw-autoresearch"
# a folder name that normalizes to nothing (symbols-only, > CAP chars) must
# never produce an empty alias — found via independent review (devin-delegate):
# an empty alias would flow into a malformed tmux/systemd name like
# "ah-0715-0630-" (dangling separator).
long_symbolic='@@@@@@@@@@@@@@@@@@@@'
out="$(bash "$ALIAS" "$long_symbolic")"
ok "empty-normalize-nonempty" "$([ -n "$out" ] && echo yes || echo no)" "yes"
ok "empty-normalize-safe-charset" "$(printf '%s' "$out" | grep -qE '^[a-z0-9-]+$' && echo yes || echo no)" "yes"

echo "session-alias: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
