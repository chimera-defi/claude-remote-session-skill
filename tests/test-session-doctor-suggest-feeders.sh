#!/usr/bin/env bash
# session-doctor.sh `suggest-feeders`: only a suggestion-enabled interactive TUI is a feeder.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
isolate_overlay
SD="$HERE/../scripts/session-doctor.sh"
FH="$(mktemp -d)"; P="$FH/proc"; mkdir -p "$P" "$FH/home"
printf '{"promptSuggestionUnusedStreak": 20}\n' > "$FH/home/.claude.json"
printf '{"env":{"CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION":"0"}}\n' > "$FH/off.json"
mk() { local pid=$1 env=$2; shift 2; mkdir -p "$P/$pid"; printf '%s\0' "$@" > "$P/$pid/cmdline"; printf '%s' "$env" > "$P/$pid/environ"; }
mk 101 "" /usr/bin/claude --dangerously-skip-permissions --remote-control chimera-server            # TUI, suggestions on
mk 102 "" /usr/bin/claude --dangerously-skip-permissions --settings "$FH/off.json" --remote-control x  # off via --settings
mk 103 "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=0" /usr/bin/claude --dangerously-skip-permissions         # off via env
mk 104 "" /usr/bin/claude remote-control --name workspace                                              # server, no REPL
mk 105 "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=1" /usr/bin/claude --print --sdk-url https://x            # SDK child
mk 106 "" /usr/bin/claude --input-format stream-json --output-format stream-json                       # stream-json
mk 107 "" /usr/bin/vim notes
out="$(HOME="$FH/home" PROC_ROOT="$P" bash "$SD" suggest-feeders 2>&1)"; rc=$?
has "streak shown" "$out" "promptSuggestionUnusedStreak=20"
has "enabled TUI is a feeder" "$out" "FEEDER pid=101"
has "two quiet TUIs counted" "$out" "suggestions off: 2"
for n in 102 103 104 105 106 107; do hasnt "pid $n not a feeder" "$out" "pid=$n"; done
ok "rc 0" "$rc" "0"
rm -rf "$P/101"
has "none left" "$(HOME="$FH/home" PROC_ROOT="$P" bash "$SD" suggest-feeders 2>&1)" "no TUI can feed the counter"
finish "session-doctor-suggest-feeders"
