# crss host-local overlay

crss (this repo) is installed the same way on every host: the scripts under
`scripts/` are copied flat into `~/.local/bin`, and `SKILL.md`/`handoff/`/
`references/` are symlinked into `~/.claude/skills` from a canonical
checkout. Everything host-specific — which paths repo/utility sessions live
under, which `claude` binary to launch, which session names must never be
reaped, extra scaffolding paths to ignore — lives OUTSIDE the repo, in a
small local overlay directory. This lets the public skill stay generic while
still behaving exactly the way a given host needs it to.

## What `CRSS_HOME` is

Every crss script resolves the overlay directory as:

```
CRSS_HOME=${CRSS_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/crss}
```

So by default it's `~/.config/crss`. Inside it:

- `config.sh` — machine-readable settings the scripts read (see below).
- `local.md` — free-form host prose for a human/agent to read before
  spawning a session or writing a kickoff (operator handle, escalation
  channel, project index, delegate routing, whatever is useful). Not read by
  any script in this repo — it's for the always-on rules pointer below.
- anything else you want to keep here (per-project notes, etc.) — crss
  itself only looks for `config.sh` and `local.md`.

## Setting it up

```sh
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/crss"
cp -r examples/crss-overlay/config.sh.example "${XDG_CONFIG_HOME:-$HOME/.config}/crss/config.sh"
# edit config.sh for your host, then optionally:
printf '%s\n' "This host runs crss. Before spawning a session, writing a kickoff, or handing off, read ~/.config/crss/local.md if present." > "${XDG_CONFIG_HOME:-$HOME/.config}/crss/local.md"
mkdir -p ~/.claude/rules
printf '%s\n' '@~/.config/crss/local.md' > ~/.claude/rules/crss-host.md
```

The last two steps make `local.md` load into every session on the host
automatically (Claude Code loads `~/.claude/rules/*.md`, including
`@`-imports, in every session). Keep `crss-host.md` itself tiny — it loads
into every session's context — and put the actual content in `local.md`,
which only the pointer file references.

`new-session` prints an `overlay: <path> (config: found|absent, rules:
found|absent)` line on every spawn, and `session-doctor overlay` (also
folded into the default `session-doctor` report) gives a fuller health
check, so a missing or half-set-up overlay is visible rather than silent.

## Parse, never source

`config.sh` is **parsed**, not sourced. This matters: several crss scripts
run under `set -u`/`set -e`, so a single bad line in a *sourced* config
could kill every session-\* script on the host at once — including the
doctor that's supposed to diagnose it. Instead, each script reads
`config.sh` line by line and only accepts lines matching
`^CRSS_[A-Z0-9_]+=<value>`. The value is taken **literally**: one optional
layer of matching single or double quotes is stripped, and that's it —
nothing is ever `eval`'d, shell-expanded (`$VAR`, `~`), or
command-substituted (`$(...)`/`` `...` `` are kept as inert text, never
executed). Anything that doesn't match — comments, blank lines, a
lowercase or non-`CRSS_` name, a typo — is silently ignored. An environment
variable of the same name, already set before the script runs, always wins
over whatever is written in the file. The file being missing or unreadable
is completely fine: every variable has a built-in generic default and the
scripts behave normally with no overlay at all.

See `config.sh.example` in this directory for the full list of variables,
each documented with its default.
