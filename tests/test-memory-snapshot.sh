#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/config" CRSS_HOME="$TMP/config/crss"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset HOST_TOOLS_CONFIG
export GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.org
export GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.org
mkdir -p "$HOME/agent-memory" "$CRSS_HOME"
for repo in dirty clean secret locked merging staged extra; do
  path="$HOME/agent-memory/$repo"
  mkdir -p "$path"
  git -C "$path" init -q
  git -C "$path" -c commit.gpgsign=false commit -qm initial --allow-empty
done
printf note > "$HOME/agent-memory/dirty/note"
printf ignored > "$HOME/agent-memory/dirty/.gitignore"
printf local > "$HOME/agent-memory/dirty/ignored"
printf note > "$HOME/agent-memory/secret/note"
python3 - "$HOME/agent-memory" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
for name in ('secret', 'staged'):
    (root/name/'credential').write_text('sk-' + 'TEST1234' * 5)
PY
git -C "$HOME/agent-memory/staged" add credential
printf lock > "$HOME/agent-memory/locked/.git/index.lock"
printf note > "$HOME/agent-memory/locked/note"
printf merge > "$HOME/agent-memory/merging/.git/MERGE_HEAD"
printf note > "$HOME/agent-memory/merging/note"
mv "$HOME/agent-memory/extra" "$HOME/extra"
printf extra > "$HOME/extra/note"
printf '{"memory-snapshot":{"extra_repos":["~/extra"]}}' > "$CRSS_HOME/host-tools.json"
run() { bash "$ROOT/scripts/memory-snapshot.sh" --home "$HOME" "$@"; }
run --dry-run > "$TMP/dry"
test "$(git -C "$HOME/agent-memory/dirty" rev-list --count HEAD)" = 1
test -z "$(git -C "$HOME/agent-memory/dirty" diff --cached --name-only)"
run > "$TMP/output"
grep -F 'dirty: committed 2' "$TMP/output"
grep -F 'clean: clean' "$TMP/output"
grep -F 'secret: committed 1' "$TMP/output"
grep -F 'secret-pattern' "$TMP/output"
grep -F 'locked: skipped(index.lock)' "$TMP/output"
grep -F 'merging: skipped(merge/rebase in progress)' "$TMP/output"
grep -F 'staged: skipped(' "$TMP/output"
grep -F 'extra: committed 1' "$TMP/output"
test "$(git -C "$HOME/agent-memory/dirty" log -1 --format=%s)" = 'snapshot: 2 files (memory-snapshot)'
test -z "$(git -C "$HOME/agent-memory/secret" ls-files credential)"
test "$(git -C "$HOME/agent-memory/staged" rev-list --count HEAD)" = 1
for path in "$HOME/agent-memory/"* "$HOME/extra"; do
  test -z "$(git -C "$path" remote)"
done
if grep -F 'TEST1234' "$TMP/output"; then exit 1; fi
printf 'test-memory-snapshot: PASS\n'
