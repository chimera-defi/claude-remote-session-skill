#!/usr/bin/env bash
# new-session.sh --dry-run resolution: --tier / effort / advisor / --escalate-from / per-tier compact window /
# overlay line, plus the generated start script exporting the compact window into the launch environment.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
NS="$HERE/../scripts/new-session.sh"
isolate_overlay
export CRSS_SESSION_PREFIX=px
WORKHOME="$(mktemp -d)"; trap 'rm -rf "$WORKHOME"' EXIT
export HOME="$WORKHOME"; mkdir -p "$HOME/workspace/proj"

# dry ENV... -- ARGS...: dry-run spawn; prints the resolved fields (stderr included).
dry() {
  local envs=(); while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  env -u CLAUDE_SESSION_PROFILE -u CLAUDE_SESSION_MODEL -u CLAUDE_SESSION_EFFORT -u CLAUDE_SESSION_ADVISOR \
    -u CLAUDE_SESSION_COMPACT_WINDOW -u CRSS_COMPACT_WINDOW_HEAVY -u CRSS_COMPACT_WINDOW_STANDARD \
    -u CRSS_COMPACT_WINDOW_LIGHT -u CRSS_COMPACT_WINDOW_DEFAULT \
    -u CRSS_OPUS_MODEL -u CRSS_SESSION_BACKEND -u CRSS_ORCHESTRATOR_PROMPT -u CRSS_AUTONOMOUS \
    -u CRSS_LANE_DENY \
    "${envs[@]}" bash "$NS" proj workspace --dry-run "$@" 2>&1
}

# delegation prompt: Claude orchestrator/owner only, with opt-out and autonomous exclusions
for profile in orchestrator owner; do
  o="$(dry CLAUDE_SESSION_PROFILE="$profile" --)"
  has "$profile appends delegation prompt" "$o" '--append-system-prompt Delegation\ \(operator\ 2026-10-25\,\ keep\ quota\):'
  hasnt "$profile has no hub prompt" "$o" 'You\ are\ a\ Sonnet\ hub.'
  o="$(dry CLAUDE_SESSION_PROFILE="$profile" CRSS_ORCHESTRATOR_PROMPT=off --)"
  hasnt "$profile opt-out removes prompt" "$o" '--append-system-prompt'
  o="$(dry CLAUDE_SESSION_PROFILE="$profile" CRSS_AUTONOMOUS=1 --)"
  hasnt "$profile autonomous skips delegation" "$o" 'Delegation\ \(operator'
  has "$profile autonomous keeps Agent disabled" "$o" '--disallowedTools Agent'
done
for profile in builder copywriter; do
  o="$(dry CLAUDE_SESSION_PROFILE="$profile" --)"
  flags="$(grep '^CLAUDE_EXTRA_FLAGS=' <<<"$o")"
  has "$profile flags contain BLOCKED:" "$flags" 'BLOCKED:'
  has "$profile flags contain session-send" "$flags" 'session-send'
  hasnt "$profile flags omit the launcher sentence without --launcher" "$flags" 'Your\ launcher\ is'
  o="$(dry CLAUDE_SESSION_PROFILE="$profile" CRSS_AUTONOMOUS=1 --)"
  flags="$(grep '^CLAUDE_EXTRA_FLAGS=' <<<"$o")"
  has "autonomous $profile flags contain BLOCKED:" "$flags" 'BLOCKED:'
  has "autonomous $profile flags contain session-send" "$flags" 'session-send'
done
for profile in orchestrator owner hub; do
  o="$(dry CLAUDE_SESSION_PROFILE="$profile" --)"
  hasnt "$profile has no builder escalation prompt" "$(grep '^CLAUDE_EXTRA_FLAGS=' <<<"$o")" 'BLOCKED:'
done
o="$(dry CLAUDE_SESSION_PROFILE=builder -- --launcher ah_x)"
has "builder flags name launcher ah_x" "$(grep '^CLAUDE_EXTRA_FLAGS=' <<<"$o")" 'Your\ launcher\ is\ ah_x.'
o="$(dry CLAUDE_SESSION_PROFILE=hub --)"
has "hub keeps consult prompt" "$o" '--append-system-prompt You\ are\ a\ Sonnet\ hub.'
hasnt "hub has no delegation prompt" "$o" 'Delegation\ \(operator'
o="$(dry CRSS_AUTONOMOUS=1 CLAUDE_SESSION_PROFILE=hub --)"
has "autonomous hub keeps bounded prompt" "$o" '--append-system-prompt Autonomous\ bounded\ session:'
hasnt "autonomous hub has no delegation prompt" "$o" 'Delegation\ \(operator'
o="$(dry A=1 -- --backend codex)"
hasre "Codex has no Claude flags" "$o" '^CLAUDE_EXTRA_FLAGS=$'

# tiers
o="$(dry A=1 --)"
hasre "default: orchestrator on pinned Opus, no tier/advisor/effort" "$o" '^PROFILE=orchestrator$'
hasre "default model" "$o" '^MODEL=claude-opus-5-5$'; hasre "default advisor" "$o" '^ADVISOR=none$'; hasre "default orchestrator effort" "$o" '^EFFORT=medium$'
o="$(dry A=1 -- --tier light)"
hasre "light: copywriter/haiku" "$o" '^PROFILE=copywriter$'; hasre "light model" "$o" '^MODEL=haiku$'
hasre "light advisor is Opus" "$o" '--advisor claude-opus-5-5'; hasre "light effort low (Haiku 5.5 supports effort)" "$o" '--effort low'
o="$(dry A=1 -- --tier standard)"; hasre "standard: builder/sonnet" "$o" '^PROFILE=builder$'; hasre "standard effort low" "$o" '--effort low'
o="$(dry CLAUDE_SESSION_EFFORT=high -- --tier standard)"; hasre "explicit effort beats tier default" "$o" '--effort high'
o="$(dry A=1 -- --tier heavy)"; hasre "heavy: owner/sonnet" "$o" '^PROFILE=owner$'
hasre "heavy is Sonnet, never Opus" "$o" '^MODEL=sonnet$'; hasre "heavy keeps Opus advisor" "$o" '^ADVISOR=claude-opus-5-5$'
hasre "resolved line names model and advisor" "$o" 'resolved: backend=claude profile=owner model=sonnet .*advisor=claude-opus-5-5 tier=heavy'
hasre "tier misread warning" "$o" 'a tier never selects Opus\); for an Opus orchestrator omit --tier'
o2="$(dry A=1 --)"; hasre "bare spawn resolved line is Opus" "$o2" 'resolved: backend=claude profile=orchestrator model=claude-opus-5-5'
o="$(dry CLAUDE_SESSION_PROFILE=orchestrator -- --tier heavy)"; hasre "explicit profile beats tier" "$o" '^PROFILE=orchestrator$'; hasre "Opus has no advisor" "$o" '^ADVISOR=none$'

