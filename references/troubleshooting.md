# Troubleshooting & recycling runbooks

Moved out of `SKILL.md` so the skill itself stays short. Each section is a
diagnose → recover recipe for one failure shape. Three shapes look alike from outside
(session "went silent") but have different causes and fixes — identify which one you have
with `tmux capture-pane -p -t <session>` before acting:

| Pane shows | Shape | Section |
|---|---|---|
| `/clear to save NNNk tokens`, long idle | bloat / staleness | [Compact before relaying](#compact-before-relaying-into-an-idlestale-session), [Preserve before reaping](#preserve-before-reaping-recycling-a-bloated-session) |
| repeated `UserPromptSubmit operation blocked by hook` | hook wedge | [Hook-wedged session](#detecting-a-hook-wedged-session-different-from-bloat) |
| numbered options, `↑/↓ to navigate` | stuck on a menu | [Stuck-on-a-menu session](#detecting-a-stuck-on-a-menu-session-different-from-both-wedge-types-above) |

## Compact before relaying into an idle/stale session

Relaying a follow-up into a session that's been sitting a while pays to reprocess its whole
bloated transcript on every subsequent turn. Compact first — but use the one command, which
does the staleness check, compacts, waits for completion, and only then relays:

```bash
session-compact before-relay <name> "the actual task"   # or --file <path>
```

It **fails closed**: if the compact can't be verified complete, the message is not sent, so
you never land a task mid-summarization. Hand-rolling this (`session-send "/compact"`, eyeball
`tmux capture-pane`, send the real task) is the fallback only if `session-compact` isn't
deployed yet. Same staleness signal as the bloat-before-routing check — a status line reading
`new task? /clear to save NNNk tokens`, or a long idle gap.

**Don't compact a session idle under ~60 minutes** — its 1-hour prompt cache is still live,
so that's the most expensive moment to compact, not the cheapest. `session-compact` defaults
to `--min-idle 60` for this reason; the mechanism, measurements, and the managed-orchestrator
exceptions are in [`docs/session-compaction.md`](../docs/session-compaction.md).

**Auto-compact reality check** (verified against the actual Claude Code changelog, not
guessed): auto-compaction is a real built-in feature and is on by default — it is **not** a
`settings.json` boolean like `autoCompactEnabled`/`autoCompactWindow`; those exact key names
were fabricated once by a guide agent asked about this and do not exist in
`~/.claude/settings.json` or the installed CLI's schema. The real controls are the in-session
`/autocompact` dialog and `/config`, plus env var `CLAUDE_CODE_DISABLE_1M_CONTEXT`. The window
scales with the model's context size (Sonnet 5 on its full 1M window auto-compacts around
~967K tokens) — a session sitting at 200-300k uncompacted tokens is not evidence auto-compact
is broken, it just hasn't neared its threshold yet. There is no `new-session` flag to make
this more aggressive; the pre-compact-before-relay habit above is the actual lever for
proactive cost control, not a spawn-time config toggle.

## Preserve before reaping (recycling a bloated session)

Long-lived sessions accumulate context until every turn is slow and expensive.
Recycling one — kill it, spawn a fresh session on the same repo — is the fix.
**Never reap before `session-preserve` says it is safe.**

```bash
session-preserve <tmux-session>            # audit only. exit 0 = safe to reap
session-preserve <tmux-session> --rescue   # + copy non-junk untracked files aside
session-preserve <tmux-session> --wip      # + WIP-commit uncommitted tracked changes
session-preserve --all                     # audit the whole fleet
```

Recycle recipe:

```bash
session-preserve <s> --rescue --wip        # must print SAFE-TO-REAP
systemctl --user disable --now <base>.service
tmux kill-session -t <s>
new-session <foldername> workspace --alias <new-alias>
```

**Never use `git log @{u}..` to decide whether work is pushed.** It returns
*nothing* when a branch has no upstream configured, so unpushed work reads as
clean. On 2026-08-17 that mistake reported 10,162 local-only commits as "0
unpushed" and nearly authorised a reap sweep across them. Use
`git log HEAD --not --remotes`, and check `git remote` separately — a repo with
**no remote at all** (e.g. `portfolio-single-source-of-truth`, 155 local
branches, zero remotes) cannot be pushed anywhere, so its branch refs are the
only copy that exists.

What actually makes a reap safe is that **HEAD is reachable from a named local
branch** — then killing the session and removing its worktree cannot orphan the
commits, because they stay in the canonical repo's object store. It follows
that *deleting the branch* is the dangerous operation, not reaping. Any worktree
GC must leave `session/*` and research branches alone.

Respawned sessions start on a fresh worktree cut from the default branch, **not**
on the old session's branch. Say so in the kickoff: name the prior branch, the
prior transcript path, and what the session was mid-way through, or the
replacement re-derives it at full cost.

## Detecting a hook-wedged session (different from bloat)

A session can go silent for a reason that looks identical to the "send didn't
land" failure mode but has a different mechanism and a different fix: a
`UserPromptSubmit` or `PreToolUse` hook in the session's own
`.claude/settings.json` throws (a subprocess spawn error, a missing script, an
unhandled exception) and has **no fail-open guard**. Because
`UserPromptSubmit` fires on *every* prompt, once it starts erroring, every
future prompt — including plain retries like "try again" — is rejected before
Claude ever sees it. No amount of resending fixes this from inside the
session; resending IS the thing that keeps failing.

**Symptom in `tmux capture-pane -p`:** repeated blocks shaped like

```
UserPromptSubmit operation blocked by hook:
  [<command>]: error: Failed to spawn: `<script>`
    Caused by: No such file or directory (os error 2)

  Original prompt: <whatever was sent>
```

with no `✻`/`●` processing indicator after it — the agent process is alive and
idle, but unreachable. This happened on 2026-08-17 to `ah-trs-fix-0816-2008`
(ironically, a session tasked with hardening the very hook scripts that then
wedged it): a `PreToolUse` hook spawn error blocked Bash/Read/Grep/Glob, the
in-session `advisor()` call stalled 16 minutes and errored, and every prompt
sent after that — from the user and from a live diagnostic retry — was
rejected by the same broken `UserPromptSubmit` hook.

**Diagnose:** `cat <rundir>/.claude/settings.json` and look at the failing
hook's command. If it has no fail-open guard (compare to a sibling hook line
in the same file that does, e.g. `[ -x <script> ] && <script> || exit 0`),
a subprocess error there is a hard, permanent block — not a fluke worth
retrying.

**Recover:** same mechanics as the bloat recycle recipe above — a hook wedge
is not a special case for reaping:

```bash
session-preserve <s> --rescue --wip        # runs from OUTSIDE the wedged session — unaffected by its hook
systemctl --user disable --now <base>.service
new-session <foldername> workspace --alias <same-alias>
```

Then hand off the wedged session's actual state in the kickoff (branch, task
list, what was in progress) since its own transcript may be unrecoverable —
`tmux capture-pane -S` is capped by the pane's history-limit and may not reach
back to the original kickoff.

