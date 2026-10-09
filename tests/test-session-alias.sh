#!/usr/bin/env bash
# session-alias: inference, store, anti-poisoning guards, per-spawn --alias.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
ALIAS="$HERE/../scripts/session-alias.sh"

STORE="$(mktemp)"; rm -f "$STORE"; export SESSION_ALIAS_STORE="$STORE"
isolate_overlay
# Fixture shape: configured prefix "px", legacy "oldhost".
export CRSS_SESSION_PREFIX=px
export CRSS_LEGACY_PREFIXES=oldhost

# short folder (<=18) passes through unchanged
ok "short-passthrough" "$(bash "$ALIAS" widget-tracker)" "widget-tracker"
# long folder -> initials acronym
ok "long-acronym" "$(bash "$ALIAS" some-very-long-project-name)" "svlpn"
# ALIAS_PROTECT is narrower than session-doctor's PROTECT: a folder merely containing "claude-remote" shortens normally.
# explicit --alias overrides and is sanitized
ok "explicit-alias" "$(bash "$ALIAS" some-thing --alias 'My Alias!')" "my-alias"
# stored alias is reused (no re-inference); established via --set-default since a bare --alias is per-spawn
bash "$ALIAS" a-very-long-folder-name-here --alias keep --set-default >/dev/null
ok "store-hit" "$(bash "$ALIAS" a-very-long-folder-name-here)" "keep"
# protected folder is never aliased nor stored; ALIAS_PROTECT defaults to empty, so set it via CRSS_ALIAS_PROTECT_NAMES
ok "protected-passthrough" "$(CRSS_ALIAS_PROTECT_NAMES='otherbot|thirdbot' bash "$ALIAS" otherbot-autoresearch)" "otherbot-autoresearch"
ok "protected-not-stored" "$(awk -F'\t' '$1=="otherbot-autoresearch"' "$STORE" | wc -l | tr -d ' ')" "0"
# --alias on a protected folder is ignored (still keeps identity token)
ok "protected-ignores-alias" "$(CRSS_ALIAS_PROTECT_NAMES='otherbot|thirdbot' bash "$ALIAS" otherbot-autoresearch --alias oa)" "otherbot-autoresearch"
# with no overlay (generic default) the same folder is NOT protected
ok "unprotected-by-default" "$(bash "$ALIAS" otherbot-autoresearch --alias oa2)" "oa2"
# --no-save resolves (incl. inference) but must NEVER write the store (a --dry-run must not mutate state)
NS_STORE="$(mktemp)"; rm -f "$NS_STORE"
ok "nosave-resolves"  "$(SESSION_ALIAS_STORE="$NS_STORE" bash "$ALIAS" brand-new-long-folder-xyz --no-save)" "bnlfx"
ok "nosave-no-write"  "$([ -f "$NS_STORE" ] && echo exists || echo absent)" "absent"

# ── Anti-poisoning (real corrupt values seen in the live store) ──
# An alias must never look like a session name (px- prefix / MMDD-HHMM / trailing -MMDD / long numeric run).
notsess(){ grep -qiE '^px[-_]|[0-9]{4}-[0-9]{4}|-[0-9]{4}$|-[0-9]{5,}' <<<"$1" && echo POISONED || echo clean; }

# READ-PATH guard: a poisoned stored value is discarded, re-inferred, and self-healed in the store.
PZ="$(mktemp)"
printf 'my-example-long-project-name\ttranche1-ready-0728\n' > "$PZ"
printf 'discovery-0718\tdiscovery-0718-153051-4107171\n' >> "$PZ"
printf 'px-demo-project-0722\tpx-demo-project-0722-194533-425253\n' >> "$PZ"
r1="$(SESSION_ALIAS_STORE="$PZ" bash "$ALIAS" my-example-long-project-name)"
r2="$(SESSION_ALIAS_STORE="$PZ" bash "$ALIAS" discovery-0718)"
r3="$(SESSION_ALIAS_STORE="$PZ" bash "$ALIAS" px-demo-project-0722)"
ok "readguard-1-clean" "$(notsess "$r1")" "clean"
ok "readguard-2-value" "$r2" "discovery"
ok "readguard-3-value" "$r3" "demo-project"
ok "readguard-selfheal" "$(awk -F'\t' '{print $2}' "$PZ" | while read -r v; do notsess "$v"; done | grep -c POISONED | tr -d ' ')" "0"