# auto tier routing: explicit types and task brief keywords
 o="$(dry A=1 -- --tier auto --task-type review)"; hasre "auto review profile" "$o" '^PROFILE=copywriter$'; hasre "auto review model" "$o" '^MODEL=haiku$'; hasre "auto review tier" "$o" '^TIER=light$'
 o="$(dry A=1 -- --tier auto --task-type research)"; hasre "auto research profile" "$o" '^PROFILE=owner$'; hasre "auto research model" "$o" '^MODEL=sonnet$'
 GOODCFG="$(mktemp -d)"; mkdir -p "$GOODCFG"; printf '%s\n' 'CRSS_CODEX_ARGS=-s danger-full-access' > "$GOODCFG/config.sh"
 o="$(dry CRSS_HOME="$GOODCFG" -- --tier auto --task-type build)"; hasre "auto build backend" "$o" '^BACKEND=codex$'; has "auto build model" "$o" '-m gpt-6.1-sol'; has "auto build effort" "$o" 'model_reasoning_effort=high'; hasnt "auto build fast mode off" "$o" 'service_tier=priority'; has "auto build keeps sandbox" "$o" '-s danger-full-access'; rm -rf "$GOODCFG"
 o="$(dry CRSS_CODEX_ARGS='-m custom -s danger-full-access' -- --tier auto --task-type build)"; hasre "env Codex args preserved" "$o" '^CODEX_ARGS=-m custom -s danger-full-access$'
 o="$(dry A=1 -- --tier auto --task 'please review the diff')"; hasre "keyword review maps light" "$o" '^TIER=light$'
 o="$(dry A=1 -- --tier auto)"; hasre "no match maps standard" "$o" '^TIER=standard$'; hasre "no match builder" "$o" '^PROFILE=builder$'
 o="$(dry A=1 -- --backend claude --tier auto --task-type build)"; hasre "explicit backend beats auto" "$o" '^BACKEND=claude$'
 o="$(dry A=1 -- --tier auto --task-type invalid)"; hasre "invalid task type" "$o" 'invalid --task-type'
 o="$(dry CRSS_ORCHESTRATOR_EFFORT=none --)"; hasre "orchestrator effort none" "$o" '^EFFORT=default$'; o="$(dry CLAUDE_SESSION_EFFORT=high --)"; hasre "explicit orchestrator effort wins" "$o" '^EFFORT=high$'

# quota failover uses only isolated fixture directories
QHOME="$(mktemp -d)"; mkdir -p "$QHOME/codex" "$QHOME/claude/project"
printf '%s\n' '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":100,"resets_at":1999999999},"rate_limit_reached_type":"rate_limit_reached"}}}' > "$QHOME/codex/x.jsonl"
o="$(dry CRSS_CODEX_SESSIONS_DIR="$QHOME/codex" CRSS_CLAUDE_PROJECTS_DIR="$QHOME/claude" -- --backend codex)"; hasre "Codex quota failover" "$o" '^BACKEND=claude$'; hasre "Codex quota decision shown" "$o" '^QUOTA=codex-out$'
# quota-check keys on the line's own timestamp, so the fixture needs a fresh one
printf '{"type":"user","timestamp":"%s","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"You'"'"'ve hit your monthly spend limit · raise it at claude.ai/settings/usage"}]}}\n' "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" > "$QHOME/claude/project/error.jsonl"
o="$(dry CRSS_CODEX_SESSIONS_DIR="$QHOME/empty" CRSS_CLAUDE_PROJECTS_DIR="$QHOME/claude" --)"; hasre "Claude quota failover" "$o" '^BACKEND=codex$'; hasre "Claude quota decision shown" "$o" '^QUOTA=claude-out$'
o="$(dry CRSS_CODEX_SESSIONS_DIR="$QHOME/codex" CRSS_CLAUDE_PROJECTS_DIR="$QHOME/claude" --)"; hasre "both quotas out exits 3" "$o" 'both quotas out: pausing' # exit is separately pinned below
set +e; env HOME="$QHOME" CRSS_SESSION_PREFIX=px CRSS_WORKSPACE="$QHOME/workspace" CRSS_SESSIONS_DIR="$QHOME/sessions" CRSS_CODEX_SESSIONS_DIR="$QHOME/codex" CRSS_CLAUDE_PROJECTS_DIR="$QHOME/claude" bash "$NS" proj workspace --dry-run >/dev/null 2>&1; _both_rc=$?; set +e
ok "both quotas exit code" "$_both_rc" 3
 o="$(dry CRSS_QUOTA_FAILOVER=0 CRSS_CODEX_SESSIONS_DIR="$QHOME/codex" -- --backend codex)"; hasre "quota failover disabled" "$o" '^BACKEND=codex$'; hasre "disabled quota marker" "$o" '^QUOTA=none$'
