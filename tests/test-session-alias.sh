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
# stored alias is reused on the next call (no re-inference). NB the stored entry
# is established with --set-default: a bare --alias is per-spawn and deliberately
# does NOT persist any more (see the per-spawn block at the end of this file).
bash "$ALIAS" a-very-long-folder-name-here --alias keep --set-default >/dev/null
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

# Single-long-numeric-run false positives (found in review: a lone trailing
# 5+-digit group was treated as a poisoned timestamp/random suffix regardless
# of context, colliding distinct folders onto the same alias exactly like the
# MMDD false positives above — e.g. issue-12345/issue-67890 both -> "issue").
# A long numeric run only poisons when it's part of a 2+-group numeric tail
# (the real legacy shape: name-MMDD-HHMMSS-RANDOM).
FP3="$(mktemp -u)"
ok "not-longrun-issue-id"  "$(SESSION_ALIAS_STORE="$FP3" bash "$ALIAS" issue-12345)" "issue-12345"
ok "not-longrun-ticket-id" "$(SESSION_ALIAS_STORE="$FP3" bash "$ALIAS" ticket-99999)" "ticket-99999"
ok "not-longrun-build-id"  "$(SESSION_ALIAS_STORE="$FP3" bash "$ALIAS" build-100000)" "build-100000"
# A genuine multi-group timestamp+random tail (real production fixture, no
# ah- prefix so it relies solely on the long-numeric-run check) still poisons.
ok "real-longrun-still-caught" "$(SESSION_ALIAS_STORE="$(mktemp -u)" bash "$ALIAS" discovery-0718-153051-4107171)" "discovery"

# Two-group false positives (found in review: the [0-9]{4}-[0-9]{4} fast path
# accepted ANY two adjacent 4-digit runs as an MMDD-HHMM timestamp, not just a
# real date+time — e.g. sprint-2024-2025 / port-8080-9090 both still collided).
FP2="$(mktemp -u)"
ok "not-mmdd-hhmm-year-range" "$(SESSION_ALIAS_STORE="$FP2" bash "$ALIAS" sprint-2024-2025)" "sprint-2024-2025"
ok "not-mmdd-hhmm-port-pair"  "$(SESSION_ALIAS_STORE="$FP2" bash "$ALIAS" port-8080-9090)" "port-8080-9090"
# A genuine MMDD-HHMM pair (real date + real time) is still caught.
ok "real-mmdd-hhmm-still-caught" "$(SESSION_ALIAS_STORE="$(mktemp -u)" bash "$ALIAS" foo-0715-0630)" "foo"

# 5-digit numeric-run false positives (chain ids, zip codes, and ephemeral
# ports (49152-65535) are all commonly 5 digits and must not collide onto the
# same alias, same bug class as the 4-digit cases above — already covered by
# the has_mmdd_group() gate below, not by a digit-count floor).
FP3c="$(mktemp -u)"
ok "not-longnum-chainid-5digit" "$(SESSION_ALIAS_STORE="$FP3c" bash "$ALIAS" chain-84532)" "chain-84532"
ok "not-longnum-zip"            "$(SESSION_ALIAS_STORE="$FP3c" bash "$ALIAS" client-90210)" "client-90210"
ok "not-longnum-ephemeral-port" "$(SESSION_ALIAS_STORE="$FP3c" bash "$ALIAS" port-49152)" "port-49152"
# Distinct 5-digit-suffixed folders must alias distinctly, not collide.
ok "not-longnum-chainid-distinct" "$(SESSION_ALIAS_STORE="$FP3c" bash "$ALIAS" chain-42161)" "chain-42161"

