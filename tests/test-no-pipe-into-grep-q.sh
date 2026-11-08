#!/usr/bin/env bash
# Under pipefail, `producer | grep -q` flakes (SIGPIPE once output passes ~4 KiB), and `grep -q PAT < <(producer)`
# drops the producer's status. Capture the output with its status checked, then match it.
cd "$(dirname "$0")/.." || exit 1
q='(-[^[:space:]]+[[:space:]]+)*(-[A-Za-z]*[ql][A-Za-z]*|--quiet|--silent|--files-with-matches)'
for f in scripts/*.sh tests/*.sh; do   # sed drops comments and joins continuation lines
  hits+=$(sed -E '/^[[:space:]]*#/d; :a; /(\\|\|[[:space:]]*)$/{N; s/\\?\n[[:space:]]*/ /; ba}' "$f" |
    grep -HE --label="$f" "\|[[:space:]]*grep[[:space:]]+$q|grep[[:space:]]+$q.*<[[:space:]]*<\(")
done
[ -z "${hits:-}" ] || { echo "FAIL: pipe into grep -q/-l:"; echo "$hits"; exit 1; }
echo "no-pipe-into-grep-q: PASS"
