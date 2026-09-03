# Spawn context footprint: builder/orchestrator profiles

Companion to the `CLAUDE_SESSION_PROFILE` feature in `scripts/new-session.sh`.
It records the measured token cost of each spawn profile so the `builder`
allowlist can be tuned without re-deriving the numbers.

All token numbers come from a real `/context` reading on a freshly spawned
session — **not** inferred. Harness: launch `claude` with the exact per-profile
flag string in a controlled tmux pane over a fixed workdir, drive `/context`,
capture the pane. CLI **v2.1.206**, model resolved to **Sonnet 5**
(`claude-sonnet-5`, ~967k window).

## Hard before/after numbers (same bare `.sessions/` workdir, all real spawns)

| `/context` category | Baseline (no flags) | **orchestrator** (`--exclude…`) | **builder** (`--exclude…` + `--tools`) |
|---|---:|---:|---:|
| **Total** | 35.7k | 35.7k | **24.3k** |
| System prompt | 9.1k | 9.1k | 9.1k |
| **System tools** | 19.5k | 19.5k | **8.2k** |
| Memory files | 737 | 737 | 737 |
| Skills (91) | 5.1k | 5.1k | 5.1k |
| Messages | 1.3k | 1.3k | 1.3k |
| MCP tools | 46 · **0 tokens** | 46 · 0 | 46 · 0 |

- **Builder saves 11.4k total (−32%)**, entirely from **System tools 19.5k → 8.2k**.
- **Orchestrator = baseline exactly.** The default profile is backward-compatible
  (full tool set); `--exclude-dynamic-system-prompt-sections` is **token-count
  neutral** — it *relocates* cwd/env/git-status out of the cached system prompt
  into the first user message (a prompt-cache-reuse win), it does not shrink the
  count. Do **not** attribute a token saving to the orchestrator profile; its
  only change is cache behaviour.
- **MCP schemas cost 0 tokens upfront** (deferred) — confirmed, not a contributor.

### Where the builder's 11.3k comes from (System-tools drill-down)

`--tools` is an **exhaustive allowlist over the built-in set**. The 11.3k saving
is entirely from dropping **6 upfront-schema tools**:

| Dropped tool | ~upfront cost |
|---|---:|
| **Workflow** (multi-agent fan-out — *the* orchestrator-defining tool) | **~7.8k** |
| Artifact + SendUserFile | ~1.9k combined |
| ReportFindings + ScheduleWakeup | ~0.6k combined |

Measured points: base builder = 8.2k; +Workflow = 16.0k; +advisor+SendUserFile+Artifact = 11.1k.

> **Since these measurements were taken, `advisor` was moved from dropped to
> kept** (see `BUILDER_TOOLS` in `scripts/new-session.sh` — the builder role is
> the one that actually reaches for a second opinion, and `--tools` gates
> deferred built-ins too, so omitting it there made it unreachable entirely).
> The **8.2k / 24.3k builder totals above therefore no longer include
> advisor's ~1k** and are stale by that amount; they have not been
> re-measured with advisor included. The dropped-tool breakdown and "Final
> `BUILDER_TOOLS`" list below are updated to match the current script.

### Builder allowlist: capability preserved at zero token cost

`--tools` also gates **deferred built-ins** (WebFetch, WebSearch, Task\*,
plan-mode, NotebookEdit, Monitor). Those cost **0 upfront tokens**, so the
allowlist **re-lists them** — measured System tools = **8.2k with or without
them**. Verified they are actually *invocable* under the allowlist (not just
listed): a live builder spawn ran a real **WebFetch** on example.com and
**TaskCreate + TaskList**.

> Caveat found the hard way: a built-in **omitted** from `--tools` is unreachable
> **even via ToolSearch** (an early 10-tool list could not load WebFetch).
> MCP-server tools are a separate namespace and stay reachable regardless.

Final `BUILDER_TOOLS` (kept in sync with `scripts/new-session.sh`; `advisor` was
added back after these measurements were taken, see the note above):
`Bash,Read,Edit,Write,Glob,Grep,Agent,AskUserQuestion,Skill,ToolSearch,WebFetch,WebSearch,TaskCreate,TaskGet,TaskList,TaskUpdate,TaskStop,TaskOutput,EnterPlanMode,ExitPlanMode,NotebookEdit,Monitor,advisor`

**Override knob:** a builder that genuinely needs SendUserFile / Artifact
should add it to `BUILDER_TOOLS` (~1k each) or just use the orchestrator profile.
`advisor` is already included by default (~1k) — no override needed for it.
