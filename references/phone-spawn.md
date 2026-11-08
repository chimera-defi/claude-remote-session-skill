# Starting sessions from the phone

Problem: the Claude app on a phone can follow a crss session (`ah-NAME` under Remote sessions),
but it cannot create one on this host unless something on the host is already listening.

## The answer: a Remote Control spawn server

`claude remote-control` has a server mode (`claude remote-control --help`, checked on CLI 2.1.319;
first checked on 2.1.308). It is one long-lived process per directory that shows up in the Claude
app (Code) and on claude.ai/code as an **environment**. Starting a new session in that
environment from the phone runs a fresh session on this host. `--spawn worktree` gives each
session its own git worktree, `--spawn same-dir` runs them in the directory itself, `--capacity N`
caps concurrent sessions. No agent has to be present.

crss does not wrap this. Run it yourself under a process that survives logout and reboot (a tmux
session, or a systemd user unit with `loginctl enable-linger`):

```bash
cd <dir> && claude remote-control --name <name> --spawn worktree --capacity 4
```

Check `claude remote-control --help` for the current flags and for `--permission-mode` before
relying on any of them. On the phone: Claude app, Code, choose the environment named `<name>`,
new session, type the ask. The server prints the environment URL.

Which directories get a server is host config, so it belongs in `$CRSS_HOME/local.md`, not here.
Two useful shapes:

- **A launcher**: a server on the workspace root (non-git, so `same-dir`). Each phone session
  starts there with the crss skill loaded. "Create a session for X" runs `crss spawn`, which gives
  a full crss session (tmux, restart loop, boot recovery) that you then follow from the phone as
  usual.
- **A project**: a server on a repo (git, so `worktree`). It suits quick one-off work in that repo.

## What a phone-spawned session is (and isn't)

- It is a child of the server process, not a crss session. It has no tmux, no env file, no `crss
  ls` entry and no restart loop. Anything long-lived should be launched through `crss spawn` from
  it.
- Its model is the account default (Opus) unless the server's environment sets `ANTHROPIC_MODEL`
  (how the old wrapper chose one). It has no per-spawn model choice, so it routes its own work per [orchestration-flow.md](orchestration-flow.md):
  gpt-6.1-terra low builds, Haiku repairs a failed check.
- Permissions follow the server's `--permission-mode`. A phone-started session is a different
  trust case from an unattended crss lane, so choose `bypassPermissions` only on purpose; a
  blocked action shows up in the phone session, where you answer it. Sessions it launches through
  `crss spawn` follow the usual crss rules.
- `--spawn worktree` sessions leave CLI-made worktrees behind; clean them with `git worktree list`
  and the usual unlanded-work checks (`git status`, `git log HEAD --not --remotes`), never a
  blind remove.

## Options considered

| Option | Verdict |
|---|---|
| Remote Control spawn server | **Chosen.** Native, no extra credentials; survives reboots if you run it under a unit. |
| A tmux session already running `--remote-control` | It works, but you can only talk to that one session: you need an agent there to spawn others. |
| Channels (`claude --channels plugin:telegram@claude-plugins-official`) | Pushes Telegram/Discord DMs into a running session. It needs a bot token, a plugin install and pairing, so it's the operator's call; other bots on the host polling the same Telegram token would conflict. |
| Routines / `/schedule` (`/fire` API) | Run in Anthropic's cloud (or an org's self-hosted environment), not on this host. |
| Desktop scheduled tasks | They run on the machine with the desktop app open, but they fire on a schedule, not when you ask from the phone. |