# WRITE guard: an explicit --alias that looks like a session name is refused; a clean one is inferred and stored.
# --set-default is required, else the store is never created and the assertion would pass vacuously.
W="$(mktemp)"; rm -f "$W"
ok "aliasguard-return" "$(notsess "$(SESSION_ALIAS_STORE="$W" bash "$ALIAS" myproj --alias px-batch-cleanup-0725 --set-default)")" "clean"
ok "aliasguard-store"  "$(notsess "$(awk -F'\t' '$1=="myproj"{print $2}' "$W")")" "clean"

# INFER de-sessionify: a session-name folder yields a clean alias (no px-px- / MMDD-MMDD doubling).
ok "desessionify-folder" "$(SESSION_ALIAS_STORE="$(mktemp -u)" bash "$ALIAS" px-widget-build-0721)" "widget-build"

# de-sessionify is a FIXED POINT: `px-px-x-0101-0725` (doubled name from a prior poisoning) must not leave a `px-`-prefixed
# alias, else store_upsert refuses it and it re-doubles every spawn.
DP="$(mktemp -u)"
dp_out="$(SESSION_ALIAS_STORE="$DP" bash "$ALIAS" px-px-demo-project-0101-0725)"
ok "layered-poison-value" "$dp_out" "demo-project"
ok "layered-poison-clean" "$(notsess "$dp_out")" "clean"
ok "layered-poison-stored" "$(awk -F'\t' '$1=="px-px-demo-project-0101-0725"{print $2}' "$DP")" "demo-project"

# Trailing 4-digit non-date (sprint-2024 / sprint-2025) must alias as-is, not be stripped as MMDD and collide.
FP="$(mktemp -u)"
ok "not-mmdd-year-2024"   "$(SESSION_ALIAS_STORE="$FP" bash "$ALIAS" sprint-2024)" "sprint-2024"
ok "not-mmdd-bad-day"     "$(SESSION_ALIAS_STORE="$FP" bash "$ALIAS" client-1042)" "client-1042"
# but a genuine MMDD-shaped trailing date still poisons
ok "real-mmdd-still-caught" "$(SESSION_ALIAS_STORE="$(mktemp -u)" bash "$ALIAS" tranche1-ready-0728)" "tranche1-ready"

# A lone trailing 5+-digit group (issue-12345 / issue-67890) must not be treated as poisoned and collide;
# a long numeric run only poisons as part of a 2+-group tail (legacy name-MMDD-HHMMSS-RANDOM).
FP3="$(mktemp -u)"
ok "not-longrun-issue-id"  "$(SESSION_ALIAS_STORE="$FP3" bash "$ALIAS" issue-12345)" "issue-12345"
# a genuine multi-group timestamp+random tail (no px- prefix) still poisons via the long-numeric-run check
ok "real-longrun-still-caught" "$(SESSION_ALIAS_STORE="$(mktemp -u)" bash "$ALIAS" discovery-0718-153051-4107171)" "discovery"

# Two adjacent 4-digit runs that are not a real date+time (sprint-2024-2025 / port-8080-9090) must not collide.
FP2="$(mktemp -u)"
ok "not-mmdd-hhmm-year-range" "$(SESSION_ALIAS_STORE="$FP2" bash "$ALIAS" sprint-2024-2025)" "sprint-2024-2025"
# a genuine MMDD-HHMM pair is still caught
ok "real-mmdd-hhmm-still-caught" "$(SESSION_ALIAS_STORE="$(mktemp -u)" bash "$ALIAS" foo-0715-0630)" "foo"

# 5-digit runs (chain ids, zips, ephemeral ports) must not collide; covered by the has_mmdd_group() gate.
FP3c="$(mktemp -u)"
ok "not-longnum-chainid-5digit" "$(SESSION_ALIAS_STORE="$FP3c" bash "$ALIAS" chain-84532)" "chain-84532"

# a long numeric run PAIRED with a real MMDD date is still caught (discovery-0718-153051-4107171)
ok "real-longrun-still-caught-2" "$(SESSION_ALIAS_STORE="$(mktemp -u)" bash "$ALIAS" release-0715-123456)" "release"

# PR #22: an invalid pair BEFORE a real timestamp (project-2024-2025-0715-2359) must not let the real pair slip through;
# every matched pair must be checked (needs the READ-PATH guard, not desessionify).
PZ2="$(mktemp)"
printf 'multipair-proj\tproject-2024-2025-0715-2359\n' > "$PZ2"
r4="$(SESSION_ALIAS_STORE="$PZ2" bash "$ALIAS" multipair-proj)"
ok "readguard-multipair-caught" "$r4" "multipair-proj"
ok "readguard-multipair-clean"  "$(notsess "$r4")" "clean"