# Long-numeric-run false positives (found live: the un-gated `-[0-9]{5,}` check
# treated ANY trailing run of 5+ digits as timestamp/random-suffix evidence,
# not just one paired with a real date — e.g. port-12345/port-54321 both
# collided onto "port", same bug class as the sprint-2024/sprint-2025 fix
# above but for 5+ digit runs instead of 4).
FP3b="$(mktemp -u)"
ok "not-longrun-port"    "$(SESSION_ALIAS_STORE="$FP3b" bash "$ALIAS" port-12345)" "port-12345"
ok "not-longrun-port-2"  "$(SESSION_ALIAS_STORE="$FP3b" bash "$ALIAS" port-54321)" "port-54321"
ok "not-longrun-client"  "$(SESSION_ALIAS_STORE="$FP3b" bash "$ALIAS" client-99999)" "client-99999"
ok "not-longrun-invoice" "$(SESSION_ALIAS_STORE="$FP3b" bash "$ALIAS" invoice-123456)" "invoice-123456"
# A long numeric run PAIRED with a real MMDD date fragment elsewhere in the
# string is still caught (the legacy shape this check exists to catch, e.g.
# discovery-0718-153051-4107171 above).
ok "real-longrun-still-caught-2" "$(SESSION_ALIAS_STORE="$(mktemp -u)" bash "$ALIAS" release-0715-123456)" "release"

# Found in review (chatgpt-codex-connector, PR #22): an invalid digit pair
# BEFORE a real embedded timestamp must not let the real pair slide through.
# `[0-9]{4}-[0-9]{4}` matches non-overlapping left-to-right, so a stored value
# like "project-2024-2025-0715-2359" yields TWO pairs: "2024-2025" (fails date
# validation) and "0715-2359" (a real MMDD-HHMM). Only checking the first match
# (`head -1`, the pre-fix behavior) stops at the invalid pair and never
# inspects the genuinely poisoned one that follows, so the whole value reads
# as "clean" and gets embedded verbatim into the next generated session name.
# Every matched pair must be checked; catching this needs the READ-PATH guard
# (a poisoned stored value discarded + self-healed on lookup), not desessionify.
PZ2="$(mktemp)"
printf 'multipair-proj\tproject-2024-2025-0715-2359\n' > "$PZ2"
r4="$(SESSION_ALIAS_STORE="$PZ2" bash "$ALIAS" multipair-proj)"
ok "readguard-multipair-caught" "$r4" "multipair-proj"
ok "readguard-multipair-clean"  "$(notsess "$r4")" "clean"

# Multi-candidate scan (found via review: `head -1` on the first matched pair
# let a real MMDD-HHMM slip through when an invalid-as-date pair, like a year
# range, appeared earlier in the string and the scan stopped there instead of
# examining every candidate). Different fixture than the multipair-proj case
# above (three digit-pairs instead of two), extra coverage for the same fix.
MP="$(mktemp)"
printf 'somefolder\trelease-2024-2025-x-0715-0630-copy\n' > "$MP"
mp_out="$(SESSION_ALIAS_STORE="$MP" bash "$ALIAS" somefolder)"
ok "multi-pair-readguard-clean" "$(notsess "$mp_out")" "clean"
ok "multi-pair-readguard-selfheal" "$(awk -F'\t' '$1=="somefolder"{print $2}' "$MP")" "$mp_out"

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

# CASE-INSENSITIVITY guard: looks_like_session_name's ah-/ah_ prefix check must
# catch mixed/upper-case values too, not just lowercase. The store is
# documented as user-editable and this is also the read-path guard for values
# from an external writer, so a hand-typed `AH-foo-bar` (no embedded date, so
# none of the digit checks would catch it either) must not silently survive as
# a stored alias — found via targeted probing of the read path.
CI="$(mktemp)"
printf 'myproj\tAH-foo-bar\n' > "$CI"
ci_out="$(SESSION_ALIAS_STORE="$CI" bash "$ALIAS" myproj)"
ok "caseinsens-readguard-caught"    "$(notsess "$ci_out")" "clean"
ok "caseinsens-readguard-selfheal"  "$(awk -F'\t' '$1=="myproj"{print $2}' "$CI")" "$ci_out"

