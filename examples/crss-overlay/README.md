# crss host-local overlay

The tool and these docs are public and generic. Everything host-specific (operator, escalation
channel, project index, delegate routing) lives outside the repo in `CRSS_HOME`, by default
`${XDG_CONFIG_HOME:-$HOME/.config}/crss`:

- `local.md`: prose for a human or agent to read before spawning or writing a kickoff. No script
  reads it; an always-on rules pointer loads it.
- `crss.env`: settings `crss` sources (`CRSS_STATE`, `CRSS_DEFAULT_ARGS`, exported environment such
  as the auto-compact window). Read from `CRSS_CONFIG` (default `~/.config/crss/crss.env`), not
  `CRSS_HOME`. See `SKILL.md` "Setup".
- `leak-denylist.txt`: optional host-private terms that must never reach this public repo, one ERE
  per line (`#` comments and blanks ignored; add a TAB and comma-separated path globs to exempt
  paths). Only `tests/test-no-host-leaks.sh` reads it, via
  `CRSS_LEAK_DENYLIST=~/.config/crss/leak-denylist.txt bash tests/test-no-host-leaks.sh`. CI never
  sets it. Fix a hit in the repo file, not in the denylist.

Load `local.md` into every session:

```sh
mkdir -p ~/.config/crss ~/.claude/rules
echo "Read ~/.config/crss/local.md before spawning a session or writing a kickoff." > ~/.config/crss/local.md
echo '@~/.config/crss/local.md' > ~/.claude/rules/crss-host.md
```

Keep `crss-host.md` tiny since it loads into every session. Host facts never go in `SKILL.md`,
`references/`, a script or a test here.
