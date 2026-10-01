# crss host-local overlay

crss's scripts are copied flat into `~/.local/bin` and `SKILL.md`/`handoff/`/`references/`
are symlinked into `~/.claude/skills` from a canonical checkout (see `CLAUDE.md`
"Deploying"). Everything host-specific — session paths, which `claude` binary, session names
never to reap, extra scaffolding paths to ignore — lives OUTSIDE the repo in a small local
overlay directory, so the public skill stays generic.

## What `CRSS_HOME` is

Every crss script that uses the overlay resolves the overlay directory as:

```
CRSS_HOME=${CRSS_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/crss}
```

So by default it's `~/.config/crss`. Inside it:

- `config.sh` — machine-readable settings the scripts listed below read.
- `local.md` — free-form host prose for a human/agent to read before
  spawning a session or writing a kickoff (operator handle, escalation
  channel, project index, delegate routing, whatever is useful). No script
  reads it — it's for the always-on rules pointer below.
- `leak-denylist.txt` — optional, host-private terms that must never appear
  in this public repo (an operator handle, a private project or session
  name, a sibling agent's name — anything host-specific that isn't a
  structurally-detectable leak like a home path or email). Only
  `tests/test-no-host-leaks.sh` reads it, and only when told to. One
  extended regex (ERE) per line, `#`-comments and blank lines ignored. A
  line may add a per-term exclusion for a path that legitimately contains the
  term (e.g. a test fixture that pins it on purpose) with a second column:
  `<ERE><TAB><globs>`, a comma-separated list of path globs (matched against
  the path exactly as `git ls-files` prints it); the term is then not checked
  against paths matching one of those globs. The authoritative syntax and
  worked examples are in `tests/test-no-host-leaks.sh`'s header comment. Run it with:

  ```sh
  CRSS_LEAK_DENYLIST=~/.config/crss/leak-denylist.txt bash tests/test-no-host-leaks.sh
  ```

  Any hit names the file and line: fix the file in the repo (make it generic), not the
  denylist, and run this before every PR that touches docs, scripts, or tests.

  CI never sets `$CRSS_LEAK_DENYLIST`, so it only runs the generic,
  host-agnostic checks (absolute home paths, emails, github owners, …); this
  file adds host-specific coverage locally, and — being outside the repo —
  never becomes a second copy of the leak it's checking for.
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

The last two steps load `local.md` into every session (Claude Code loads
`~/.claude/rules/*.md`, including `@`-imports). Keep `crss-host.md` tiny — it loads into
every session's context — and put the content in `local.md`.

`new-session` prints an `overlay: <path> (config: found|absent, rules: found|absent)` line
on every spawn; `session-doctor overlay` (also in the default `session-doctor` report) is
the fuller health check.

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
2. Do NOT put either in `SKILL.md`, `references/`, a script, or a test in this repo — it is
   public; host facts there are leaks.
3. Verify: `session-doctor overlay` (shows whether `config.sh` and the rules pointer are
   found), then start a session or run the affected script.

## Parse, never source

`config.sh` is **parsed**, not sourced: several scripts run under `set -u`/`set -e`, so one bad line
in a *sourced* config could kill every session-\* script on the host, including the doctor
meant to diagnose it. Each script reads it line by line and accepts only lines matching
`^CRSS_[A-Z0-9_]+=<value>`. The value is **literal**: one optional layer of matching
single or double quotes is stripped; nothing is `eval`'d, shell-expanded (`$VAR`, `~`) or
command-substituted (`$(...)`/`` `...` `` stay inert text). Anything else — comments, blank
lines, lowercase or non-`CRSS_` names, typos — is silently ignored. An environment variable
of the same name, set before the script runs, always wins. A missing or unreadable file is
fine: every variable has a generic default.

See `config.sh.example` in this directory for the full list of variables,
each documented with its default.