# deployed layout drops .sh: new-session must find quota-check on PATH
mkdir -p "$WORKHOME/bin"; cp "$NS" "$WORKHOME/bin/new-session"; cp "$HERE/../scripts/quota-check.sh" "$WORKHOME/bin/quota-check"
o="$(NS="$WORKHOME/bin/new-session" PATH="$WORKHOME/bin:$PATH" dry CRSS_CODEX_SESSIONS_DIR="$QHOME/codex" CRSS_CLAUDE_PROJECTS_DIR="$QHOME/empty" -- --backend codex)"; hasre "deployed layout finds quota-check" "$o" '^QUOTA=codex-out$'
rm -rf "$QHOME"

# advisor: one Opus source, overridable, validated
o="$(dry CRSS_OPUS_MODEL=claude-opus-9-9 -- --tier standard)"; hasre "Opus id feeds the advisor" "$o" '--advisor claude-opus-9-9'
o="$(dry CLAUDE_SESSION_ADVISOR=claude-fable-5-1 -- )"; hasre "explicit advisor honoured on the Opus orchestrator" "$o" '--advisor claude-fable-5-1'
o="$(dry A=1 -- --launcher no-such-tmux-session-xyz)"; has "unreachable launcher is flagged" "$o" "not a live tmux session"
o="$(dry CLAUDE_SESSION_ADVISOR=none -- --tier standard)"; hasnt "advisor=none drops the flag" "$o" '--advisor'
o="$(dry CLAUDE_SESSION_ADVISOR='x;y' -- --tier standard)"; hasre "bad advisor id refused" "$o" 'invalid'
o="$(dry CRSS_OPUS_MODEL='a b' -- --backend codex)"; hasre "bad Opus id harmless for codex" "$o" '^BACKEND=codex$'

# bad inputs
o="$(dry A=1 -- --tier bogus)"; hasre "bad tier" "$o" 'unknown --tier'
o="$(dry CLAUDE_SESSION_EFFORT=turbo -- --tier light)"; hasre "bad effort" "$o" 'invalid'
o="$(dry CLAUDE_SESSION_PROFILE=bulder -- --tier light)"; hasre "typo'd profile refused under a tier" "$o" 'unknown CLAUDE_SESSION_PROFILE'
o="$(dry CLAUDE_SESSION_PROFILE=bulder --)"; hasre "typo'd profile falls back without a tier" "$o" '^PROFILE=orchestrator$'

# --escalate-from: one tier above the recorded tier; explicit --tier wins
TR="$(mktemp -d)"; mkdir -p "$TR/artifacts/telemetry"
cat > "$TR/artifacts/telemetry/events.jsonl" <<'J'
{"event":"spawn","timestamp":"2026-10-05T10:00:00+00:00","session":"px_l-1","remote_name":"px-l-1","routing":{"tier":"light"},"meta":{}}
{"event":"spawn","timestamp":"2026-10-05T10:00:00+00:00","session":"px_h-1","remote_name":"px-h-1","routing":{"tier":"heavy"},"meta":{}}
{"event":"spawn","timestamp":"2026-10-05T10:00:00+00:00","session":"px_n-1","remote_name":"px-n-1","meta":{}}
J
o="$(dry TELEMETRY_ROOT="$TR" -- --escalate-from px_l-1)"; hasre "escalate light -> standard" "$o" '^TIER=standard$'
o="$(dry TELEMETRY_ROOT="$TR" -- --escalate-from px_h-1)"; has "escalate past heavy -> Opus" "$o" "escalating past it to Opus"; hasre "escalate past heavy profile" "$o" '^PROFILE=orchestrator$'
o="$(dry TELEMETRY_ROOT="$TR" -- --escalate-from px_n-1)"; hasre "unknown tier assumed standard -> heavy" "$o" '^TIER=heavy$'
o="$(dry TELEMETRY_ROOT="$TR" -- --escalate-from px_l-1 --tier heavy)"; hasre "explicit --tier wins" "$o" '^TIER=heavy$'
rm -rf "$TR"

# per-tier compact window
o="$(dry A=1 -- --tier heavy)"; hasre "no tier value = built-in default" "$o" '^COMPACT_WINDOW=234000$'
o="$(dry A=1 --)"; hasre "untiered spawn gets the default too" "$o" '^COMPACT_WINDOW=234000$'
o="$(dry CRSS_COMPACT_WINDOW_HEAVY=600000 -- --tier heavy)"; hasre "heavy tier value applies" "$o" '^COMPACT_WINDOW=600000$'
o="$(dry CRSS_COMPACT_WINDOW_HEAVY=600000 CRSS_COMPACT_WINDOW_DEFAULT=300000 -- --tier standard)"; hasre "other tiers take the overlay default" "$o" '^COMPACT_WINDOW=300000$'
o="$(dry CRSS_COMPACT_WINDOW_DEFAULT=host -- --tier standard)"; hasre "default=host exports nothing" "$o" '^COMPACT_WINDOW=host$'
o="$(dry CLAUDE_SESSION_COMPACT_WINDOW=host -- --tier standard)"; hasre "per-spawn host exports nothing" "$o" '^COMPACT_WINDOW=host$'
o="$(dry CRSS_COMPACT_WINDOW_HEAVY=600000 CLAUDE_SESSION_COMPACT_WINDOW=450000 -- --tier heavy)"; hasre "explicit beats tier" "$o" '^COMPACT_WINDOW=450000$'
o="$(dry CLAUDE_SESSION_COMPACT_WINDOW=50 -- --tier heavy)"; hasre "too small refused" "$o" 'out of range'
o="$(dry CLAUDE_SESSION_COMPACT_WINDOW=abc -- --tier heavy)"; hasre "non-numeric refused" "$o" 'compact window .* invalid'
o="$(dry CRSS_COMPACT_WINDOW_HEAVY=600000 -- --tier heavy --backend codex)"; hasre "codex ignores it" "$o" '^COMPACT_WINDOW=host$'

