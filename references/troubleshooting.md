# Troubleshooting & recycling runbooks

Each section is a diagnose -> recover recipe for one failure shape. Three shapes look alike
(session "went silent"); identify which with `tmux capture-pane -p -t <session>` before acting:

| Pane shows | Shape | Section |
|---|---|---|
| `/clear to save NNNk tokens`, long idle | bloat / staleness | [Compact before relaying](#compact-before-relaying-into-an-idlestale-session), [Preserve before reaping](#preserve-before-reaping-recycling-a-bloated-session) |
| repeated `UserPromptSubmit operation blocked by hook` | hook wedge | [Hook-wedged session](#detecting-a-hook-wedged-session-different-from-bloat) |
| numbered options, `↑/↓ to navigate` | stuck on a menu | [Stuck-on-a-menu session](#detecting-a-stuck-on-a-menu-session-different-from-both-wedge-types-above) |

A `--task`/`--task-file` kickoff reporting `trust dialog open` or `claude not running in
pane` is this same menu/not-ready detection firing during spawn, not a new shape (SKILL.md
"Done for a spawn"; pinned by `tests/test-new-session-kickoff.sh` and
`tests/test-session-handoff-tui.sh`).

## Compact before relaying into an idle/stale session

Relaying into a session that has sat a while pays to reprocess its whole bloated transcript
on every later turn. Use the one command: it checks staleness, compacts, waits for
completion, then relays.

```bash
session-compact before-relay <name> "the actual task"   # or --file <path>
```

It fails closed: if the compact can't be verified complete the message is not sent, so a
task never lands mid-summarization. Hand-rolling (`session-send "/compact"`, eyeball
`tmux capture-pane`, send the task) is only for hosts without `session-compact` deployed.
Staleness signal: a status line `new task? /clear to save NNNk tokens`, or a long idle gap.

**Don't compact a session idle under ~60 minutes**: its 1-hour prompt cache is still live,
so that is the most expensive moment. `session-compact` defaults to `--min-idle 60`. Mechanism,
measurements and managed-orchestrator exceptions: [`docs/session-compaction.md`](../docs/session-compaction.md).

**Auto-compact is real and on by default** (checked against CLI 2.1.280; `--autocompact` still
in `claude --help` on 2.1.285). `autoCompactEnabled` and `autoCompactWindow` are real
`settings.json`-schema fields. Evidence:

- `autoCompactWindow` is causally confirmed for a plain host: `claude -p ... --settings '{"autoCompactWindow": N}'`
  gave the same `effectiveWindow` in `-d config,settings,compact --debug-file <f>` output as the
  `--autocompact N` flag (`N=105000` -> `85000`). The clamp is the model's context window (200k
  for older models; Sonnet 5.5 reports 1M, so `N=500000` is no longer clamped).
- `autoCompactEnabled` sits in the same schema object as `autoCompactWindow` (both on the same
  ~118KB minified schema line, ~12.4KB apart, no object boundary between), not in the global
  `~/.claude.json` preferences schema. Its `.describe()`: "Automatically compact conversation
  when context fills"; it also backs the `/config` "Auto-compact" toggle. Its read-from-
  `--settings` behaviour was not reproduced (the debug line didn't fire in a single-turn `-p`
  run): strong but not causally confirmed.

Other controls: launch flag `--autocompact <auto|tokens>`, in-session `/autocompact` and
`/config`, env `CLAUDE_CODE_DISABLE_1M_CONTEXT`. A session at 200-300k uncompacted tokens is
not evidence it's broken.

**Precedence (CLI 2.1.287, probed with `claude -p ok --model claude-sonnet-5-5 -d config,settings,compact
--debug-file <f>` and `grep effectiveWindow <f>`):** if the host's `~/.claude/settings.json`
`env` sets `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, then `--autocompact`, `--settings '{"env":...}'` and
`--settings '{"autoCompactWindow":...}'` are all ignored. Only the same variable exported in the
launch environment wins (host 300000 -> `effectiveWindow=280000`; launch export 600000 ->
`580000`). `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=P` makes the compact trigger `min(floor(effectiveWindow*P/100),
effectiveWindow-13000)` tokens (read from the 2.1.287 binary), so P=70 means ~196k at a 300000
window and ~406k at 600000. `new-session` now sets the window per tier from the overlay
(`CRSS_COMPACT_WINDOW_<TIER>`, per-spawn `CLAUDE_SESSION_COMPACT_WINDOW`); see
`scripts/new-session.sh`, pinned by `tests/test-new-session-tier.sh`, and
`examples/crss-overlay/config.sh.example`. It affects new spawns only. A larger window is not
free: every advisor call forwards the whole transcript and cache reads scale with context, so
keep durable TASKS/DECISIONS files and call advisor while context is small. Lesson: verify a
specific claim yourself before repeating it, in either direction.

## Preserve before reaping (recycling a bloated session)

Long-lived sessions accumulate context until every turn is slow and expensive. Recycle: kill
it, spawn a fresh one on the same repo. **Never reap before `session-preserve` says it is safe.**

```bash
session-preserve <tmux-session>            # audit only. exit 0 = safe to reap
session-preserve <tmux-session> --rescue   # + copy non-junk untracked files aside
session-preserve <tmux-session> --wip      # + WIP-commit uncommitted tracked changes
session-preserve --all                     # audit the whole fleet
```

```bash
session-preserve <s> --rescue --wip        # must print SAFE-TO-REAP
systemctl --user disable --now <base>.service
tmux kill-session -t <s>
new-session <foldername> workspace --alias <new-alias>
```

**Never use `git log @{u}..` to decide whether work is pushed.** With no upstream it prints
nothing, so unpushed work reads as clean and can authorise a reap over unpushed commits. Use
`git log HEAD --not --remotes`, and check `git remote` separately: a repo with no remote
cannot be pushed anywhere, so its branch refs are the only copy. Pinned by
`session-preserve.sh`'s header comment and `tests/test-session-preserve.sh` ("no-remote-flagged").

A reap is safe when **HEAD is reachable from a named local branch**: killing the session and
removing its worktree can't orphan commits, which stay in the canonical repo's object store.
So *deleting the branch* is the dangerous operation, not reaping; worktree GC must leave
`session/*` and research branches alone.

A respawned session starts on a fresh worktree cut from the default branch, **not** the old
session's branch. Name the prior branch, prior transcript path and what it was mid-way
through in the kickoff, or the replacement re-derives it at full cost.

## Detecting a hook-wedged session (different from bloat)

A `UserPromptSubmit` or `PreToolUse` hook in the session's `.claude/settings.json` throws
(spawn error, missing script, unhandled exception) with **no fail-open guard**.
`UserPromptSubmit` fires on every prompt, so every later prompt, including "try again", is
rejected before Claude sees it; resending cannot fix it. A `PreToolUse` wedge also blocks
Bash/Read/Grep/Glob, so even `advisor()` stalls. No automated test covers this shape (needs a
genuinely broken hook); diagnose from outside.

**Symptom** in `tmux capture-pane -p`: repeated blocks like

```
UserPromptSubmit operation blocked by hook:
  [<command>]: error: Failed to spawn: `<script>`
    Caused by: No such file or directory (os error 2)

  Original prompt: <whatever was sent>
```

with no `✻`/`●` processing indicator after: process alive and idle but unreachable.

**Diagnose:** `cat <rundir>/.claude/settings.json`; look at the failing hook's command. With no
fail-open guard (compare a sibling like `[ -x <script> ] && <script> || exit 0`) a subprocess
error is a permanent block, not a fluke.

**Recover** (same mechanics as the bloat recycle):

```bash
session-preserve <s> --rescue --wip        # runs from OUTSIDE the wedged session, unaffected by its hook
systemctl --user disable --now <base>.service
new-session <foldername> workspace --alias <same-alias>
```

Hand off the wedged session's state in the kickoff (branch, task list, in-progress work); its
transcript may be unrecoverable and `tmux capture-pane -S` is capped by the pane's
history-limit. **Prevention:** any script wired to `UserPromptSubmit` or `PreToolUse` must
fail open (catch errors, `exit 0`); a failure there can permanently wedge the session.

## Detecting a stuck-on-a-menu session (different from both wedge types above)

Nothing is wrong with the session: it is mid an interactive multi-choice widget
(`AskUserQuestion`-style: numbered options with `[ ]`/`[✔]` checkboxes, a
`←  ☐ Next direction  ✔ Submit  →` bar, "Enter to select · ↑/↓ to navigate · Esc to cancel")
and someone sent free text. The widget only understands arrows + Enter (and a "Type
something" option), so plain text sits inert while the agent is healthy. Detection is pinned
by `tests/test-session-handoff-ready.sh` (`_is_on_menu` true/false-positive cases).

**Symptom:** option list with checkboxes and the `↑/↓ to navigate` hint on screen, with a
plain-text line below it that no checkbox reflects.

**Recover (no reap):**
1. `tmux send-keys -t <s> Down` (or `Up`) and re-capture; the `❯` marker moving proves the
   widget is live and just mis-navigated.
2. Navigate to the option matching the sender's intent (`Enter` toggles `[ ]`->`[✔]`; it does
   **not** submit).
3. `Right` to move to "Submit", then `Enter` on the review screen ("1. Submit answers").
   Re-capture after each step (type, act, verify).

If in doubt, check `session-preserve` / `git log HEAD --not --remotes` first, but a stuck-menu
session usually has nothing to lose: it was mid a review pause, not an edit.

**Workspace-trust dialog** ("Do you trust the files in this folder? ... Enter to confirm · Esc
to cancel") is also classified `menu` (`_is_on_menu` / `_state_of` in
`scripts/session-handoff.sh`, pinned by `tests/test-session-handoff-tui.sh`), since
blind text/Enter is unsafe there too. On CLI 2.1.285 the highlighted default is **"No, exit"**
(so `1 Enter` quits claude), "Yes, I trust this folder" is the second option. Spawns avoid the
dialog: the start script runs `scripts/session-trust-seed.sh` on the run directory first (it
explains which key the CLI checks for git worktrees; pinned by `tests/test-session-trust-seed.sh`).

## Autocomplete (prompt suggestions) missing in the desktop app

**Verdict (operator-verified in the app, 2026-10-15, CLI 2.1.293 `/usr/bin/claude` under `--remote-control`
and the app's `ccd-cli` 2.1.295): suggestions show in the app composer for BOTH app-started (`+`) sessions
and crss TUI sessions, until the host-wide back-off counter (below) trips; crss now keeps its own sessions out of that counter.** The 2026-10-11 report (TUI showed one, app did not) was
the back-off counter below (found 2026-10-15); the other common cause of "no autocomplete" is that the model
chose to say nothing.

- **Why it looks missing:** the suggestion is a model call whose prompt says "Stay silent if the next step
  isn't obvious" (also silent after errors and on sensitive topics). Open-ended turns ("reply ok", "list
  three files") produced no suggestion on the TUI line either; "Write hello.py that prints hi. Do not run
  it." produced the dim `run it`, in the TUI and in the app. Check the TUI line first
  (`tmux capture-pane -e`, `ESC[2m` on the `❯` line): no dim text there means the model stayed silent,
  not that the app is broken.
  The app also hides the placeholder while the composer holds text or a turn is running.
- **How each path gets it** (CLI strings, 2.1.295): app sessions run `ccd-cli --input-format stream-json`
  with no `--prompt-suggestions` argv, so the host enables it in the `initialize` request's
  `promptSuggestions` option (the `set_prompt_suggestions_paused` doc says it sits "on top of the
  initialize request's promptSuggestions option and the user's own setting"). The `prompt_suggestion`
  stream-json message and the `ui_prompt_suggest` request (headless sessions, Tab-to-accept) are the SDK
  routes. Which route carries a crss TUI session's suggestion to the app was not traced; it works anyway.
  2.1.293 and 2.1.300 carry the same strings.
- **The knobs:** `promptSuggestionEnabled` (user setting) and `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION`
  gate whether the CLI generates suggestions at all (env `false`/`0` = off for the session, `true`/`1` = on and
  exempt from back-off; checked in the installed CLI 2.1.295/2.1.300). The app's `prompt_suggestions` setting
  applies from a session's next start or resume. `--prompt-suggestions` only works with `--print` and
  `--output-format=stream-json`, so do **not** add it to `new-session`'s launch line.
- **Back-off (the real cause when suggestions stop in the app and the TUI still shows one):** after 20
  suggestions in a row go unused, the CLI writes `promptSuggestionUnusedStreak: 20` to `~/.claude.json`
  (21 once the "Showing fewer prompt suggestions · use one to bring them back" notice has been shown) and
  stops suggesting. That counter is **host-wide**, so the unattended fleet (nobody accepts its
  suggestions) pushes the operator's app sessions into back-off. A session skips back-off only when its
  parsed env has `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION` true, and only counts as young for 14 days after
  `firstStartTime`. Check: `jq .promptSuggestionUnusedStreak ~/.claude.json`; at 20 or 21 it is in back-off.
  Reset (not a credentials file; back it up first): set it to 0 with `jq` and write the file back.
- **Fix in `new-session`:** the `--settings` layer crss already passes (`rc-firstparty.settings.json`) now
  carries `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=0` (added when the key is absent; an explicit value is kept),
  so crss-spawned unattended sessions generate no suggestions and never touch the counter. Verified: that
  layer overrides the `"1"` in `~/.claude/settings.json` (probe with the override showed no dim suggestion,
  the control showed `run it`). Sessions already running keep generating until restarted. Pinned by
  `tests/test-new-session-tier.sh`. To watch suggestions in a crss TUI session on purpose, set the key to
  `"1"` in that file.
- **Ruled out:** `--exclude-dynamic-system-prompt-sections` (it only moves cwd/env/memory-path/git
  sections into the first user message). The earlier "ruled out: back-off" was wrong: the TUI line in a
  fresh process can still render a suggestion while the shared counter holds app sessions in back-off.
- **Cost:** each suggestion is one extra model request per turn; off for crss spawns saves that call.
- **Probe recipe:** `new-session x sessions --alias ac-probe --tier light`, send the hello.py prompt,
  confirm the dim line in the pane, open it in the app, then reap with the tmux-style name
  (`session-doctor reap ah_<alias>-<MMDD-HHMM> --allow-young --outcome ok`; the `ah-` name is a silent
  no-op that still prints `reaped`; always pass the `ah_` tmux name).

## Every session stopped answering: dead login (silent on an idle fleet)

All sessions on a host share one `~/.claude/.credentials.json`. If its OAuth refresh token is declared dead
(the CLI then throws `OAuthRefreshDeadError`), every session fails the same way once the ~8 h access token
expires, and idle remote-control sessions log nothing until someone prompts them. Exact texts seen:
`Failed to authenticate: OAuth session expired and could not be refreshed` and
`Login expired · Please run /login`.

- Detect: `session-doctor auth-scan [--days N]` (also one line in the default `report`). It reads
  transcripts only, never the credentials file; exit 1 means the newest auth failure is newer than every
  successful turn. Tmux/units look healthy in this state — `proc=yes` proves nothing about auth.
- Fix: the operator runs `/login` once (in the `claude-remote` pane). Agents never run the login or touch
  credential files. After it, re-run `auth-scan`; a newer successful turn flips it to "recovered".
- Resume stalled auth lanes after login: `session-doctor auth-heal` previews; add `--apply` to nudge.
- Not the same thing as a spend-limit stop (`You've hit your monthly spend limit`) — that one has its own
  exact text and recovers on its own when the limit is raised.
