# Design: shorter session names (`ah-<alias>-<MMDD-HHMM>`)

**Date:** 2026-07-15
**Status:** approved (pending user review of this spec)
**Repo:** claude-remote-session-skill (source for `~/.local/bin/new-session`, `session-doctor`, `session-git-prep`)

## Problem

The app-visible remote-control name is `agenthost-<folder>-<YYYYMMDD-HHMM>` (e.g.
`agenthost-claude-remote-session-skill-20260715-0630`, 51 chars). On mobile the list
truncates around 31 chars, so the user sees `agenthost-claude-remote-session` — the
**unique identifier at the tail is cut off**, which is exactly the token orchestrators
and the user use to refer to a session. The `agenthost-` prefix (10 chars) is constant
noise, and long folder names push the ID off-screen.

## Goal

Make the app-visible name short, information-dense, and put the **unique ID first** so it
always survives truncation — while keeping the host-side lifecycle machinery
(`session-doctor` reaping) correct across the transition.

## Decisions (locked with user)

1. **Layout:** short `ah-` host tag (was `agenthost-`); name-first with the date last
   (revised from ID-first after live feedback — see "Ordering").
2. **Folder handling:** cap long folder names **and** support an optional, inferred,
   *persisted* short alias (like the `ssot` convention for portfolio sessions).
3. **Scope:** change **both** the app-visible name and the host-side tmux/systemd names;
   update `session-doctor` to match.

## New naming scheme

```
TAG   = ah                        # was "agenthost"
ALIAS = <resolved short name>     # see "Alias resolution"
ID    = MMDD-HHMM                  # date +%m%d-%H%M
BODY  = ${ALIAS}-${ID}            # name-first, date last

tmux session (host):  ${TAG}_${BODY}          e.g.  ah_crss-0715-0630
remote-control (app): ${TAG}-${BODY}          e.g.  ah-crss-0715-0630
start script:         ~/.local/bin/${TAG}-${BODY}-start.sh
systemd unit:         ~/.config/systemd/user/${TAG}-${BODY}.service
```

- The only structural difference between tmux and remote name remains the `_` vs `-`
  after the tag — the invariant `session-doctor` relies on to map one to the other.
  Component order within `BODY` is opaque to `session-doctor` (it keys off the prefix
  only and never parses the date), so it plays no part in reaping.
- Year drops from the name but is preserved in `~/.sessions/session-starts.log`
  (full ISO-8601 timestamps), so it is recoverable.
- Mobile view of `ah-crss-0715-0630`: **entire name visible**; identity + date readable.

### Ordering (revised after live feedback)

Initial deploy front-loaded the ID (`ah-<ID>-<alias>`) to guarantee the token survived
truncation. In practice the **shortening** (short tag + capped alias) is what fixed the
problem — the whole name now fits — so the order was flipped to **name-first, date last**
(`ah-<alias>-<MMDD-HHMM>`): it reads naturally and groups by project, and the capped
alias (≤18) keeps the trailing date inside the mobile window. A max-length (18-char)
alias puts the date right at the edge; acronyms keep typical names well within it.

## Alias resolution

`ALIAS` is the short "name" component. Resolved **once per spawn**, in priority order:

0. **Protected folder guard (safety, highest priority).** If `FOLDERNAME` matches
   `ALIAS_PROTECT` (`openclaw|hermes`), alias = sanitized `FOLDERNAME` **unchanged** —
   never acronymed, and `--alias` is ignored (warn if passed).
   Rationale: `session-doctor` protects sessions by **substring-matching the session
   name**. Aliasing strips the folder token (e.g. an `openclaw-<workload>` folder →
   acronym → `ah_…-ow`, which no longer contains `openclaw`), silently making a protected
   session reapable. Keeping the token in the name preserves the guarantee.
   **`ALIAS_PROTECT` is intentionally NARROWER than `session-doctor`'s reap PROTECT
   (`claude-remote|openclaw|hermes`).** Only `openclaw`/`hermes` are ever spawned as
   new-session *folders* needing protection; the bare `claude-remote`/`claude-remote-b`
   RC bridge sessions are not created via `new-session`, so a folder that merely *contains*
   `claude-remote` (e.g. this repo, `claude-remote-session-skill`) is a normal dev session
   that SHOULD shorten and SHOULD be reapable when dead. `session-doctor`'s PROTECT is
   unchanged and still shields the real bridge sessions by their literal names; the two
   patterns are deliberately different and each file documents why.
