# Starting sessions from the phone

Problem: the Claude app on a phone can follow a crss session, but it cannot create one on this host
unless some agent on the host is already listening.

## The answer: a Remote Control spawn server

`claude remote-control` has a server mode (checked on CLI 2.1.308 with `claude remote-control --help`).
It is one long-lived process per directory that shows up in the Claude app (Code) and on claude.ai/code as an
**environment**. Starting a new session in that environment from the phone runs a fresh session on
this host. `--spawn worktree` gives each session its own git worktree; `--spawn same-dir` runs them in
the directory itself. No agent has to be present.

`session-spawn-server` wraps it in the usual envelope: tmux, a restart loop, a generated start
script, a systemd user unit and a trust seed. Behaviour and the reason behind each choice are in the
header of [`scripts/session-spawn-server.sh`](../scripts/session-spawn-server.sh), pinned by
[`tests/test-session-spawn-server.sh`](../tests/test-session-spawn-server.sh).

```bash
session-spawn-server install <dir> [--name N] [--spawn worktree|same-dir] [--capacity N] [--model M]
session-spawn-server status
session-spawn-server uninstall <name>
```

On the phone: Claude app → Code → choose the environment named `<name>` → new session → type the
ask. The server pane, on its own tmux socket, is `tmux -L crss-spawn-<name> attach`; it prints the environment URL.

Which directories get a server is host config, so it belongs in the overlay's `local.md`, not here. Two
useful shapes:

- **A launcher**: `install <workspace root>` (non-git, so `same-dir`). Each phone session starts there
  with the crss skill loaded. "Create a session for X" runs `new-session`, which gives a full crss
  session (tmux, unit, restart loop, tier, telemetry) that you then follow from the phone as usual.
- **A project**: `install <repo>` (git, so `worktree` and no pre-created session). It suits quick
  one-off work in that repo.

## What a phone-spawned session is (and isn't)

- It is a child of the server process, not a crss session. It has no tmux, no unit, no
  `session-doctor` view and no restart loop. Anything long-lived should be launched through `new-session` from it.
- Its model is the account default (Opus), unless the server was installed with `--model`, which is
  passed as `ANTHROPIC_MODEL`. It has no `--tier`, so it routes its own work per
  [orchestration-flow.md](orchestration-flow.md): luna high builds, Haiku repairs and checks.
- `--permission-mode auto` by default: the CLI's auto-mode classifier approves or blocks each action.
  A phone-started session is a different trust case from an unattended crss lane, so `bypassPermissions`
  is an explicit `--permission-mode` opt-in. A blocked action shows up in the phone session; answer it
  there. Sessions it launches through `new-session` follow the usual crss rules.
- `--spawn worktree` sessions leave CLI-made worktrees behind; clean them with `git worktree list`
  and the usual unlanded-work checks, never a blind remove.

## Options considered

| Option | Verdict |
|---|---|
| Remote Control spawn server | **Built.** Native, no extra credentials, survives reboots through the unit. |
| A tmux session already running `--remote-control` | It works, but you can only talk to that one session: you need an agent there to spawn others. |
| Channels (`claude --channels plugin:telegram@claude-plugins-official`) | Pushes Telegram/Discord DMs into a running session. It needs a bot token, a plugin install and pairing, so it's the operator's call. Hermes and OpenClaw already poll Telegram bots on this host, and reusing one token would conflict. |
| Routines / `/schedule` (`/fire` API) | Run in Anthropic's cloud (or an org's self-hosted environment), not on this host. |
| Desktop scheduled tasks | They run on the machine with the desktop app open, but they fire on a schedule, not when you ask from the phone. |