# generated start script exports the window before claude launches (stub systemctl, fake HOME)
mkdir -p "$HOME/.local/bin" "$HOME/.config/systemd/user"
printf "#!/bin/sh\nexit 0\n" > "$HOME/.local/bin/systemctl"; chmod +x "$HOME/.local/bin/systemctl"
gen() {
  rm -rf "$HOME/.sessions" "$HOME"/.local/bin/*-start.sh
  env -u CLAUDE_SESSION_COMPACT_WINDOW -u CRSS_COMPACT_WINDOW_HEAVY -u CRSS_COMPACT_WINDOW_DEFAULT -u CRSS_LANE_DENY "$@" PATH="$HOME/.local/bin:$PATH" bash "$NS" proj workspace --alias cw --tier heavy >/dev/null 2>&1
  cat "$HOME"/.local/bin/*-start.sh 2>/dev/null
}
hasre "start script exports the window" "$(gen CRSS_COMPACT_WINDOW_HEAVY=600000)" "'export CLAUDE_CODE_AUTO_COMPACT_WINDOW=600000' Enter$"
hasnt "start script exports nothing for host" "$(gen CRSS_COMPACT_WINDOW_DEFAULT=host)" 'CLAUDE_CODE_AUTO_COMPACT_WINDOW'

# prompt-suggestion off switch: the generated start script adds it to the --settings layer only when absent
SCR="$(gen A=1)"
BLK="$(awk '/^python3 -c "$/{f=1} f{print} f&&/^" /{exit}' <<<"$SCR")"
has "start script carries the suggestion off-switch" "$BLK" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION"
RCF="$(sed -n 's/^" \(.*rc-firstparty.settings.json\).*/\1/p' <<<"$BLK")"
mkdir -p "$(dirname "$RCF")"
echo '{"env":{"ANTHROPIC_BASE_URL":"x"}}' > "$RCF"; bash -c "$BLK"
has "off-switch added when absent" "$(cat "$RCF")" '"CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION": "0"'
has "other keys kept" "$(cat "$RCF")" '"ANTHROPIC_BASE_URL": "x"'
echo '{"env":{"CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION":"1"}}' > "$RCF"; bash -c "$BLK"
has "explicit value kept" "$(cat "$RCF")" '"CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION":"1"'

# Superpowers plugin: builder/copywriter and autonomous spawns launch with a derived settings file that switches
# it off; orchestrator/owner/hub keep the plugin and, by default, launch on the lane deny file. Repeated --settings
# flags REPLACE each other (probed on CLI 2.1.308), so the plugin switch and the deny list ride in ONE file derived
# from rc-firstparty, never in a second layer. CRSS_LANE_DENY= opts out: superpowers-on lanes use plain rc-firstparty.
SP_ON="$HOME/.claude/rc-firstparty.settings.json"; SP_OFF="$HOME/.claude/rc-firstparty-no-superpowers.settings.json"
SP_LANE="$HOME/.claude/rc-firstparty-lane.settings.json"
hasnt "BUILDER_TOOLS omits AskUserQuestion" "$(grep -m1 '^BUILDER_TOOLS=' "$NS")" "AskUserQuestion"
for profile in orchestrator owner hub; do
  o="$(dry CLAUDE_SESSION_PROFILE="$profile" --)"
  hasre "$profile keeps superpowers" "$o" '^SUPERPOWERS=on$'; hasre "$profile launches on the lane deny file" "$o" "^SETTINGS_FILE=$SP_LANE\$"
  hasre "$profile lane deny default" "$o" '^LANE_DENY=mcp__gbrain,mcp__plugin_token-reduce_token-reduce-mcp,SendFeedback,ReportFindings$'
  # The delegation prompt quotes a Haiku repair as the escaped token --tools\ \"\" . That is prose, not an
  # allowlist. Strip it so a real --tools flag (which would drop AskUserQuestion) still fails this check.
  hasnt "$profile CLAUDE_EXTRA_FLAGS has no --tools" "$(grep '^CLAUDE_EXTRA_FLAGS=' <<<"$o" | sed 's/--tools\\//g')" '--tools'
  hasnt "$profile LANE_DENY omits AskUserQuestion" "$(grep '^LANE_DENY=' <<<"$o")" 'AskUserQuestion'
  o="$(dry CLAUDE_SESSION_PROFILE="$profile" CRSS_LANE_DENY= --)"
  hasre "$profile deny opt-out keeps superpowers" "$o" '^SUPERPOWERS=on$'; hasre "$profile deny opt-out uses plain rc-firstparty" "$o" "^SETTINGS_FILE=$SP_ON\$"
  hasre "$profile deny opt-out prints empty LANE_DENY" "$o" '^LANE_DENY=$'
  o="$(dry CLAUDE_SESSION_PROFILE="$profile" CRSS_AUTONOMOUS=1 --)"
  hasre "autonomous $profile drops superpowers" "$o" '^SUPERPOWERS=off$'; hasre "autonomous $profile uses the derived file" "$o" "^SETTINGS_FILE=$SP_OFF\$"
done
for profile in builder copywriter; do
  o="$(dry CLAUDE_SESSION_PROFILE="$profile" --)"
  hasre "$profile drops superpowers" "$o" '^SUPERPOWERS=off$'; hasre "$profile uses the derived file" "$o" "^SETTINGS_FILE=$SP_OFF\$"
  has "$profile CLAUDE_EXTRA_FLAGS has --tools" "$(grep '^CLAUDE_EXTRA_FLAGS=' <<<"$o")" '--tools'
  # The escalation prompt names AskUserQuestion as off. That is prose, not an allowlist entry.
  hasnt "$profile --tools omits AskUserQuestion" "$(grep '^CLAUDE_EXTRA_FLAGS=' <<<"$o" | grep -o -- '--tools [^ ]*' | head -1)" 'AskUserQuestion'
done
o="$(dry A=1 -- --tier standard)"; hasre "tier standard (builder) drops superpowers" "$o" '^SUPERPOWERS=off$'
o="$(dry A=1 -- --tier heavy)"; hasre "tier heavy (owner) keeps superpowers" "$o" '^SUPERPOWERS=on$'
hasre "tier heavy launches on the lane deny file" "$o" "^SETTINGS_FILE=$SP_LANE\$"
o="$(dry A=1 -- --backend codex)"; hasre "codex has no plugin switch" "$o" '^SUPERPOWERS=n/a$'

# generated start script: the launch lines name the resolved file. Superpowers-free lanes derive the
# no-superpowers file; superpowers-on lanes derive the lane file unless CRSS_LANE_DENY is empty.
launches() { grep -c -- "--remote-control" <<<"$1"; }
SCR="$(CLAUDE_SESSION_PROFILE=builder gen A=1)"
ok "builder: three launch lines" "$(launches "$SCR")" 3
ok "builder: every launch line uses the derived file" "$(grep -c -- "--settings $SP_OFF --remote-control" <<<"$SCR")" 3
ok "builder: no launch line uses plain rc-firstparty" "$(grep -c -- "--settings $SP_ON --remote-control" <<<"$SCR")" 0
hasnt "builder --tools omits AskUserQuestion" "$(grep -o -- '--tools [^ ]*' <<<"$SCR" | head -1)" "AskUserQuestion"
printf '%s\n' "$SCR" > "$HOME/ss-builder-esc.sh"
ok "builder escalation start script parses" "$(bash -n "$HOME/ss-builder-esc.sh" 2>&1; echo "rc=$?")" "rc=0"
has "builder start script carries BLOCKED:" "$SCR" "BLOCKED:"
has "builder start script carries session-send" "$SCR" "session-send"
SCR_O="$(CLAUDE_SESSION_PROFILE=orchestrator gen A=1)"
ok "orchestrator: every launch line uses the lane deny file" "$(grep -c -- "--settings $SP_LANE --remote-control" <<<"$SCR_O")" 3
ok "orchestrator: no launch line uses plain rc-firstparty" "$(grep -c -- "--settings $SP_ON --remote-control" <<<"$SCR_O")" 0
hasnt "orchestrator: derives nothing" "$SCR_O" 'if [ "off" = off ]'
hasnt "orchestrator: never names the derived file" "$SCR_O" "$SP_OFF"
# Same escaped repair token as the dry-run check; a real --tools allowlist would remain.
hasnt "orchestrator start script has no --tools" "$(sed 's/--tools\\//g' <<<"$SCR_O")" '--tools'
SCR_OPT="$(CLAUDE_SESSION_PROFILE=orchestrator gen CRSS_LANE_DENY=)"
ok "orchestrator deny opt-out: every launch line uses plain rc-firstparty" "$(grep -c -- "--settings $SP_ON --remote-control" <<<"$SCR_OPT")" 3
hasnt "orchestrator deny opt-out: no lane file" "$SCR_OPT" "rc-firstparty-lane.settings.json"
hasnt "orchestrator deny opt-out: no derive" "$SCR_OPT" "os.replace"

# the derive block, run against fixture layers: every rc-firstparty key survives, the plugin switch and the
# deny union are applied, and a rerun follows later edits to rc-firstparty
SPB="$(awk '/^if \[ "off" = off \]; then$/{f=1} f{print} f&&/^fi$/{exit}' <<<"$SCR")"
[ -n "$SPB" ] || { echo "FAIL: could not extract the superpowers derive block"; fail=$((fail+1)); }
field() { python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d.get(sys.argv[2],{}).get(sys.argv[3]))' "$@"; }
deny_of() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["permissions"]["deny"])' "$1"; }
mkdir -p "$HOME/.claude"
echo '{"env":{"ANTHROPIC_BASE_URL":"https://api.anthropic.com","CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION":"0"},"enabledPlugins":{"other@market":true},"permissions":{"allow":["Read"],"deny":["Bash(rm *)","SendFeedback"]}}' > "$SP_ON"
chmod 600 "$SP_ON"; echo stale > "$SP_OFF"; chmod 664 "$SP_OFF"
SESSION=px_sp LOG_FILE="$HOME/sp.log" bash -c "$SPB" >/dev/null
ok "derived takes the private mode of rc-firstparty, not the umask default" "$(stat -c %a "$SP_OFF")" 600
ok "derived keeps the base URL (remote-control needs it)" "$(field "$SP_OFF" env ANTHROPIC_BASE_URL)" "https://api.anthropic.com"
ok "derived keeps the suggestion off-switch" "$(field "$SP_OFF" env CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION)" 0
ok "derived switches superpowers off" "$(field "$SP_OFF" enabledPlugins superpowers@claude-plugins-official)" False
ok "derived keeps other plugin entries" "$(field "$SP_OFF" enabledPlugins other@market)" True
ok "derived deny keeps pre-existing entries then the lane deny" "$(deny_of "$SP_OFF")" "['Bash(rm *)', 'SendFeedback', 'mcp__gbrain', 'mcp__plugin_token-reduce_token-reduce-mcp', 'ReportFindings']"
ok "derived keeps permissions.allow" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["permissions"]["allow"])' "$SP_OFF")" "['Read']"
ok "derived keeps env beside the deny list" "$(field "$SP_OFF" env ANTHROPIC_BASE_URL)" "https://api.anthropic.com"
ok "rc-firstparty itself is not touched" "$(field "$SP_ON" enabledPlugins superpowers@claude-plugins-official)" None
ok "rc-firstparty deny list is not rewritten" "$(deny_of "$SP_ON")" "['Bash(rm *)', 'SendFeedback']"
echo '{"env":{"ANTHROPIC_BASE_URL":"https://edited.example"}}' > "$SP_ON"
SESSION=px_sp LOG_FILE="$HOME/sp.log" bash -c "$SPB" >/dev/null
ok "rerun follows a later edit to rc-firstparty" "$(field "$SP_OFF" env ANTHROPIC_BASE_URL)" "https://edited.example"
ok "rerun drops entries rc-firstparty no longer has" "$(field "$SP_OFF" enabledPlugins other@market)" None
ok "rerun deny list is exactly the lane deny" "$(deny_of "$SP_OFF")" "['mcp__gbrain', 'mcp__plugin_token-reduce_token-reduce-mcp', 'SendFeedback', 'ReportFindings']"
ok "no temp file left behind" "$(find "$HOME/.claude" -name '*.tmp' | wc -l | tr -d ' ')" 0
echo 'not json' > "$SP_ON"; chmod 600 "$SP_ON"; chmod 664 "$SP_OFF"
SESSION=px_sp LOG_FILE="$HOME/sp.log" bash -c "$SPB" >/dev/null
ok "unreadable rc-firstparty: lane still gets a settings file" "$(cat "$SP_OFF")" "not json"
ok "unreadable rc-firstparty: the copy keeps the private mode too" "$(stat -c %a "$SP_OFF")" 600
has "unreadable rc-firstparty: failure logged" "$(cat "$HOME/sp.log")" "event=no-superpowers-settings-FAILED"
rm -f "$SP_ON" "$SP_OFF"

