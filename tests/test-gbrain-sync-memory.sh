#!/usr/bin/env bash
# Plain-bash assertions for gbrain-sync-memory. No external test framework.
#
# Every scenario runs entirely inside a throwaway AGENT_MEMORY_ROOT (mktemp -d)
# with git-init'd namespace repos, and with a stub `gbrain` first on PATH.
# Nothing here may touch /home/agents/agent-memory or invoke the real gbrain
# CLI -- see AGENT_MEMORY_ROOT in scripts/gbrain-sync-memory.sh, added
# specifically so these tests never need the live memory store.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/gbrain-sync-memory.sh"
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }
contains(){
  case "$2" in
    *"$3"*) pass=$((pass+1)) ;;
    *) fail=$((fail+1)); echo "FAIL: $1 — output did not contain '$3'"; echo "--- output ---"; echo "$2"; echo "--------------" ;;
  esac
}
not_contains(){
  case "$2" in
    *"$3"*) fail=$((fail+1)); echo "FAIL: $1 — output unexpectedly contained '$3'" ;;
    *) pass=$((pass+1)) ;;
  esac
}

# ── stub gbrain: first on PATH, real gbrain is never invoked ────────────────
# It only understands `sync --source <name> --no-pull` and answers by looking
# at real git status in the fixture dir for that source -- so its warning
# line matches gbrain's real wording exactly, verbatim, and reflects whatever
# the test just did to the fixture (mirrors real gbrain's behavior instead of
# needing a parallel "which test case am I in" flag).
STUBDIR="$(mktemp -d)"
cat > "$STUBDIR/gbrain" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
cmd="${1:-}"; shift || true
src=""
while [ $# -gt 0 ]; do
  case "$1" in
    --source) src="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ "$cmd" != "sync" ]; then
  echo "gbrain-stub: unsupported command $cmd" >&2
  exit 1
fi
dir_for() {
  case "$1" in
    agent-claude-public)  echo "$AGENT_MEMORY_ROOT/agents/claude/public" ;;
    agent-claude-private) echo "$AGENT_MEMORY_ROOT/agents/claude/private/curated" ;;
    agent-shared-public)  echo "$AGENT_MEMORY_ROOT/shared/public" ;;
    *) echo "" ;;
  esac
}
d="$(dir_for "$src")"
if [ -n "$d" ] && [ -d "$d" ]; then
  st="$(git -C "$d" status --porcelain 2>/dev/null)"
  untracked="$(printf '%s\n' "$st" | grep -cE '^\?\?|^A ')"
  modified="$(printf '%s\n' "$st" | grep -cE '^ M|^M ')"
  deleted="$(printf '%s\n' "$st" | grep -cE '^ D|^D ')"
  total=$((untracked + modified + deleted))
  if [ "$total" -gt 0 ]; then
    echo "[sync] $total uncommitted file(s) are invisible to commit-driven sync ($untracked untracked/added, $modified modified, $deleted deleted)."
    exit 0
  fi
fi
echo "[sync] up to date"
exit 0
STUB
chmod +x "$STUBDIR/gbrain"
export PATH="$STUBDIR:$PATH"

# ── fixture helpers ──────────────────────────────────────────────────────
# A fresh AGENT_MEMORY_ROOT with the three owned namespace repos the script
# knows about (agent-claude-public / agent-claude-private / agent-shared-public),
# each already committed once so the baseline is clean (pending == 0).
new_fixture() {
  local root
  root="$(mktemp -d)"
  local d
  for d in agents/claude/public agents/claude/private/curated shared/public; do
    mkdir -p "$root/$d"
    git -C "$root/$d" init -q
    git -C "$root/$d" config user.email test@example.com
    git -C "$root/$d" config user.name test
    echo "seed" > "$root/$d/seed.md"
    git -C "$root/$d" add -A
    git -C "$root/$d" commit -q -m seed
  done
  printf '%s' "$root"
}

run_wrapper() {
  local root="$1"; shift
  AGENT_MEMORY_ROOT="$root" bash "$SCRIPT" "$@"
}

