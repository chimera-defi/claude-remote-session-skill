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

Every crss script that uses the overlay resolves the overlay directory as:

```
CRSS_HOME=${CRSS_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/crss}
```

So by default it's `~/.config/crss`. Inside it:

- `config.sh` — machine-readable settings the scripts listed below read.
- `local.md` — free-form host prose for a human/agent to read before
  spawning a session or writing a kickoff (operator handle, escalation
  channel, project index, delegate routing, whatever is useful). Not read by
  any script in this repo — it's for the always-on rules pointer below.
- `leak-denylist.txt` — optional, host-private terms that must never appear
  in this public repo (an operator handle, a private project or session
  name, a sibling agent's name — anything specific to this host that isn't
  a structurally-detectable leak like a home path or email). Not read by any
  crss script at runtime; only `tests/test-no-host-leaks.sh` reads it, and
  only when told to. One extended regex (ERE) per line, `#`-comments and
  blank lines ignored. A line may add a per-term exclusion — a real path
  legitimately contains the term (e.g. a test fixture that pins it on
  purpose) — with a second column: `<ERE><TAB><globs>`, where `<globs>` is a
  comma-separated list of path globs (matched against the path exactly as
  `git ls-files` prints it); the term is then simply not checked against any
  path matching one of those globs. See `tests/test-no-host-leaks.sh`'s own
  header comment for the authoritative syntax and worked examples — this
  paragraph summarizes it, that file defines it. Run it with:

  ```sh
  CRSS_LEAK_DENYLIST=~/.config/crss/leak-denylist.txt bash tests/test-no-host-leaks.sh
  ```

  CI never sets `$CRSS_LEAK_DENYLIST`, so it only ever runs the generic,
  host-agnostic checks (absolute home paths, emails, github owners, …); this
  file adds host-specific coverage locally, and — being outside the repo —
  never itself becomes a second copy of the leak it's checking for.
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

## How to add a host fact

1. Decide what kind of fact it is.
   - A value a script reads (a path, a model flag, a protected name, a timeout): add a
     `CRSS_*=value` line to `$CRSS_HOME/config.sh`. Most variables are documented in
     `config.sh.example` with their default; a few (`CRSS_UNIT_DIR`, `CRSS_RESUME_BACKUP_DIR`,
     `CRSS_RESUME_WAIT`, `CRSS_RESUME_REG_WAIT`, read by `session-resume`) are not listed there
     but are accepted the same way, because the loader takes any `CRSS_*` key. The scripts that
     load `config.sh` are `fleet-status`, `new-session`, `record-spawn-telemetry`,
     `session-alias`, `session-doctor`, `session-handoff`, `session-preserve`,
     `session-registry`, `session-resume` and `telemetry-report`; `session-compact`,
     `session-git-prep` and `session-send` do not (set their variables in the environment).
   - Prose for a human or agent (who the operator is, where to escalate, which project
     lives where, which delegate to use): add it to `$CRSS_HOME/local.md`.
2. Do NOT put either in `SKILL.md`, `references/`, a script, or a test in this repo. It is
   public; host facts there are leaks.
3. Verify: run `session-doctor overlay` (shows whether `config.sh` and the rules pointer
   are found) and start a session or run the affected script.

## How to add a leak-denylist term

1. Append one line to `$CRSS_HOME/leak-denylist.txt`: an ERE for the private word, for
   example `my-private-project` (comments start with `#`). Optionally add a TAB and a
   comma-separated list of path globs where the term is legitimately allowed.
2. Run the stricter local check from a repo checkout:

   ```sh
   CRSS_LEAK_DENYLIST="${CRSS_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/crss}/leak-denylist.txt" bash tests/test-no-host-leaks.sh
   ```

   Any hit names the file and line; fix the file in the repo (make it generic), not the
   denylist. Run this before every PR that touches docs, scripts, or tests.

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
