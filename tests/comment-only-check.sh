#!/usr/bin/env bash
# comment-only-check.sh <base-ref> [file...] — prove changed scripts differ from <base-ref>
# only in comments and blank lines (proof 1 in references/refactor-plan.md). Run from the
# repo root. Needs shfmt. Not part of the test-*.sh loop: CI has no shfmt.
#   .sh: `shfmt -mn` output must match (it strips comments, keeps heredoc bodies).
#   .py: `ast.dump` must match.
# Then the help text of the scripts that print their own header comment must match.
# Exit 0 = comment-only; 1 = code or help changed (diff printed).
set -uo pipefail
base="${1:?usage: comment-only-check.sh <base-ref> [file...]}"; shift
command -v shfmt >/dev/null || { echo "comment-only-check: needs shfmt" >&2; exit 2; }
files=("$@")
[ "${#files[@]}" -gt 0 ] || mapfile -t files < <(git diff --name-only "$base" -- scripts/)
astdump='import ast,sys;print(ast.dump(ast.parse(sys.stdin.read())))'
rc=0
for f in "${files[@]}"; do
  case "$f" in
    *.sh) a="$(git show "$base:$f" | shfmt -mn)"; b="$(shfmt -mn "$f")" ;;
    *.py) a="$(git show "$base:$f" | python3 -c "$astdump")"; b="$(python3 -c "$astdump" <"$f")" ;;
    *) continue ;;
  esac
  if [ "$a" = "$b" ]; then
    printf 'SAME  %-34s %5s -> %5s lines\n' "$f" "$(git show "$base:$f" | wc -l)" "$(wc -l <"$f")"
  else
    printf 'CODE CHANGED: %s\n' "$f"; diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | head -20; rc=1
  fi
done

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
git archive "$base" scripts | tar -x -C "$tmp"
mkdir -p "$tmp/home"
help_of() { # <tree>: help output of every script whose help is read from its own source
  local d="$1" c argv
  for c in "crss-tmux-scope.sh -h" "session-preserve.sh -h" "session-registry.sh -h" \
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
