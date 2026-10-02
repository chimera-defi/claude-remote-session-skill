# Git-aware run directory (RUNDIR)

How `session-git-prep` (run by `new-session`'s start script for every git workdir) decides
where a spawned session runs. Read it when a spawn landed somewhere unexpected, or to
decide whether the canonical checkout or a worktree owns a session's uncommitted work.

```
free + clean canonical tree -> put it on the default branch, run there
dirty OR already owned       -> run in a fresh per-session worktree
                                 branched from the default branch
```

- **Default branch**: `origin/HEAD` -> `main` -> `master` -> current `HEAD`. With an
  `origin` remote it fetches and fast-forwards first.
- **Dirty** ignores the spawn skill's own housekeeping (the `.claude/` skills symlink,
  bootstrap edits, `.sessions-init-*` sentinels).
- **Busy**: another live session holds the owner lock under `~/.claude/session-locks/`
  (keyed off the repo path, outside the repo so claiming never dirties the tree). A lock
  whose tmux session is gone is stale and cleared.
- **Worktree reuse on restart**: the worktree path is baked into the generated start script,
  so it is stable across systemd restarts and an already-registered worktree is reused, not
  orphaned. This protects uncommitted work across a supervisor restart.
- **Never fails the spawn**: any checkout/fetch/worktree-add error falls back to the
  canonical repo path as-is.
- **Non-git workdirs** skip this silently.

Precedence and edge cases (legacy lock-key format, retry-with-suffix on worktree-add
collision): `scripts/session-git-prep.sh`, pinned by `tests/test-session-git-prep.sh`.

A fresh worktree would otherwise park claude on its folder-trust dialog, so the start script then
runs `scripts/session-trust-seed.sh` on the chosen run directory (which key it writes, and why it is
the main repo root, is documented there and pinned by `tests/test-session-trust-seed.sh`).
