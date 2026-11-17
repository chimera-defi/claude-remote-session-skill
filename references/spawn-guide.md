# Spawn guide: models, second opinions, kickoff

Commands are in `SKILL.md`. This file holds the judgment: which model, who gets a second opinion,
how to write the first prompt.

## Choosing the model

`crss spawn` has no profiles: pick the model and effort with `--model` and `--effort`, and put other claude flags after `--`. A host keeps
its standard arg sets in its overlay docs and passes them after `--`. Roles and which model suits
each: [orchestration-flow](orchestration-flow.md#roles); which model fills them on this host:
`$CRSS_HOME/staffing.md` if it has one.

| Job | Example launch (model ids and the `--advisor` id are examples) |
|---|---|
| Planner, risky or ambiguous design | `--model opus --effort medium` (high only at risky forks) |
| Long-lived lane owner or hub | `--model sonnet -- --advisor claude-opus-5-5` |
| Debugging or review in one repo; fallback builder | `--model sonnet --effort low` |
| Mechanical, doc-only, sweeps | `--model haiku --effort low` |

- Aliases (CLI 2.1.308): `sonnet opus haiku fable best sonnet[1m] opus[1m] fable[1m] opusplan`.
  There is no `auto` router. `--fallback-model a,b` handles overload only.
- The strongest model is for a short, hard, bounded task: reap when done (nothing enforces it). Unsure
  which model: default to Sonnet; for a real fork ask your own advisor once.
- Global skills and plugins load into every spawn, and some inject their own skill at start (the
  Superpowers plugin's `using-superpowers`, about 900 tokens). A lane that shouldn't carry one needs
  the plugin off in the settings it launches with; see "Lean loadouts" below.
- Default launch arguments come from `CRSS_DEFAULT_ARGS` ([env knobs](../examples/crss-overlay/README.md#env-knobs)).
  Auto-compact window: [troubleshooting](troubleshooting.md#auto-compact).
- `-- --tools "Bash,Read,..."` is an exhaustive allowlist over built-ins, including deferred ones;
  a built-in left out is unreachable even through ToolSearch, MCP tools stay reachable. On a fresh
  Sonnet session it cut the prefix from 35.7k to 24.3k tokens (CLI 2.1.206).
- A session started from the phone is not a crss session ([troubleshooting](troubleshooting.md#a-new-session-never-appears-on-the-phone)).
- `agents/builder.md` has `maxTurns` 250 per invocation. After "Agent stopped at its 250-turn limit",
  run `git status` and `git diff --stat` in its worktree and continue it with SendMessage; a fresh
  spawn orphans its context and edits.
- Wide work (many independent slices, or a change needing adversarial review): plan first, then fan
  out parallel `builder` subagents. Narrow work stays in one Sonnet session.

## Lean loadouts

Verified on CLI 2.1.325. Skill bodies load only when a skill is invoked; the always-on cost is the
skill listing, so trim the listing first for worker sessions.

- `crss spawn NAME DIR -- --disable-slash-commands` starts a session with no skills listed at all.
  Good for pure build or scan workers.
- A settings file with `"skillOverrides": {"skill-name": "off"}` (other values: `"on"`, `"name-only"`,
  `"user-invocable-only"`), passed as `-- --settings FILE`, hides those skills. Only one `--settings`
  flag is honoured (the last wins), so if `CRSS_DEFAULT_ARGS` already carries `--settings`, the loadout
  file must repeat what that file sets.
- A deny rule `Skill(name)` in permissions does not remove the skill from the listing.
- Args given at spawn are stored and re-passed on every restart.

### Add or drop a skill in a running session

Tested once on a live session, CLI 2.1.325. No restart, and the prompt cache held.

```bash
mkdir -p DIR/.claude/skills && cp -r path/to/my-skill DIR/.claude/skills/   # DIR: the session's folder (crss ls)
crss send NAME "/reload-skills"   # pane: "Reloaded skills: N skills available (1 added)"
# ... the session lists and can invoke my-skill from its next turn ...
rm -r DIR/.claude/skills/my-skill && crss send NAME "/reload-skills"         # "(1 removed)"
```

- Cache: the turn after each reload read the whole prefix from cache (43k tokens) and wrote a few
  hundred new ones.
- In a shared repo the folder shows up as untracked: remove it when the task is done, and don't commit it.
- `/add-dir PATH` sent to a running session did not work in the test: it opens a dialog (the session
  goes `waiting`), and after the dialog was accepted a skill under that folder's `.claude/skills` was
  still not listed to the model.
- MCP servers have their own live switch: `crss send NAME "/mcp disable SERVER"` and
  `"/mcp enable SERVER"` (pane: `MCP server "SERVER" disabled`). No dialog. It is not session-only: the CLI saves it under
  the project's entry in `~/.claude.json`, so it also applies to other sessions in that project and
  survives restarts until `/mcp enable SERVER`.
- These commands start no turn; `crss send` confirms them from the transcript and prints the result
  line. A command that has written nothing there within ten seconds (one waiting in a dialog) prints
  `UNVERIFIED`; use `crss peek NAME`.

## Second opinions

- **Advisor.** Launch Sonnet and Haiku lanes with `-- --advisor <model id>`; the strongest models default
  to self-advice, and explicit ids work. It needs CLI 2.1.300 or later and an interactive session
  (`claude -p` hides it). Call it before choosing an approach and before declaring done; it sees the
  whole transcript. Use it for routine forks.
- **Independent read** at risky or destructive forks, ambiguous designs, and before declaring a
  multi-step task done: a one-shot reviewer on a frozen packet (state, options, recommendation, the
  diff), never a builder checking itself (`agents/reviewer.md`).
- **Hub consult.** A Sonnet or Haiku hub asks for a strongest-model one-shot only at real forks
  (destructive action, ambiguous design, before declaring done): write a frozen packet, spawn a subagent
  with `model: "opus"`, give it the packet and never the transcript. The hub owns the decision and
  records which models ran. The strongest model is never a resident or polling session.
- **Independent review rule (canonical).** A merge, or a review a person will act on, needs a reviewer
  who is not the builder, preferably from a different model family. Name the reviewing model in the PR
  body. When no second family is available, an independent subagent of the same family reading the
  frozen diff stands in; say so in the PR body. A cheap first-pass reviewer (`agents/haiku-reviewer.md`)
  is advisory, not a gate. Order: cheap first pass, different-family check, expensive reviewer last.

## Writing the kickoff

A spawn has none of your context, so the brief carries it. Read `$CRSS_HOME/local.md` first if it
exists (escalation channel, guardrails). Shapes:
[kickoff-templates](../handoff/references/kickoff-templates.md).

- **Finish line.** "PR merged with `shell-tests` green and the script redeployed", not "look into
  the compaction bug".
- **Stop rule and channel.** When the launcher is a crss session: `crss send <launcher> --file F`,
  numbered options with a recommendation. Otherwise name the host's channel from `$CRSS_HOME/local.md`,
  since `crss send` can't reach it. A question sitting in a pane raises no notification; builders send
  the exact blocked command or decision to the launcher and print a final `BLOCKED:` line.
  `crss spawn` records its caller, so a child finds its launcher with `crss ls NAME --json | jq -r '.[0].by'`.
  That prints a NAME you can `crss send` to when the caller is a live crss session; otherwise it is a
  conversation title (a Desktop session, or one cleared or reaped since) or a systemd unit.
  `CRSS_BY=name crss spawn ...` overrides what is recorded.
- **Concrete anti-patterns:** "don't branch from local `main`", "no deploys without explicit human
  approval in this session". Specific mistakes beat "be careful".
- **Builders:** record the model that ran.
- **Delegate** independent research, edits and verification by
  [role](orchestration-flow.md#roles). Only the prompt crosses over: brief fully, have another
  reader verify, write large output to files and return a summary and path.
- **Long runs:** `TASKS.md` with the finish line on top, re-read after compaction.
- Leave out "think carefully", "step by step", ALL-CAPS and "MUST": give a reason instead.

Add mid-run context with `crss send`; respawning discards the work. On a done report, first unblock
any decision, approval, merge or credential the lane needs, then read the rest.

## Naming

NAME is lowercase letters, digits and dashes (`cmd_spawn` in `scripts/crss.sh` checks it). Nothing
adds a date suffix, so pick a name that is unique and short to type. The app lists the session by
its title, not NAME ([names](../SKILL.md#commands)). `--worktree` branches are `session/NAME`, so a
reused name is refused while the branch exists.
