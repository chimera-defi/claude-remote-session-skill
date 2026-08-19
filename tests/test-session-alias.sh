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

# INFER de-sessionify is a FIXED POINT, not a single pass: a folder poisoned more
# than one layer deep (e.g. `ah-ah-x-0722-0725` — literally the doubled name a
# prior poisoning incident produces) must still yield a clean, non-`ah-`-prefixed
# alias. A single-pass strip would leave `ah-universe-expand` (still session-name-
# shaped), which store_upsert then refuses to persist — so the poisoned value is
# never self-healed and keeps re-doubling on every future spawn.
DP="$(mktemp -u)"
dp_out="$(SESSION_ALIAS_STORE="$DP" bash "$ALIAS" ah-ah-universe-expand-0722-0725)"
ok "layered-poison-value" "$dp_out" "universe-expand"
ok "layered-poison-clean" "$(notsess "$dp_out")" "clean"
ok "layered-poison-stored" "$(awk -F'\t' '$1=="ah-ah-universe-expand-0722-0725"{print $2}' "$DP")" "universe-expand"

# Trailing-4-digit false positives (regression: a folder ending in a plain
# 4-digit number that is NOT a calendar date must alias as-is, not get treated
# as a poisoned MMDD fragment and stripped — that silently collided distinct
# folders onto the same alias, e.g. sprint-2024/sprint-2025 both -> "sprint").
FP="$(mktemp -u)"
ok "not-mmdd-year-2024"   "$(SESSION_ALIAS_STORE="$FP" bash "$ALIAS" sprint-2024)" "sprint-2024"
ok "not-mmdd-year-2025"   "$(SESSION_ALIAS_STORE="$FP" bash "$ALIAS" sprint-2025)" "sprint-2025"
ok "not-mmdd-chainid"     "$(SESSION_ALIAS_STORE="$FP" bash "$ALIAS" chain-8453)" "chain-8453"
ok "not-mmdd-port"        "$(SESSION_ALIAS_STORE="$FP" bash "$ALIAS" port-8080)" "port-8080"
ok "not-mmdd-bad-day"     "$(SESSION_ALIAS_STORE="$FP" bash "$ALIAS" client-1042)" "client-1042"
# But a genuine MMDD-shaped trailing date (real production fixture) still poisons.
ok "real-mmdd-still-caught" "$(SESSION_ALIAS_STORE="$(mktemp -u)" bash "$ALIAS" tranche1-ready-0728)" "tranche1-ready"

# Two-group false positives (found in review: the [0-9]{4}-[0-9]{4} fast path
# accepted ANY two adjacent 4-digit runs as an MMDD-HHMM timestamp, not just a
# real date+time — e.g. sprint-2024-2025 / port-8080-9090 both still collided).
FP2="$(mktemp -u)"
ok "not-mmdd-hhmm-year-range" "$(SESSION_ALIAS_STORE="$FP2" bash "$ALIAS" sprint-2024-2025)" "sprint-2024-2025"
ok "not-mmdd-hhmm-port-pair"  "$(SESSION_ALIAS_STORE="$FP2" bash "$ALIAS" port-8080-9090)" "port-8080-9090"
# A genuine MMDD-HHMM pair (real date + real time) is still caught.
ok "real-mmdd-hhmm-still-caught" "$(SESSION_ALIAS_STORE="$(mktemp -u)" bash "$ALIAS" foo-0715-0630)" "foo"

# --audit-store: read-only report of stored entries where fresh inference now
# disagrees with what's stored (e.g. collapsed by the pre-fix inference bug).
# Must NOT mutate the store — a human decides what to do with drift.
AS="$(mktemp)"
printf 'sprint-2024\tsprint\n' > "$AS"
printf 'sprint-2025\tsprint\n' >> "$AS"
printf 'crss\tcrss\n' >> "$AS"
audit_out="$(SESSION_ALIAS_STORE="$AS" bash "$ALIAS" --audit-store)"
ok "audit-finds-drift-1" "$(printf '%s' "$audit_out" | grep -c "folder='sprint-2024'")" "1"
ok "audit-finds-drift-2" "$(printf '%s' "$audit_out" | grep -c "folder='sprint-2025'")" "1"
ok "audit-no-drift-for-legit" "$(printf '%s' "$audit_out" | grep -c "folder='crss'")" "0"
ok "audit-does-not-mutate" "$(cat "$AS")" "$(printf 'sprint-2024\tsprint\nsprint-2025\tsprint\ncrss\tcrss')"

# FOLDER-KEY guard: a folder name containing a literal tab/newline must never
# be persisted as a store key — it would split into extra TSV fields/lines
# and corrupt the store for every entry sharing the file (found via targeted
# fuzzing of store_upsert's untrusted $1, not from a live incident).
TK="$(mktemp -u)"
tabfolder=$'weird\tfolder'
out_tab="$(SESSION_ALIAS_STORE="$TK" bash "$ALIAS" "$tabfolder" 2>/dev/null)"
ok "tabkey-resolves"     "$([ -n "$out_tab" ] && echo yes || echo no)" "yes"
ok "tabkey-not-persisted" "$([ -f "$TK" ] && echo exists || echo absent)" "absent"

NK="$(mktemp -u)"
nlfolder=$'weird\nfolder'
out_nl="$(SESSION_ALIAS_STORE="$NK" bash "$ALIAS" "$nlfolder" 2>/dev/null)"
ok "newlinekey-resolves"     "$([ -n "$out_nl" ] && echo yes || echo no)" "yes"
ok "newlinekey-not-persisted" "$([ -f "$NK" ] && echo exists || echo absent)" "absent"

# Every current legit alias must survive untouched (no false positives).
LS="$(mktemp -u)"
for x in crss portfolio-ssot opt-verify eth2qs-orch sl0 ahbr rc-disconnect ebw wmc srf; do
  ok "legit-survives-$x" "$(SESSION_ALIAS_STORE="$LS" bash "$ALIAS" "$x")" "$x"
done

echo "session-alias: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
