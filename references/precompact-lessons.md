# PreCompact lessons hook

A self-improvement loop with a trigger instead of a promise: before a Wren session compacts,
a cheap Haiku reviewer reads the human turns since the previous compaction and saves **at most
one** durable lesson to the session's auto-memory. "Nothing to save" is the normal outcome.
Code and the rules it enforces: `scripts/precompact-lessons.py`; behaviour pinned by
`tests/test-precompact-lessons.py`.

## How it runs

1. The Claude Code `PreCompact` hook starts `precompact-lessons`, which records the transcript
   size, starts a detached worker and exits 0 with no output. It can't block, slow or fail
   compaction (the CLI treats exit 2 or stdout as instructions; this script never does either).
2. The worker only proceeds for a Wren session: one that read the persona's `BOOT.md` or
   `START.md` (a `Read`, or a `cat`-style Bash command naming `agents/claude/public/wren/` and the
   file) within its first 40 tool calls. A mention in text or tool output, another file of that dir,
   an edit of it, or a compaction summary naming it does not count. `CRSS_LESSONS=all` skips this
   check; `CRSS_LESSONS=0` turns the hook off. A session continued in a fresh transcript must read
   the boot file again to qualify. The gate tells sessions apart (a Bash command only has to name the
   dir, a boot file and a reader, outside comments); the operator-quote rule below is what bounds a lesson.
