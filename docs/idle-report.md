# `session-doctor idle-report`: the "candidates to reap" list

`session-doctor.sh idle-report [--days N | --minutes N] [--tsv]` lists **live local**
claude `--remote-control` sessions with no genuine `type:user` transcript activity in the
last N days (default **2**) or, with `--minutes`, N minutes.

```
session-doctor.sh idle-report               # idle >=2 days (default)
session-doctor.sh idle-report --days 7      # idle >=7 days
session-doctor.sh idle-report --days 0      # no threshold: list every live session
session-doctor.sh idle-report --minutes 30  # finer-grained than --days
session-doctor.sh idle-report --tsv         # machine-readable rows, no header/summary
```

`--minutes` and `--days` are mutually exclusive (both is a usage error). `--tsv` combines
with either. Pinned by `tests/test-session-doctor-tsv.sh`.

## `--tsv` columns

One line per idle session, 10 tab-separated columns, no header or footer:

1. `tmux_session`
2. `remote_name`
3. `pid`
4. `cwd`
5. `idle_minutes` (integer, or the literal `never` for no genuine user turn; consumers must not assume a number)
6. `last_genuine_user_ts` (`-` if never messaged)
7. `protected` (`yes`/`no`)
8. `compacted_since_last_turn` (`yes`/`no`/`unknown`)
9. `landed` (same signal as `land-check`/`worktree-stale`: `yes`/`no`/`unknown`/`no-worktree`)
10. `dirty` (`clean`/`DIRTY`/`unknown`; `landed=no-worktree` pairs with `dirty=unknown`)

Consume with `while IFS=$'\t' read -r ...`. Primary consumer: `session-compact.sh`
([`session-compaction.md`](session-compaction.md)).

## Report-only: it never kills

Every row is a still-alive process, so `reap-local` (which only removes sessions whose
`claude` process is gone) won't touch it. Act in two lanes:

- dead sessions: `session-doctor reap-local [--force]`
- idle-but-alive: `session-doctor reap <name> [--force]` (tmux + unit + registry entry +
  worktree, after the session-preserve check)

Do not wire `idle-report` into an auto-kill path; the report/act separation is the safety
property. Rows flagged `[P]` are protected (built-in `claude-remote` pattern plus
`CRSS_PROTECT_NAMES`, see `examples/crss-overlay/config.sh.example`) and are never reaped.

## Non-obvious details (verified empirically)

1. **Enumeration**: `pgrep -af 'claude.*--remote-control'`, keeping only rows whose
   executable basename is `claude` (or `node`). The pattern also matches the tmux launcher
   and the bash supervisor loop, whose args carry the same string.
2. **cwd** from `readlink /proc/<pid>/cwd`.
3. **remote name -> tmux name** via `svc_to_tmux` (`<prefix>-X` -> `<prefix>_X` for
   `CRSS_SESSION_PREFIX` and each `CRSS_LEGACY_PREFIXES` entry; others unchanged, so rows
   outside those prefixes show an approximate name; they are `[P]` anyway).
4. **Transcript dir** `~/.claude/projects/<encoded>`, `encoded = cwd.replace('.', '-').replace('/', '-')`
   (holds for dotted paths too; undocumented in Claude Code, verified by checking dirs exist).
5. **Idle signal** = max `timestamp` over `*.jsonl` entries with `type == "user"`, excluding
   all FIVE artifacts one `/compact` writes. Excluding only the `isCompactSummary:true`
   entry was not enough: idle still reset from days to minutes because four more synthetic
   `type:user` entries land with it:
   - the `isCompactSummary:true` summary;
   - the bare `/compact` trigger keystroke;
   - an `isMeta:true` `<local-command-caveat>` wrapper (emitted for any local slash command);
   - the `<command-name>/compact</command-name>` echo;
   - the `<local-command-stdout>Compacted...` line (it carried the latest timestamp of the
     five, so it dominated the idle calculation).

   `isMeta` is excluded unconditionally: pure boilerplate, and the sibling command-name echo
   (kept as genuine for every command other than `/compact`) carries the same timestamp.
   The other three are excluded only when tied to `/compact` (exact match on the trigger: a
   chat message `/compact handoff first` is genuine). Do not generalize to any command-name
   echo, bare slash command or `<local-command-stdout>`: a human typing `/clear`, `/context`,
   `/model` is evidence of presence, and excluding those would compact a session someone is
   using. Code: the idle-report scan in `scripts/session-doctor.sh` (search `isMeta`).

   No transcript dir, or zero `user` entries, means "never messaged", shown as
   `never: no transcript` / `never: no user msgs` (a stronger reap signal than going quiet
   after real use). "never" rows always appear, sorted first.

> **`type:user` includes tool-result turns.** A session looping on tools with no human input
> counts as active and stays off the list. Intentional: live autonomous work must never be
> surfaced as a reap candidate. "No human touch in N days" would be a separate tool.

Cadence: [`references/session-lifecycle.md`](../references/session-lifecycle.md).