# ── 1. clean state: exit 0, prints the success line ────────────────────────
ROOT1="$(new_fixture)"
out1="$(run_wrapper "$ROOT1" 2>&1)"; rc1=$?
ok "clean-exit-code" "$rc1" "0"
contains "clean-success-line" "$out1" "[gbrain-sync-memory] done (all sources committed and indexed)"
rm -rf "$ROOT1"

# ── 2. a stranded uncommitted file: exit 1, output names gbrain's real
#      warning verbatim. This is the lossy-grep regression guard: the old
#      wrapper piped gbrain's output through a grep that never matched this
#      exact string and reported "done" regardless -- 86 files sat unindexed
#      for months while it claimed success. If this string stops appearing,
#      that bug is back. ────────────────────────────────────────────────────
ROOT2="$(new_fixture)"
echo "stray" > "$ROOT2/agents/claude/public/stray.md"
out2="$(run_wrapper "$ROOT2" 2>&1)"; rc2=$?
ok "stranded-exit-code" "$rc2" "1"
contains "stranded-warning-verbatim" "$out2" "invisible to commit-driven sync"
# Perturbation: commit the stray file in the same fixture and re-run. The
# warning must disappear and exit must go back to 0 -- proves the assertion
# above is actually keyed off the stranded file, not always-true.
git -C "$ROOT2/agents/claude/public" add -A
git -C "$ROOT2/agents/claude/public" commit -q -m "commit the stray file"
out2b="$(run_wrapper "$ROOT2" 2>&1)"; rc2b=$?
ok "stranded-perturbation-exit-code" "$rc2b" "0"
not_contains "stranded-perturbation-warning-gone" "$out2b" "invisible to commit-driven sync"
rm -rf "$ROOT2"

# ── 3. --commit: commits the pending file and reports it ───────────────────
ROOT3="$(new_fixture)"
echo "new memory" > "$ROOT3/agents/claude/public/new-memory.md"
out3="$(run_wrapper "$ROOT3" --commit 2>&1)"; rc3=$?
ok "commit-exit-code" "$rc3" "0"
contains "commit-reports-committed" "$out3" "committed 1 pending file(s) in agent-claude-public"
status3="$(git -C "$ROOT3/agents/claude/public" status --porcelain)"
ok "commit-actually-committed" "$status3" ""
rm -rf "$ROOT3"

# ── 4. a file with a secret-shaped string: refuses to auto-commit, exit 1 ──
# Fixture literal is fake ("Bearer " + 34 A's) -- it is not a credential, it
# only needs to match the script's own SECRET_RE (`Bearer [A-Za-z0-9._-]{20,}`).
ROOT4="$(new_fixture)"
echo "Bearer AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" > "$ROOT4/agents/claude/public/leak.md"
out4="$(run_wrapper "$ROOT4" --commit 2>&1)"; rc4=$?
ok "secret-exit-code" "$rc4" "1"
contains "secret-refused-message" "$out4" "SECRET-SHAPED STRING found in agent-claude-public"
status4="$(git -C "$ROOT4/agents/claude/public" status --porcelain)"
contains "secret-file-left-uncommitted" "$status4" "leak.md"
# Perturbation: same fixture, same filename, secret string removed. Must now
# commit cleanly -- proves the refusal above is triggered by the secret
# content, not by something else about the fixture or the filename.
echo "totally normal memory, no secrets here" > "$ROOT4/agents/claude/public/leak.md"
out4b="$(run_wrapper "$ROOT4" --commit 2>&1)"; rc4b=$?
ok "secret-perturbation-commits" "$rc4b" "0"
contains "secret-perturbation-reports-committed" "$out4b" "committed 1 pending file(s) in agent-claude-public"
status4b="$(git -C "$ROOT4/agents/claude/public" status --porcelain)"
ok "secret-perturbation-clean-tree" "$status4b" ""
rm -rf "$ROOT4"

rm -rf "$STUBDIR"

echo "gbrain-sync-memory: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
