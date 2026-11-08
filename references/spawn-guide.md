# Spawn guide: models, second opinions, kickoff

Commands are in `SKILL.md`. This file holds the judgment: which model, who gets a second opinion,
how to write the first prompt.

## Choosing the model

`crss spawn` has no profiles: pick the model with `--model` and put the rest after `--`.

| Job | Launch |
|---|---|
| Orchestrator, risky or ambiguous design | `--model claude-opus-5-5 -- --effort medium` (high only at risky forks) |
| Long-lived lane owner or hub | `--model sonnet -- --advisor claude-opus-5-5` |
| Debugging or review in one repo; Claude fallback builder | `--model sonnet -- --effort low` |
| Mechanical, doc-only, sweeps | `--model haiku -- --effort low` |

- Implementation goes to Codex first ([orchestration-flow](orchestration-flow.md)), not a Claude session.
- Aliases (CLI 2.1.308): `sonnet opus haiku fable best sonnet[1m] opus[1m] fable[1m] opusplan`.
  There is no `auto` router. `--fallback-model a,b` handles overload only.
- Opus is for a short, hard, bounded task: reap when done (nothing enforces it). Unsure which model:
  default to Sonnet; for a real fork ask your own advisor once.
- Default launch arguments come from `CRSS_DEFAULT_ARGS` in `~/.config/crss/crss.env`. Auto-compact
  window: [troubleshooting](troubleshooting.md#auto-compact).
- Global skills load into every spawn. The Superpowers plugin injects its `using-superpowers` skill
  (about 900 tokens per start); a lane that shouldn't carry it needs the plugin off in the settings
  it launches with. Never pass `--settings` twice: a later flag replaces an earlier one.
- `-- --tools "Bash,Read,..."` is an exhaustive allowlist over built-ins, including deferred ones;
  a built-in left out is unreachable even through ToolSearch, MCP tools stay reachable. On a fresh
  Sonnet session it cut the prefix from 35.7k to 24.3k tokens (CLI 2.1.206).
- A session started from the phone is not a crss session ([troubleshooting](troubleshooting.md#a-new-session-never-appears-on-the-phone)).
- `agents/builder.md` has `maxTurns` 250 per invocation. After "Agent stopped at its 250-turn limit",
  run `git status` and `git diff --stat` in its worktree and continue it with SendMessage; a fresh
  spawn orphans its context and edits.
- Wide work (many independent slices, or a change needing adversarial review): plan first, then fan
  out parallel `builder` subagents. Narrow work stays in one Sonnet session.

## Second opinions

- **Advisor.** Launch Sonnet and Haiku lanes with `-- --advisor claude-opus-5-5`; Opus and Fable
  default to self-advice, and explicit ids work. It needs CLI 2.1.300 or later and an interactive
  session (`claude -p` hides it). Call it before choosing an approach and before declaring done; it
  sees the whole transcript.
- **Independent read** at risky or destructive forks, ambiguous designs, and before declaring a
  multi-step task done: a one-shot reviewer on a frozen packet, never a Sonnet builder checking
  itself. Fable (`agents/reviewer.md`) is paused (operator 2026-10-28); until lifted use one
  gpt-6.1-sol call on the same packet.
- **Hub consult.** A Sonnet or Haiku hub asks for an Opus one-shot only at real forks (destructive
  action, ambiguous design, before declaring done): write a frozen packet (for example
  `.claude/hub-opus-frozen-packet.md`), spawn a subagent with `model: "opus"`, give it the packet
  and never the transcript. The hub owns the decision and records `models_ran`. Opus is never a
  resident or polling session.
- **Order:** cheap strong reviewer, different-family check, expensive reviewer last. A merge or
  operator-facing review needs two model families. Single-family review counts only when Claude is
  quota-out; with Codex out (2026-11-06) an independent Claude review stands in (2026-11-07). Name the model in the PR body.

## Writing the kickoff

A spawn has none of your context, so the brief carries it. Read `$CRSS_HOME/local.md` first if it
exists (escalation channel, guardrails, delegate routing). Shapes:
[kickoff-templates](../handoff/references/kickoff-templates.md).

- **Finish line.** "PR merged with `shell-tests` green and the script redeployed", not "look into
  the compaction bug".
- **Stop rule and channel.** When the launcher is a crss session: `crss send <launcher> --file F`,
  numbered options with a recommendation. Otherwise name the host's channel from `$CRSS_HOME/local.md`,
  since `crss send` can't reach it. A question sitting in a pane raises no notification; builders send
  the exact blocked command or decision to the launcher and print a final `BLOCKED:` line.
- **Concrete anti-patterns:** "don't branch from local `main`", "no deploys without explicit human
  approval in this session". Specific mistakes beat "be careful".
- **Builders:** Codex first per [orchestration-flow](orchestration-flow.md#escalation-ladder); record
  the model that ran.
- **Delegate** independent research, edits and verification by
  [Roles](orchestration-flow.md#roles). Only the prompt crosses over: brief fully, have another
  reader verify, write large output to files and return a summary and path.
- **Long runs:** `TASKS.md` with the finish line on top, re-read after compaction.
- Leave out "think carefully", "step by step", ALL-CAPS and "MUST": give a reason instead.

Add mid-run context with `crss send`; respawning discards the work. On a done report, first unblock
any decision, approval, merge or credential the lane needs, then read the rest.

## Naming

NAME is lowercase letters, digits and dashes (`cmd_spawn` in `scripts/crss.sh` checks it). Nothing
adds a date suffix, so pick a name that is unique and readable on a phone. `--worktree` branches are
`session/NAME`, so a reused name is refused while the branch exists.