**Prevention (tell whoever fixes the hook):** any script wired to
`UserPromptSubmit` or `PreToolUse` must fail open — catch spawn/subprocess
errors and `exit 0` rather than propagate — because a failure there doesn't
just fail one tool call, it can permanently wedge the whole session.

## Detecting a stuck-on-a-menu session (different from both wedge types above)

A session can look wedged for a third reason that has nothing wrong with it
at all: it's mid an interactive multi-choice widget (an `AskUserQuestion`-style
prompt — numbered options with `[ ]`/`[✔]` checkboxes, a
`←  ☐ Next direction  ✔ Submit  →` bar, "Enter to select · ↑/↓ to navigate ·
Esc to cancel") and whoever replied sent ordinary free text instead of
navigating it. The widget only understands arrow keys + Enter (and a
dedicated "Type something" option for free text); a plain sentence sent into
it is not a valid input, so it just sits there inert — the session looks
unresponsive to normal chat, but the agent process is perfectly healthy the
whole time. Confirmed on 2026-08-21 (`ah-frontend-refactor-0821-0657`): a
plain-text reply ("all good?") to a "where should I point the next
iterations" menu never registered; the widget was still waiting for a
selection.

**Symptom in `tmux capture-pane -p`:** a numbered option list with checkboxes
and the `↑/↓ to navigate` hint still on screen, with a plain-text line sitting
below it that was clearly meant as an answer but isn't reflected in any
checkbox state.

**Recover (no reap needed — this is not a broken session):**
1. `tmux send-keys -t <s> Down` (or `Up`) and re-capture to confirm the `❯`
   marker actually moves — this proves the widget is live and just
   mis-navigated, not stuck for some other reason.
2. Navigate to the option that best matches what the original sender meant
   (`Enter` toggles a `[ ]`→`[✔]` checkbox on the highlighted option — it does
   **not** submit).
3. `Right` arrow to move from the options page to "Submit", then `Enter` again
   on the review screen ("1. Submit answers") to actually confirm. Re-capture
   after each step — the same "type, act, verify" discipline as any other
   kickoff, just with arrow keys instead of literal text.

Check `session-preserve` / `git log HEAD --not --remotes` before doing
anything if there's any doubt — but a stuck-menu session usually has nothing
to lose: it was mid a *review* pause, not mid an edit.

**A different widget classifies the same way but recovers differently:**
Claude Code's first-launch workspace-trust dialog ("Do you trust the files in
this folder? ... Enter to confirm · Esc to cancel") is also detected as
`menu` (`_is_on_menu` / `_state_of` in `scripts/session-handoff.sh` — see its
comment for the 2026-09-24 incident this covers), since blind text/Enter is
just as unsafe there as on the widget above — but it is a numbered
Yes/No choice, not an arrow-key+checkbox+Submit-page flow: recover with
`tmux send-keys -t <s> 1 Enter` (trust) or `2 Enter` (exit), not the
Down/Right/Enter sequence above.

