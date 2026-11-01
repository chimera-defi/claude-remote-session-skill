#!/usr/bin/env bash
# codex-git-roots: print the `--add-dir` flags a sandboxed `codex exec -s workspace-write` needs to
# `git add` / `git commit` inside a LINKED git worktree.
#
# Why: workspace-write marks <writable-root>/.git read-only, and a linked worktree's index, HEAD and lock
# live in <main>/.git/worktrees/<name>, outside the worktree root. The run fails with
# "Unable to create '.../.git/worktrees/<name>/index.lock': Read-only file system" and the orchestrator
# redoes the commit (crss PR 218 case study, 2026-10-28). Adding the common dir itself as a root does not
# help (its name is .git, so it is protected again); adding its subdirectories does (verified live,
# codex-cli 0.164, 2026-11-02).
#
# Usage (paths with spaces are safe): mapfile -d '' -t R < <(codex-git-roots -0 "$dir")
#        codex exec -s workspace-write -C "$dir" "${R[@]}" "<task>"
# Without -0 the flags print space-separated with %q quoting, for display only.
# A plain checkout (git-dir == common dir) gets no flags: its .git cannot be opened under
# workspace-write; use a linked worktree or the lane's danger-full-access policy there.
set -uo pipefail
nul=0; [ "${1:-}" = -0 ] && { nul=1; shift; }
dir="${1:-.}"
gd="$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)" || { echo "codex-git-roots: not a git checkout: $dir" >&2; exit 2; }
cd_="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || exit 2
if [ "$gd" = "$cd_" ]; then
  echo "codex-git-roots: $dir is a plain checkout; workspace-write cannot write its .git" >&2
  exit 0
fi
for p in "$gd" "$cd_/objects" "$cd_/refs" "$cd_/logs"; do
  [ -d "$p" ] || continue
  if [ "$nul" = 1 ]; then printf -- '--add-dir\0%s\0' "$p"; else printf -- '--add-dir %q ' "$p"; fi
done
[ "$nul" = 1 ] || echo
