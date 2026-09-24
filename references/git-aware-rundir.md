# Git-aware run directory (RUNDIR)

Moved out of `SKILL.md` so the skill itself stays short. This is how
`session-git-prep` (invoked by `new-session`'s start script for every git
workdir) decides where a spawned session actually runs — read it when a spawn
landed somewhere you didn't expect, or to reason about whether a canonical
checkout or a worktree owns a given session's uncommitted work.

## The decision

```
free + clean canonical tree -> put it on the default branch, run there
dirty OR already owned       -> run in a fresh per-session worktree
                                 branched from the default branch
```

- **Default branch** resolves `origin/HEAD` → `main` → `master` → current
  `HEAD`, in that order, and (when an `origin` remote exists) fetches and
  fast-forwards to it before use.
- **Dirty** ignores the spawn skill's own housekeeping (the `.claude/` skills
  symlink, bootstrap edits, `.sessions-init-*` sentinels) so those never read
  as real uncommitted work.
- **Busy** means another live session already claimed the canonical tree — an
  owner lock under `~/.claude/session-locks/`, keyed off the repo path (kept
  outside the repo so claiming it never dirties the working tree). A lock from
  a dead session (no matching tmux session) is treated as stale and cleared.
- **Worktree reuse on restart**: a session's worktree path is stable across
  systemd restarts of that same session (baked into its generated start
  script, not regenerated per spawn), so a worktree already registered there
  is reused rather than orphaned — this is what protects uncommitted work in
  a session's worktree across a supervisor restart.
- **Never fails the spawn.** Any error along the way — checkout failure,
  fetch failure, worktree-add failure — falls back to the canonical repo path
  as-is rather than blocking the session from starting.
- **Non-git workdirs skip this entirely, silently** — no message either way.

Exercised by `tests/test-session-git-prep.sh`; read that alongside
`scripts/session-git-prep.sh` for the exact precedence and edge cases (legacy
lock-key format during a deploy rollout, retry-with-suffix on a worktree-add
collision, etc.) rather than a restatement here.
