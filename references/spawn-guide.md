# Spawn guide: model policy, tiers, kickoff, naming

Extracted from always-loaded `SKILL.md` on 2026-10-15.

## Model and second-opinion policy (Key Rules detail)

- Global skills link into every spawn; use them without waiting for a request. Superpowers
  injects `using-superpowers` for orchestrator/owner/hub. Builder/copywriter/`CRSS_AUTONOMOUS=1`
  disable it via derived `rc-firstparty-no-superpowers.settings.json` (hook: ~900 tokens per
  start/clear/compact and brainstorming before replies). Never repeat `--settings`: later
  flags replace earlier ones, losing the first-party base URL. See `scripts/new-session.sh`,
  pinned by `tests/test-new-session-tier.sh`.
- `CLAUDE_SESSION_PROFILE`: `owner`/`hub`/`builder`→`sonnet`, `copywriter`→`haiku`
  (bare aliases track releases); `orchestrator`→pinned `claude-opus-5-5`.
  Owner has full tools for long-lived lanes; hub adds the Opus consult contract.
  Override: `CLAUDE_SESSION_MODEL=<model>`. Rationale: `scripts/new-session.sh`, "Model selection";
  pinned by `tests/test-new-session-tier.sh`.
- `agents/builder.md`: `maxTurns` = 250 per invocation; the CLI can stop mid-step.
  After "Agent stopped at its 250-turn limit", run `git status` / `git diff --stat` in its
  worktree, then continue with SendMessage to keep context/edits; a fresh spawn orphans them.
- Hub sessions run Sonnet by default and keep both native `advisor` and the Opus one-shot
  consult contract in [`references/hub-opus-consult.md`](hub-opus-consult.md).
- The standard lane shape (Opus orchestrates, Codex gpt-6.1-terra low builds, Haiku checks, Opus
  adversarial review) is in [`references/orchestration-flow.md`](orchestration-flow.md);
  link it in kickoff briefs instead of restating it.
- `advisor` verified 2026-10-15, CLI 2.1.300: interactive `--model opus` listed it and a call
  succeeded. Model table: `advisor_rank >= 2`; Opus 5.5 = 7. Absent in 2.1.280 probes;
  `claude -p` hides it for every model, so probe interactively. Opus uses native `advisor`
  for routine forks (cheap, transcript-aware). Independent opinion at risky/destructive forks,
  ambiguous designs and multi-step completion: one-shot Fable on a frozen packet via
  `subagent_type: "reviewer"` (`agents/reviewer.md`) or `Agent({description, prompt, model: "fable"})`,
  never a Sonnet builder checking itself. `model: fable` frontmatter was verified by a probe
  running Fable. Decided 2026-10-15.
- ChatGPT uses a project relay subagent, not a standalone session: that project's
  `.claude/agents/` and roles table own call-out details; `$CRSS_HOME/local.md` lists availability.
- `$CRSS_HOME/local.md` orders second opinions (cheap strong reviewer, different-family
  check, expensive reviewer last). Merge/operator-facing reviews require multiple model
  families. Single-family review counts only when Claude is quota-out (gpt-6.1-terra low builds and a
  separate gpt-6.1-sol call reviews); if Codex is out, the PR stays draft with the review marked
  UNVERIFIED. Record `models_ran` in the PR body.
  The orchestrator's Fable sanity check above is separate.

## Choosing a tier (right-size the model, save quota)

Pass `--tier` / one-line `--tier-reason` (spawn telemetry records the decision, not outcome),
or `--tier auto --task-type orchestrate|review|mechanical|research|build` (else brief keywords).
Auto mapping, printed reason, routing log and explicit `--backend`/env precedence:
`scripts/new-session.sh`, pinned by `tests/test-new-session-tier.sh`.

| Tier | Pick it when the task is | Defaults |
|---|---|---|
| `light` | mechanical, doc/copy-only, a bounded edit with a clear check | copywriter profile, haiku, `--effort low` |
| `standard` | debugging or review in one repo; implementation only as the Claude fallback (implementation goes to Codex gpt-6.1-terra low first: `--tier auto --task-type build`) | builder profile, sonnet, `--effort low` |
| `heavy` | ambiguous design, long-lived lane, gating review, needs `Workflow` fan-out | owner profile (full tools), **sonnet** + Opus advisor. Not Opus: for an Opus orchestrator omit `--tier` |

