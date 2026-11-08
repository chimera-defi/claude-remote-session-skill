#!/usr/bin/env bash
# comment-only-check.sh <base-ref> [file...] — prove changed scripts differ from <base-ref>
# only in comments and blank lines (proof 1 in references/refactor-plan.md). Run from the
# repo root. Needs shfmt and jq. Not part of the test-*.sh loop: CI has no shfmt.
#   Every file: line 1 (the shebang) must match.
#   .sh: the `shfmt --to-json` syntax tree must match once comments and source positions are
#        removed. Heredoc bodies stay in the tree. (`shfmt -mn` is not enough: it rewrites
#        code, e.g. `$(( $a * 2 ))` to `$((a*2))`, which differ when a='1+1'.)
#   .py: `ast.dump` must match.
# Then the help output of the scripts listed in help_of must match.
# Exit 0 = comment-only; 1 = code or help changed (diff printed).
set -uo pipefail
base="${1:?usage: comment-only-check.sh <base-ref> [file...]}"; shift
for t in shfmt jq; do command -v "$t" >/dev/null || { echo "comment-only-check: needs $t" >&2; exit 2; }; done
files=("$@")
[ "${#files[@]}" -gt 0 ] || mapfile -t files < <(git diff --name-only "$base" -- scripts/)
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
shtree() {
  shfmt --to-json | jq 'walk(if type == "object" then del(.Comments, .Last)
    | with_entries(select(.value | (type == "object" and keys == ["Col","Line","Offset"]) | not))
    else . end)'
}
pytree() { python3 -c 'import ast,sys;print(ast.dump(ast.parse(sys.stdin.read()), indent=1))'; }
rc=0
for f in "${files[@]}"; do
  case "$f" in
    *.sh) tree=shtree ;;
    *.py) tree=pytree ;;
    *) continue ;;
  esac
  { git show "$base:$f" | head -1; git show "$base:$f" | "$tree"; } >"$tmp/a"
  { head -1 "$f"; "$tree" <"$f"; } >"$tmp/b"
  if cmp -s "$tmp/a" "$tmp/b"; then
    printf 'SAME  %-34s %5s -> %5s lines\n' "$f" "$(git show "$base:$f" | wc -l)" "$(wc -l <"$f")"
  else
    printf 'CODE CHANGED: %s\n' "$f"; diff "$tmp/a" "$tmp/b" | head -40; rc=1
  fi
done

git archive "$base" scripts | tar -x -C "$tmp"
mkdir -p "$tmp/home"
help_of() { # <tree>: help output of the scripts whose help once came from their header
  local d="$1" c argv
  for c in "crss-tmux-scope.sh status -h" "session-preserve.sh -h" "session-registry.sh -h" \
           "session-resume.sh --help" "codex-resume-pin.sh --bogus" \
           "session-spawn-server.sh --help" "new-session.sh --help" \
           "telemetry-report.sh --help" "quota-check.sh --help"; do
    read -r -a argv <<<"$c"
    echo "== $c"
    HOME="$tmp/home" timeout 10 bash "$d/scripts/${argv[0]}" "${argv[@]:1}" 2>&1 | sed "s#$d#DIR#g"
    echo "rc=${PIPESTATUS[0]}"
  done
}
if diff <(help_of "$tmp") <(help_of "$PWD") >"$tmp/help.diff"; then echo "HELP SAME"
else echo "HELP CHANGED"; cat "$tmp/help.diff"; rc=1; fi
exit "$rc"
