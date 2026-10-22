#!/usr/bin/env bash
# session-spawn-server: generated start script + unit (dry-run text and real install with stubbed
# systemctl/tmux). Live registration was checked by hand against the installed CLI; see
# references/phone-spawn.md.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
isolate_overlay
S="$HERE/../scripts/session-spawn-server.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T" "$TELEMETRY_ROOT"' EXIT
unset CLAUDE_CONFIG_DIR; export HOME="$T/hm" CRSS_BIN_DIR="$T/hm/bin" CRSS_SYSTEMD_DIR="$T/hm/units" CRSS_CLAUDE_BIN=/usr/bin/claude
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
has "own namespace, outside session prefixes" "$out" "SESSION=crss-spawn-repo"

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

# Execute the generated launcher (Codex review): hostile dir name, own tmux socket, exact targets.
printf '#!/bin/sh\necho "$PWD|$ANTHROPIC_BASE_URL|$*" > %s/claude-ran\nkill -TERM $PPID\n' "$T" > "$T/fakeclaude"; chmod +x "$T/fakeclaude"
evil="$T/odd dir \$(touch $T/PWNED) \`x\` 'q'"; mkdir -p "$evil"; : > "$T/calls"
CRSS_CLAUDE_BIN="$T/fakeclaude" bash "$S" install "$evil" --name odd >/dev/null 2>&1
gen="$CRSS_BIN_DIR/crss-spawn-odd-start.sh"
bash "$gen" >/dev/null 2>&1
calls="$(cat "$T/calls")"
has "has-session on own socket, exact target" "$calls" "tmux -L crss-spawn-odd has-session -t =crss-spawn-odd"
has "new-session on own socket" "$calls" "tmux -L crss-spawn-odd new-session -d -s crss-spawn-odd"
(cd / && timeout 10 bash "$gen" --loop >/dev/null 2>&1)
ran="$(cat "$T/claude-ran" 2>/dev/null)"
ok "loop ran claude in the odd dir" "${ran%%|*}" "$evil"
has "first-party env reached claude" "$ran" "|https://api.anthropic.com|remote-control --name odd --spawn same-dir"
gone "dir name never evaluated as code" "$T/PWNED"
bash "$S" uninstall odd >/dev/null 2>&1
has "uninstall kills only its own tmux server" "$(cat "$T/calls")" "tmux -L crss-spawn-odd kill-server"
ok "unit path with a space refused" "$(CRSS_BIN_DIR="$T/bin space" bash "$S" install "$T/repo" --dry-run >/dev/null 2>&1; echo $?)" 2
finish "session-spawn-server"
