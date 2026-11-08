# crss host-local overlay

The tool and these docs are public and generic. Everything host-specific (who the operator is,
where to escalate, which project lives where, which delegate to use) lives OUTSIDE the repo in a
small local overlay directory.

## What `CRSS_HOME` is

```
CRSS_HOME=${CRSS_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/crss}
```

By default `~/.config/crss`. Inside it:

- `local.md`: free-form host prose for a human or agent to read before spawning a session or
  writing a kickoff (operator handle, escalation channel, project index, delegate routing).
  No script reads it; an always-on rules pointer loads it (below).
- `crss.env`: settings the `crss` script sources (`CRSS_STATE`, `CRSS_DEFAULT_ARGS`, exported
  environment such as the auto-compact window). It is `crss`'s own config, set via `$CRSS_CONFIG`;
  see `SKILL.md` "Setup". The old `config.sh` (parsed `CRSS_*` lines for the retired `session-*`
  scripts) is no longer read by anything in this repo.
- `leak-denylist.txt`: optional, host-private terms that must never appear in this public repo
  (an operator handle, a private project or session name, a sibling agent's name: anything
  host-specific that isn't a structurally detectable leak like a home path or email). Only
  `tests/test-no-host-leaks.sh` reads it, and only when told to. One extended regex (ERE) per
  line, `#`-comments and blank lines ignored. A line may add a per-term exclusion for a path that
  legitimately contains the term (for example a test fixture that pins it on purpose) with a
  second column: `<ERE><TAB><globs>`, a comma-separated list of path globs (matched against the
  path exactly as `git ls-files` prints it); the term is then not checked against paths matching
  one of those globs. The authoritative syntax and worked examples are in
  `tests/test-no-host-leaks.sh`'s header comment. Run it with:

  ```sh
  CRSS_LEAK_DENYLIST=~/.config/crss/leak-denylist.txt bash tests/test-no-host-leaks.sh
  ```

  Any hit names the file and line: fix the file in the repo (make it generic), not the denylist,
  and run this before every PR that touches docs, scripts or tests.

  CI never sets `$CRSS_LEAK_DENYLIST`, so it only runs the generic, host-agnostic checks
  (absolute home paths, emails, github owners, ...); this file adds host-specific coverage
  locally and, being outside the repo, never becomes a second copy of the leak it is checking for.
- anything else you want to keep here (per-project notes, host tools and their docs).

## Setting it up

```sh
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/crss"
printf '%s\n' "This host runs crss. Before spawning a session, writing a kickoff, or handing off, read ~/.config/crss/local.md if present." > "${XDG_CONFIG_HOME:-$HOME/.config}/crss/local.md"
mkdir -p ~/.claude/rules
printf '%s\n' '@~/.config/crss/local.md' > ~/.claude/rules/crss-host.md
```

The last two steps load `local.md` into every session (Claude Code loads `~/.claude/rules/*.md`,
including `@`-imports). Keep `crss-host.md` tiny, since it loads into every session's context, and
put the content in `local.md`.

## Adding a host fact

- A value `crss` reads (default launch arguments, state directory, an exported environment
  variable): `~/.config/crss/crss.env`.
- Prose for a human or agent: `local.md`.
- Never put either in `SKILL.md`, `references/`, a script or a test in this repo: it is public,
  and host facts there are leaks.