# superpowers-on lane file: plugin left untouched, deny unioned, env kept
LANEB="$(awk '/^# crss-lane-deny-derive$/{f=1} f{print} f&&/^fi$/{exit}' <<<"$SCR_O")"
[ -n "$LANEB" ] || { echo "FAIL: could not extract the lane deny derive block"; fail=$((fail+1)); }
echo '{"env":{"ANTHROPIC_BASE_URL":"https://api.anthropic.com","CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION":"0"},"enabledPlugins":{"superpowers@claude-plugins-official":true,"other@market":true},"permissions":{"allow":["Read"],"deny":["Bash(rm *)","SendFeedback"]}}' > "$SP_ON"
chmod 600 "$SP_ON"
SESSION=px_lane LOG_FILE="$HOME/lane.log" bash -c "$LANEB" >/dev/null
ok "lane derive leaves superpowers on" "$(field "$SP_LANE" enabledPlugins superpowers@claude-plugins-official)" True
ok "lane derive keeps other plugins" "$(field "$SP_LANE" enabledPlugins other@market)" True
ok "lane derive keeps the base URL" "$(field "$SP_LANE" env ANTHROPIC_BASE_URL)" "https://api.anthropic.com"
ok "lane derive keeps the suggestion off-switch" "$(field "$SP_LANE" env CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION)" 0
ok "lane derive unions pre-existing deny entries" "$(deny_of "$SP_LANE")" "['Bash(rm *)', 'SendFeedback', 'mcp__gbrain', 'mcp__plugin_token-reduce_token-reduce-mcp', 'ReportFindings']"
ok "lane derive keeps permissions.allow" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["permissions"]["allow"])' "$SP_LANE")" "['Read']"
ok "lane derive takes the private mode" "$(stat -c %a "$SP_LANE")" 600
rm -f "$SP_ON" "$SP_LANE" "$SP_OFF"

