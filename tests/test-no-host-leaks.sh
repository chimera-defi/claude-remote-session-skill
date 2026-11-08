#!/usr/bin/env bash
# Public repo: fail on host-identifying literals in tracked files. Generic checks always run (this is CI).
# CRSS_LEAK_DENYLIST=<file> adds private terms: one ERE per line, '#' comments and blanks ignored, optional
# TAB then comma-separated path globs that term skips. Keep that file outside the repo.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
hits=0; files=()
while IFS= read -r f; do [ -f "$f" ] && [ "$f" != tests/test-no-host-leaks.sh ] && files+=("$f"); done < <(git ls-files)

scan() {  # REGEX REASON [SAFE-ERE matched against "line:match"] [skip-globs]
  local f g l out skip gs
  for f in "${files[@]}"; do
    skip=0; IFS=, read -ra gs <<<"${4:-}"
    # shellcheck disable=SC2053  # glob match is the point
    for g in "${gs[@]}"; do [[ $f == $g ]] && skip=1; done
    [ $skip = 1 ] && continue
    out=$(grep -noE -- "$1" "$f" | grep -vE -- "${3:-^\$}")
    while IFS= read -r l; do [ -n "$l" ] && { echo "FAIL: $f:$l  [$2]"; hits=$((hits+1)); }; done <<<"$out"
  done
}

scan '/home/[a-z_][a-z0-9_-]*' 'absolute home path (use /home/youruser)' ':/home/(youruser|user|me)$'
scan '/Users/[A-Za-z0-9_.-]+/|/tmp/claude-[0-9]+|Environment=HOME=/[^[:space:]]*' 'host path or hardcoded unit HOME'
scan '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' 'email address' ':(noreply@anthropic\.com|t@t\.com|[^:]*@example\.(com|org))$'
scan '\bsk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|0x[0-9a-fA-F]{40}\b|scope_claim|coordination_bus' \
  'secret-shaped literal or bus reference' ':sk-[A-Za-z-]*$|fake|example|placeholder|dummy|your|here|xxx|\.\.\.|test'
owner=$(git remote get-url origin 2>/dev/null | sed -nE 's#.*github\.com[:/]+([A-Za-z0-9_.-]+)/.*#\1#p')
if [ -n "$owner" ]; then   # fakeorg: fixture owner; garrytan: README credits the upstream gstack project
  scan 'github\.com/[A-Za-z0-9_.-]+/' "github.com owner other than $owner" "/($owner|fakeorg|garrytan)/\$"
else echo "note: no origin remote, skipping the github-owner check"; fi

if [ -n "${CRSS_LEAK_DENYLIST:-}" ]; then
  if [ ! -f "$CRSS_LEAK_DENYLIST" ]; then echo "FAIL: CRSS_LEAK_DENYLIST=$CRSS_LEAK_DENYLIST not readable"; hits=$((hits+1))
  else
    while IFS= read -r l || [ -n "$l" ]; do
      t=${l%%$'\t'*}; g=; [[ $l == *$'\t'* ]] && g=${l#*$'\t'}
      t=${t%%#*}; t=${t%"${t##*[![:space:]]}"}; [ -n "$t" ] && scan "$t" "denylist term: $t" '' "$g"
    done <"$CRSS_LEAK_DENYLIST"
  fi
fi
[ "$hits" -eq 0 ] && { echo "test-no-host-leaks: PASS"; exit 0; }
echo "test-no-host-leaks: FAIL ($hits hit(s))"; exit 1
