#!/usr/bin/env bash
# codex-git-roots: print the `--add-dir` flags a sandboxed `codex exec -s workspace-write` needs
# to git add/commit inside a linked worktree. workspace-write makes <root>/.git read-only, but the
# linked index, HEAD and lock live in <main>/.git/worktrees/<name>. Adding the common dir itself
# does not help (its name is .git); its objects, refs and logs subdirectories do.
#
# Usage: mapfile -d '' -t R < <(codex-git-roots -0 "$dir")
#        codex exec -s workspace-write -C "$dir" "${R[@]}" "<task>"
# Without -0 the flags print %q-quoted, for display only. A plain checkout gets no flags.
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
