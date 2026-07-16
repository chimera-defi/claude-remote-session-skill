# Shorter ID-first Session Names — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the app-visible session name short and ID-first (`ah-<MMDD-HHMM>-<alias>`) so the unique identifier survives mobile truncation, backed by an inferred+persisted alias store, without breaking `session-doctor` reaping during the transition.

**Architecture:** A new standalone `session-alias` helper (deployed to `~/.local/bin`, mirroring the existing `session-git-prep` helper pattern) resolves the short alias and owns the alias store. `new-session.sh` calls it, front-loads a `MMDD-HHMM` id, and switches the `agenthost` prefix to `ah`. `session-doctor.sh` learns both `agenthost` and `ah` prefixes so live old sessions stay reapable. Docs follow.

**Tech Stack:** Bash, coreutils (`awk`/`sed`/`grep`/`flock`/`mktemp`), `python3` (already a dependency). No new runtime dependencies. No test framework dependency — tests are plain-bash assertion scripts.

## Global Constraints

- Prefix tag: `ah` (host-side tmux uses `ah_`, app/service/script use `ah-`). Legacy `agenthost` must keep working for the transition.
- ID format: `date +%m%d-%H%M` → `MMDD-HHMM`, always front-loaded.
- Alias cap: `CAP=18` (folder ≤18 chars → used as-is; else initials-acronym).
- Alias charset: sanitize to `[a-z0-9-]` (lowercase; other runs → `-`; strip leading/trailing `-`).
- PROTECT pattern `claude-remote|openclaw|hermes` is duplicated in `session-alias` and `session-doctor.sh`; a comment in each ties them together — **keep in sync**.
- Protected folders are **never aliased** (identity token must remain in the name).
- **No real project names in any committed file.** Only generic placeholders. The live per-box seed is provisioned at deploy time from a local file, never committed.
- Alias store writes are atomic: `flock` + write-temp-then-`mv`.
- Store path override for tests: honor `SESSION_ALIAS_STORE` env var; default `~/.claude/session-aliases`.
- Deployment is manual copy to `~/.local/bin` (the established path). Helpers stay single-file and self-contained.
- Commit trailers on every commit:
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01T6svu6TeVndTRkNdvJuDev
  ```

---

## File Structure

- **Create** `scripts/session-alias.sh` — resolver + store owner (deployed as `~/.local/bin/session-alias`).
- **Create** `scripts/session-aliases.example` — generic placeholder seed template (committed).
- **Create** `tests/test-session-alias.sh` — unit tests for the resolver.
- **Create** `tests/test-session-doctor.sh` — unit tests for prefix mapping.
- **Modify** `scripts/new-session.sh` — naming block, `--alias` arg, helper wiring, `--dry-run`, `--help`, confirm output.
- **Modify** `scripts/session-doctor.sh` — dual-prefix helpers, scoped reap, source-guard.
- **Modify** `references/fallback-recipe.md`, `SKILL.md`, `README.md`, `references/session-lifecycle.md` — docs.

---

## Task 1: `session-alias` resolver helper + store

**Files:**
- Create: `scripts/session-alias.sh`
- Create: `scripts/session-aliases.example`
- Test: `tests/test-session-alias.sh`

**Interfaces:**
- Consumes: nothing (leaf helper).
- Produces: CLI `session-alias <foldername> [--alias <x>]` → prints the resolved alias on stdout, exit 0. Side effect: upserts `folder<TAB>alias` into `${SESSION_ALIAS_STORE:-$HOME/.claude/session-aliases}` (except protected folders, which are echoed but not stored). Reads `SESSION_ALIAS_STORE` for the store path.

- [ ] **Step 1: Write the failing test**

Create `tests/test-session-alias.sh`:

```bash
#!/usr/bin/env bash
# Plain-bash assertions for session-alias. No external test framework.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ALIAS="$HERE/../scripts/session-alias.sh"
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }

STORE="$(mktemp)"; rm -f "$STORE"; export SESSION_ALIAS_STORE="$STORE"

