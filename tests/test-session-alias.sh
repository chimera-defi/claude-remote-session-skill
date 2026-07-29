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
# --no-save resolves (incl. inference) but must NEVER write the store — a --dry-run
# preview must not mutate shared state.
NS_STORE="$(mktemp)"; rm -f "$NS_STORE"
ok "nosave-resolves"  "$(SESSION_ALIAS_STORE="$NS_STORE" bash "$ALIAS" brand-new-long-folder-xyz --no-save)" "bnlfx"
ok "nosave-no-write"  "$([ -f "$NS_STORE" ] && echo exists || echo absent)" "absent"

# ── Anti-poisoning (regression: real corrupt values seen in the live store) ──
# The alias must never itself look like a session name (ah- prefix / MMDD-HHMM /
# trailing -MMDD / long numeric run) — that yields doubled ah-ah-...-MMDD-MMDD names.
notsess(){ printf '%s' "$1" | grep -qE '^ah[-_]|[0-9]{4}-[0-9]{4}|-[0-9]{4}$|-[0-9]{5,}' && echo POISONED || echo clean; }

# READ-PATH guard: a poisoned stored value (from an external writer / manual edit /
# legacy) is discarded on resolution, re-inferred, and self-healed in the store.
PZ="$(mktemp)"
printf 'portfolio-single-source-of-truth\ttranche1-ready-0728\n' > "$PZ"
printf 'discovery-0718\tdiscovery-0718-153051-4107171\n' >> "$PZ"
printf 'ah-universe-expand-0722\tah-universe-expand-0722-194533-425253\n' >> "$PZ"
r1="$(SESSION_ALIAS_STORE="$PZ" bash "$ALIAS" portfolio-single-source-of-truth)"
r2="$(SESSION_ALIAS_STORE="$PZ" bash "$ALIAS" discovery-0718)"
r3="$(SESSION_ALIAS_STORE="$PZ" bash "$ALIAS" ah-universe-expand-0722)"
ok "readguard-1-clean" "$(notsess "$r1")" "clean"
ok "readguard-2-value" "$r2" "discovery"
ok "readguard-3-value" "$r3" "universe-expand"
ok "readguard-selfheal" "$(awk -F'\t' '{print $2}' "$PZ" | while read -r v; do notsess "$v"; done | grep -c POISONED | tr -d ' ')" "0"

# WRITE guard: an explicit --alias that looks like a session name is refused and a
# clean alias inferred + stored instead.
W="$(mktemp)"; rm -f "$W"
ok "aliasguard-return" "$(notsess "$(SESSION_ALIAS_STORE="$W" bash "$ALIAS" myproj --alias ah-rotation-finalize-0725)")" "clean"
ok "aliasguard-store"  "$(notsess "$(awk -F'\t' '$1=="myproj"{print $2}' "$W")")" "clean"

# INFER de-sessionify: a folder that is itself a session name yields a clean alias
# from the meaningful part (no ah-ah- / MMDD-MMDD doubling).
ok "desessionify-folder" "$(SESSION_ALIAS_STORE="$(mktemp -u)" bash "$ALIAS" ah-agent-torque-0721)" "agent-torque"

# Every current legit alias must survive untouched (no false positives).
LS="$(mktemp -u)"
for x in crss portfolio-ssot opt-verify eth2qs-orch sl0 ahbr rc-disconnect ebw wmc srf; do
  ok "legit-survives-$x" "$(SESSION_ALIAS_STORE="$LS" bash "$ALIAS" "$x")" "$x"
done

echo "session-alias: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