# --audit-store: read-only report of entries where fresh inference disagrees with the stored value; must NOT mutate.
AS="$(mktemp)"
printf 'sprint-2024\tsprint\n' > "$AS"
printf 'sprint-2025\tsprint\n' >> "$AS"
printf 'crss\tcrss\n' >> "$AS"
audit_out="$(SESSION_ALIAS_STORE="$AS" bash "$ALIAS" --audit-store)"
ok "audit-finds-drift-1" "$(printf '%s' "$audit_out" | grep -c "folder='sprint-2024'")" "1"
ok "audit-finds-drift-2" "$(printf '%s' "$audit_out" | grep -c "folder='sprint-2025'")" "1"
ok "audit-no-drift-for-legit" "$(printf '%s' "$audit_out" | grep -c "folder='crss'")" "0"
ok "audit-does-not-mutate" "$(cat "$AS")" "$(printf 'sprint-2024\tsprint\nsprint-2025\tsprint\ncrss\tcrss')"

# FOLDER-KEY guard: a folder name with a literal tab/newline must never become a store key (would corrupt the TSV).
TK="$(mktemp -u)"
tabfolder=$'weird\tfolder'
out_tab="$(SESSION_ALIAS_STORE="$TK" bash "$ALIAS" "$tabfolder" 2>/dev/null)"
ok "tabkey-resolves"     "$(yn test -n "$out_tab")" "yes"
ok "tabkey-not-persisted" "$([ -f "$TK" ] && echo exists || echo absent)" "absent"


# CASE-INSENSITIVITY: the px-/px_ prefix check must catch `PX-foo-bar` (hand-edited store, no date to trip the digit checks).
CI="$(mktemp)"
printf 'myproj\tPX-foo-bar\n' > "$CI"
ci_out="$(SESSION_ALIAS_STORE="$CI" bash "$ALIAS" myproj)"
ok "caseinsens-readguard-caught"    "$(notsess "$ci_out")" "clean"
ok "caseinsens-readguard-selfheal"  "$(awk -F'\t' '$1=="myproj"{print $2}' "$CI")" "$ci_out"



# ── --alias is PER-SPAWN: it must not mutate the folder's stored default (it names the TASK; persisting it renamed
# folders forever, 11 of ~40 entries drifted). Persisting is an explicit opt-in via --set-default. ──
PS="$(mktemp -u)"
# no stored entry: --alias resolves for this spawn and stores NOTHING
ok "per-spawn-alias-returns-value" \
  "$(SESSION_ALIAS_STORE="$PS" bash "$ALIAS" my-long-project-folder --alias taskname)" "taskname"
ok "per-spawn-alias-creates-no-entry" \
  "$([ -f "$PS" ] && echo exists || echo absent)" "absent"
# with a stored default: --alias overrides for this spawn without overwriting
printf 'stable-folder\tstable\n' > "$PS"
ok "per-spawn-alias-overrides-for-this-spawn" \
  "$(SESSION_ALIAS_STORE="$PS" bash "$ALIAS" stable-folder --alias throwaway)" "throwaway"
ok "per-spawn-alias-leaves-default-intact" \
  "$(awk -F'\t' '$1=="stable-folder"{print $2}' "$PS")" "stable"
# --set-default is the explicit opt-in that DOES persist
ok "set-default-returns-value" \
  "$(SESSION_ALIAS_STORE="$PS" bash "$ALIAS" stable-folder --alias renamed --set-default)" "renamed"
ok "set-default-persists" \
  "$(awk -F'\t' '$1=="stable-folder"{print $2}' "$PS")" "renamed"
# opting in must not smuggle a poisoned default past the guard (anti-poisoning runs BEFORE persisting)
pz_out="$(SESSION_ALIAS_STORE="$PS" bash "$ALIAS" poison-folder --alias px-x-0101-0725 --set-default 2>/dev/null)"
ok "set-default-rejects-poisoned"      "$(notsess "$pz_out")" "clean"
ok "set-default-poisoned-not-verbatim" "$(grep -cF 'px-x-0101-0725' "$PS" 2>/dev/null; true)" "0"
# inference still persists (deterministic cache, not drift)
PS2="$(mktemp -u)"
inf_out="$(SESSION_ALIAS_STORE="$PS2" bash "$ALIAS" some-very-long-project-name)"
ok "inference-still-persists" \
  "$(awk -F'\t' '$1=="some-very-long-project-name"{print $2}' "$PS2")" "$inf_out"
rm -f "$PS" "$PS2"

finish "session-alias"
