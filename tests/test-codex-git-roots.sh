#!/usr/bin/env bash
# codex-git-roots: linked worktree -> add-dir flags for its gitdir + common objects/refs/logs; plain
# checkout -> no flags (exit 0); non-repo -> exit 2. Hermetic: temp repo, no codex.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
S="$HERE/../scripts/codex-git-roots.sh"
W="$CRSS_TEST_TMP/r with space"; mkdir -p "$W"; cd "$W" || exit 1
git init -q main && git -C main -c user.name=t -c user.email=t@t commit -q --allow-empty -m i
git -C main worktree add -q ../wt -b t1
out="$(bash "$S" "$W/wt")"; rc=$?
ok "linked worktree exits 0" "$rc" 0
for p in "$W/main/.git/worktrees/wt" "$W/main/.git/objects" "$W/main/.git/refs" "$W/main/.git/logs"; do
  q="$(printf "%q" "$p")"; case "$out" in *"--add-dir $q "*) ok "flag for $p" 1 1;; *) ok "flag for $p" "missing in: $out" 1;; esac
done
out="$(bash "$S" "$W/main" 2>/dev/null)"; rc=$?
ok "plain checkout exits 0" "$rc" 0; ok "plain checkout prints no flags" "$out" ""
bash "$S" "$CRSS_TEST_TMP" >/dev/null 2>&1; ok "non-repo exits 2" "$?" 2
mapfile -d '' -t R < <(bash "$S" -0 "$W/wt"); ok "-0 yields 8 args" "${#R[@]}" 8; ok "-0 keeps spaced path whole" "${R[1]}" "$W/main/.git/worktrees/wt"
finish codex-git-roots