1. **`--alias <x>` / `-a <x>` flag** → use `<x>`; **upsert** `folder → <x>` into the store.
2. **Saved alias** for this folder in the store → reuse it (guarantees every spawn of the
   same long folder gets the *same* short name).
3. **Inferred + saved**:
   - if `len(folder) <= CAP` (CAP = 18) → alias = folder (unchanged);
   - else → alias = initials-acronym of the hyphen-separated words, lowercased
     (a five-word `a-b-c-d-e` folder → `abcde`; `claude-remote-session-skill` → `crss`);
   - then upsert `folder → alias` so it is stable on every later spawn.

Notes:
- **Sanitize** every alias (explicit or inferred) to `[a-z0-9-]`: lowercase, replace any
  other run of chars with `-`, strip leading/trailing `-`. Aliases become part of tmux
  session names, systemd unit names, and filenames, so they must be shell/systemd-safe.
  Reject (fall back to acronym) if empty after sanitizing.
- Inference is best-effort and predictable; it cannot reliably guess `ssot` (which drops
  the leading "portfolio"). The **store + `--alias` override are the source of truth** —
  set once, sticks forever. The store is seeded (below) so common projects are correct
  from day one.
- The alias only changes the session **name**. Workdir still resolves from the real
  `FOLDERNAME`, so `workspace/` vs `.sessions/` auto-detection is unaffected.

### Alias store

- **Path:** `~/.claude/session-aliases` — local-only runtime state (same spirit as
  `~/.claude/session-locks/`, `~/.claude/rc-firstparty.settings.json`). Not per-repo.
- **Format:** TSV, one `folder<TAB>alias` per line. Lines beginning `#` and blank lines
  ignored.
- **Self-heal:** `new-session` copies the repo `.example` template to the live path if
  the live file is missing; it **never overwrites** an existing live file (user edits
  persist).
- **Upsert (atomic — required):** parallel spawns are a designed feature, so the store is
  a shared-write resource. Take an exclusive `flock` on the store for the read-modify-write,
  and write to a temp file then `mv` into place (atomic replace). Never edit in place.
  If `folder` is already a key, replace its line; else append.

### Seed content

**Privacy:** this repo is public/MIT and installed across the box, so **real project
names are never committed.** Two artifacts:

- **`scripts/session-aliases.example`** (committed) — generic placeholders only, documents
  the format and is the first-run self-heal source:
  ```
  # folder<TAB>alias — session name aliases (managed by new-session; edit freely)
  # some-very-long-project-name	svlpn
  # another-long-workspace-name	awn
  ```
- **Live `~/.claude/session-aliases`** (local, never committed; outside the repo tree) —
  provisioned at deploy time with the approved per-box seed. The real seed values for this
  host are handed to the builder **out-of-band in the delegation brief**, not written to
  any committed file. Deploy step: if the live file is absent, write the approved seed;
  if present, leave it.

Seeding rules the builder must honor (stated generically, no real names committed):
- Do **not** map two different folders to the same alias — same-minute spawns would
  collide on one session name. Prefer leaving an already-short folder unaliased.
- Protected folders (PROTECT pattern) are handled by resolution rule 0 above; do not seed
  an alias that strips their protected token.

## `session-doctor` back-compat (highest-risk change)

`session-doctor` is the **single** component that programmatically parses session names,
and reaping is **manual** (no timer/cron; verified). So teaching it both prefixes fully
covers the transition. During transition BOTH forms coexist: ~11 live sessions are still
`agenthost_*`; new spawns are `ah_*`.

Required changes:
- **Enumerate units** for both prefixes: `grep -E '^(agenthost|ah)-.*\.service$'`.
- Add two mapping helpers used everywhere a name is derived:
  ```sh
  tmux_to_base() {  # tmux session name -> service/script base, or "" if not ours
    case "$1" in
      agenthost_*) echo "agenthost-${1#agenthost_}" ;;
      ah_*)        echo "ah-${1#ah_}" ;;
      *)           echo "" ;;
    esac
  }
  svc_to_tmux() {   # service/script base -> tmux session name
    case "$1" in
      agenthost-*) echo "agenthost_${1#agenthost-}" ;;
      ah-*)        echo "ah_${1#ah-}" ;;
      *)           echo "$1" ;;
    esac
  }
  ```
- **Scope reap loop 1 to our sessions:** iterate live tmux, skip any where
  `tmux_to_base` returns "" (not ours). This also **fixes a current over-reach** where
  `reap-local` would `tmux kill-session` *any* dead non-protected tmux (e.g. the
  `codexhost_*` session) even though it is not an agenthost session. Intended behavior
  change — note it in the commit.
