#!/usr/bin/env bash
# test-session-handoff-locale-safe-match.sh — regression: session-handoff.sh's
# prompt-glyph matching must never use a bracket character class containing
# more than one multi-byte UTF-8 literal (e.g. `[❯›]`).
#
# Concrete bug this guards (found in nightly review, 2026-09-29): the Codex
# backend PR added Codex's `›` prompt alongside Claude's `❯` by writing
# `[❯›]`/`[^❯›]` bracket expressions in _input_region/_transcript_region/
# _has_prompt and the input-box prefix-strip in _input_box_empty. Under a
# POSIX/C locale (this repo's own stated support target — see
# _input_box_empty's border-line comment for the same class of bug hitting a
# `─+` regex), grep/awk/sed treat a bracket class as a set of raw BYTES, not
# atomic characters: a multi-byte char placed inside `[...]` is decomposed
# into its individual bytes as separate class members. `❯` (E2 9D AF) and `›`
# (E2 80 BA) share a lead byte (E2) with nearly every other symbol the
# Claude/Codex TUIs print (✢✻✽⏵…), so `[❯›]` false-matched on ANY line
# containing one of those — e.g. the routine "⏵⏵ bypass permissions on
# (shift+tab to cycle)" status line under a ready pane — which collapsed
# _input_region to the tail of the capture and made _safety_reason report
# every idle Claude pane as "draft-in-input-box" instead of "safe". This broke
# session-handoff's --wait-ready gate and session-compact's busy/idle check
# fleet-wide on any host running a non-UTF-8 locale (verified: LC_ALL=C, no
# LANG set). Root cause + fix are documented at each call site; this test
# pins the fix at the source level so a future edit re-adding a multi-char
# bracket class here fails loudly instead of silently reintroducing the bug.
#
# tests/test-session-handoff-codex.sh and tests/test-session-handoff-ready.sh
# already exercise the functional behavior (and would have caught this bug
# had they been run under LC_ALL=C); this test is a cheap, locale-independent
# static guard against the specific pattern shape that caused it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SH="$HERE/../scripts/session-handoff.sh"
pass=0; fail=0

# A bracket expression containing BOTH glyphs (in either order, negated or
# not) is exactly the shape that decomposes into bytes and false-matches.
# Restricted to non-comment lines: the fix's own explanatory comments quote
# the bad pattern verbatim as a warning, which would otherwise self-trigger.
if grep -vE '^\s*#' "$SH" | grep -qE '\[\^?(❯›|›❯)\]'; then
  fail=$((fail+1))
  echo "FAIL: no-multi-glyph-bracket-class — found a [❯›]-shaped bracket expression in $SH; use alternation (❯|›) instead (see _input_region's comment)"
else
  pass=$((pass+1))
fi

# Sanity: the alternation form this was fixed to use is actually present, so
# this guard isn't just checking a pattern that no longer exists at all.
if grep -qE '(❯\|›|›\|❯)' "$SH"; then
  pass=$((pass+1))
else
  fail=$((fail+1))
  echo "FAIL: alternation-form-present — expected an alternation (❯|›) in $SH; has the Codex prompt-glyph support been restructured?"
fi

echo "session-handoff-locale-safe-match: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
