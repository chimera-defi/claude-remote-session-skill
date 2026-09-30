#!/usr/bin/env bash
# test-session-handoff-locale-safe-match.sh — regression: session-handoff.sh's
# prompt-glyph matching must never use a bracket character class containing
# any multi-byte prompt glyph (e.g. `[❯›]`).
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
# pins the fix at the source level so a future edit re-adding a prompt-glyph
# bracket class here fails loudly instead of silently reintroducing the bug.
#
# Exercise the real functions under byte and UTF-8 locales as well as
# guarding the source against unsafe bracket expressions.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SH="$HERE/../scripts/session-handoff.sh"
# shellcheck disable=SC1090
source "$SH"   # source-guarded: must NOT run dispatch
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }

has_glyph_bracket() {
  # Flag ANY bracket expression containing a non-ASCII character (a multi-byte
  # glyph inside [...] is decomposed into member BYTES under a byte locale).
  # grep -P under LC_ALL=C sees raw bytes, so \x80-\xff is "any byte of a
  # multi-byte character" regardless of the caller's locale.
  # Comment-only lines are ignored. Documented exceptions (none is a regex
  # class; each is a non-ASCII literal that merely sits between square
  # brackets): a parameter expansion like `${x//─/}`, the bracketed
  # '[no log entry — ...]' note, and the python '[... is LIVE now — ...]' note.
  # Every other line is checked, including multi-line awk/sed program bodies.
  grep -vE '^[[:space:]]*#' |
    grep -vE '\$\{[A-Za-z_]+//[^}]*\}|\[no log entry |is LIVE now — ' |
    LC_ALL=C grep -P '\[\^?\]?(?:[^\]]|\[:[^\]]*:\])*[\x80-\xff]' >/dev/null
}

# Every script under scripts/ must be free of such classes (the original
# prompt-glyph bug, and the spinner-glyph class in _is_working).
for f in "$HERE"/../scripts/*.sh; do
  if has_glyph_bracket < "$f"; then
    fail=$((fail+1))
    echo "FAIL: no-nonascii-bracket-class — found a bracket expression containing a non-ASCII char in $f"
  else
    pass=$((pass+1))
  fi
done
for pattern in '[❯]' '[›]' '[ ❯›]' '[^❯›]' '[[:space:]❯]' '[]❯]' '[^]›]' '[✻✽✶·]' '[a…]'; do
  ok "guard-rejects-$pattern" "$(printf '%s\n' "grep -E 'x$pattern'" | has_glyph_bracket && echo yes || echo no)" yes
done
for pattern in "grep -E 'x[[:space:]]*y'" 'if [ -z "${x//─/}" ]; then' "echo '[no log entry — none]'" "grep -E '(✻|✽)'" "grep -E '[a-z]'"; do
  ok "guard-accepts-$pattern" "$(printf '%s\n' "$pattern" | has_glyph_bracket && echo yes || echo no)" no
done
# A multi-line awk program: the class sits on a line with no tool name.
ok "guard-rejects-multiline-awk" "$(printf '%s\n' "awk '" '/[❯›]/ { n++ }' "'" | has_glyph_bracket && echo yes || echo no)" yes
ok guard-ignores-comment "$(printf '%s\n' "# grep -E '[❯]'" | has_glyph_bracket && echo yes || echo no)" no

# Sanity: the alternation form this was fixed to use is actually present, so
# this guard isn't just checking a pattern that no longer exists at all.
if grep -qE '(❯\|›|›\|❯)' "$SH"; then
  pass=$((pass+1))
else
  fail=$((fail+1))
  echo "FAIL: alternation-form-present — expected an alternation (❯|›) in $SH; has the Codex prompt-glyph support been restructured?"
fi

# Select every available requested UTF-8 locale; never silently skip both.
locales=(C)
for candidate in C.UTF-8 en_US.UTF-8; do
  if [ "$(LC_ALL="$candidate" locale charmap 2>/dev/null)" = UTF-8 ]; then
    locales+=("$candidate")
  fi
done
ok utf8-locale-available "$([ "${#locales[@]}" -gt 1 ] && echo yes || echo no)" yes

# A shell function selects the awk implementation for all sourced helpers.
# Subshells keep locale and function overrides out of the parent test shell.
for awk_impl in awk gawk mawk; do
  command -v "$awk_impl" >/dev/null 2>&1 || continue
  awk_path="$(command -v "$awk_impl")"
  for test_locale in "${locales[@]}"; do
    if (
      export LC_ALL="$test_locale"
      awk() { "$awk_path" "$@"; }
      pass=0; fail=0
      for prompt in '❯ ' '❯ explain ›' '› foo' '❯ hi' '› explain ❯' '❯ explain ❯'; do
        expected=draft-in-input-box; empty=no
        if [ "$prompt" = '❯ ' ]; then expected=safe; empty=yes; fi
        ok "$prompt empty" "$(_input_box_empty "$prompt" && echo yes || echo no)" "$empty"
        ok "$prompt safety" "$(_safety_reason "$prompt")" "$expected"
      done
      pane=$'❯ \n────────────────\n  ⏵⏵ bypass permissions on (shift+tab to cycle)'
      ok status-empty "$(_input_box_empty "$pane" && echo yes || echo no)" yes
      ok status-safe "$(_safety_reason "$pane")" safe
      pane=$'❯ \n  real draft\n────────────────'
      ok multiline-draft "$(_safety_reason "$pane")" draft-in-input-box
      # _is_working: a spinner glyph class must not false-match the bytes of
      # an ordinary ellipsis ("…" = E2 80 A6; A6 is a byte of "✦" = E2 9C A6).
      ok "working-spinner" "$(_is_working '✽ Crafting…' && echo yes || echo no)" yes
      ok "working-esc" "$(_is_working 'x (esc to interrupt)' && echo yes || echo no)" yes
      ok "idle-two-ellipses" "$(_is_working 'Reading… done…' && echo yes || echo no)" no
      ok "idle-see-foo" "$(_is_working 'see foo… bar…' && echo yes || echo no)" no
      echo "  $awk_impl / $test_locale: pass=$pass fail=$fail"
      [ "$fail" -eq 0 ]
    ); then
      pass=$((pass+1))
    else
      fail=$((fail+1))
    fi
  done
done

echo "session-handoff-locale-safe-match: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
