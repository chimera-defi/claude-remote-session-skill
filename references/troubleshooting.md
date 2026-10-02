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
"Done for a spawn"; pinned by `tests/test-new-session-settle-loop.sh` and
`tests/test-session-handoff-paste-race.sh`).

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

- `autoCompactWindow` is causally confirmed: `claude -p ... --settings '{"autoCompactWindow": N}'`
  gave the same `effectiveWindow` in `-d config,settings,compact --debug-file <f>` output as
  the `--autocompact N` flag (`N=105000` -> `85000`; `N=500000` -> `180000`, clamped to the
  200k model window, both ways).
- `autoCompactEnabled` sits in the same schema object as `autoCompactWindow` (both on the same
  ~118KB minified schema line, ~12.4KB apart, no object boundary between), not in the global
  `~/.claude.json` preferences schema. Its `.describe()`: "Automatically compact conversation
  when context fills"; it also backs the `/config` "Auto-compact" toggle. Its read-from-
  `--settings` behaviour was not reproduced (the debug line didn't fire in a single-turn `-p`
  run): strong but not causally confirmed.

Other controls: launch flag `--autocompact <auto|tokens>`, in-session `/autocompact` and
`/config`, env `CLAUDE_CODE_DISABLE_1M_CONTEXT`. The window scales with model context (Sonnet 5
on 1M auto-compacts near ~967K), so a session at 200-300k uncompacted tokens is not evidence
it's broken. There is no `new-session` flag to make it more aggressive; compact-before-relay is
the lever for proactive cost control. Lesson: verify a specific claim yourself before
repeating it, in either direction.

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
`scripts/session-handoff.sh`, pinned by `tests/test-session-handoff-trust-dialog.sh`), since
blind text/Enter is unsafe there too. On CLI 2.1.285 the highlighted default is **"No, exit"**
(so `1 Enter` quits claude), "Yes, I trust this folder" is the second option. Spawns avoid the
dialog: the start script runs `scripts/session-trust-seed.sh` on the run directory first (it
explains which key the CLI checks for git worktrees; pinned by `tests/test-session-trust-seed.sh`).
