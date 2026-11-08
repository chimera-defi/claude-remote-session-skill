#!/usr/bin/env bash
# Under pipefail, `producer | grep -q` flakes (SIGPIPE once output passes ~4 KiB). Capture the output, then match it.
cd "$(dirname "$0")/.." || exit 1
hits=$(grep -nE '\|[[:space:]]*grep[[:space:]]+-[A-Za-z]*[ql]|grep[[:space:]]+-[A-Za-z]*[ql].*<[[:space:]]*<\(' scripts/*.sh tests/test-crss.sh)
[ -z "$hits" ] || { echo "FAIL: pipe into grep -q/-l:"; echo "$hits"; exit 1; }
echo "no-pipe-into-grep-q: PASS"
