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
2. The worker only proceeds for a Wren session: a tool call touching `agents/claude/public/wren/`
   anywhere in the transcript (or a compaction summary naming it). `CRSS_LESSONS=all` skips this
   check; `CRSS_LESSONS=0` turns the hook off.
3. It builds a window from the last `compact_boundary` to the recorded size: every human turn
   (capped), plus assistant and tool lines newest-first within a budget. Sidechain, meta,
   compaction-summary and `<system-reminder>` text are dropped.
4. It runs `claude -p --model haiku --effort high --tools "" --setting-sources ""` from an empty
   temp dir with `--settings '{"disableAllHooks": true}'` (no settings, hooks, CLAUDE.md or
   memory: about 4k input tokens). The reviewer gets the memory index and replies with one JSON
   object.
5. The script, not the model, validates and writes. It rejects dates, PR/issue numbers, hashes,
   "X is broken"-style claims and secret-looking strings (in the slug and description too);
   rejects duplicates of any existing memory file (word overlap, or the same rule text for short
   lessons); appends to an existing file when the reviewer names one, else creates a file with
   the frontmatter the other memory files use and adds one index line.
6. One line per run goes to `$XDG_STATE_HOME/crss/precompact-lessons.jsonl` (default
   `~/.local/state/crss/`): `outcome` is `saved:create`, `saved:update`, `nothing-to-save`,
   `skip:*`, `rejected:*` or `error:*`.

The memory dir is where the CLI loads auto-memory: `~/.claude/projects/<project>/memory`, with
`<project>` the main checkout's path for a linked worktree (they share it), else the cwd's path,
else the transcript's own project dir (`memory_dir_for` in the script has the order and a test
pins the worktree case). A symlinked memory dir, or a state dir inside it, is refused
(`skip:memory-dir-redirected`). Writes take a `flock` outside that dir and are atomic (temp file
plus rename). The size cap applies to new files as well as updates. The hook process itself
only logs through a non-blocking open, so a broken log path can't stall compaction.
The reviewer does not see the target file's body, so duplicate detection is the script's
word-overlap check, not the model's judgement.

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
| `CRSS_LESSONS_MAX_FILE_BYTES` | `6000` | a new file, or an update that would grow a file, past this is refused |
| `CRSS_LESSONS_INDEX_MAX_LINES` / `_BYTES` | `190` / `24000` | past this only updates are written, new files are refused (the CLI's own `MEMORY.md` load limit was not found in the binary; these are conservative) |
| `CRSS_LESSONS_MEMORY_DIR`, `_STATE`, `_CLAUDE`, `_SIGNAL` | derived | overrides for tests and odd layouts |

## Check it works

`precompact-lessons --sync --dry-run < payload.json` runs the whole pipeline in the foreground
and prints the outcome without writing memory (payload: `session_id`, `transcript_path`,
`trigger`). A live check without touching global settings: pass the hook inline
(`claude -p ... --settings '{"hooks":{"PreCompact":[...]}}'`), do a short Wren-style exchange
with one correction, then `claude -p --resume <id> "/compact"` and read the log line.
`session-doctor` does not read the log yet; a curator that prunes lessons is a separate piece.