- Derive service/script names from `tmux_to_base` output instead of the hardcoded
  `agenthost-${s#agenthost_}` substitution.
- `report` mode's "orphan units" section uses the same enumeration + `svc_to_tmux`.
- `PROTECT` regex is unchanged (it substring-matches `claude-remote|openclaw|hermes`).

## Files to change

| File | Change |
|------|--------|
| `scripts/new-session.sh` | new naming block; `--alias`/`-a` arg parsing (positional folder/type preserved); `resolve_alias()` + store self-heal/upsert; `--help` text; confirm/echo messages |
| `scripts/session-doctor.sh` | dual-prefix helpers; enumeration; reap loops scoped to our prefixes; report mode |
| `scripts/session-aliases.example` | **new** — generic placeholder template (no real names); first-run self-heal source |
| `references/fallback-recipe.md` | update inline recipe to new prefix + ID-first format. To avoid producing a *different* name than `new-session` for the same folder (a silent duplicate if used to recreate), the recipe does a **one-line store lookup** (`awk -F'\t' '$1==f{print $2}'` against `~/.claude/session-aliases`, default to folder) rather than the full resolver. No acronym/seed logic in the emergency path — documented as intentional |
| `SKILL.md` | naming-convention section; `--alias` usage; alias-store note |
| `README.md` | naming table; examples; alias mention |
| `references/session-lifecycle.md` | unit glob mentions both `agenthost-*` and `ah-*`; note session-doctor dual-prefix |

## Migration & back-compat

- Existing `agenthost_*` sessions keep their names until reaped/restarted. No rename of
  live sessions (out of scope).
- `session-doctor` handles both prefixes for the whole transition — verified by running
  `report` / `reap-local` (dry-run) while old sessions are live and confirming they still
  appear.
- No external tooling depends on the `agenthost` tmux prefix (scanned the box: the only
  non-repo reference is a stale doc-only `SKILL.md` copy in `Etc-mono-repo`, never
  executed). Change is self-contained.

## Risks

1. **Protected session loses protection (safety).** Aliasing strips the folder token that
   `session-doctor`'s PROTECT substring-match depends on. *Mitigation:* resolution rule 0 —
   protected folders are never aliased; verify by resolving each PROTECT-matching folder
   and grepping the result against the PROTECT pattern.
2. **`session-doctor` dual-prefix bug** → silently stops reaping live `agenthost_*`
   sessions. *Mitigation:* explicit dry-run test with old sessions live; assert both
   prefixes enumerate.
3. **Alias-store corruption under parallel spawns** → garbage feeds straight into session/
   unit names. *Mitigation:* `flock` + temp-file-then-`mv` on every upsert (see store spec).
4. **Alias collision** (two folders resolve to the same alias, spawned same minute) →
   duplicate session name. *Mitigation:* existing `tmux has-session` guard exits
   `already-running`; seeding rule forbids mapping two folders to one alias. Acceptable/rare.
5. **Unsafe alias chars** in tmux/systemd names. *Mitigation:* sanitize to `[a-z0-9-]`.
6. **`ah` prefix over-broad match.** *Mitigation:* enumeration is scoped to the systemd
   user dir + our tmux `ah_`/`agenthost_` sessions; structure `ah_MMDD-HHMM-` is specific.

## Testing / verification

- `bash -n` on all changed scripts.
- `new-session --help` shows the new usage + `--alias`.
- Alias unit checks (throwaway folder): inference for a >18-char name yields the acronym;
  `--alias x` overrides and writes the store; a second spawn reuses the stored alias;
  sanitization strips unsafe chars.
- **Protected-folder check:** resolve every PROTECT-matching folder through the alias
  rule and assert the resulting session name still matches the PROTECT pattern.
- End-to-end: spawn a real test session under the new scheme; confirm tmux (`ah_...`),
  systemd unit (`ah-...service`), and start script exist; confirm it **registers** by
  querying the registry endpoint (`GET /v1/sessions`, the same call `session-doctor`
  makes) — an agent cannot observe the app UI, so verify via the API, not the app;
  confirm `session-doctor report` lists it *and* still lists the live `agenthost_*` ones;
  reap the test session and confirm cleanup.
- Redeploy `new-session` + `session-doctor` to `~/.local/bin` (manual copy — the
  established deploy path) and create the seed store; re-verify with `md5sum` that
  deployed == repo.

## Out of scope

- Registry cleanup (155 sessions, ~93 likely zombies) — account-facing, a separate pass.
- Renaming already-running sessions.
- Any change to `session-git-prep` (RUNDIR logic) — untouched by this work.
