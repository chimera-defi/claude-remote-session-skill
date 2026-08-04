# Design: `/handoff` skill for launcher sessions

**Date:** 2026-08-04
**Repo:** claude-remote-session-skill (session-tooling family)
**Requested by:** chimera_defi via session-launcher

## Problem

A launcher session (e.g. `session-launcher-0718`) repeatedly performs the same manual
workflow: take a terse human task, pick/spawn a target session, verify it's healthy,
**massage** the raw request into a structured self-contained prompt, relay it into the
target's live pane, verify it landed, and report back. Steps 2–6 are re-hand-rolled every
time. `/handoff` codifies them so a launcher invokes one skill instead.

## The hard constraint (from the requester)

Step 4 — massaging — is judgment. A rigid fill-in template would lose the context-awareness
that made the manual versions good. So: **script the mechanics, guide the judgment.** And
the two failure modes seen live must not recur:
- **Dropped guardrails** — domain governance already established (e.g. the WATCH-only /
  `EXECUTION_APPROVED_HUMAN` gate every portfolio session enforces) gets silently lost in a
  naive relay. Must be carried forward.
- **Assumed-stale context** — a candidate list / known-state relayed as fact when it may be
  out of date. Must be relayed as "verify, don't assume."

## Scripted vs LLM split

| Step | Owner | Rationale |
|------|-------|-----------|
| 2 discover/spawn target | `session-handoff targets` + `new-session` (script); **routing choice** (LLM) | enumeration is deterministic; *which/whether* is judgment |
| 3 verify healthy | `session-handoff check <s>` (script) | pure mechanics: unit active, pane ready, model |
| 4 **massage** | **LLM**, guided by `references/massaging.md` contract | inherently context-dependent |
| 5 relay + confirm landed | `session-handoff send <s> <msg>` (script) | the finicky send-keys/Enter/verify-it-started dance |
| 6 report | **LLM** | summarize + flag guardrails |

Spawning defers to `new-session` (already has anti-poisoning + model-pin warning). Handoff
spawns default to **Opus** unless the task names a model (launcher work is orchestration-
heavy). `send`'s verify-landed reuses `new-session`'s proven kickoff-retry pattern.

## Components

- **`scripts/session-handoff.sh`** → `~/.local/bin/session-handoff` (like the other helpers):
  - `targets` — list live `ah_*`/`agenthost_*` sessions with health + model (routing input).
  - `check <tmux-session>` — one target's health: exists, unit active, pane ready/busy/dead,
    model; exit code + one human line.
  - `send <tmux-session> (<msg> | --file <f>)` — verify ready → `send-keys -l` → Enter →
    confirm the input cleared / the session started working, retrying Enter if buffered →
    report `landed` vs `unverified`.
- **`handoff/SKILL.md`** → `~/.claude/skills/handoff/` (symlink): the LLM workflow (steps
  2–6), invoked by `/handoff`.
- **`handoff/references/massaging.md`**: the massaging **contract** — the parts a good
  handoff prompt contains, in order, expressed as what the output IS (a recipe, not a
  prohibition list, per writing-skills "match the form to the failure"). Includes the
  guardrail-carry-forward and verify-don't-assume requirements as structural slots, plus
  genericized examples from the live cases.
- **`tests/test-session-handoff.sh`**: plain-bash tests for the deterministic logic
  (arg parsing, target parsing, landed-detection against captured-pane fixtures).

## Massaging contract (what a handoff prompt IS — filled by judgment)

1. **Goal** — one sentence; what "done" looks like.
2. **Numbered steps** — concrete, ordered.
3. **Known state to VERIFY, not assume** — context you hold, each item marked with how to
   confirm it and that it may be stale.
4. **Deliverable** — what to produce and where (file / PR / memory / report-back).
5. **Carry-forward guardrails** — restate domain governance already in force; never drop.
6. **Scope boundaries** — what NOT to touch.

Guidance weights these per domain (a survey leans on #3; an execution task leads with #5).

## Safety / scope

- `send` is the only outward action; it targets exactly the named pane, verifies before and
  after, and never touches other sessions.
- `/handoff` inherits the launcher's bounded scope (create/route/relay/monitor — not do the
  target's project work itself).
- Report always surfaces preserved guardrails so the human can veto ("flag if you want it
  dropped").

## Out of scope (separate follow-up)

`registry-reap` / `worktree-prune` (session-doctor maintenance for the nightly) — different
domain, its own PR.
