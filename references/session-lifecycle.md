# Session lifecycle, reaping & expiry

Remote-control sessions exist in **four independent layers**. Cleaning one does not
clean the others — this is the #1 source of "I reaped everything but the session
count is still high" confusion.

| Layer | Where | Lives until | Cleaned by |
|-------|-------|-------------|------------|
| **tmux window** | `tmux ls` on the host | host reboot or `tmux kill-session` | `session-doctor reap-local` |
| **systemd --user unit** | `~/.config/systemd/user/agenthost-*.service` / `ah-*.service` | `systemctl --user disable` + `rm` | `session-doctor reap-local` |
| **registry entry** | `GET /v1/sessions` (org-wide, all devices) | explicit `DELETE` (never expires on its own) | `session-doctor registry-prune --apply` (or `reap <name>`, which prunes its own entry) |
| **git worktree** | `~/.claude/worktrees/<remote_name>` (only for dirty/busy repos — see `session-git-prep`) | `git worktree remove` (never expires on its own) | `session-doctor reap <name>` (prunes its own worktree; branch kept) — or manual removal via `worktree-stale` for a worktree left by an already-reaped session |

Sessions created before the 2026-07-15 naming change use the `agenthost-`/`agenthost_`
prefix; sessions created after use the shorter `ah-`/`ah_` prefix. `session-doctor`
matches both prefixes for the whole transition — old and new sessions are reaped
identically.

**Key fact:** the registry is org-wide and effectively permanent. It accumulates:
- **disconnected** entries (session ended, registration lingers), and
- **zombies** — `connection_status: connected` but the real process died without a clean
  disconnect (common after host reboots / OOM kills). These keep counting as "connected."

Reaping local tmux/systemd does **not** remove registry entries, so it does little for
any per-org session-count pressure. Registry hygiene is a separate, deliberate step.
Reaping local tmux/systemd via `reap-local` (the DEAD-process sweep) also does **not**
remove worktrees — a session that ran in an isolated worktree (because its canonical
repo was dirty or already owned; see `session-git-prep`) leaves that worktree + branch
behind if it's reaped that way. `reap <name>` (the named, ALIVE-session teardown) DOES
remove that one session's own worktree by default — see `_reap_remove_worktree` in
`scripts/session-doctor.sh` and `tests/test-session-doctor-reap-worktree.sh` for exactly
what it checks before removing (never a dirty one, never one another systemd unit still
uses, never the caller's own cwd, never a repo's primary checkout, never the branch).

## The tool: `scripts/session-doctor.sh`

```
session-doctor.sh                       # read-only 3-layer audit (default)
session-doctor.sh reap-local            # DRY-RUN: list dead local tmux + orphan units
session-doctor.sh reap-local --force    # actually reap them
session-doctor.sh reap <name> [--force] [--keep-registry] [--keep-worktree]
                                         # teardown (tmux + unit) + registry entry + worktree
session-doctor.sh registry-stale --days 30   # list registry entries disconnected > N days
session-doctor.sh registry-prune --days 30   # DRY-RUN: same candidates, would-delete/skip/report
session-doctor.sh registry-prune --apply     # actually delete the non-protected candidates
session-doctor.sh worktree-stale             # list worktrees whose owning session is dead
session-doctor.sh archive-ignored <worktree> # verified copy of its gitignored results → ~/backups/reaped-worktree-ignored/
session-doctor.sh idle-report           # LIVE local sessions idle (no type:user msg) ≥2d — report only
session-doctor.sh idle-report --days 7  # widen the idle window; --days 0 = no threshold (list all)
```

Safety guarantees:
- Never touches protected plumbing: `claude-remote*`, `*openclaw*`, `*hermes*`.
- Only reaps local items whose `claude` process is genuinely gone.
- `reap-local` is dry-run unless `--force` — so a control session merely inside a
  supervisor restart window is never reaped by accident.
- **`registry-stale` never deletes** — it prints candidates and the exact
  `curl -X DELETE …` to run by hand. `registry-prune` is the automated form of the
  same candidate set (dry-run by default, `--apply` to mutate) — see its own header
  comment in `scripts/session-doctor.sh` for exactly what it always skips
  (PROTECT-matching titles, a title matching a live tmux session, `requires_action`
  rows) and its per-row deleted/skipped/failed outcome. `reap <name>` also prunes
  that one session's own registry entry on success, unless `--keep-registry`.