# empty deny still derives the superpowers-off file, but does not touch permissions.deny
SCR_BOPT="$(CLAUDE_SESSION_PROFILE=builder gen CRSS_LANE_DENY=)"
SPBOPT="$(awk '/^if \[ "off" = off \]; then$/{f=1} f{print} f&&/^fi$/{exit}' <<<"$SCR_BOPT")"
[ -n "$SPBOPT" ] || { echo "FAIL: could not extract the opt-out derive block"; fail=$((fail+1)); }
echo '{"env":{"ANTHROPIC_BASE_URL":"https://kept.example"},"permissions":{"deny":["Bash(rm *)"]}}' > "$SP_ON"
chmod 600 "$SP_ON"
SESSION=px_bopt LOG_FILE="$HOME/bopt.log" bash -c "$SPBOPT" >/dev/null
ok "builder deny opt-out keeps the pre-existing deny list only" "$(deny_of "$SP_OFF")" "['Bash(rm *)']"
ok "builder deny opt-out still switches superpowers off" "$(field "$SP_OFF" enabledPlugins superpowers@claude-plugins-official)" False
ok "builder deny opt-out keeps env" "$(field "$SP_OFF" env ANTHROPIC_BASE_URL)" "https://kept.example"
rm -f "$SP_ON" "$SP_OFF"

# Every profile's start script must parse, and so must the text it types into the pane. The loop rides in
# `tmux send-keys '...'`, so an apostrophe in an interpolated flag (printf %q writes it as \') used to close that
# quote and leave the whole script unparseable: orchestrator/owner spawns died at once on the apostrophes in the
# delegation prompt. The fresh-launch line is then run against a stub claude to prove the pane's shell hands claude
# the prompt as ONE intact argument, including a prompt full of quote characters and expansions.
printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done\n' > "$HOME/stub-claude"; chmod +x "$HOME/stub-claude"
# an autonomous spawn asks the admission authority first; this throwaway-HOME stub says yes so its script can be generated
printf 'import sys\nsys.exit(0)\n' > "$HOME/stub-admit.py"
typed() {  # start script on stdin -> the text its main send-keys literal types into the pane
  local lit; lit="$(awk '/^tmux send-keys -t .* .LOG_FILE=/{f=1} f{print} f&&/^done.$/{exit}')"
  bash -c "tmux() { shift 3; printf '%s' \"\$1\"; }
$lit"
}
launch_argv() {  # typed pane text on stdin -> the argv its fresh-launch line gives claude, one per line
  local line; line="$(grep -- '--dangerously-skip-permissions' | grep -v -e '--resume' -e '--continue$' | head -1)"
  bash -c "$line"
}
for spec in orchestrator owner hub builder copywriter "orchestrator CRSS_AUTONOMOUS=1" "owner CRSS_AUTONOMOUS=1" \
            "hub CRSS_AUTONOMOUS=1" "builder CRSS_AUTONOMOUS=1"; do
  set -- $spec; profile="$1"; shift
  SCR="$(CLAUDE_SESSION_PROFILE="$profile" gen CRSS_CLAUDE_BIN="$HOME/stub-claude" AGENT_HOST_ADMISSION_CLI="$HOME/stub-admit.py" "$@")"
  has "$spec: start script generated" "$SCR" "tmux send-keys"
  printf '%s\n' "$SCR" > "$HOME/ss.sh"
  ok "$spec: start script parses" "$(bash -n "$HOME/ss.sh" 2>&1; echo "rc=$?")" "rc=0"
  typed <<<"$SCR" > "$HOME/typed.sh"
  has "$spec: pane text extracted" "$(cat "$HOME/typed.sh")" "--remote-control"
  ok "$spec: pane text parses" "$(bash -n "$HOME/typed.sh" 2>&1; echo "rc=$?")" "rc=0"