3. Cheap skips follow, all logged. `skip:cooldown`: the log shows a real run for this session
   in the last 15 minutes (a subagent's auto-compaction fires the hook with the parent's transcript
   and no `agent_id`, so the hook can't tell it apart; dry runs, marked `dry_run`, don't count).
   `skip:in-flight`: another worker for this session holds its run lock (an `flock`, held until the log
   line is written, so overlapping compactions can't both review). `skip:session-saved-memory`: the window shows
   an Edit or Write into the target dir or any `~/.claude/projects/*/memory/` dir, so the session
   already saved its own lesson.
4. It builds a window from the last `compact_boundary` to the recorded size: every operator turn
   (capped), plus assistant and tool-call lines newest-first within a budget. Tool results never
   enter the window. Sidechain, meta, compaction-summary, notification, cross-session-message and
   `<system-reminder>` text are dropped; from the first cross-session-message or task-notification tag
   on, a text block is dropped whole (its body can contain a closing tag), as is a block with a closing
   tag that has no opener.
5. It runs `claude -p --model haiku --effort high --tools "" --setting-sources ""` from an empty
   temp dir with `--settings '{"disableAllHooks": true}'` (no settings, hooks, CLAUDE.md or
   memory: about 4k input tokens) and an allowlisted environment (`PATH`, `HOME`, auth and proxy
   variables, `LC_*`; not the parent session's id, messaging socket or token). The reviewer gets
   the memory index and replies with one JSON object, including an `evidence` quote.
6. The script, not the model, validates and writes. The `evidence` quote must be at least 12
   characters and appear verbatim (whitespace and case aside) in an operator turn of the window, so a
   lesson is always tied to something the operator said (`rejected:no-evidence`,
   `rejected:evidence-not-from-user`). It rejects dates, PR/issue numbers, hashes,
   "X is broken"-style claims and secret-looking strings (in the slug and description too);
   rejects duplicates of any existing memory file (word overlap, or the same rule text for short
   lessons); appends to an existing file when the reviewer names one, else creates a file with
   the frontmatter the other memory files use and adds one index line. The quote goes to the log,
   not into memory.
7. One line per run goes to `$XDG_STATE_HOME/crss/precompact-lessons.jsonl` (default
   `~/.local/state/crss/`): `outcome` is `saved:create`, `saved:update`, `nothing-to-save`,
   `skip:*`, `rejected:*` or `error:*`.

By default the memory dir is where the CLI loads auto-memory, which is not always the transcript's own project
dir (linked worktrees share their main checkout's); `memory_dir_for` and its worktree test are the
rule. It starts from the session's start directory, read from the transcript, not the hook payload's
`cwd` (that follows `cd`); with no start directory found the run is skipped. Known gap: sessions started under `/tmp` map to a bare `-tmp` project dir in the CLI; the
hook does not follow that. A symlinked memory dir, or a state dir inside it, is refused
(`skip:memory-dir-redirected`). Writes take a `flock` outside that dir and are atomic (temp file
plus rename). The size cap applies to new files as well as updates. The hook process itself
only logs through a non-blocking open, so a broken log path can't stall compaction.
The reviewer does not see the target file's body, so duplicate detection is the script's
word-overlap check, not the model's judgement.

## Pointing it at a lessons dir (host config)

A hook runs with none of crss's environment, so a host sets its target in
`${CRSS_HOME:-~/.config/crss}/precompact-lessons.env`: plain `KEY=VALUE` lines, `#` comments, only
`CRSS_LESSONS_*` keys are read, and a variable already in the environment wins. Two keys matter:

```
CRSS_LESSONS_MEMORY_DIR=<dir that holds the lesson files>
CRSS_LESSONS_INDEX_NAME=INDEX.md
```

`CRSS_LESSONS_MEMORY_DIR` replaces the per-project auto-memory dir (the project-key logic is skipped).
`CRSS_LESSONS_INDEX_NAME` (default `MEMORY.md`) names that dir's index; it is guarded exactly like
`MEMORY.md` (never an update target, never scanned for duplicates, subject to the index caps) and new
index lines go after the last list item, so a closing note in the index stays last. The hook only
writes files: it never runs `git`, so a lesson is exactly as durable as the dir it lands in. Where a
host points `CRSS_LESSONS_MEMORY_DIR` into the central agent-memory store (this host does: the Wren
lessons dir under `agents/claude/private/curated/`), that store's `.gitignore` is `*`, so the lessons
are disk-only: nothing there can be committed, and a human or orchestrator reviews them in place. To
keep one in version control, copy it into a tracked doc by hand.

## Install (global settings, operator-approved)

Add one `PreCompact` entry under `hooks` in `~/.claude/settings.json` (deploy the script first):

```json
"PreCompact": [{"hooks": [{"type": "command", "command": "$HOME/.local/bin/precompact-lessons", "timeout": 10}]}]
```

Use the absolute path to `~/.local/bin/precompact-lessons` for `command`. Edit only the `hooks`
key (with `jq` into a temp file) and diff only that subtree.

## Knobs (environment)

| Variable | Default | Effect |
|---|---|---|
| `CRSS_LESSONS` | unset | `0` off; `all` every session, not just Wren |
| `CRSS_LESSONS_MODEL` / `_EFFORT` / `_TIMEOUT` | `haiku` / `high` / `120` | reviewer call |
| `CRSS_LESSONS_COOLDOWN` | `900` | seconds between real runs for one session; `0` off; dry runs ignore it |
| `CRSS_LESSONS_MAX_FILE_BYTES` | `6000` | a new file, or an update that would grow a file, past this is refused |
| `CRSS_LESSONS_INDEX_MAX_LINES` / `_BYTES` | `190` / `24000` | past this only updates are written, new files are refused (the CLI's own `MEMORY.md` load limit was not found in the binary; these are conservative) |
| `CRSS_LESSONS_MEMORY_DIR` / `_INDEX_NAME` | derived / `MEMORY.md` | target dir and its index file (usually set in the host config above) |
| `CRSS_LESSONS_STATE`, `_CLAUDE`, `_SIGNAL` | derived | overrides for tests and odd layouts |

## Check it works

`precompact-lessons --sync --dry-run < payload.json` runs the whole pipeline in the foreground
and prints the outcome without writing memory (payload: `session_id`, `transcript_path`,
`trigger`). A live check without touching global settings: pass the hook inline
(`claude -p ... --settings '{"hooks":{"PreCompact":[...]}}'`), have the session read the Wren
`START.md` (or `BOOT.md`), give it one correction, then `claude -p --resume <id> "/compact"` and read the log line.
`session-doctor` does not read the log yet; a curator that prunes lessons is a separate piece.
