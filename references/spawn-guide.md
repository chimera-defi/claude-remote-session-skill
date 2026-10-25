# Spawn guide: model policy, tiers, kickoff, naming

Detail moved out of `SKILL.md` (which every spawn loads) on 2026-10-15; text unchanged except where noted.

## Model and second-opinion policy (Key Rules detail)

- The superpowers plugin injects `using-superpowers` at session start and the global skills are linked into every spawn; don't wait for the user to ask
- Claude profile default is **per role** via `CLAUDE_SESSION_PROFILE`: `owner`→`sonnet` (full tool set, for long-lived lane owners), `hub`→`sonnet` (full tools plus the Opus consult contract), `builder`→`sonnet`, `copywriter`→`haiku` (bare aliases, auto-track the latest release for their tier); `orchestrator`→`claude-opus-5-5`, **pinned** to an exact id (see `scripts/new-session.sh`'s "Model selection" comment for why). Override per-spawn with `CLAUDE_SESSION_MODEL=<model>`
- `agents/builder.md` caps a builder at 250 turns per invocation (`maxTurns`). The CLI stops it
  mid-step. On an "Agent stopped at its 250-turn limit" result, run `git status` /
  `git diff --stat` in its worktree before deciding anything. Then continue it with SendMessage,
  which keeps its context and its half-done edits; a fresh spawn would orphan them.
- Hub sessions run Sonnet by default and keep both native `advisor` and the Opus one-shot
  consult contract in [`references/hub-opus-consult.md`](hub-opus-consult.md).
- The standard lane shape (Opus orchestrates, Codex gpt-6.1-sol high builds, Haiku checks, Opus
  adversarial review) is in [`references/orchestration-flow.md`](orchestration-flow.md);
  link it in kickoff briefs instead of restating it.
- `advisor` availability (verified 2026-10-15 on CLI 2.1.300: an interactive `--model opus` probe listed the
  tool and a call succeeded; the installed model table gates it on `advisor_rank >= 2`, Opus 5.5 is 7; 2.1.280
  probes had it absent, and `claude -p` hides it for every model, so probe interactively). An Opus orchestrator uses its native `advisor` for routine forks (it is cheap and sees
  the transcript). An independent second opinion is still a one-shot Fable — `subagent_type: "reviewer"`
  (`agents/reviewer.md`) or `Agent({description, prompt, model: "fable"})` on a frozen packet — at risky or
  destructive forks, designs under real ambiguity, and before declaring a multi-step task done; never a Sonnet
  builder, which would just be Sonnet checking its own reasoning. `model: fable` is a valid agent-frontmatter
  value on the installed CLI (a probe agent with it ran as a Fable model). (decided 2026-10-15)
- ChatGPT is reached, if at all, through a project-specific relay subagent (not a standalone
  session), defined in that project's own `.claude/agents/` and roles table — don't copy its
  call-out details here. `$CRSS_HOME/local.md` says which projects have one.
- The order of second opinions is overlay-configurable: `$CRSS_HOME/local.md` may name which
  reviewer goes first (for example a cheaper strong model), which gives a different-family
  cross-check, and which expensive reviewer goes last. Whatever the order, a review that gates
  a merge or an operator-facing decision never rests on a single model family; if only one
  family is available, merge anyway and record `models_ran` in the PR body. An
  orchestrator's own sanity check (the Fable bullet above) is not that review.

## Choosing a tier (right-size the model, save quota)

Pass `--tier` and a one-line `--tier-reason` (logged in spawn telemetry: the decision, not the outcome),
or `--tier auto` with `--task-type orchestrate|review|mechanical|research|build` (else keywords in the brief):
it prints the pick and why and logs it to the routing log; `build` picks Codex gpt-6.1-sol high, review/mechanical `light`, research `heavy`, orchestrate the Opus default, no match `standard`. Explicit `--backend`/env win. Resolution lives in
`scripts/new-session.sh` and is pinned by `tests/test-new-session-tier.sh`; do not restate it here.

| Tier | Pick it when the task is | Defaults |
|---|---|---|
| `light` | mechanical, doc/copy-only, a bounded edit with a clear check | copywriter profile, haiku, `--effort low` |
| `standard` | debugging or review in one repo; implementation only as the Claude fallback (implementation goes to Codex gpt-6.1-sol high first: `--tier auto --task-type build`) | builder profile, sonnet, `--effort low` |
| `heavy` | ambiguous design, long-lived lane, gating review, needs `Workflow` fan-out | owner profile (full tools), **sonnet** + Opus advisor. Not Opus: for an Opus orchestrator omit `--tier` |

- Tier defaults unchanged: the 2026-10-22 bench did not test Haiku as an agentic builder (the 10-24 follow-up ran haiku-high 12/12 agentic, used only on the Codex-out ladder); `light`/`standard` already use effort low, and higher effort bought nothing ([bench evidence](orchestration-flow.md#bench-evidence)).
- **Claude Code has no per-request model router.** Checked on CLI 2.1.308: the alias table is
  `sonnet opus haiku fable best sonnet[1m] opus[1m] fable[1m] opusplan`, with no `auto`. `opusplan` swaps
  Opus (plan mode) for Sonnet (execution) on the plan-mode toggle and nothing else. `default`/`best` follow the
  account or release. `--fallback-model a,b` is an availability fallback (overloaded or unavailable; retries
  the primary each user turn), not a router. "Auto mode" (`--permission-mode auto`, `claude auto-mode`) is
  the permission classifier and never picks a model. So right-sizing happens once, at spawn:
  `--tier auto` classifies the brief, and inside a session the orchestrator routes each slice by the table in
  [orchestration-flow.md](orchestration-flow.md). `new-session` without `--tier` uses the profile
  default (orchestrator pins `$CRSS_OPUS_MODEL`). Native sessions it does not launch (desktop app, phone, a
  remote-control spawn server) run the account default, Opus, and delegate the same way.
- **Orchestrator effort** defaults to medium (`CRSS_ORCHESTRATOR_EFFORT`, `none` drops it); set `CLAUDE_SESSION_EFFORT=high` at risky forks. A 2026-10-22 blind check (3 planning prompts, Fable judge) scored medium 8.3 vs high 8.0 at ~60% of the cost.
- A tier never selects Opus (`heavy` is a Sonnet owner with an Opus advisor; `new-session` prints `resolved: ... model=` on every spawn so this is visible). Opus is the no-tier default or an explicit
  `CLAUDE_SESSION_PROFILE=orchestrator` / `CLAUDE_SESSION_MODEL`; use it for short, truly hard,
  bounded jobs, give it a task, and reap it when done (nothing enforces that).
- A `--launcher` that is not a live tmux session (a desktop/app launcher) cannot be reached by `session-send`; `new-session` warns on stderr, so tell the lane in its kickoff to report through the host's bus/mailbox.
- Explicit `CLAUDE_SESSION_PROFILE` / `_MODEL` / `_EFFORT` win over the tier, one value at a time.
  `standard` and `light` set effort `low` (Haiku 5.5 supports effort; verified in the CLI model table 2026-10-15); `heavy` sets none. Pass `CLAUDE_SESSION_EFFORT` to override.
  Auto-compact window is per tier too: overlay `CRSS_COMPACT_WINDOW_<TIER>` (per spawn `CLAUDE_SESSION_COMPACT_WINDOW=<n|host>`), else `CRSS_COMPACT_WINDOW_DEFAULT` (234000, ~150k trigger at PCT=70). See `references/troubleshooting.md` (Precedence).
- **Advisor.** Sonnet/Haiku sessions (with or without `--tier`) get
  `--advisor $CRSS_OPUS_MODEL`; `CLAUDE_SESSION_ADVISOR=<model>|none` overrides. Opus/Fable sessions default to no `--advisor` flag (self-advice), but an explicit id is honoured (probed 2026-10-17, CLI 2.1.300: an Opus 5.5 session with `--advisor claude-fable-5-1` showed "Advising using Fable 5.1"). `CRSS_OPUS_MODEL`
  (overlay `config.sh`) is the one place `new-session` takes the Opus id from; `references/fallback-recipe.md`
  and README also name it and are bumped by hand. The advisor sees the whole transcript, so tell kickoffs to
  call it before committing to an approach and before declaring done, while context is small. Escalation for a
  hard fork: advisor (Opus) → cross-family check → Fable as a one-shot `Agent(model:"fable")` from the parent,
  never a spawn profile.
- **Unsure which tier?** Default `standard`; for a real fork (standard vs heavy, or whether Opus is worth it)
  ask your own advisor once, with a short summary, before spawning. Obvious cases skip it.
- **Outcome logging and escalation.** Reap records a teardown event (lifetime, forced, and `clean` = the
  unlanded-work audit passed; never set under `--force`) that `telemetry-report.sh` joins to the spawn by tier.
  Teardown cannot tell success from failure, so state it: `session-doctor reap <name> --outcome
  ok|failed|escalated|abandoned [--outcome-note "..."]` (default `unknown`; the idle reaper cannot say, so its
  events stay `unknown`). If a `light`/`standard` session misses its finish line, reap it with `--outcome
  escalated`, then `new-session <folder> --escalate-from <name> --task-file <path>` respawns one tier up
  (explicit `--tier` wins; a `heavy` source escalates to Opus, an untiered one is assumed `standard`) with the failure in the kickoff. You
  initiate it; nothing escalates on its own.
- **Wide or multi-faceted work** (many independent slices, or a change that needs adversarial review): plan
  first, then fan out. That needs `Workflow` (only `heavy`/owner/orchestrator sessions have it, and only on an
  explicit operator opt-in) or parallel `builder` subagents, not a serial edit-and-wait loop. Narrow work stays
  a single `standard` session.


## Writing the kickoff task

A spawned session starts with none of your context and works unattended for a long time;
the shape of the first message decides whether it succeeds, not how hard you tell it to try.
Full contract: [`handoff/references/massaging.md`](../handoff/references/massaging.md); fill-in
starting shape: [`handoff/references/kickoff-templates.md`](../handoff/references/kickoff-templates.md)
template (a). Before writing, read `$CRSS_HOME/local.md` if it exists — this host's real
escalation channel, project guardrail index, and delegate routing; absent overlay, use the
generic defaults in those two files. What matters most for a fresh spawn:

- **A finish line, not an activity.** "PR merged with `shell-tests` green and the script
  redeployed" — not "look into the compaction bug". Models sustain long multi-step work
  *when they know what done looks like*; an open-ended ask is where they drift.
- **A stop rule that names the channel.** Say when to keep going, when to stop and ask, and
  *through what*: a question left only in the child's own pane is a stall, not an
  escalation. Default wording (via `session-send <parent-session> --file <f>`, numbered list
  with a recommended option): [`handoff/references/massaging.md`](../handoff/references/massaging.md).
  A permission denial or a plain-text question in the child's pane does **not** raise an
  `AskUserQuestion` notification, so the operator never sees it. A blocked child therefore
  `session-send`s its launcher the exact command or decision needed. Launchers sweep their
  children's panes read-only for such stalls and alert the operator; they never answer a
  permission denial on the operator's behalf. Pass `--launcher <your-session>` to
  `new-session` (auto-detected inside tmux); `telemetry-report.sh --kids` lists your
  children with state, brief, final report and next action — behaviour lives in
  that script and `tests/test-telemetry.sh`.
- **Concrete anti-patterns, not "be careful".** Name the specific mistakes to avoid in this
  domain ("don't branch from local `main`", "no deploys without explicit human approval in this session").
  A named habit gets avoided; a general caution gets ignored.
- **Builders: Codex first, gpt-6.1-sol high in fast mode by default** (`codex exec -m gpt-6.1-sol -c model_reasoning_effort=high -c service_tier=priority`, or `new-session --backend codex --tier auto --task-type build`, which adds those flags).
  - Trims: `-c skills.include_instructions=false --disable multi_agent -c project_doc_max_bytes=0`.
  - Run the task's tests first; only on a failed check does Haiku low repair, then `-m gpt-6-astra` medium (also the pick when latency matters) → Sonnet 5.5 low ([ladder](orchestration-flow.md#escalation-ladder)). Codex out (exact quota error text): Haiku low builds, Haiku high on a failed check or a costly miss. Never luna or sol61 medium for builds.
  - Fast mode (`service_tier=priority`) is the builder default: 37% faster on the hard set, same pass rate and code, ~2x list price. Not for luna (no gain). xhigh effort adds cost and time, not quality.
  - Record the model that ran.
- **Delegate every independent slice, with evidence checks.** Research, per-file edits, and
  verification each go to their own delegate (Codex first for implementation; Codex/ChatGPT gpt-6.1-sol first for read-only research, see the Research row in [orchestration-flow.md](orchestration-flow.md#roles); Claude fallback:
  `subagent_type: builder` or `model: "sonnet"`, which keeps `advisor`). Brief each completely: only the prompt string crosses over. Don't delegate a builder's own verification back to itself. Have subagents write large
  output to files and return a short summary plus the path; check each one's evidence before
  accepting its report. Second opinion on the orchestrator's own work: Fable (see Key Rules).
- **A task file for long runs.** For anything multi-hour or multi-PR: *"keep a TASKS.md
  checklist with the finish line at the top; update it as you go; re-read it after any
  compaction, before acting."* Context gets summarized; the file doesn't.
- **Eval/hillclimb campaigns need a budget gate.** For prompt/model/grader/harness loops,
  use the compact add-on in
  [`handoff/references/kickoff-templates.md`](../handoff/references/kickoff-templates.md#e-evalhillclimb-campaign-kickoff-add-on)
  and the canonical protocol in
  [`handoff/references/eval-hillclimb-protocol.md`](../handoff/references/eval-hillclimb-protocol.md).
  It covers eval splits, novelty reserve, budget, stop/revert, and
  `scripts/eval-hillclimb-decision.py` decisions.
- **Leave out "think carefully / step by step / ultrathink".** Models decide how much to
  think on their own; those lines add length, not quality. Same for ALL-CAPS or "MUST" — a
  reason attached to a rule holds up better than a rule shouted louder.

While it runs, **add context with `session-send`** rather than killing and respawning — the
session picks up a mid-run message without losing its work. When it reports done, **first
check what it needs from you** (a decision, an approval, a merge, a credential) and unblock
that, then read the rest of its summary.


## Naming

```
tmux session:    <prefix>_<alias>-<MMDD-HHMM>
remote-control:  <prefix>-<alias>-<MMDD-HHMM>
workdir (repo):  $CRSS_WORKSPACE/<foldername>     (default $HOME/workspace)
workdir (util):  $CRSS_SESSIONS_DIR/<foldername>  (default $HOME/.sessions)
```

Name-first, date last; every spawn gets a unique name, so it never collides with a
same-minute session. Use `workspace/` for repo sessions, `.sessions/` for utilities
(managers, monitors, etc.). `<prefix>` defaults to `cs` (`CRSS_SESSION_PREFIX`); a host that
changes prefix can list the old one(s) in `CRSS_LEGACY_PREFIXES` so `session-doctor` keeps
recognising older sessions.

`<alias>` comes from the `session-alias` helper, persisted in `~/.claude/session-aliases`
(`folder<TAB>alias` per line):

- Folder names `<= 18` chars are used as-is; longer ones become an initials acronym
  (`claude-remote-session-skill` → `crss`), saved so later spawns reuse it.
- **`--alias` is per-spawn.** Sessions habitually pass the *task* (`--alias crss-prs`), so it
  no longer rewrites the folder default. Add `--set-default-alias` only when the name
  describes the **folder**, not the task.
- **Protected folders are never aliased**: a folder matching `CRSS_ALIAS_PROTECT_NAMES`
  (see `examples/crss-overlay/config.sh.example`) keeps its full name so `session-doctor`
  can protect it by that token. (Narrower than reap's `CRSS_PROTECT_NAMES`, which also covers
  `claude-remote` bridge sessions; this repo's folder still shortens normally.)
- **Alias values are validated (anti-poisoning)** on read, write, and store upsert, so a
  stored alias that looks like a full session name can't produce
  `<prefix>-<prefix>-…-MMDD-MMDD`. Rules: `scripts/session-alias.sh`, pinned by
  `tests/test-session-alias.sh`.
- `session-alias --audit-store` read-only-reports stored entries that fresh inference now
  disagrees with; it never rewrites. A human decides what to change.