# CASE-INSENSITIVITY, infer(): a folder whose own name carries an uppercase
# `AH-` prefix + a real embedded date must still desessionify down to the
# meaningful part (like the lowercase `ah-agent-torque-0721` case above),
# not fall back to an opaque checksum alias because desessionify's prefix
# strip couldn't match the uppercase prefix.
ok "caseinsens-infer-desessionify" "$(SESSION_ALIAS_STORE="$(mktemp -u)" bash "$ALIAS" "AH-project-0810-1234")" "project"

# Every current legit alias must survive untouched (no false positives).
LS="$(mktemp -u)"
for x in crss portfolio-ssot opt-verify eth2qs-orch sl0 ahbr rc-disconnect ebw wmc srf; do
  ok "legit-survives-$x" "$(SESSION_ALIAS_STORE="$LS" bash "$ALIAS" "$x")" "$x"
done

# ── --alias is PER-SPAWN: it must not mutate the folder's stored default ──────
# The dominant real-world drift: `--alias` names the TASK, not the folder, but it
# used to persist unconditionally, so a single spawn renamed the folder forever
# and every later bare `new-session <folder>` inherited a name describing work
# that finished weeks ago. Two audits found 11-of-37 and 11-of-42 entries
# drifted and every single one was this shape -- none were collisions. The
# operator cleared all 11 and asked for the leak itself to be closed
# (2026-09-03), so the common case is now non-destructive and persisting is an
# explicit opt-in via --set-default.
PS="$(mktemp -u)"
# No stored entry yet: --alias resolves for this spawn and stores NOTHING.
ok "per-spawn-alias-returns-value" \
  "$(SESSION_ALIAS_STORE="$PS" bash "$ALIAS" my-long-project-folder --alias taskname)" "taskname"
ok "per-spawn-alias-creates-no-entry" \
  "$([ -f "$PS" ] && echo exists || echo absent)" "absent"
# With a stored default: --alias overrides for this spawn but must not overwrite.
printf 'stable-folder\tstable\n' > "$PS"
ok "per-spawn-alias-overrides-for-this-spawn" \
  "$(SESSION_ALIAS_STORE="$PS" bash "$ALIAS" stable-folder --alias throwaway)" "throwaway"
ok "per-spawn-alias-leaves-default-intact" \
  "$(awk -F'\t' '$1=="stable-folder"{print $2}' "$PS")" "stable"
ok "bare-resolve-still-returns-default" \
  "$(SESSION_ALIAS_STORE="$PS" bash "$ALIAS" stable-folder)" "stable"
# --set-default is the explicit opt-in that DOES persist.
ok "set-default-returns-value" \
  "$(SESSION_ALIAS_STORE="$PS" bash "$ALIAS" stable-folder --alias renamed --set-default)" "renamed"
ok "set-default-persists" \
  "$(awk -F'\t' '$1=="stable-folder"{print $2}' "$PS")" "renamed"
ok "bare-resolve-after-set-default" \
  "$(SESSION_ALIAS_STORE="$PS" bash "$ALIAS" stable-folder)" "renamed"
# Opting in must not be a way to smuggle a poisoned default past the guard: the
# anti-poisoning check runs BEFORE the persist decision.
pz_out="$(SESSION_ALIAS_STORE="$PS" bash "$ALIAS" poison-folder --alias ah-x-0722-0725 --set-default 2>/dev/null)"
ok "set-default-rejects-poisoned"      "$(notsess "$pz_out")" "clean"
ok "set-default-poisoned-not-verbatim" "$(grep -cF 'ah-x-0722-0725' "$PS" 2>/dev/null; true)" "0"
# Inference still persists -- that is a deterministic cache, not drift.
PS2="$(mktemp -u)"
inf_out="$(SESSION_ALIAS_STORE="$PS2" bash "$ALIAS" some-very-long-project-name)"
ok "inference-still-persists" \
  "$(awk -F'\t' '$1=="some-very-long-project-name"{print $2}' "$PS2")" "$inf_out"
rm -f "$PS" "$PS2"

echo "session-alias: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