done
set --
SCR="$(CLAUDE_SESSION_PROFILE=orchestrator gen CRSS_CLAUDE_BIN="$HOME/stub-claude")"
ARGV="$(typed <<<"$SCR" | launch_argv)"
ok "orchestrator: the default delegation prompt arrives as one argument" \
  "$(awk 'p{print substr($0,1,26); exit} $0=="--append-system-prompt"{p=1}' <<<"$ARGV")" "Delegation (operator 2026-"
ok "orchestrator: its apostrophes arrive intact" "$(grep -c "slice's test" <<<"$ARGV")" 1
SCR="$(CLAUDE_SESSION_PROFILE=builder gen CRSS_CLAUDE_BIN="$HOME/stub-claude")"
ARGV="$(typed <<<"$SCR" | launch_argv)"
builder_prompt="$(awk 'p{print; exit} $0=="--append-system-prompt"{p=1}' <<<"$ARGV")"
case "$builder_prompt" in
  "Unattended lane:"*"does not depend on it.") builder_prompt_shape=yes ;;
  *) builder_prompt_shape=no ;;
esac
ok "builder: the default delegation prompt arrives as one argument" "$builder_prompt_shape" yes
NASTY="it's a \"test\" with \$HOME, \`date\`, \$(touch \$HOME/pwned), 'quoted' text, a \\ and a trailing quote'"
rm -rf "$HOME/scripts-nasty"; cp -r "$HERE/../scripts" "$HOME/scripts-nasty"
NASTY="$NASTY" python3 - "$HOME/scripts-nasty/new-session.sh" <<'PY'
import os, re, sys
p = sys.argv[1]
s = open(p).read()
new = "ORCHESTRATOR_DELEGATION_PROMPT='" + os.environ["NASTY"].replace("'", "'\\''") + "'"
s2 = re.sub(r"^ORCHESTRATOR_DELEGATION_PROMPT=.*$", lambda m: new, s, count=1, flags=re.M)
assert s2 != s
open(p, "w").write(s2)
PY
SCR="$(NS="$HOME/scripts-nasty/new-session.sh" CLAUDE_SESSION_PROFILE=orchestrator gen CRSS_CLAUDE_BIN="$HOME/stub-claude")"
printf '%s\n' "$SCR" > "$HOME/ss.sh"
ok "hostile prompt: start script parses" "$(bash -n "$HOME/ss.sh" 2>&1; echo "rc=$?")" "rc=0"
ARGV="$(typed <<<"$SCR" | launch_argv)"
ok "hostile prompt reaches claude byte for byte" "$(awk 'p{print; exit} $0=="--append-system-prompt"{p=1}' <<<"$ARGV")" "$NASTY"
ok "hostile prompt: nothing in it was executed" "$(yn test -e "$HOME/pwned")" no
rm -rf "$HOME/scripts-nasty"

# CLAUDE_SESSION_MODEL is validated against the same ^[a-z0-9][a-z0-9.-]*$ shape as CRSS_OPUS_MODEL and
# session-resume --model, not just apostrophe-escaped: unlike the settings path and remote name (shell-quoted
# bare words), the model sits unescaped inside an existing `--model "..."` in the pane text, so a value with a
# `"`, `$`, or backtick would close that quote and run arbitrary commands when the pane types the launch line.
rm -f "$HOME/pwn-model-inject"
MAL_MODEL="sonnet\"; touch \"$HOME/pwn-model-inject\"; echo \""
o="$(dry CLAUDE_SESSION_MODEL="$MAL_MODEL" --)"
hasre "hostile CLAUDE_SESSION_MODEL (quote-breakout) is rejected, not typed into the pane" "$o" 'CLAUDE_SESSION_MODEL=.* must match \^\[a-z0-9\]\[a-z0-9\.-\]\*'
ok "hostile CLAUDE_SESSION_MODEL: nothing executed" "$(yn test -e "$HOME/pwn-model-inject")" no
# The 1M-context suffix is the one bracket form allowed: claude must get `claude-opus-5-5[1m]` as one literal word
# (a planted file the bracket would glob-match proves it is never expanded). Anything after or inside it still fails.
SCR="$(CLAUDE_SESSION_PROFILE=orchestrator CLAUDE_SESSION_MODEL='claude-opus-5-5[1m]' gen CRSS_CLAUDE_BIN="$HOME/stub-claude")"
printf '%s\n' "$SCR" > "$HOME/ss.sh"
ok "1m model: start script parses" "$(bash -n "$HOME/ss.sh" 2>&1; echo "rc=$?")" "rc=0"
ok "1m model: launch lines keep --model \"...\"" "$(grep -c -- '--model "claude-opus-5-5\[1m\]" ' <<<"$SCR")" 3
ARGV="$(cd "$HOME" && touch claude-opus-5-5m && typed <<<"$SCR" | launch_argv)"
ok "1m model reaches claude as one literal word" "$(awk 'p{print; exit} $0=="--model"{p=1}' <<<"$ARGV")" 'claude-opus-5-5[1m]'
o="$(dry CLAUDE_SESSION_MODEL='claude-opus-5-5[1m]' --)"
hasre "1m model: dry run resolves it" "$o" 'resolved: .* model=claude-opus-5-5\[1m\] '
hasre "1m model: one-line advisory on stderr" "$o" "^note: CLAUDE_SESSION_MODEL='claude-opus-5-5\\[1m\\]' accepted: 1M context comes only from the \\[1m\\] suffix"
for bad in 'claude-opus-5-5[1m]"; touch "'"$HOME"'/pwn-1m"; echo "' 'claude-opus-5-5[1m]$(touch '"$HOME"'/pwn-1m)' \
           'claude-opus-5-5[2m]' 'claude-opus-5-5[1m][1m]' 'claude-opus-5-5[1m]x' '[1m]'; do
  o="$(dry CLAUDE_SESSION_MODEL="$bad" --)"
  hasre "CLAUDE_SESSION_MODEL='$bad' is rejected" "$o" 'CLAUDE_SESSION_MODEL=.* must match'