- **`reap <name>` also removes that one session's own worktree**, unless
  `--keep-worktree`. `git worktree remove` runs without `--force` on its own (a dirty
  worktree refuses and is left in place, reported, never fails the rest of reap) except
  under reap's own `--force`, which is passed through. A worktree still referenced by
  any OTHER systemd unit (`WorkingDirectory` or anywhere in `ExecStart`, including
  `.service.d/*.conf` drop-ins), the caller's own cwd, or a repo's primary checkout is
  never removed either way. The branch is never deleted. See `_reap_remove_worktree`'s
  header comment in `scripts/session-doctor.sh` and
  `tests/test-session-doctor-reap-worktree.sh`. Before removing, reap archives the
  worktree's non-regenerable *gitignored* files (which `git worktree remove` deletes
  and a `clean` status never shows) to `~/backups/reaped-worktree-ignored/`, and keeps
  the worktree if it can't — see `_wt_archive_ignored` in the same script and case 13
  of that test.
- **Worktree removal for everything else is never automated.** `worktree-stale` prints
  each remaining candidate's dirty/unpushed status and the exact `git worktree remove`
  to run by hand (a `git branch -D` is appended only for a `landed=yes` row; otherwise a
  `NOTE:` says to keep the ref) — for a worktree left by a session that was
  `reap-local`'d (not `reap <name>`'d) or reaped before this existed, a dead session's
  worktree may hold unpushed work, so this stays a review step. A worktree another
  systemd unit still runs from gets a `KEEP:` line and no removal command, and a
  `status=DIRTY` row gets the removal without `--force` or `branch -D` plus a `NOTE:`.
  A row whose worktree holds non-regenerable gitignored files (a `clean` row can) gets a
  `NOTE:` and `session-doctor archive-ignored <worktree> &&` chained ahead of its
  `remove:` line. These rules are in the `worktree-stale)` case of
  `scripts/session-doctor.sh`, pinned by `tests/test-session-doctor.sh`.
- **`idle-report` is report-only** (like `registry-stale`): every row is a still-*alive*
  proc, so `reap-local` won't touch it. It generates the "candidates to reap" list; you
  then kill an idle-but-alive one by hand. It never kills anything itself.

## Recommended cadence (expiry policy)

1. **Weekly:** `session-doctor.sh report`. If orphan units or dead tmux pile up,
   `reap-local --force`.
2. **Weekly (idle sweep):** `session-doctor.sh idle-report`. This is the default,
   reusable way to get the "candidates to reap" list — LIVE sessions no one has touched
   in ≥2 days. Dead ones flow to `reap-local`; idle-but-*alive* ones (which `reap-local`
   deliberately leaves running) you reap by name: `session-doctor reap <name>` (tmux +
   unit + registry entry + worktree, all in one shot, after the session-preserve safety
   check — `--force` to skip it). Rows flagged `[P]` are protected — never reap those.
3. **Monthly:** `session-doctor.sh registry-prune --days 30` (dry-run), skim the
   would-delete list, then `registry-prune --days 30 --apply`. `registry-stale` still
   works for a manual spot-check of the same candidates.
4. **Monthly:** `session-doctor.sh worktree-stale`. For each candidate, confirm its
   work is merged/pushed or no longer needed, then run the printed removal command. This
   is for LEFTOVER worktrees — from a session `reap-local` swept (not `reap <name>`), or
   reaped before `reap <name>` removed worktrees itself — not for a fresh `reap <name>`.
5. **After a host reboot:** expect zombies (registry says connected, process gone).
   Respawn the sessions you still want; the old registry entries become deletable.

## Why sessions stop registering (the 2026-07 regression)

If a **new** session never appears on the phone, the usual cause is the remote-control
bridge gate: the CLI only enables the bridge when `ANTHROPIC_BASE_URL` is absent or its
host is `api.anthropic.com`. A proxy base URL (e.g. headroom `127.0.0.1`) silently
disables registration. The launcher fixes this by forcing a first-party base URL via
`--settings …/rc-firstparty.settings.json`. If you see a session live in `tmux` but
absent/disconnected in `session-doctor report`'s registry section, check that its
`claude` process carries that `--settings` flag.
