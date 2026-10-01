# Spawn context footprint: builder/orchestrator profiles

Measured token cost of each `CLAUDE_SESSION_PROFILE` (`scripts/new-session.sh`), so the
`builder` allowlist can be tuned without re-deriving numbers. Numbers are real `/context`
readings on a freshly spawned session (CLI v2.1.206, `claude-sonnet-5`, ~967k window,
same bare `.sessions/` workdir), not inferred.

| `/context` category | Baseline (no flags) | orchestrator | builder (`--tools` allowlist) |
|---|---:|---:|---:|
| **Total** | 35.7k | 35.7k | **24.3k** |
| System prompt | 9.1k | 9.1k | 9.1k |
| **System tools** | 19.5k | 19.5k | **8.2k** |
| Memory files | 737 | 737 | 737 |
| Skills (91) | 5.1k | 5.1k | 5.1k |
| Messages | 1.3k | 1.3k | 1.3k |
| MCP tools | 0 (deferred) | 0 | 0 |

- Builder saves 11.4k (-32%), all from System tools 19.5k -> 8.2k. MCP schemas cost 0 upfront.
  Measured points: base builder = 8.2k; +Workflow = 16.0k; +advisor+SendUserFile+Artifact = 11.1k.
- Orchestrator equals baseline: `--exclude-dynamic-system-prompt-sections` is token-neutral.
  It moves cwd/env/git-status out of the cached system prompt into the first user message
  (a prompt-cache win). Do not claim a token saving for the orchestrator profile.
- The builder saving comes from dropping 5 upfront-schema tools: Workflow ~7.8k (the
  orchestrator-defining fan-out tool), Artifact + SendUserFile ~1.9k, ReportFindings +
  ScheduleWakeup ~0.6k.
- Stale by ~1k: `advisor` was later moved from dropped to kept (builders are the role that
  uses a second opinion, and `--tools` gates deferred built-ins too). The 8.2k/24.3k totals
  were not re-measured with it.

## Builder allowlist

`--tools` is an exhaustive allowlist over built-ins and also gates deferred built-ins
(WebFetch, WebSearch, Task*, plan-mode, NotebookEdit, Monitor). Those cost 0 upfront, so the
list re-lists them (System tools stays 8.2k); verified invocable under the allowlist (live
WebFetch and TaskCreate/TaskList). A built-in omitted from `--tools` is unreachable even via
ToolSearch. MCP-server tools are a separate namespace and stay reachable.

`BUILDER_TOOLS` in `scripts/new-session.sh` is the source of truth (the `builder` and
`copywriter` profiles both use it). Current value:
`Bash,Read,Edit,Write,Glob,Grep,Agent,AskUserQuestion,Skill,ToolSearch,WebFetch,WebSearch,TaskCreate,TaskGet,TaskList,TaskUpdate,TaskStop,TaskOutput,EnterPlanMode,ExitPlanMode,NotebookEdit,Monitor,advisor`

Override: a builder that needs SendUserFile / Artifact should add it to `BUILDER_TOOLS`
(~1k each) or use the orchestrator profile. `advisor` is already included (~1k).
