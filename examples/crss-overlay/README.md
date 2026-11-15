# crss host-local overlay

The tool and these docs are public and generic. Everything host-specific (operator, escalation
channel, project index, which model fills which role) lives outside the repo in the overlay folder.
`CRSS_HOME` is the name the docs and tests use for that folder, by default
`${XDG_CONFIG_HOME:-$HOME/.config}/crss`. `crss` itself never reads `CRSS_HOME`, only `$CRSS_CONFIG`:

- `local.md`: prose for a human or agent to read before spawning or writing a kickoff. No script
  reads it; an always-on rules pointer loads it.
- `crss.env`: settings `crss` sources (`CRSS_STATE`, `CRSS_DEFAULT_ARGS`, exported environment such
  as the auto-compact window). Read from `CRSS_CONFIG` (default `~/.config/crss/crss.env`). See
  `SKILL.md` "Setup".
- `staffing.md` (optional): which model fills each role on this host
  ([roles](../../references/orchestration-flow.md#roles)).
- `leak-denylist.txt`: optional host-private terms that must never reach this public repo, one ERE
  per line (`#` comments and blanks ignored; add a TAB and comma-separated path globs to exempt
  paths). Only `tests/test-no-host-leaks.sh` reads it; the command is in `CLAUDE.md` "What done
  means". CI never sets it. Fix a hit in the repo file, not in the denylist.

Load `local.md` into every session:

```sh
mkdir -p ~/.config/crss ~/.claude/rules
echo "Read ~/.config/crss/local.md before spawning a session or writing a kickoff." > ~/.config/crss/local.md
echo '@~/.config/crss/local.md' > ~/.claude/rules/crss-host.md
```

Keep `crss-host.md` tiny since it loads into every session. Host facts never go in `SKILL.md`,
`references/`, a script or a test here.

## Env knobs

The variables the scripts read. `crss` reads each from the environment or from `crss.env` (except
`CRSS_CONFIG`, which must be in the environment); `crss-compat` reads only the environment.

| Variable | Read by | Effect (default) |
|---|---|---|
| `CRSS_CONFIG` | `crss` | the env file sourced first (`~/.config/crss/crss.env`) |
| `CRSS_STATE` | `crss` | folder for per-session state files (`${XDG_STATE_HOME:-~/.local/state}/crss`) |
| `CRSS_DEFAULT_ARGS` | `crss spawn` | launch arguments every new session starts with; copied into the session's state file at spawn |
| `CRSS_CLAUDE` | `crss` | the claude command (`claude`) |
| `CRSS_TMUX` | `crss` | the tmux command (`tmux`) |
| `CRSS_NO_SYSTEMD` | `crss` | set to skip `systemd-run` scoping of new tmux sessions |
| `CRSS_NAMES` | `crss spawn` | `auto` (default): Claude titles the session; `plain`: it is named `ah-NAME`. Any other value is an error; `--title` forces `auto`. `auto` is written to the state file as `NAMES=auto`; a state file without it (older sessions) keeps `ah-NAME` |
| `CRSS_POLL` | `crss wait` | seconds between status polls (2) |
| `CRSS_BACKOFF` | restart loop | seconds to wait after a launch that failed within 30 s (300) |
| `CRSS_PAUSE` | restart loop | seconds to wait between normal restarts (5) |
| `CLAUDE_SESSION_MODEL` | `crss-compat` | if set, `new-session` launches with this model instead of the one its tier picks |
| `CRSS_BIN` | `crss-compat` | path of the `crss` script it calls (the `crss` next to it) |
| `CRSS_WORKSPACE` | `crss-compat` | base folder `new-session` resolves a folder name under (`~/workspace`) |
