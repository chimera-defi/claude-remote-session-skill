#!/usr/bin/env bash
# test-no-pipe-into-grep-q.sh — fail if a pipefail script pipes into `grep -q`.
#
# Why: under `set -o pipefail`, `producer | grep -q PAT` fails even when grep matched. grep -q
# exits on its first match, the producer's next write gets EPIPE/SIGPIPE, and pipefail reports
# that as the pipeline's status. It only bites when the producer writes in more than one chunk
# (output over ~4 KiB), so it shows up as a rare flake: positive checks fail falsely, and negative
# checks (`if … | grep -q …; then fail`) PASS falsely when the forbidden text is present.
# Use a here-string (`grep -q PAT <<<"$var"`), a process substitution
# (`grep -q PAT < <(producer)`), or capture the producer first.
#
# Scans every scripts/*.sh and tests/*.sh that mentions pipefail, except this file. A line is a
# hit when `| grep` is followed by any option cluster containing q (-q -qE -Eq -qxF …) or
# --quiet/--silent. Backslash-continued lines and a trailing `|` are joined first; full-line
# comments are skipped. No allowlist.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
SELF="$(basename "$0")"

# scan FILE...: print file:line for each pipe-into-grep-q in the files that mention pipefail.
scan() {
  local f
  for f in "$@"; do
    [ "$(basename "$f")" = "$SELF" ] && continue
    grep -q pipefail "$f" || continue
    awk -v F="$f" '
      /^[[:space:]]*#/ { if (!cont) next }
      { if (!cont) { start = NR; buf = "" }
        line = $0
        cont = 0
        if (line ~ /\\$/) { sub(/\\$/, "", line); cont = 1 }
        else if (line ~ /\|[[:space:]]*$/) { cont = 1 }
        buf = buf " " line
        if (!cont && buf ~ /\|[[:space:]]*grep[[:space:]]+(-[^[:space:]]+[[:space:]]+)*(-[A-Za-z]*q[A-Za-z]*|--quiet|--silent)([[:space:]]|$)/) print F ":" start ": " substr(buf, 2, 110)
      }' "$f"
  done
}

# Self-test: the scanner must go red on the bad forms and green on the good ones.
FIX="$(mktemp -d)"; trap 'rm -rf "$FIX"' EXIT
mkfix() { printf '%s\n' 'set -o pipefail' "$2" > "$FIX/$1.sh"; }
bad=(
  'printf %s "$x" | grep -q PAT'
  'cmd | grep -qE PAT'
  'cmd | grep -Eq PAT'
  'cmd |   grep -qxF -- PAT'
  'cmd | grep -F -q PAT'
  'cmd | grep --quiet PAT'
  'cmd | grep -qv PAT'
  'a | b | grep -qi PAT'
  'cmd \'$'\n''  | grep -q PAT'
  'cmd |'$'\n''  grep -q PAT'
)
i=0; for b in "${bad[@]}"; do i=$((i+1)); mkfix "bad$i" "$b"; hits="$(scan "$FIX/bad$i.sh")"; ok "selftest-bad-$i-flagged" "$([ -n "$hits" ] && echo yes || echo no)" yes; done
good=(
  'grep -q PAT <<<"$x"'
  'grep -qE PAT < <(cmd)'
  'out="$(cmd)"; grep -q PAT <<<"$out"'
  'cmd | grep PAT'
  'cmd | grep -c PAT'
  '# cmd | grep -q PAT'
)
i=0; for g in "${good[@]}"; do i=$((i+1)); mkfix "good$i" "$g"; hits="$(scan "$FIX/good$i.sh")"; ok "selftest-good-$i-clean" "${hits:-none}" none; done
printf '%s\n' 'cmd | grep -q PAT' > "$FIX/nopipefail.sh"
ok "selftest-no-pipefail-file-ignored" "$(scan "$FIX/nopipefail.sh" | wc -l | tr -d ' ')" 0
ok "selftest-reports-file-line" "$(scan "$FIX/bad1.sh" | cut -d: -f2)" 2

# The real scan.
hits="$(scan "$HERE"/../scripts/*.sh "$HERE"/*.sh)"
ok "no-pipe-into-grep-q-in-repo" "${hits:-none}" none
finish "no-pipe-into-grep-q"