# short folder (<=18) passes through unchanged
ok "short-passthrough" "$(bash "$ALIAS" eth2-quickstart)" "eth2-quickstart"
# long folder -> initials acronym
ok "long-acronym" "$(bash "$ALIAS" claude-remote-session-skill)" "crss"
# explicit --alias overrides and is sanitized
ok "explicit-alias" "$(bash "$ALIAS" some-thing --alias 'My Alias!')" "my-alias"
# stored alias is reused on the next call (no re-inference)
bash "$ALIAS" a-very-long-folder-name-here --alias keep >/dev/null
ok "store-hit" "$(bash "$ALIAS" a-very-long-folder-name-here)" "keep"
# protected folder is never aliased (token must survive), and not stored
ok "protected-passthrough" "$(bash "$ALIAS" openclaw-autoresearch)" "openclaw-autoresearch"
ok "protected-not-stored" "$(awk -F'\t' '$1=="openclaw-autoresearch"' "$STORE" | wc -l | tr -d ' ')" "0"
# --alias on a protected folder is ignored (still keeps identity token)
ok "protected-ignores-alias" "$(bash "$ALIAS" openclaw-autoresearch --alias oa)" "openclaw-autoresearch"

echo "session-alias: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-session-alias.sh`
Expected: FAIL (script `scripts/session-alias.sh` does not exist → non-zero, assertion output).

- [ ] **Step 3: Write the resolver**

Create `scripts/session-alias.sh`:

```bash
#!/usr/bin/env bash
# session-alias — resolve a short, stable session alias for a workdir folder and
# persist it. Invoked by new-session.sh (like session-git-prep). Prints the alias.
#
# Usage: session-alias <foldername> [--alias <x>]
set -uo pipefail

# PROTECT: keep in sync with session-doctor.sh. Protected folders are NEVER
# aliased — session-doctor protects sessions by substring-matching the name, so
# the identifying token must remain in it.
PROTECT='claude-remote|openclaw|hermes'
CAP=18
STORE="${SESSION_ALIAS_STORE:-$HOME/.claude/session-aliases}"

FOLDER=""; ALIAS_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    -a|--alias) ALIAS_ARG="${2:-}"; shift 2 ;;
    *) [ -z "$FOLDER" ] && FOLDER="$1"; shift ;;
  esac
done
[ -n "$FOLDER" ] || { echo "usage: session-alias <foldername> [--alias <x>]" >&2; exit 2; }

sanitize() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//'; }

infer() { # $1 = folder ; echo alias
  local f="$1" acr="" w
  if [ "${#f}" -le "$CAP" ]; then sanitize "$f"; return; fi
  local IFS='-'; for w in $f; do acr="${acr}${w:0:1}"; done
  acr="$(sanitize "$acr")"
  [ "${#acr}" -ge 2 ] && printf '%s' "$acr" || sanitize "${f:0:$CAP}"
}

store_lookup() { [ -f "$STORE" ] && awk -F'\t' -v f="$1" '$1==f{print $2; exit}' "$STORE"; }

store_upsert() { # $1 folder $2 alias — atomic
  mkdir -p "$(dirname "$STORE")"
  exec 9>"${STORE}.lock"; flock 9
  local tmp; tmp="$(mktemp "${STORE}.XXXXXX")"
  { [ -f "$STORE" ] && grep -q . "$STORE" && awk -F'\t' -v f="$1" '$1!=f' "$STORE"; } > "$tmp" 2>/dev/null || true
  printf '%s\t%s\n' "$1" "$2" >> "$tmp"
  mv -f "$tmp" "$STORE"
  flock -u 9
}

# Resolution order (see spec):
# 0. protected -> sanitized folder, never stored, --alias ignored (warn)
if printf '%s' "$FOLDER" | grep -qiE "$PROTECT"; then
  [ -n "$ALIAS_ARG" ] && echo "session-alias: '$FOLDER' is protected; ignoring --alias" >&2
  sanitize "$FOLDER"; exit 0
fi
# 1. explicit --alias -> sanitize, store, print
if [ -n "$ALIAS_ARG" ]; then
  a="$(sanitize "$ALIAS_ARG")"; [ -n "$a" ] || a="$(infer "$FOLDER")"
  store_upsert "$FOLDER" "$a"; printf '%s\n' "$a"; exit 0
fi
# 2. stored alias -> reuse
s="$(store_lookup "$FOLDER")"
if [ -n "$s" ]; then printf '%s\n' "$s"; exit 0; fi
# 3. infer + store
a="$(infer "$FOLDER")"; store_upsert "$FOLDER" "$a"; printf '%s\n' "$a"
```

- [ ] **Step 4: Create the seed example**

Create `scripts/session-aliases.example` (generic placeholders only — no real names):

