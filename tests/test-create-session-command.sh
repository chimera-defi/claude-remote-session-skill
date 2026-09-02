#!/usr/bin/env bash
# test-create-session-command.sh — regression: the /create-session command must
# stay a thin pointer at new-session.sh, never a hand-rolled recipe.
#
# Concrete incident this guards (2026-09-02): the DEPLOYED global command at
# ~/.claude/commands/create-session.md was a stale physical copy from 2026-06-08
# that still told the model to derive SESSION=agenthost_<folder>-<YYYYMMDD>, to
# hand-write the start script and systemd unit inline, and to commit them to
# Etc-mono-repo/scripts/agenthost/. Every one of those is wrong now: the naming
# scheme is ah_<alias>-<MMDD-HHMM>, new-session.sh generates the unit, and the
# generated scripts are explicitly local-only. Invoking /create-session outside
# this repo therefore produced a session named on the legacy scheme with none of
# the aliasing, profile/model defaults, or same-minute collision lock — the exact
# divergence class that PRs #44-#46 were patching in the fallback recipe.
#
# The repo copy was already correct; only the deployed copy had rotted, because
# ~/.claude/skills/gstack-session-spawn is a SYMLINK to this repo (so SKILL.md
# can never drift) while ~/.claude/commands/create-session.md was a plain file
# that nothing kept in sync. It is now symlinked to this file too, and this test
# guards the source of that symlink so the recipe cannot creep back in.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CMD="$HERE/../.claude/commands/create-session.md"
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }
has(){ if grep -qF "$2" "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — pattern not found in $3: $2"; fi; }

ok "command-file-exists" "$([ -f "$CMD" ] && echo yes || echo no)" "yes"

# It must delegate to the script, and name the ONE sanctioned manual fallback.
has "delegates-to-new-session"     'new-session "$FOLDERNAME"' "$CMD"
has "points-at-fallback-recipe"    'references/fallback-recipe.md' "$CMD"
has "forbids-hand-rolling-inline"  'do not hand-roll the start script/systemd unit inline' "$CMD"

# It must NOT re-teach the legacy creation scheme. `agenthost_`/`agenthost-` are
# still recognised by session-doctor/handoff/preserve/registry for the live
# legacy session, but nothing should ever CREATE one again.
ok "no-legacy-agenthost-naming" "$(grep -cE 'agenthost[_-]' "$CMD")" "0"
# The date shape too: legacy was `date +%Y%m%d`, current is <MMDD-HHMM>.
ok "no-legacy-date-derivation"  "$(grep -cE 'date \+%Y%m%d' "$CMD")" "0"
has "documents-current-name-shape" 'ah-<alias>-<MMDD-HHMM>' "$CMD"

# It must NOT walk the model through writing the unit/start script by hand.
ok "no-inline-start-script-step" "$(grep -cE 'Create the start script at' "$CMD")" "0"
ok "no-inline-systemd-step"      "$(grep -cE 'Create the systemd service at' "$CMD")" "0"
ok "no-manual-daemon-reload"     "$(grep -cE 'systemctl --user daemon-reload &&' "$CMD")" "0"

# Generated scripts are local-only — the stale copy told the user to commit them.
ok "no-stale-monorepo-commit" "$(grep -cE 'Etc-mono-repo' "$CMD")" "0"
has "states-local-only"       'local-only' "$CMD"

echo "create-session command: pass=$pass fail=$fail"; [ "$fail" -eq 0 ]
