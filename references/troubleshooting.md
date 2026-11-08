# Troubleshooting and recycling runbooks

For a silent session, run `crss ls`, then `tmux capture-pane -p -t =ah_NAME:` and identify the
shape:

| Pane shows | Shape | Section |
|---|---|---|
| `/clear to save NNNk tokens`, long idle | bloat / staleness | [Compact or recycle](#compact-or-recycle-a-bloated-session) |
| repeated `UserPromptSubmit operation blocked by hook` | hook wedge | [Hook-wedged session](#a-hook-wedged-session-different-from-bloat) |
| numbered options, `↑/↓ to navigate`, or a trust dialog | stuck on a menu | [Stuck on a menu](#a-session-stuck-on-a-menu) |
| `crss ls` says `waiting` | a dialog is open | same as the menu row; `crss send` refuses until it is closed |
| `crss ls` says `?` | tmux is up but claude is starting or in its crash backoff (up to 300 s) | look at the pane; `crss up` does nothing here |
| `crss ls` says `down` | the tmux session is gone | `crss up NAME` |
| every session silent, `Login expired` | dead login | [Dead login](#every-session-stopped-answering-dead-login-silent-on-an-idle-fleet) |

`crss send` exit codes and what each status means are in `SKILL.md`.

## Compact or recycle a bloated session

Before relaying into a stale session, check how big it is (`/clear to save NNNk tokens` in the
pane, and how long it has been idle). Either compact it or recycle it:

- **Compact:** `crss send NAME "/compact"` once it is idle (the status must be `idle`; a busy
  session queues the compact to fire at an unpredictable point mid-workflow). Check the pane to
  confirm it finished before sending the task (bracketed paste delivers `/compact` atomically, so
  the slash-command autocomplete menu does not intercept it; verified with 4 sends). There is no
  tool that does this for you; judge completion from the transcript's `compact_boundary` entry
  (below), not from pane text alone, which gave false timeouts when the pane never looked busy.
- **Recycle:** reap and respawn on the same repo (below).

**Don't compact a session idle under about 60 minutes.** Claude Code uses a 1-hour prompt-cache
TTL, a sliding window refreshed on every cache read (verified in the v2.1.206 binary: the 1-hour
TTL is behind four gates: no `FORCE_PROMPT_CACHING_5M`, an OAuth-scope eligibility check, not on
overage billing, and a remotely configurable `querySource` allowlist that includes the
interactive main thread). Inside that hour a resumer would read the cache at about 0.1x cost, so
compacting then is the most expensive moment. Compaction is not a total miss: caching is tiered
(tools, system, messages) and compaction rewrites only the messages tier. The real trade is one
summarization call plus one messages-tier miss, repaid by smaller context on every later turn, so
compact lazily, when someone is about to message a stale session.

Measured once (v2.1.206, disposable session): `compactMetadata` pre/post tokens 91,726 to 18,542;
`/context` Messages 62.6k to 34.9k; the compact took about 101 s. Transcript bytes are not
tokens; never quote them as a saving (a real 30 MB transcript had a 15x bytes-per-character ratio,
39% duplicate `toolUseResult`, and empty `thinking` strings). The only ground truth for context
occupancy is a live `/context` reading. A completed compaction is visible in the transcript as a
`type:"system"` entry with `"subtype":"compact_boundary"` and a `compactMetadata` object, followed
by a `type:"user"` entry with `"isCompactSummary": true` (v2.1.206 and later).

**Don't paste onto a draft.** An idle pane with no spinner can still hold an unsent draft. Claude
Code also renders its auto-suggested next action as dim placeholder text after the `❯`, which
`capture-pane -p` shows exactly like a draft. Use `tmux capture-pane -p -e -t =ah_NAME:`: dim
(SGR 2, `ESC[2m`) is a placeholder and safe to overwrite; non-dim is a real draft. Key on an
actual escape sequence, not the substring `[2m`, since coloured draft text is `ESC[38;5;12m`.
`crss send` checks only the session's status (`busy`/`waiting`/idle), not the input box.

### Auto-compact

Auto-compact defaults on (CLI 2.1.280; `--autocompact` in `claude --help` on 2.1.285).
`autoCompactEnabled` / `autoCompactWindow` are `settings.json`-schema fields:

- `autoCompactWindow` is causally confirmed for a plain host: `claude -p ... --settings '{"autoCompactWindow": N}'`
  gave the same `effectiveWindow` in `-d config,settings,compact --debug-file <f>` output as the
  `--autocompact N` flag (`N=105000` -> `85000`). The clamp is the model's context window (200k
  for older models; Sonnet 5.5 reports 1M, so `N=500000` is no longer clamped).
- `autoCompactEnabled` shares `autoCompactWindow`'s schema object (~118KB minified line,
  ~12.4KB apart, no intervening object boundary), outside `~/.claude.json` preferences.
  `.describe()`: "Automatically compact conversation when context fills"; backs `/config`
  "Auto-compact". Reading it via `--settings` remains unconfirmed: no debug line in a
  single-turn `-p` probe.

Other controls: launch flag `--autocompact <auto|tokens>`, in-session `/autocompact` and
`/config`, env `CLAUDE_CODE_DISABLE_1M_CONTEXT`. A session at 200-300k uncompacted tokens is
not evidence it's broken.

**Precedence (CLI 2.1.287, probed with `claude -p ok --model claude-sonnet-5-5 -d config,settings,compact
--debug-file <f>` and `grep effectiveWindow <f>`):** if the host's `~/.claude/settings.json`
`env` sets `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, then `--autocompact`, `--settings '{"env":...}'` and
`--settings '{"autoCompactWindow":...}'` are all ignored. Only the same variable exported in the
launch environment wins (host 300000 -> `effectiveWindow=280000`; launch export 600000 ->
`580000`). `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=P` makes the compact trigger `min(floor(effectiveWindow*P/100),
effectiveWindow-13000)` tokens, with `effectiveWindow = window - 20000` (read from the 2.1.287 binary,
re-read on 2.1.300), so P=70 means ~150k at a 234000 window, ~196k at 300000 and ~406k at 600000.
For crss sessions, export the window in `~/.config/crss/crss.env`
(`export CLAUDE_CODE_AUTO_COMPACT_WINDOW=234000`, as `SKILL.md` shows): `crss` sources that file, and
the loop's `claude` inherits it. It applies from a session's next launch (`crss restart`). Advisor
forwards the whole transcript; cache reads scale with context. Keep durable TASKS/DECISIONS files and
call advisor early. Long-running orchestrators should checkpoint durably and compact at major phase
boundaries. Verify claims before repeating them.

## Preserve before reaping (recycling a bloated session)

For bloated context, recycle on the same repo. `crss reap NAME` refuses a busy session and keeps
a worktree that has uncommitted files or commits on no remote (it prints `kept <path>: ...`). It
does not copy untracked files out of a *non*-worktree session folder, so before reaping a session
that ran in a plain folder, look yourself: `git status`, `git log HEAD --not --remotes`, `git
remote`, and the untracked files.

```bash
git -C DIR status --short; git -C DIR log HEAD --not --remotes --oneline
git -C DIR add -A && git -C DIR commit -m "WIP: before recycle"   # if the work should survive
crss reap NAME
crss spawn NAME-2 DIR --model sonnet --brief next-brief.md        # a --worktree NAME stays taken: its session/NAME branch is kept
```

**Never judge pushed work with `git log @{u}..`**: no upstream prints nothing. With no remote,
branch refs are the only copy. For commit reachability, HEAD must be reachable from a named local
branch; keep `session/*` and research branches (`crss reap` never deletes them). Put the prior
branch, transcript path and in-progress work in the next kickoff to avoid re-derivation.

## A hook-wedged session (different from bloat)

A throwing `UserPromptSubmit` / `PreToolUse` hook in `.claude/settings.json` without a fail-open
guard wedges the session (spawn error, missing script, unhandled exception). `UserPromptSubmit`
rejects every prompt before Claude sees it; resending cannot help. `PreToolUse` blocks
Bash/Read/Grep/Glob and even `advisor()`. Diagnose from outside; no automated test covers this
broken-hook shape.

**Symptom** in `tmux capture-pane -p`: repeated blocks like

```
UserPromptSubmit operation blocked by hook:
  [<command>]: error: Failed to spawn: `<script>`
    Caused by: No such file or directory (os error 2)

  Original prompt: <whatever was sent>
```

with no `✻`/`●` processing indicator after: process alive and idle but unreachable. `crss ls`
may show it as `idle` while `crss send` reports `UNVERIFIED`.

**Diagnose:** `cat <rundir>/.claude/settings.json`; inspect the failing command for a fail-open
guard such as `[ -x <script> ] && <script> || exit 0`.

**Recover:** commit or copy out the session's work from outside (its folder is on disk and
unaffected by the hook), `crss reap NAME`, and respawn on the same folder with a kickoff that
carries the branch, task list and in-progress work. Its transcript may be unrecoverable and
`tmux capture-pane -S` is capped by the pane's history-limit. **Prevention:** any script wired to
`UserPromptSubmit` or `PreToolUse` must fail open (catch errors, `exit 0`); a failure there can
permanently wedge the session.

## A session stuck on a menu

A healthy agent can be inside an `AskUserQuestion`-style widget: numbered `[ ]`/`[✔]` checkboxes,
`←  ☐ Next direction  ✔ Submit  →`, "Enter to select · ↑/↓ to navigate · Esc to cancel". Free
text sits below the options without changing a checkbox; use arrows + Enter or "Type something".
`crss ls` reports such a session as `waiting` and `crss send` refuses it, because pasted text and
Enter would answer the dialog.

**Recover (no reap):**
1. `tmux send-keys -t =ah_NAME: Down` (or `Up`) and re-capture; the `❯` marker moving proves the
   widget is live and just mis-navigated.
2. Navigate to the option matching the sender's intent (`Enter` toggles `[ ]`->`[✔]`; it does
   **not** submit).
3. `Right` to move to "Submit", then `Enter` on the review screen ("1. Submit answers").
   Re-capture after each step (type, act, verify).

A stuck-menu session usually has nothing to lose: it was mid a review pause, not an edit.

**Workspace-trust dialog** ("Do you trust the files in this folder? ... Enter to confirm · Esc to
cancel") is also `waiting`, and blind text/Enter is unsafe there too. On CLI 2.1.285 the
highlighted default is **"No, exit"** (so `1 Enter` quits claude); "Yes, I trust this folder" is
the second option. `crss` avoids the dialog: before each launch the loop pre-accepts trust for
the run folder (for a worktree, keyed by its main repo root; the `trust` function in
`scripts/crss.sh`, pinned by `tests/test-crss.sh`) and prints `could not pre-trust` if it
cannot.

## A new session never appears on the phone

The Remote Control bridge only enables when `ANTHROPIC_BASE_URL` is absent or its host is
`api.anthropic.com`; a proxy base URL (for example a local `127.0.0.1` proxy) silently disables
registration. `crss` does not set a base URL, so a proxy configured in `~/.claude/settings.json`
or the environment disables it. Fix by launching with a first-party base URL, for example
`CRSS_DEFAULT_ARGS` carrying `--settings` with a small file that sets
`{"env":{"ANTHROPIC_BASE_URL":"https://api.anthropic.com"}}`. Pass exactly one `--settings`
flag: repeated flags replace each other. If the session is live in `tmux` but missing in the app,
check its `claude` process carries that flag (`ps`). Lane-wide `permissions.deny` entries (for
example MCP servers a lane never uses) belong in that same settings file, since a launch can carry
only one.

## Autocomplete (prompt suggestions) missing in the desktop app

**Verified 2026-10-15:** suggestions reach the app composer from app-started (`+`) and crss
TUI sessions (CLI 2.1.293 `/usr/bin/claude --remote-control`, app `ccd-cli` 2.1.295).
The 2026-10-11 TUI/app discrepancy was host-wide back-off (found 2026-10-15). Model silence is
the other common cause.

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
  `--output-format=stream-json`, so do **not** add it to a crss launch line.
- **Back-off (the real cause when suggestions stop in the app and the TUI still shows one):** after 20
  suggestions in a row go unused, the CLI writes `promptSuggestionUnusedStreak: 20` to `~/.claude.json`
  (21 once the "Showing fewer prompt suggestions · use one to bring them back" notice has been shown) and
  stops suggesting. That counter is **host-wide**, so the unattended fleet (nobody accepts its
  suggestions) pushes the operator's app sessions into back-off. A session skips back-off only when its
  parsed env has `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION` true, and only counts as young for 14 days after
  `firstStartTime`. Check: `jq .promptSuggestionUnusedStreak ~/.claude.json`; at 20 or 21 it is in back-off.
  Reset (not a credentials file; back it up first): set it to 0 with `jq` and write the file back.
- **Who can write the counter (CLI 2.1.308, 2026-10-24):** only an interactive REPL. Each submit that differs from a
  shown suggestion bumps an in-memory per-process count; at 20 in ONE process it writes `promptSuggestionUnusedStreak: 20`
  (a step 0 -> 20, never a tally, so sampling the file cannot name the feeder). `--print`, `--sdk-url`/stream-json children
  (desktop `ccd-cli`, `claude remote-control` spawns) only send telemetry and never write it. The feeders are interactive
  `--remote-control` TUIs nobody tab-accepts; with the old launcher's suppression gone, crss
  sessions are feeders too (phone input never tab-accepts).
  Launch with `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=0` in the environment (below).
- **What crss does about it:** nothing by itself. The old launcher added
  `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=0` to its settings layer, so unattended sessions generated
  no suggestions and never touched the counter (verified then: that layer overrode the `"1"` in
  `~/.claude/settings.json`; a probe with it showed no dim suggestion, the control showed `run it`).
  `crss` has no such layer. To keep unattended sessions out of the counter, put
  `export CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=0` in `~/.config/crss/crss.env` (the loop's `claude`
  inherits it; unverified for this key, so check a restarted session's pane for a dim suggestion)
  or pass a `--settings` file carrying it via `CRSS_DEFAULT_ARGS`. Running sessions keep generating
  until `crss restart`. To watch suggestions in a crss session on purpose, leave it unset.
- `--exclude-dynamic-system-prompt-sections` only moves cwd/env/memory-path/git into the
  first user message. Back-off remains possible even if a fresh TUI renders a suggestion.
- **Cost:** each suggestion is one extra model request per turn; turning it off for unattended crss sessions (above) saves that call.
- **Probe recipe:** `mkdir -p ~/.sessions/ac-probe && crss spawn ac-probe ~/.sessions/ac-probe --model haiku`, send the hello.py
  prompt with `crss send`, confirm the dim line in the pane, open it in the app, then
  `crss reap ac-probe`.

## Every session stopped answering: dead login (silent on an idle fleet)

Sessions share `~/.claude/.credentials.json`. A dead OAuth refresh token
(`OAuthRefreshDeadError`) breaks all sessions after the ~8 h access token expires;
idle remote-control sessions log nothing until prompted. Exact errors:
`Failed to authenticate: OAuth session expired and could not be refreshed` and
`Login expired · Please run /login`.

- Detect: grep recent transcripts (`~/.claude/projects/*/*.jsonl`) for those two strings; never
  read the credentials file. If the newest auth failure is newer than every successful turn, the
  login is dead. `crss ls` and tmux look healthy in this state (the process is alive), so they prove
  nothing about auth.
- Fix: the operator runs `/login` once (in any `claude` pane). Agents never run the login or touch
  credential files. After it, send each stalled lane a one-line nudge (`crss send NAME "login restored; continue"`); a
  newer successful turn means it recovered. (An automatic auth-heal helper was retired with the old tooling.)
- Not the same thing as a spend-limit stop (`You've hit your monthly spend limit`) — that one has its own
  exact text and recovers on its own when the limit is raised.
