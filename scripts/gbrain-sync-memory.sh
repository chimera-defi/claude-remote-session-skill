#!/usr/bin/env bash
# Sync agent-memory into gbrain. Call after writing new memories.
#
# Usage: gbrain-sync-memory [--all] [--commit]
#   --all     also sync the other agents' public namespaces (read-only for us)
#   --commit  auto-commit uncommitted files in OUR OWN namespaces first
#
# WHY THIS SCRIPT CHECKS GIT (2026-09-12):
#   `gbrain sync` is COMMIT-DRIVEN. Files written but not committed are invisible to
#   the index -- and therefore to every sibling session. This wrapper previously piped
#   gbrain through `grep -E '(imported|error|done|complete|stale)' || true`, which does
#   not match gbrain's real warning string ("uncommitted file(s) are invisible to
#   commit-driven sync"), then echoed its own "done". The result: 86 files of shared
#   memory sat unindexed since ~2026-07 while the wrapper reported success every time.
#   Never let this wrapper claim success it did not verify.
set -uo pipefail

REPO="/home/agents/agent-memory"

SOURCES=(agent-claude-public agent-claude-private agent-shared-public)
EXTRA=(agent-codex-public agent-hermes-public agent-openclaw-public agent-opencode-public)

# source name -> working directory
dir_for() {
  case "$1" in
    agent-claude-public)   echo "$REPO/agents/claude/public" ;;
    agent-claude-private)  echo "$REPO/agents/claude/private/curated" ;;
    agent-shared-public)   echo "$REPO/shared/public" ;;
    agent-codex-public)    echo "$REPO/agents/codex/public" ;;
    agent-hermes-public)   echo "$REPO/agents/hermes/public" ;;
    agent-openclaw-public) echo "$REPO/agents/openclaw/public" ;;
    agent-opencode-public) echo "$REPO/agents/opencode/public" ;;
    *)                     echo "" ;;
  esac
}

# Namespaces we are allowed to commit. Never auto-commit another agent's memory.
owned() { [[ "$1" == agent-claude-* || "$1" == agent-shared-public ]]; }

DO_COMMIT=0
for arg in "$@"; do
  case "$arg" in
    --all)    SOURCES+=("${EXTRA[@]}") ;;
    --commit) DO_COMMIT=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# Secret-shaped strings. A hit blocks the auto-commit -- inspect by hand.
SECRET_RE='(sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|eyJ[A-Za-z0-9_-]{30,}|BEGIN [A-Z ]*PRIVATE KEY|Bearer [A-Za-z0-9._-]{20,})'

STRANDED=()

for src in "${SOURCES[@]}"; do
  d="$(dir_for "$src")"
  echo "[gbrain-sync-memory] syncing $src..."

  if [[ -n "$d" && -d "$d" ]]; then
    pending="$(git -C "$d" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$pending" != "0" ]]; then
      if [[ "$DO_COMMIT" == "1" ]] && owned "$src"; then
        if git -C "$d" status --porcelain | sed 's/^...//' | tr -d '"' \
             | while read -r f; do [[ -f "$d/$f" ]] && grep -lEq "$SECRET_RE" "$d/$f" 2>/dev/null && echo "$f"; done \
             | grep -q .; then
          echo "  !! SECRET-SHAPED STRING found in $src -- refusing to auto-commit. Inspect by hand." >&2
          STRANDED+=("$src ($pending file(s), secret scan tripped)")
          continue
        fi
        git -C "$d" add -A
        git -C "$d" commit -q -m "memory($src): sync $pending pending file(s) into the gbrain index

gbrain sync is commit-driven; uncommitted files are invisible to the index.

Co-authored-by: Chimera <chimera_defi@protonmail.com>
Co-Authored-By: Claude <noreply@anthropic.com>" \
          && echo "  committed $pending pending file(s) in $src"
      else
        echo "  !! $pending UNCOMMITTED file(s) in $d" >&2
        echo "     gbrain sync is commit-driven -- these will NOT be indexed." >&2
        if owned "$src"; then
          echo "     Fix: gbrain-sync-memory --commit   (or commit by hand in that dir)" >&2
        else
          echo "     Not our namespace -- leave it for its owning agent." >&2
        fi
        STRANDED+=("$src ($pending file(s))")
      fi
    fi
  fi

  # Do NOT filter gbrain's output through a lossy grep. Surface warnings verbatim.
  out="$(gbrain sync --source "$src" --no-pull 2>&1)"
  echo "$out" | grep -E "(imported|sync\.imports|error|Error|complete|stale|invisible|not synced|up to date)" \
    | grep -v "UPGRADE_AVAILABLE" | sed 's/^/  /'
  if echo "$out" | grep -qE "invisible to commit-driven sync"; then
    STRANDED+=("$src (gbrain reported stranded files)")
  fi
done

if (( ${#STRANDED[@]} )); then
  echo
  echo "[gbrain-sync-memory] INCOMPLETE -- files were NOT indexed:" >&2
  printf '  - %s\n' "${STRANDED[@]}" >&2
  echo "Those memories are invisible to every other session until committed." >&2
  exit 1
fi

echo "[gbrain-sync-memory] done (all sources committed and indexed)"
