# Session lifecycle, reaping & expiry

Remote-control sessions live in **four independent layers**; cleaning one does not clean the
others (the #1 cause of "I reaped everything but the count is still high").

| Layer | Where | Lives until | Cleaned by |
|-------|-------|-------------|------------|
| **tmux window** | `tmux ls` on the host | host reboot or `tmux kill-session` | `session-doctor reap-local` |
| **systemd --user unit** | `~/.config/systemd/user/<prefix>-*.service` | `systemctl --user disable` + `rm` | `session-doctor reap-local` |
| **registry entry** | `GET /v1/sessions` (org-wide, all devices) | explicit `DELETE` (never expires) | `session-doctor registry-prune --apply` (or `reap <name>`, which prunes its own entry) |
| **git worktree** | `~/.claude/worktrees/<remote_name>` (only for dirty/busy repos, see `session-git-prep`) | `git worktree remove` (never expires) | `session-doctor reap <name>` (prunes its own worktree; branch kept), or `worktree-stale` for one left by an already-reaped session |

`<prefix>` is `CRSS_SESSION_PREFIX` (default `cs`); old prefixes go in `CRSS_LEGACY_PREFIXES`
and `session-doctor` matches both (`examples/crss-overlay/config.sh.example`).

The registry is org-wide and effectively permanent. It accumulates **disconnected** entries
and **zombies** (`connection_status: connected` but the process died without a clean
disconnect, common after reboots/OOM kills). Reaping local tmux/systemd does not touch it, so
registry hygiene is a separate, deliberate step. `reap-local` (the DEAD-process sweep) also
leaves worktrees + branches behind; `reap <name>` (named, ALIVE-session teardown) removes that
session's own worktree by default. Guards (never a dirty one, never one another unit uses,
never the caller's cwd, never a primary checkout, never the branch): `_reap_remove_worktree`
in `scripts/session-doctor.sh`, `tests/test-session-doctor-reap-worktree.sh`.

## The tool: `scripts/session-doctor.sh`

```
session-doctor.sh                       # read-only 3-layer audit (default)
session-doctor.sh reap-local            # DRY-RUN: list dead local tmux + orphan units
session-doctor.sh reap-local --force    # actually reap them
session-doctor.sh reap <name> [--force] [--allow-young] [--keep-registry] [--keep-worktree] [--dry-run]
                                         # teardown (tmux + unit) + registry entry + worktree; reap, reap-local
                                         # and reap-merged refuse sessions younger than CRSS_REAP_MIN_AGE_H
                                         # (default 24h): see _reap_age_gate, tests/test-reap-min-age.sh
session-doctor.sh registry-stale --days 30   # list registry entries disconnected > N days
session-doctor.sh registry-prune --days 30   # DRY-RUN: same candidates, would-delete/skip/report
session-doctor.sh registry-prune --apply     # actually delete the non-protected candidates
session-doctor.sh worktree-stale             # list worktrees whose owning session is dead
session-doctor.sh archive-ignored <worktree> # verified copy of its gitignored results -> ~/backups/reaped-worktree-ignored/
session-doctor.sh idle-report           # LIVE local sessions idle (no type:user msg) >=2d, report only
session-doctor.sh idle-report --days 7  # widen the idle window; --days 0 = no threshold
```

Safety guarantees:
- Never touches protected plumbing: built-in `claude-remote*` plus `CRSS_PROTECT_NAMES`.
- Only reaps local items whose `claude` process is genuinely gone; `reap-local` is dry-run
  unless `--force`, so a control session inside a supervisor restart window isn't reaped.
- **`registry-stale` never deletes**: it prints candidates and the exact `curl -X DELETE ...`.
  `registry-prune` is the automated form (dry-run default, `--apply` mutates); it always skips
  PROTECT-matching titles, a title matching a live tmux session, and `requires_action` rows
  (header comment in `scripts/session-doctor.sh`). `reap <name>` prunes its own registry entry
  unless `--keep-registry`.
- **`reap <name>` removes that session's own worktree** unless `--keep-worktree`, archives its
  unit/start artifacts first, and never deletes the branch. See the `reap` case,
  `_reap_archive_unit_files`, `_reap_remove_worktree`, `_wt_archive_ignored`; pinned by
  `tests/test-session-doctor.sh` and `tests/test-session-doctor-reap-worktree.sh`.
- **Other worktree removal is never automated**: a dead session's worktree may hold unpushed
  work. `worktree-stale` prints each candidate's dirty/unpushed status and the exact
  `git worktree remove`; rules (`worktree-stale)` case, pinned by `tests/test-session-doctor.sh`):
  `git branch -D` is appended only for `landed=yes` (else a `NOTE:` says keep the ref); a
  worktree another unit runs from gets `KEEP:` and no command; `status=DIRTY` gets removal
  without `--force`/`branch -D` plus a `NOTE:`; a worktree with non-regenerable gitignored
  files gets a `NOTE:` and `session-doctor archive-ignored <worktree> &&` chained ahead of
  `remove:`.
- **`idle-report` is report-only** ([`docs/idle-report.md`](../docs/idle-report.md)): rows are
  alive, so `reap-local` won't touch them; you reap by hand.

## Bringing a dead session back: `scripts/session-resume.sh`

The inverse of `reap`. `session-resume <name> --dry-run` prints the unit, start script, launch
line, run directory, the transcript uuid it would resume, and every reason it would refuse.
Pass `--uuid`: without it the tool auto-picks only when exactly one transcript exists in that
cwd, else refuses and lists them (the newest isn't necessarily the real conversation). Without
`--dry-run` it:

1. writes a one-shot resume pin;
2. runs `systemctl --user reset-failed`, `enable` and `start` on the unit;
3. checks the relaunched process has the same binary and flags plus `--resume <uuid>` and that
   Claude's registry shows that sessionId (no entry = WARN, exit 3, not success). The pin is
   kept until claude has run 30s+ (or that confirmation), so a uuid claude rejects is retried,
   never downgraded to `--continue`.

Start scripts predating the pin loop are patched once (backup in `~/backups/session-resume/`).
Codex-backend units are refused: session-resume does not handle Codex units. The Codex start loop itself resumes an explicitly pinned thread (see `scripts/codex-resume-pin.sh` and `tests/test-codex-resume-pin.sh`).

Why a tool: a hand-relaunched session lacks `--dangerously-skip-permissions`, may run a
different CLI binary, and has no unit, so it stalls on approval prompts; a bare
`systemctl start` of an externally-killed session started a *fresh* conversation because the
`--continue` sentinel was only written when claude exited on its own.

## Recommended cadence

1. **Weekly:** `session-doctor.sh report`; if orphan units or dead tmux pile up,
   `reap-local --force`.
2. **Weekly (idle sweep):** `session-doctor.sh idle-report` (LIVE sessions untouched >=2
   days). Dead ones go to `reap-local`; idle-but-alive ones by name:
   `session-doctor reap <name>` (tmux + unit + registry + worktree, after the session-preserve
   check; `--force` skips it). `[P]` rows are protected, never reap.
3. **Monthly:** `registry-prune --days 30` (dry-run), skim, then `--days 30 --apply`.
   `registry-stale` spot-checks the same set.
4. **Monthly:** `worktree-stale`; confirm each candidate's work is merged/pushed or
   unneeded, then run the printed command. For LEFTOVER worktrees only (from `reap-local`, or
   reaped before `reap <name>` removed worktrees), not a fresh `reap <name>`.
5. **After a host reboot:** expect zombies. Respawn what you still want; the old registry
   entries become deletable.

## Why sessions stop registering

If a **new** session never appears on the phone: the remote-control bridge only enables when
`ANTHROPIC_BASE_URL` is absent or its host is `api.anthropic.com`; a proxy base URL (e.g. a
local `127.0.0.1` proxy) silently disables registration. The launcher forces a first-party URL
via `--settings .../rc-firstparty.settings.json`. If a session is live in `tmux` but
absent/disconnected in `session-doctor report`'s registry section, check its `claude` process
carries that `--settings` flag.
