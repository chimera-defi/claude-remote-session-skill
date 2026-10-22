#!/usr/bin/env bash
# session-spawn-server: generated start script + unit (dry-run text and real install with stubbed
# systemctl/tmux). Live registration was checked by hand against the installed CLI; see
# references/phone-spawn.md.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
isolate_overlay
S="$HERE/../scripts/session-spawn-server.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T" "$TELEMETRY_ROOT"' EXIT
unset CLAUDE_CONFIG_DIR; export HOME="$T/home" CRSS_BIN_DIR="$T/home/bin" CRSS_SYSTEMD_DIR="$T/home/units" CRSS_CLAUDE_BIN=/usr/bin/claude
mkdir -p "$HOME"
printf '#!/bin/sh\necho "systemctl $*" >> %s/calls\n' "$T" > "$T/systemctl"; chmod +x "$T/systemctl"
printf '#!/bin/sh\necho "tmux $*" >> %s/calls\nexit 1\n' "$T" > "$T/tmux"; chmod +x "$T/tmux"
export CRSS_SYSTEMCTL="$T/systemctl" CRSS_TMUX="$T/tmux" PATH="$T:$PATH"
git init -q "$T/repo"; mkdir -p "$T/plain dir"

out="$(bash "$S" install "$T/repo" --model 'opus[1m]' --dry-run)"
has "first-party base URL exported" "$out" "export ANTHROPIC_BASE_URL=https://api.anthropic.com"
has "model via env, quoted" "$out" 'ANTHROPIC_MODEL=opus\[1m\]'
has "git dir defaults to worktree, no pre-created session" "$out" "--spawn worktree --capacity 4 --permission-mode auto --no-create-session-in-dir"
hasnt "never --continue (crash-loops after ~4h idle)" "$out" "remote-control -c"
hasnt "no --settings (remote-control rejects it)" "$out" "--settings"
has "own namespace, outside session prefixes" "$out" "SESSION=\"crss-spawn-repo\""

out="$(bash "$S" install "$T/plain dir" --name 'My Box' --dry-run)"
has "non-git defaults to same-dir" "$out" "--spawn same-dir"
hasnt "non-git keeps the pre-created session" "$out" "--no-create-session-in-dir"
has "name sanitised" "$out" "--name my-box"

ok "worktree on non-git refused" "$(bash "$S" install "$T/plain dir" --spawn worktree --dry-run >/dev/null 2>&1; echo $?)" 2
ok "bad model refused" "$(bash "$S" install "$T/repo" --model 'x;rm' --dry-run >/dev/null 2>&1; echo $?)" 2
has "bypass only on explicit opt-in" "$(bash "$S" install "$T/repo" --permission-mode bypassPermissions --dry-run)" "--permission-mode bypassPermissions"
ok "session spawn mode refused" "$(bash "$S" install "$T/repo" --spawn session --dry-run >/dev/null 2>&1; echo $?)" 2

bash "$S" install "$T/repo" >/dev/null 2>&1
isfile "unit written" "$CRSS_SYSTEMD_DIR/crss-spawn-repo.service"
ok "start script executable" "$(yn test -x "$CRSS_BIN_DIR/crss-spawn-repo-start.sh")" yes
has "unit enabled" "$(cat "$T/calls")" "systemctl --user enable --now crss-spawn-repo.service"
ok "reinstall refused" "$(bash "$S" install "$T/repo" >/dev/null 2>&1; echo $?)" 1
has "status lists it" "$(bash "$S" status)" "crss-spawn-repo"
bash "$S" uninstall crss-spawn-repo >/dev/null 2>&1
nofile "unit removed" "$CRSS_SYSTEMD_DIR/crss-spawn-repo.service"
nofile "start script removed" "$CRSS_BIN_DIR/crss-spawn-repo-start.sh"
finish "session-spawn-server"
