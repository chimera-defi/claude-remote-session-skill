# Spawn guide: models, second opinions, kickoff

The commands are in `SKILL.md`. This file holds the judgment: which model, who gets a second
opinion, and how to write the first prompt.

## Choosing the model

`crss spawn` has no profiles or tiers: pick the model per spawn with `--model`, and put the rest
after `--`.

| Job | Launch |
|---|---|
| Orchestrator, risky or ambiguous design | `--model claude-opus-5-5 -- --effort medium` (high only at risky forks) |
| Long-lived lane owner or hub | `--model sonnet -- --advisor claude-opus-5-5` |
| Debugging or review in one repo; Claude fallback builder | `--model sonnet -- --effort low` |
| Mechanical, doc-only, sweeps | `--model haiku -- --effort low` |

- Implementation goes to Codex first (`orchestration-flow.md`), not to a Claude session.
- Aliases (CLI 2.1.308): `sonnet opus haiku fable best sonnet[1m] opus[1m] fable[1m] opusplan`.
  There is no `auto` router. `opusplan` switches Opus planning to Sonnet execution only on the
  plan-mode toggle. `--fallback-model a,b` handles overload and retries the primary each turn.
- Effort: a 2026-10-22 blind check (3 planning prompts, Fable judge) scored medium 8.3 vs high
  8.0 at about 60% of the cost, so orchestrators default to medium. Haiku 5.5 supports effort
  (CLI model table, 2026-10-15). The 2026-10-22 bench did not test Haiku as an agentic builder;
  the 10-24 follow-up ran haiku-high 12/12 agentic and is used only on the Codex-out ladder
  ([bench evidence](orchestration-flow.md#bench-evidence)).
- Opus is for a short, hard, bounded task: reap when done (nothing enforces it).
- Default launch arguments (permission mode, `--exclude-dynamic-system-prompt-sections`, ...)
  come from `CRSS_DEFAULT_ARGS` in `~/.config/crss/crss.env`.
- Auto-compact window: see [troubleshooting](troubleshooting.md#auto-compact).
- Global skills load into every spawn; use them without waiting to be asked. The Superpowers
  plugin injects its `using-superpowers` skill (a hook, about 900 tokens per start, clear and
  compact, and brainstorming before replies). A lane that should not carry it needs the plugin
  switched off in the settings it launches with. Never pass `--settings` twice: a later flag
  replaces an earlier one and drops whatever the first carried (such as a first-party base URL,
  see [troubleshooting](troubleshooting.md#a-new-session-never-appears-on-the-phone)).
- A session started from the phone is not a crss session: [phone-spawn.md](phone-spawn.md).

## Second opinions

- **Advisor.** Launch Sonnet and Haiku lanes with `-- --advisor claude-opus-5-5`; Opus and Fable
  default to self-advice, and explicit ids work (2026-10-17, CLI 2.1.300: Opus 5.5 with
  `--advisor claude-fable-5-1` showed "Advising using Fable 5.1"). Verified 2026-10-15, CLI
  2.1.300: interactive `--model opus` listed `advisor` and a call succeeded; model table
  `advisor_rank >= 2`, Opus 5.5 = 7; absent in 2.1.280 probes; `claude -p` hides it for every
  model, so probe interactively. Call it before choosing an approach and before declaring done,
  while context is small: it sees the whole transcript.
- **Independent read** at risky or destructive forks, ambiguous designs and before declaring a
  multi-step task done: one-shot reviewer on a frozen packet, never a Sonnet builder checking
  itself. Fable via `subagent_type: "reviewer"` (`agents/reviewer.md`) is paused (operator
  2026-10-28); until lifted use one gpt-6.1-sol call on the same packet. A Sonnet or Haiku hub
  uses the Opus one-shot in [hub-opus-consult.md](hub-opus-consult.md).
- **Order** (host policy in `$CRSS_HOME/local.md`): cheap strong reviewer, different-family
  check, expensive reviewer last. A merge or operator-facing review needs two model families.
  Single-family review counts only when Claude is quota-out (terra low builds, a separate
  gpt-6.1-sol call reviews); with Codex out the PR waits with the review marked UNVERIFIED.
  Record `models_ran` in the PR body.
- ChatGPT is reached through a project relay subagent, not a session of its own; that project's
  `.claude/agents/` and roles table own the details, and `$CRSS_HOME/local.md` says what is
  available.
- Unsure which model? Default to Sonnet; for a real fork (Sonnet or Opus) ask your own advisor
  once, with a short summary, before spawning.
- `agents/builder.md` has `maxTurns` 250 per invocation, and the CLI can stop it mid-step. After
  "Agent stopped at its 250-turn limit", run `git status` and `git diff --stat` in its worktree,
  then continue it with SendMessage; a fresh spawn orphans its context and edits.
- Wide or multi-faceted work (many independent slices, or a change that needs adversarial
  review): plan first, then fan out with parallel `builder` subagents or `Workflow` (Opus
  orchestrators, on explicit operator opt-in). Narrow work stays in one Sonnet session.
- Trimming a lane's tool list: `-- --tools "Bash,Read,..."` is an exhaustive allowlist over
  built-ins, including deferred ones (WebFetch, WebSearch, Task*, plan mode, NotebookEdit,
  Monitor); a built-in left out is unreachable even through ToolSearch, while MCP-server tools
  are a separate namespace and stay reachable. Measured with `/context` on a fresh session (CLI
  v2.1.206, Sonnet 5): 35.7k total with no flags, 24.3k with the allowlist; system tools 19.5k
  to 8.2k, the saving coming from Workflow (about 7.8k), Artifact and SendUserFile (about 1.9k)
  and ReportFindings and ScheduleWakeup (about 0.6k); `advisor` costs about 1k more.
  `--exclude-dynamic-system-prompt-sections` is token-neutral: it moves cwd, env and git status
  into the first user message, which helps the prompt cache.

## Writing the kickoff

A spawn has none of your context. The contract is
[`massaging.md`](../handoff/references/massaging.md); fill-in shapes are in
[`kickoff-templates.md`](../handoff/references/kickoff-templates.md). Read `$CRSS_HOME/local.md`
for escalation, guardrails and delegate routing if it exists.

- **Finish line.** "PR merged with `shell-tests` green and the script redeployed", not "look into
  the compaction bug".
- **Stop rule and channel.** Say when to continue and when to escalate. When the launcher is a
  crss session: `crss send <launcher> --file F`, numbered options with a recommendation. When it
  is not (a desktop launcher, the bus), name the host's channel from `$CRSS_HOME/local.md` in the
  brief, since `crss send` cannot reach it. A question that sits in a pane raises no
  notification and no `AskUserQuestion` alert; launchers sweep panes read-only, and no one
  answers a permission denial for a lane. Builders send the exact blocked command, decision or
  input to the launcher and print a final `BLOCKED:` line.
- **Concrete anti-patterns.** "Don't branch from local `main`", "no deploys without explicit
  human approval in this session". Specific mistakes beat "be careful".
- **Builders.** Codex first: gpt-6.1-terra low in fast mode by default (operator 2026-11-02):
  `codex exec -m gpt-6.1-terra -c model_reasoning_effort=low -c service_tier=priority`, stdin
  closed. Run the task's tests; only a failed check sends Haiku low to repair, then
  `-m gpt-6-astra` medium (also the pick when latency matters), then a Sonnet 5.5 low builder.
  Codex out (exact quota error text): Haiku low builds, Haiku high on a failed check or a costly
  miss. Never luna or sol61 medium for builds. Trims and evidence:
  [Codex flags](orchestration-flow.md#codex-flags), [bench evidence](orchestration-flow.md#bench-evidence).
  Record the model that ran.
- **Delegate** independent research, edits and verification by
  [Roles](orchestration-flow.md#roles): Codex or ChatGPT gpt-6.1-sol for research; Claude
  fallback `subagent_type: builder` or `model: "sonnet"`, which keeps `advisor`. Only the prompt
  crosses over: brief fully, use another reader to verify, write large output to files and
  return a summary and path, then check the evidence.
- **Long runs.** `TASKS.md` with the finish line on top, updated as you go, re-read after
  compaction.
- **Eval and hillclimb campaigns** need a budget gate: use the add-on in
  [`kickoff-templates.md`](../handoff/references/kickoff-templates.md#e-evalhillclimb-campaign-kickoff-add-on)
  and the protocol in
  [`eval-hillclimb-protocol.md`](../handoff/references/eval-hillclimb-protocol.md) (splits,
  novelty reserve, budget, stop and revert rules).
- Leave out "think carefully", "step by step", "ultrathink", ALL-CAPS and "MUST". Models size
  their own thinking; give a reason instead of length.

Add mid-run context with `crss send` to preserve work. On a done report, first unblock any
decision, approval, merge or credential the lane needs, then read the rest.

## Naming

`crss spawn NAME DIR`: NAME is lowercase letters, digits and dashes; the tmux session is
`ah_NAME` and the phone name `ah-NAME` (`cmd_spawn` in `scripts/crss.sh` checks the pattern).
Nothing adds a date suffix or looks up an alias, so pick a name that is unique and readable on a
phone. `--worktree` branches are `session/NAME`, which is why a reused name is refused while the
branch exists.