```
# folder<TAB>alias — session name aliases (managed by session-alias; edit freely).
# One "folder<TAB>alias" per line. Lines starting with # and blank lines are ignored.
# Protected folders (claude-remote|openclaw|hermes) are never aliased; don't add them.
# some-very-long-project-name	svlpn
# another-long-workspace-name	awn
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `chmod +x scripts/session-alias.sh tests/test-session-alias.sh && bash tests/test-session-alias.sh`
Expected: `session-alias: pass=7 fail=0` and exit 0.

- [ ] **Step 6: Commit**

```bash
git add scripts/session-alias.sh scripts/session-aliases.example tests/test-session-alias.sh
git commit -m "feat(session): session-alias resolver + persisted alias store

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01T6svu6TeVndTRkNdvJuDev"
```

---

## Task 2: `new-session.sh` — ID-first naming, `--alias`, helper wiring, `--dry-run`

**Files:**
- Modify: `scripts/new-session.sh` (help block ~10-41; inputs ~43-45; naming ~62-67; confirm ~183-186)
- Test: reuse `tests/test-session-alias.sh` pattern via a new `tests/test-new-session-names.sh`

**Interfaces:**
- Consumes: `session-alias` (Task 1) from PATH; falls back to inline sanitized-folder if absent.
- Produces: `--dry-run` prints resolved `SESSION`, `REMOTE_NAME`, `SCRIPT`, `SERVICE` (one `KEY=VALUE` per line) and exits 0 without spawning. `--alias <x>`/`-a <x>` accepted anywhere in args.

- [ ] **Step 1: Write the failing test**

Create `tests/test-new-session-names.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NS="$HERE/../scripts/new-session.sh"
export PATH="$HERE/../scripts:$PATH"   # so `session-alias` resolves to our helper
ln -sf session-alias.sh "$HERE/../scripts/session-alias" 2>/dev/null || true
STORE="$(mktemp)"; rm -f "$STORE"; export SESSION_ALIAS_STORE="$STORE"
pass=0; fail=0
has(){ if printf '%s' "$2" | grep -q "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }

out="$(bash "$NS" --dry-run claude-remote-session-skill 2>/dev/null)"
has "remote-ah-id-alias" "$out" 'REMOTE_NAME=ah-[0-9]\{4\}-[0-9]\{4\}-crss'
has "tmux-underscore"    "$out" 'SESSION=ah_[0-9]\{4\}-[0-9]\{4\}-crss'
has "service-name"       "$out" 'SERVICE=.*/ah-[0-9]\{4\}-[0-9]\{4\}-crss\.service'
out2="$(bash "$NS" --dry-run some-proj --alias myproj 2>/dev/null)"
has "explicit-alias"     "$out2" 'REMOTE_NAME=ah-[0-9]\{4\}-[0-9]\{4\}-myproj'

echo "new-session names: pass=$pass fail=$fail"; [ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-new-session-names.sh`
Expected: FAIL (no `--dry-run` support; names still `agenthost-…`).

- [ ] **Step 3: Add `--alias` + `--dry-run` parsing and the new naming block**

In `scripts/new-session.sh`, after the help block, replace the Inputs section (lines ~43-45) with arg parsing that preserves the positional `foldername`/`type` while extracting flags:

```bash
# ── Inputs ──────────────────────────────────────────────────────────────────
FOLDERNAME=""; TYPE="auto"; ALIAS_ARG=""; DRYRUN=no
while [ $# -gt 0 ]; do
  case "$1" in
    -a|--alias) ALIAS_ARG="${2:?--alias needs a value}"; shift 2 ;;
    --dry-run)  DRYRUN=yes; shift ;;
    workspace|sessions|auto) TYPE="$1"; shift ;;
    *) if [ -z "$FOLDERNAME" ]; then FOLDERNAME="$1"; else TYPE="$1"; fi; shift ;;
  esac
done
: "${FOLDERNAME:?Usage: new-session <foldername> [workspace|sessions] [--alias X]}"
```

Replace the Naming block (lines ~62-67) with:

```bash
# ── Naming ──────────────────────────────────────────────────────────────────
# ID-first so the unique token survives mobile truncation. Prefix `ah` (was
# `agenthost`); session-doctor understands both during the transition.
ID=$(date +%m%d-%H%M)
if command -v session-alias >/dev/null 2>&1; then
  ALIAS=$(session-alias "$FOLDERNAME" ${ALIAS_ARG:+--alias "$ALIAS_ARG"} 2>/dev/null) || ALIAS=""