- Tier defaults unchanged: the 2026-10-22 bench did not test Haiku as an agentic builder (the 10-24 follow-up ran haiku-high 12/12 agentic, used only on the Codex-out ladder); `light`/`standard` already use effort low, and higher effort bought nothing ([bench evidence](orchestration-flow.md#bench-evidence)).
- **No per-request model router** (CLI 2.1.308). Aliases:
  `sonnet opus haiku fable best sonnet[1m] opus[1m] fable[1m] opusplan`; no `auto`.
  `opusplan` only switches Opus planning → Sonnet execution on the plan-mode toggle;
  `default`/`best` follow account/release. `--fallback-model a,b` handles overload/unavailability
  and retries the primary each turn. `--permission-mode auto` / `claude auto-mode` classify
  permissions. `--tier auto` classifies once at spawn; route later slices by
  [orchestration-flow.md](orchestration-flow.md). Without `--tier`, `new-session` uses profile
  defaults (orchestrator pins `$CRSS_OPUS_MODEL`); native desktop/phone/remote-control
  spawn-server sessions use account-default Opus and the same delegation policy.
- **Orchestrator effort** defaults to medium (`CRSS_ORCHESTRATOR_EFFORT`, `none` drops it); set `CLAUDE_SESSION_EFFORT=high` at risky forks. A 2026-10-22 blind check (3 planning prompts, Fable judge) scored medium 8.3 vs high 8.0 at ~60% of the cost.
- Read `new-session`'s `resolved: ... model=`. Opus requires no tier or explicit
  `CLAUDE_SESSION_PROFILE=orchestrator` / `CLAUDE_SESSION_MODEL`; give it a short, hard,
  bounded task and reap when done (not enforced).
- A `--launcher` that is not a live tmux session (a desktop/app launcher) cannot be reached by `session-send`; `new-session` warns on stderr, so tell the lane in its kickoff to report through the host's bus/mailbox.
- Explicit `CLAUDE_SESSION_PROFILE` / `_MODEL` / `_EFFORT` win over the tier, one value at a time.
  `standard` and `light` set effort `low` (Haiku 5.5 supports effort; verified in the CLI model table 2026-10-15); `heavy` sets none. Pass `CLAUDE_SESSION_EFFORT` to override.
  Auto-compact window is per tier too: overlay `CRSS_COMPACT_WINDOW_<TIER>` (per spawn `CLAUDE_SESSION_COMPACT_WINDOW=<n|host>`), else `CRSS_COMPACT_WINDOW_DEFAULT` (234000, ~150k trigger at PCT=70). See `references/troubleshooting.md` (Precedence).
- **Advisor:** Sonnet/Haiku get `--advisor $CRSS_OPUS_MODEL` with or without `--tier`;
  `CLAUDE_SESSION_ADVISOR=<model>|none` overrides. Opus/Fable default to self-advice;
  explicit ids work (2026-10-17, CLI 2.1.300: Opus 5.5 with `--advisor claude-fable-5-1`
  showed "Advising using Fable 5.1"). `new-session` takes its Opus id only from overlay
  `config.sh`'s `CRSS_OPUS_MODEL`; update `references/fallback-recipe.md` and README by hand.
  Call advisor before choosing an approach and declaring done, while context is small:
  it sees the whole transcript. Hard forks: Opus advisor → cross-family check → one-shot
  `Agent(model:"fable")` from the parent, never a spawn profile. Implementation/test:
  `scripts/new-session.sh`, `tests/test-new-session-tier.sh`.
- **Unsure which tier?** Default `standard`; for a real fork (standard vs heavy, or whether Opus is worth it)
  ask your own advisor once, with a short summary, before spawning. Obvious cases skip it.
- **Outcomes:** `session-doctor reap <name> --outcome
  ok|failed|escalated|abandoned [--outcome-note "..."]`; default/idle-reaper = `unknown`.
  Teardown logs lifetime, forced and `clean` (unlanded audit passed; never under `--force`);
  `telemetry-report.sh` joins spawn/teardown by tier, not inferred success.
  On a missed `light`/`standard` finish, reap with `--outcome escalated`, then
  `new-session <folder> --escalate-from <name> --task-file <path>` with failure in the kickoff.
  Tier escalation and explicit `--tier` precedence: `scripts/new-session.sh`, pinned by
  `tests/test-new-session-tier.sh` (heavy → Opus; untiered assumed standard). Always manual.
- **Wide or multi-faceted work** (many independent slices, or a change that needs adversarial review): plan
  first, then fan out. That needs `Workflow` (only `heavy`/owner/orchestrator sessions have it, and only on an
  explicit operator opt-in) or parallel `builder` subagents, not a serial edit-and-wait loop. Narrow work stays
  a single `standard` session.


## Writing the kickoff task

Spawns have none of your context. Contract:
[`handoff/references/massaging.md`](../handoff/references/massaging.md); template (a):
[`handoff/references/kickoff-templates.md`](../handoff/references/kickoff-templates.md).
Read `$CRSS_HOME/local.md` for escalation, guardrails and delegate routing if present;
otherwise use those generic defaults.

- **Finish line:** "PR merged with `shell-tests` green and the script redeployed";
  an open-ended "look into the compaction bug" invites drift.
- **Stop rule + channel:** say when to continue/escalate; use
  `session-send <parent-session> --file <f>` with numbered options and a recommendation
  ([contract](../handoff/references/massaging.md)). Pane questions/permission denials raise no
  `AskUserQuestion` notification. Builder/copywriter spawn instructions:
  `BUILDER_ESCALATION_PROMPT` in `scripts/new-session.sh` (AskUserQuestion off; send exact
  blocked command/decision/input to launcher, use host mailbox if not tmux, print final
  `BLOCKED:`). Launchers sweep panes read-only and alert the operator; never answer a
  denial for them. `new-session --launcher <your-session>` auto-detects inside tmux;
  `telemetry-report.sh --kids` shows children/state/brief/report/next action, pinned by
  `tests/test-telemetry.sh`.
- **Concrete anti-patterns:** e.g. "don't branch from local `main`", "no deploys without
  explicit human approval in this session"; specific mistakes beat "be careful".
- **Builders: Codex first, gpt-6.1-terra low in fast mode by default (operator 2026-11-02)** (`codex exec -m gpt-6.1-terra -c model_reasoning_effort=low -c service_tier=priority`, or `new-session --backend codex --tier auto --task-type build`, which adds those flags).
  - Trims: `-c skills.include_instructions=false --disable multi_agent -c project_doc_max_bytes=0`.
  - Run the task's tests first; only on a failed check does Haiku low repair, then `-m gpt-6-astra` medium (also the pick when latency matters) → Sonnet 5.5 low ([ladder](orchestration-flow.md#escalation-ladder)). Codex out (exact quota error text): Haiku low builds, Haiku high on a failed check or a costly miss. Never luna or sol61 medium for builds.
  - Fast mode (`service_tier=priority`): default again 2026-10-30; off 10-28 to 10-30
    because standard benchmarked too slow. Hard set: 37% faster, same pass/code, ~2x list
    price; no luna gain. xhigh costs more time/money without quality gain; full evidence:
    [Codex flags](orchestration-flow.md#codex-flags), [bench evidence](orchestration-flow.md#bench-evidence).
  - Record the model that ran.
- **Delegate independent research/edits/verification** by [Roles](orchestration-flow.md#roles)
  (Codex implementation first; Codex/ChatGPT gpt-6.1-sol research first; Claude fallback
  `subagent_type: builder` / `model: "sonnet"` keeps `advisor`). Only the prompt crosses over:
  brief fully, use another reader for verification, write large output to files and return
  summary/path; check evidence. Orchestrator's independent read: Fable plus gpt-6.1-sol
  cross-family check (gpt-6.1-sol only; never Grok; Codex out: draft/report, UNVERIFIED); see Key Rules.
- **Multi-hour/multi-PR:** keep `TASKS.md` with finish line atop, update as you go,
  re-read after compaction before acting; the file survives context summarization.
- **Eval/hillclimb campaigns need a budget gate.** For prompt/model/grader/harness loops,
  use the compact add-on in
  [`handoff/references/kickoff-templates.md`](../handoff/references/kickoff-templates.md#e-evalhillclimb-campaign-kickoff-add-on)
  and the canonical protocol in
  [`handoff/references/eval-hillclimb-protocol.md`](../handoff/references/eval-hillclimb-protocol.md).
  It covers eval splits, novelty reserve, budget, stop/revert, and
  `scripts/eval-hillclimb-decision.py` decisions.
- Omit "think carefully / step by step / ultrathink", ALL-CAPS and "MUST": models choose
  their own thinking; attach reasons instead of adding length without quality.

Add mid-run context with `session-send` to preserve work. On a done report, first unblock
any needed decision/approval/merge/credential, then read the rest.


## Naming

```
tmux session:    <prefix>_<alias>-<MMDD-HHMM>
remote-control:  <prefix>-<alias>-<MMDD-HHMM>
workdir (repo):  $CRSS_WORKSPACE/<foldername>     (default $HOME/workspace)
workdir (util):  $CRSS_SESSIONS_DIR/<foldername>  (default $HOME/.sessions)
```

Name first, date last; same-minute spawns stay unique. `workspace/` holds repos,
`.sessions/` utilities (managers/monitors). Default `<prefix>`: `cs` (`CRSS_SESSION_PREFIX`);
`CRSS_LEGACY_PREFIXES` keeps older names recognisable to `session-doctor`.

`<alias>` comes from the `session-alias` helper, persisted in `~/.claude/session-aliases`
(`folder<TAB>alias` per line):

- `<= 18` chars stay as-is; longer folders become saved initials
  (`claude-remote-session-skill` → `crss`). `--alias crss-prs` is per-spawn;
  `--set-default-alias` changes the folder default only when the alias describes the folder.
- Protection and anti-poisoning (read/write/upsert): `scripts/session-alias.sh`, pinned by
  `tests/test-session-alias.sh`. `CRSS_ALIAS_PROTECT_NAMES`
  (`examples/crss-overlay/config.sh.example`) preserves identifying tokens for `session-doctor`;
  narrower than reap's `CRSS_PROTECT_NAMES` for `claude-remote` bridges, so this repo still
  shortens. Full-session-shaped aliases cannot produce `<prefix>-<prefix>-…-MMDD-MMDD`.
- `session-alias --audit-store` reports fresh-inference disagreements without rewriting;
  a human chooses changes.


