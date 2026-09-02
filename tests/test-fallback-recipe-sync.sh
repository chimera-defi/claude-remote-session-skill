#!/usr/bin/env bash
# test-fallback-recipe-sync.sh — regression: references/fallback-recipe.md is a
# hand-maintained duplicate of the start-script generation logic in
# scripts/new-session.sh. When new-session.sh gets a correctness fix to that
# generated script, fallback-recipe.md must get the same fix or the documented
# "use this when new-session is missing" emergency path silently reintroduces
# the bug new-session.sh already fixed.
#
# Concrete case this guards (found in review): commit 12e14a6 fixed a real
# race in new-session.sh — the kickoff Enter that launches the supervisor loop
# can be dropped, leaving the loop typed-but-not-submitted with the session
# idle forever and no error. The fix (wait for the pane's shell to be ready,
# then send Enter in a verified retry loop) was never ported to
# fallback-recipe.md, so pasting the fallback recipe still hit the bug the
# primary script no longer has.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NS="$HERE/../scripts/new-session.sh"
FB="$HERE/../references/fallback-recipe.md"
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }
has(){ if grep -qF "$2" "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — pattern not found in $3: $2"; fi; }

# Both scripts wait for the pane's interactive shell before typing into it.
has "new-session-waits-for-shell" 'bash|zsh|sh) break ;;' "$NS"
has "fallback-waits-for-shell"    'bash|zsh|sh) break ;;' "$FB"

# Both scripts send the kickoff Enter in a verified retry loop (not a single
# blind `Enter` appended to the send-keys payload).
has "new-session-verifies-kickoff" 'claude|node|sleep) kicked=yes; break ;;' "$NS"
has "fallback-verifies-kickoff"    'claude|node|sleep) kicked=yes; break ;;' "$FB"

# Both scripts distinguish a verified start from an unverified one in the log.
has "new-session-logs-unverified" 'started-UNVERIFIED-kickoff-may-have-failed' "$NS"
has "fallback-logs-unverified"    'started-UNVERIFIED-kickoff-may-have-failed' "$FB"

# The fallback's generated script must NOT end its send-keys payload with a
# bare trailing ` Enter` (the pre-fix shape: submit blind, never verify).
ok "fallback-no-blind-trailing-enter" "$(grep -cE "^done' Enter$" "$FB")" "0"

# $SERVICE must be quoted in the final `basename` call, like new-session.sh's
# equivalent line — an unquoted expansion is a word-splitting/glob hazard on
# any path containing whitespace or shell metacharacters.
has "fallback-quotes-service-basename" 'basename "$SERVICE"' "$FB"

# Both scripts guard the .claude/skills symlink instead of unconditionally
# `rm -rf`-ing it: new-session.sh commit 4469055 fixed a bug where every spawn
# silently destroyed a repo's own committed project-scoped .claude/skills/
# (only a missing path or a symlink this script itself owns may be replaced;
# a real directory there is left alone). fallback-recipe.md carried its own
# copy of the pre-fix unconditional `rm -rf ... && ln -sf` line, so the
# documented emergency path reintroduced the exact bug new-session.sh no
# longer has.
has "new-session-guards-skills-symlink" '[ -L "\$RUNDIR/.claude/skills" ] || [ ! -e "\$RUNDIR/.claude/skills" ]' "$NS"
has "fallback-guards-skills-symlink"    '[ -L "\$RUNDIR/.claude/skills" ] || [ ! -e "\$RUNDIR/.claude/skills" ]' "$FB"
ok "fallback-no-unconditional-skills-rm" "$(grep -cE '^rm -rf "\$RUNDIR/\.claude/skills" && ln -sf' "$FB")" "0"

# The fallback's default MODEL (no CLAUDE_SESSION_MODEL set) must match
# new-session.sh's actual default-profile model, not a stale hardcoded value.
# Found in review: new-session.sh commit 66d1e63/cb733ec moved the no-env
# default from a flat "sonnet" to a per-profile default (orchestrator ->
# claude-opus-5, pinned), but neither that commit nor the later doc-sync
# commit (9d4c420) touched fallback-recipe.md, so the documented emergency
# path still silently spawned sonnet instead of the intended opus default.
ns_default_model="$(grep -oE 'orchestrator\) MODEL=[a-zA-Z0-9._-]+' "$NS" | sed -E 's/.*MODEL=//')"
ok "fallback-model-default-matches-new-session" \
  "$(grep -cF "CLAUDE_SESSION_MODEL:-${ns_default_model}}" "$FB")" "1"
ok "fallback-model-default-not-stale-sonnet" \
  "$(grep -cE 'MODEL="\$\{CLAUDE_SESSION_MODEL:-sonnet\}"' "$FB")" "0"

# Both scripts' claude invocation carries --exclude-dynamic-system-prompt-sections
# (new-session.sh commit c065420: a prompt-cache-reuse win applied unconditionally
# for every CLAUDE_SESSION_PROFILE, including the orchestrator default that the
# fallback recipe's non-PROFILE-aware invocation matches). Found in review: the
# flag landed in new-session.sh's CLAUDE_EXTRA_FLAGS but was never ported to the
# fallback recipe's two `/usr/bin/claude ...` lines, so the documented emergency
# path silently lost the cache-reuse win new-session.sh already has.
has "new-session-has-cache-flag" 'CLAUDE_EXTRA_FLAGS="--exclude-dynamic-system-prompt-sections"' "$NS"
# The fallback recipe's invocation has no CLAUDE_EXTRA_FLAGS variable (it isn't
# PROFILE-aware), so check the flag is baked directly into BOTH claude
# invocation lines (fresh-start and --continue), not just mentioned in prose.
ok "fallback-cache-flag-on-both-invocations" \
  "$(grep -cE -- '^\s*/usr/bin/claude .*--exclude-dynamic-system-prompt-sections' "$FB")" "2"

echo "fallback-recipe-sync: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