fi
# Fallback if the helper is missing (mirrors fallback-recipe): sanitized folder.
[ -n "$ALIAS" ] || ALIAS=$(printf '%s' "$FOLDERNAME" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//')
BODY="${ID}-${ALIAS}"
SESSION="ah_${BODY}"
REMOTE_NAME="ah-${BODY}"
SCRIPT="$HOME/.local/bin/${REMOTE_NAME}-start.sh"
SERVICE="$HOME/.config/systemd/user/${REMOTE_NAME}.service"

if [ "$DRYRUN" = yes ]; then
  printf 'SESSION=%s\nREMOTE_NAME=%s\nSCRIPT=%s\nSERVICE=%s\n' "$SESSION" "$REMOTE_NAME" "$SCRIPT" "$SERVICE"
  exit 0
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-new-session-names.sh`
Expected: `new-session names: pass=4 fail=0`.

- [ ] **Step 5: Update `--help` and the final confirm echo**

In the help heredoc (lines ~13-38) replace the four naming lines and add `--alias`:

```
                        tmux session:    ah_<MMDD-HHMM>-<alias>
                        remote-control:  ah-<MMDD-HHMM>-<alias>
                        start script:    ~/.local/bin/ah-<MMDD-HHMM>-<alias>-start.sh
                        systemd service: ~/.config/systemd/user/ah-<MMDD-HHMM>-<alias>.service
```
and under Options add:
```
  -a, --alias <x>     Short alias for the session name (persisted per folder).
  --dry-run           Print the resolved names and exit without spawning.
```

The confirm block (lines ~183-186) needs no structural change — it already echoes `${REMOTE_NAME}`.

- [ ] **Step 6: Verify syntax + commit**

Run: `bash -n scripts/new-session.sh && bash tests/test-new-session-names.sh`
Expected: no syntax error; `pass=4 fail=0`.

```bash
git add scripts/new-session.sh tests/test-new-session-names.sh
git commit -m "feat(session): ID-first ah- names + --alias/--dry-run in new-session

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01T6svu6TeVndTRkNdvJuDev"
```

---

## Task 3: `session-doctor.sh` — dual-prefix helpers, scoped reap, source-guard

**Files:**
- Modify: `scripts/session-doctor.sh` (helpers near line ~36; enumeration lines 57 & 103; reap loop 1 lines ~95-101; dispatch `case` line ~48)
- Test: `tests/test-session-doctor.sh`

**Interfaces:**
- Produces: `tmux_to_base <tmux-name>` → `agenthost-…`/`ah-…` or `""` if not ours. `svc_to_tmux <base>` → `agenthost_…`/`ah_…`. Dispatch runs only when executed directly (source-guarded) so tests can source the helpers.

- [ ] **Step 1: Write the failing test**

Create `tests/test-session-doctor.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1090
source "$HERE/../scripts/session-doctor.sh"   # must NOT run report (source-guard)
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — got '$2' want '$3'"; fi; }

ok "legacy tmux->base" "$(tmux_to_base agenthost_foo-20260101-0900)" "agenthost-foo-20260101-0900"
ok "new tmux->base"    "$(tmux_to_base ah_0101-0900-foo)"            "ah-0101-0900-foo"
ok "foreign tmux->base" "$(tmux_to_base codexhost_x)"               ""
ok "legacy svc->tmux"  "$(svc_to_tmux agenthost-foo-20260101-0900)" "agenthost_foo-20260101-0900"
ok "new svc->tmux"     "$(svc_to_tmux ah-0101-0900-foo)"            "ah_0101-0900-foo"

echo "session-doctor: pass=$pass fail=$fail"; [ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-session-doctor.sh`
Expected: FAIL — either the report runs on source (no guard) or `tmux_to_base` is undefined.

- [ ] **Step 3: Add helpers + source-guard, update enumeration + reap**

In `scripts/session-doctor.sh`, add after the `proc_alive` function (~line 46):

```bash
# Prefix mapping. `agenthost`/`ah` are the only prefixes we own; anything else
# (e.g. codexhost_) is NOT ours and must be left alone. PROTECT (line ~22) stays
# in sync with session-alias.sh.
tmux_to_base() { case "$1" in agenthost_*) echo "agenthost-${1#agenthost_}";; ah_*) echo "ah-${1#ah_}";; *) echo "";; esac; }
svc_to_tmux()  { case "$1" in agenthost-*) echo "agenthost_${1#agenthost-}";; ah-*) echo "ah_${1#ah-}";; *) echo "$1";; esac; }
```

Change both unit-enumeration greps (lines 57 and 103) from `'^agenthost-.*\.service$'` to `-E '^(agenthost|ah)-.*\.service$'`.

Change the two report/reap orphan-unit mappings (lines 58 and 105) from
`base="${u%.service}"; tm="agenthost_${base#agenthost-}"` to
`base="${u%.service}"; tm="$(svc_to_tmux "$base")"`.

Replace reap loop 1 body (lines ~95-101) to scope to our prefixes and derive via helper:

```bash
    for s in $(live_tmux); do
      echo "$s" | grep -qiE "$PROTECT" && continue
      base="$(tmux_to_base "$s")"; [ -z "$base" ] && continue   # not ours (e.g. codexhost_) → leave it
      proc_alive "$s" && continue                                # alive → keep
      echo "DEAD tmux (no claude proc): $s"
      do_reap "$s" "${base}.service" "${base}-start.sh"
      reaped=$((reaped+1))
    done