done
ok "hostile 1m-suffixed model: nothing executed" "$(yn test -e "$HOME/pwn-1m")" no

# The settings path and the remote name are typed into the same pane text as the prompt, so an apostrophe
# in one of them closed the send-keys quote just the same, and a space split a word. A normal spawn must keep the
# `--model "..."` shape session-resume --model rewrites. A settings path comes from CRSS_CLAUDE_HOME and a remote
# name from a sanitized alias, so a copy of the script plants both (the model stays a plain, valid alias here).
SCR="$(CLAUDE_SESSION_PROFILE=orchestrator gen CRSS_CLAUDE_BIN="$HOME/stub-claude")"
ok "launch lines keep --model \"...\" for session-resume" "$(grep -c -- '--model "claude-opus-5-5" ' <<<"$SCR")" 3
H_MODEL="sonnet"
rm -rf "$HOME/scripts-nasty"; cp -r "$HERE/../scripts" "$HOME/scripts-nasty"
python3 - "$HOME/scripts-nasty/new-session.sh" <<'HOSTILE_PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
a = 'SETTINGS_FILE="${CRSS_CLAUDE_HOME}/'
assert s.count(a) == 2
s = s.replace(a, a + "it's a dir/")
s, n = re.subn(r'^(REMOTE_NAME="\$\{CRSS_SESSION_PREFIX\}-\$\{BODY\})"$', lambda m: m.group(1) + "-it's a name\"", s, flags=re.M)
assert n == 1
open(p, "w").write(s)
HOSTILE_PY
for profile in orchestrator builder; do
  SCR="$(NS="$HOME/scripts-nasty/new-session.sh" CLAUDE_SESSION_PROFILE="$profile" CLAUDE_SESSION_MODEL="$H_MODEL" gen CRSS_CLAUDE_BIN="$HOME/stub-claude")"
  has "$profile, hostile model/settings/name: script generated" "$SCR" "tmux send-keys"
  printf '%s\n' "$SCR" > "$HOME/ss.sh"
  ok "$profile, hostile model/settings/name: start script parses" "$(bash -n "$HOME/ss.sh" 2>&1; echo "rc=$?")" "rc=0"
  typed <<<"$SCR" > "$HOME/typed.sh"
  ok "$profile, hostile model/settings/name: pane text parses" "$(bash -n "$HOME/typed.sh" 2>&1; echo "rc=$?")" "rc=0"
  ARGV="$(launch_argv < "$HOME/typed.sh")"
  settings_name=rc-firstparty-lane.settings.json; [ "$profile" = builder ] && settings_name=rc-firstparty-no-superpowers.settings.json
  ok "$profile: the model arrives as one argument" "$(awk 'p{print; exit} $0=="--model"{p=1}' <<<"$ARGV")" "$H_MODEL"
  ok "$profile: the settings path arrives as one argument" "$(awk 'p{print; exit} $0=="--settings"{p=1}' <<<"$ARGV")" "$HOME/.claude/it's a dir/$settings_name"
  hasre "$profile: the remote name arrives as one argument" "$(awk 'p{print; exit} $0=="--remote-control"{p=1}' <<<"$ARGV")" "^px-[a-z0-9]+-[0-9]{4}-[0-9]{4}-it's a name\$"
done
# the superpowers-off lane also derives its file at start, outside the pane: run that block against the hostile path
SPB="$(awk '/^if \[ "off" = off \]; then$/{f=1} f{print} f&&/^fi$/{exit}' <<<"$SCR")"
[ -n "$SPB" ] || { echo "FAIL: could not extract the superpowers derive block (hostile path)"; fail=$((fail+1)); }
mkdir -p "$HOME/.claude/it's a dir"; echo '{"env":{}}' > "$HOME/.claude/rc-firstparty.settings.json"
SESSION=px_h LOG_FILE="$HOME/h.log" bash -c "$SPB" >/dev/null 2>&1
ok "derive block writes the file at a path with an apostrophe and a space" \
  "$(field "$HOME/.claude/it's a dir/rc-firstparty-no-superpowers.settings.json" enabledPlugins superpowers@claude-plugins-official 2>&1)" False
rm -rf "$HOME/scripts-nasty" "$HOME/.claude/it's a dir" "$HOME/.claude/rc-firstparty.settings.json"

# an apostrophe (and a space) in CRSS_LANE_DENY is quoted into the start script; bash -n must still pass
for spec in orchestrator builder; do
  SCR_Q="$(CLAUDE_SESSION_PROFILE="$spec" gen CRSS_LANE_DENY="it's a deny")"
  printf '%s\n' "$SCR_Q" > "$HOME/ss-deny.sh"
  ok "$spec apostrophe in CRSS_LANE_DENY: start script parses" "$(bash -n "$HOME/ss-deny.sh" 2>&1; echo "rc=$?")" "rc=0"
done

# overlay line: found/absent
GOOD="$(mktemp -d)"; mkdir -p "$GOOD/rules"; touch "$GOOD/config.sh" "$GOOD/rules/crss-host.md"
ABSENT="/tmp/crss-newsession-overlay-absent-$$-nonexistent"
has "overlay line: absent" "$(CRSS_HOME="$ABSENT" CRSS_CLAUDE_HOME="$ABSENT" bash "$NS" --dry-run ov-absent 2>&1)" "overlay: $ABSENT (config: absent, rules: absent)"
has "overlay line: found" "$(CRSS_HOME="$GOOD" CRSS_CLAUDE_HOME="$GOOD" bash "$NS" --dry-run ov-good 2>&1)" "overlay: $GOOD (config: found, rules: found)"
rm -rf "$GOOD"

finish test-new-session-tier
