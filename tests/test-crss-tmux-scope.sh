#!/usr/bin/env bash
# The generated start script never forks the shared tmux server into its unit's cgroup (2026-10-24:
# one unit restart killed 29 sessions), and crss-tmux-scope migrate-scripts rewrites older scripts.
# The real proof is the live two-unit restart in the PR; this pins the text both paths depend on.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
NS="$HERE/../scripts/new-session.sh"; TOOL="$HERE/../scripts/crss-tmux-scope.sh"

ok "generator: no bare tmux new-session line" "$(grep -cE '^tmux new-session ' "$NS")" "0"
has "generator: new-session goes through the scope helper" "$(cat "$NS")" '_crss_tmux new-session -d -s "${SESSION}"'
has "generator: helper uses a transient systemd scope" "$(cat "$NS")" 'systemd-run --user --scope --quiet --collect -- tmux'

BIN="$(mktemp -d)"; trap 'rm -rf "$BIN"' EXIT
printf '#!/usr/bin/env bash\ntmux new-session -d -s x -c "$RUNDIR"\ntmux send-keys -t x Enter\n' > "$BIN/x-start.sh"
cp "$BIN/x-start.sh" "$BIN/orig"
out="$(CRSS_BIN_DIR="$BIN" bash "$TOOL" migrate-scripts 2>&1)"
has "dry-run names the script" "$out" "would migrate $BIN/x-start.sh"
ok "dry-run leaves it untouched" "$(cmp -s "$BIN/x-start.sh" "$BIN/orig" && echo same)" "same"
CRSS_BIN_DIR="$BIN" bash "$TOOL" migrate-scripts --apply >/dev/null 2>&1; rc=$?
ok "apply exits 0" "$rc" "0"
has "apply wraps new-session" "$(cat "$BIN/x-start.sh")" 'systemd-run --user --scope --quiet --collect -- tmux new-session -d -s x'
ok "apply leaves other tmux calls" "$(grep -c "^tmux send-keys -t x Enter" "$BIN/x-start.sh")" "1"
ok "backup kept" "$(cmp -s "$BIN/x-start.sh.bak-precgroup" "$BIN/orig" && echo same)" "same"
has "second run is a no-op" "$(CRSS_BIN_DIR="$BIN" bash "$TOOL" migrate-scripts --apply 2>&1)" "no start script"
ok "unknown command exits 2" "$(bash "$TOOL" bogus >/dev/null 2>&1; echo $?)" "2"
finish test-crss-tmux-scope