```

Wrap the dispatch `case "$MODE" in … esac` (lines ~48-135) so it only runs when executed directly:

```bash
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
case "$MODE" in
  # … existing report / reap-local / registry-stale / *) cases unchanged …
esac
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-session-doctor.sh`
Expected: `session-doctor: pass=5 fail=0`.

- [ ] **Step 5: Verify behavior against live sessions (both prefixes)**

Run: `bash scripts/session-doctor.sh reap-local`  (dry-run)
Expected: still lists the live `agenthost_*` sessions' status; the `codexhost_*` dead session is **no longer** reported (now correctly out of scope). No `ah_*` yet.

- [ ] **Step 6: Commit**

```bash
git add scripts/session-doctor.sh tests/test-session-doctor.sh
git commit -m "feat(session-doctor): match both agenthost and ah prefixes; scope reap to our sessions

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01T6svu6TeVndTRkNdvJuDev"
```

---

## Task 4: Documentation

**Files:**
- Modify: `references/fallback-recipe.md`, `SKILL.md`, `README.md`, `references/session-lifecycle.md`

**Interfaces:** none (docs). Verification is grep-based.

- [ ] **Step 1: `references/fallback-recipe.md`** — change `DATE=$(date +%Y%m%d-%H%M)` / `SESSION=…`/`REMOTE_NAME=…` to the new scheme, with a one-line store lookup instead of the full resolver:

```bash
ID=$(date +%m%d-%H%M)
ALIAS=$(awk -F'\t' -v f="$FOLDERNAME" '$1==f{print $2}' /home/agents/.claude/session-aliases 2>/dev/null)
[ -n "$ALIAS" ] || ALIAS=$(printf '%s' "$FOLDERNAME" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//')
SESSION="ah_${ID}-${ALIAS}"
REMOTE_NAME="ah-${ID}-${ALIAS}"
```
Add a comment: `# Emergency path: store lookup only (no acronym/inference); may differ from new-session for an un-stored long folder.`

- [ ] **Step 2: `SKILL.md`** — update the Naming Convention block (lines 17-22) to the new scheme; add a "Alias" subsection documenting `--alias`, the store at `~/.claude/session-aliases`, and that protected folders are never aliased; update the "look for `agenthost-…`" line (70).

- [ ] **Step 3: `README.md`** — update the naming table (lines 72-75) and the two example lines (58, 79) to `ah-<MMDD-HHMM>-<alias>`; add a one-line `--alias` example under "Use the script directly".

- [ ] **Step 4: `references/session-lifecycle.md`** — change unit glob mentions `agenthost-*.service` (lines 10, and the layer table) to `agenthost-*/ah-*`; add a sentence that `session-doctor` matches both prefixes during the transition.

- [ ] **Step 5: Verify + commit**

Run: `grep -rn "agenthost-<foldername>-<YYYYMMDD" SKILL.md README.md || echo "no stale naming refs"`
Expected: `no stale naming refs`.

```bash
git add references/fallback-recipe.md SKILL.md README.md references/session-lifecycle.md
git commit -m "docs(session): document ID-first ah- names, --alias, dual-prefix reaping

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01T6svu6TeVndTRkNdvJuDev"
```

---

## Task 5: Deploy, provision live seed, end-to-end verify

**Files:** none in repo (deployment + verification). Uses the local seed at
`scratchpad/session-aliases.live-seed.txt` (provided out-of-band; NOT committed).

**Interfaces:** consumes all prior tasks.

- [ ] **Step 1: Syntax + full test suite**

Run: `for f in scripts/new-session.sh scripts/session-doctor.sh scripts/session-alias.sh; do bash -n "$f"; done && for t in tests/test-*.sh; do bash "$t" || exit 1; done`
Expected: all tests `fail=0`.

- [ ] **Step 2: Provision the live alias store (if absent)**

Run:
```bash
[ -f ~/.claude/session-aliases ] || cp "$SCRATCH/session-aliases.live-seed.txt" ~/.claude/session-aliases
awk -F'\t' 'NF==2 && $1!~/^#/' ~/.claude/session-aliases | wc -l
```
Expected: ≥6 seed rows; existing file left untouched if already present.
(`$SCRATCH` = this session's scratchpad dir.)

- [ ] **Step 3: Deploy helpers to `~/.local/bin` (manual copy — established path)**

Run:
```bash
cp scripts/session-alias.sh   ~/.local/bin/session-alias
cp scripts/new-session.sh     ~/.local/bin/new-session
cp scripts/session-doctor.sh  ~/.local/bin/session-doctor
chmod 755 ~/.local/bin/session-alias ~/.local/bin/new-session ~/.local/bin/session-doctor
for f in session-alias new-session session-doctor; do
  cmp -s "scripts/$f.sh" ~/.local/bin/$f && echo "OK $f" || echo "MISMATCH $f"
done
```
Expected: three `OK` lines.

- [ ] **Step 4: End-to-end — spawn a real test session under the new scheme**

Run: `new-session ns-selftest sessions`
Then verify:
```bash
tmux ls | grep -E 'ah_[0-9]{4}-[0-9]{4}-ns-selftest'                      # host tmux exists
ls ~/.config/systemd/user/ah-*-ns-selftest.service                        # unit exists
sleep 20 && session-doctor report | grep -E 'ah_.*ns-selftest'           # doctor sees new AND lists live agenthost_*
```
Confirm registry registration via the API (agents can't see the app UI):
```bash
tok=$(python3 -c "import json;print(json.load(open('$HOME/.claude/.credentials.json'))['claudeAiOauth']['accessToken'])")
org=$(python3 -c "import json;print(json.load(open('$HOME/.claude.json')).get('oauthAccount',{}).get('organizationUuid',''))")
curl -s https://api.anthropic.com/v1/sessions -H "Authorization: Bearer $tok" -H "x-organization-uuid: $org" \
  -H "anthropic-version: 2023-06-01" -H "anthropic-beta: ccr-byoc-2025-07-29" | grep -o 'ns-selftest' | head -1
```
Expected: tmux + unit present; `session-doctor report` shows the new `ah_` session and still the live `agenthost_*` ones; registry contains `ns-selftest`.

- [ ] **Step 5: Protected-folder safety check**

Run:
```bash
for p in openclaw-x claude-remote-y hermes-z; do
  a=$(session-alias "$p"); echo "$p -> ah-0000-0000-$a" | grep -E 'openclaw|claude-remote|hermes' >/dev/null && echo "PROTECT-OK $p" || echo "PROTECT-FAIL $p"
done
```
Expected: three `PROTECT-OK` lines (the protected token survives in the name).

- [ ] **Step 6: Reap the test session + confirm cleanup**

Run:
```bash
sd=$(tmux ls | grep -oE 'ah_[0-9]{4}-[0-9]{4}-ns-selftest' | head -1)
systemctl --user disable --now "ah-${sd#ah_}.service"
tmux kill-session -t "$sd" 2>/dev/null
rm -f ~/.local/bin/ah-${sd#ah_}-start.sh
session-doctor reap-local     # dry-run; confirm nothing of ours dangling
```
Expected: test unit/tmux gone; `reap-local` clean.

- [ ] **Step 7: Final commit (if any deploy scripts/docs changed) + report**

No repo changes in this task beyond what earlier tasks committed. Report deployed md5sums and the E2E result to the user.

---

## Notes / deliberate deviations from the spec

- **Alias logic lives in a standalone `session-alias` helper**, not inline in `new-session.sh`. Rationale: mirrors the existing `session-git-prep` helper pattern (PATH lookup + graceful fallback), and makes the resolver unit-testable in isolation. `new-session` still self-contains a fallback for when the helper is absent.
- **Seed is provisioned at deploy time** (Task 5, from a local file), not runtime-copied from the repo `.example`. Rationale: the repo is not guaranteed present at a known path on the host at spawn time; the helper auto-creates the store on first write, and deploy seeds the known aliases. The committed `.example` documents the format.
- These do not change any spec-defined behavior or name format; they are implementation-structure choices.
