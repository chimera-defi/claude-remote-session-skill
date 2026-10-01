#!/usr/bin/env bash
# test-create-session-command.sh — regression: the /create-session command must
# stay a thin pointer at new-session.sh, never a hand-rolled recipe.
#
# Concrete failure this guards: a DEPLOYED global command at
# ~/.claude/commands/create-session.md was a stale physical copy
# that still told the model to derive SESSION=oldhost_<folder>-<YYYYMMDD>, to
# hand-write the start script and systemd unit inline, and to commit them to
# `<mono-repo>/scripts/oldhost/`. Every one of those is wrong now: the naming
# scheme is px_<alias>-<MMDD-HHMM>, new-session.sh generates the unit, and the
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
source "$HERE/lib.sh"
CMD="$HERE/../.claude/commands/create-session.md"
has(){ if grep -qF "$2" "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — pattern not found in $3: $2"; fi; }

isfile "command-file-exists" "$CMD"

# It must delegate to the script, and name the ONE sanctioned manual fallback.
has "delegates-to-new-session"     'new-session "$FOLDERNAME"' "$CMD"
has "points-at-fallback-recipe"    'references/fallback-recipe.md' "$CMD"
has "forbids-hand-rolling-inline"  'do not hand-roll the start script/systemd unit inline' "$CMD"

# It must NOT re-teach the legacy creation scheme. `oldhost_`/`oldhost-` are
# still recognised by session-doctor/handoff/preserve/registry for the live
# legacy session, but nothing should ever CREATE one again.
ok "no-legacy-oldhost-naming" "$(grep -cE 'oldhost[_-]' "$CMD")" "0"
# The date shape too: legacy was `date +%Y%m%d`, current is <MMDD-HHMM>.
ok "no-legacy-date-derivation"  "$(grep -cE 'date \+%Y%m%d' "$CMD")" "0"
has "documents-current-name-shape" '<prefix>-<alias>-<MMDD-HHMM>' "$CMD"
# ...and must not hard-code a concrete host's session prefix (ah/px/cs + -|_ + <alias>).
ok "no-hardcoded-prefix-name-shape" "$(grep -cE '\b(ah|px|cs)[_-]<alias>' "$CMD")" "0"

# It must NOT walk the model through writing the unit/start script by hand.
ok "no-inline-start-script-step" "$(grep -cE 'Create the start script at' "$CMD")" "0"
ok "no-inline-systemd-step"      "$(grep -cE 'Create the systemd service at' "$CMD")" "0"
ok "no-manual-daemon-reload"     "$(grep -cE 'systemctl --user daemon-reload &&' "$CMD")" "0"

# Generated scripts are local-only — the stale copy told the user to commit them.
ok "no-stale-monorepo-commit" "$(grep -cE 'Etc-mono-repo' "$CMD")" "0"
has "states-local-only"       'local-only' "$CMD"

finish "create-session command"
