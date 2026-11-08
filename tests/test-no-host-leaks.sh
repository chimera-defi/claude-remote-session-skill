#!/usr/bin/env bash
# Public repo: fail on host-identifying literals in tracked files. Generic checks always run (this is CI).
# CRSS_LEAK_DENYLIST=<file> adds private terms: one ERE per line, '#' comments and blanks ignored, optional
# TAB then comma-separated path globs that term skips. Keep that file outside the repo.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
hits=0; files=()
while IFS= read -r -d '' f; do [ -f "$f" ] && [ "$f" != tests/test-no-host-leaks.sh ] && files+=("$f"); done < <(git ls-files -z)

scan() {  # REGEX REASON [SAFE-ERE matched against "line:match"] [skip-globs]; I=i ignores case
  local f g l out skip gs
  for f in "${files[@]}"; do
    skip=0; IFS=, read -ra gs <<<"${4:-}"
    # shellcheck disable=SC2053  # glob match is the point
    for g in "${gs[@]}"; do [[ $f == $g ]] && skip=1; done
    [ $skip = 1 ] && continue
    out=$(grep "-no${I:-}E" -- "$1" "$f" | grep -viE -- "${3:-^\$}")
    while IFS= read -r l; do [ -n "$l" ] && { echo "FAIL: $f:$l  [$2]"; hits=$((hits+1)); }; done <<<"$out"
  done
}

scan '/home/[a-z_][a-z0-9_-]*' 'absolute home path (use /home/youruser)' ':/home/(youruser|user|me)$'
scan '/Users/[A-Za-z0-9_.-]+/|/tmp/claude-[0-9]+|Environment=HOME=/[^[:space:]]*' 'host path or hardcoded unit HOME'
scan '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' 'email address' ':(noreply@anthropic\.com|t@t\.com|[^:]*@example\.(com|org))$'
fakes=':sk-[A-Za-z-]*$|fake|example|placeholder|dummy|your|here|changeme|xxx|local|\.\.\.|redacted|test'
scan '\bsk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|0x[0-9a-fA-F]{40}([0-9a-fA-F]{24})?\b|AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.|Bearer [A-Za-z0-9._-]{20,}' \
  'secret-shaped literal' "$fakes"
I=i scan '(api[_-]?key|token|secret|password)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"'$<{ ][^"'"'"']{12,}' 'quoted credential assignment' "$fakes"
scan '\bbus seq\b|\bseq #[0-9]{3,}\b|scope_claim|coordination_bus|[Oo]perator (directive|ruling)|OPERATOR RULING' 'bus or operator-ruling reference'
# Fixtures stamp 0101-HHMM or use placeholders, so a month of 02-12 marks a real session name.
scan '\b[A-Za-z]{2,12}[_-][a-z][a-z0-9-]*-(0[2-9]|1[0-2])[0-3][0-9]-[0-2][0-9][0-5][0-9]\b|-20[0-9]{2}(0[2-9]|1[0-2])[0-3][0-9]-[0-9]{4}\b' 'real-looking session name'
host=$(hostname -s 2>/dev/null | tr 'A-Z' 'a-z')
case $host in localhost|runner|ubuntu|debian|fedora|centos|alpine|docker|github|server|hostname|machine|buildkitd|builder|codespaces|linux|macbook) host= ;; esac
if [ "${#host}" -ge 6 ] || { [ "${#host}" -ge 4 ] && [[ $host == *[0-9]* ]]; }; then I=i scan "\\b$host\\b" "this machine's hostname"; fi
owner=$(git remote get-url origin 2>/dev/null | sed -nE 's#.*github\.com[:/]+([A-Za-z0-9_.-]+)/.*#\1#p')
if [ -n "$owner" ]; then   # fakeorg: fixture owner; garrytan: README credits the upstream gstack project
  scan 'github\.com/[A-Za-z0-9_.-]+/' "github.com owner other than $owner" "/($owner|fakeorg|garrytan)/\$"
else echo "note: no origin remote, skipping the github-owner check"; fi

if [ -n "${CRSS_LEAK_DENYLIST:-}" ]; then
  if [ ! -f "$CRSS_LEAK_DENYLIST" ]; then echo "FAIL: CRSS_LEAK_DENYLIST=$CRSS_LEAK_DENYLIST not readable"; hits=$((hits+1))
  else
    while IFS= read -r l || [ -n "$l" ]; do
      t=${l%%$'\t'*}; g=; [[ $l == *$'\t'* ]] && g=${l#*$'\t'}
      t=${t%%#*}; t=${t%"${t##*[![:space:]]}"}; t=${t#"${t%%[![:space:]]*}"}; [ -n "$t" ] && scan "$t" "denylist term: $t" '' "$g"
    done <"$CRSS_LEAK_DENYLIST"
  fi
fi
[ "$hits" -eq 0 ] && { echo "test-no-host-leaks: PASS"; exit 0; }
echo "test-no-host-leaks: FAIL ($hits hit(s))"; exit 1
