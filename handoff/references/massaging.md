# Massaging a raw task into a handoff prompt

A handoff prompt is **self-contained**: the target session — which has *none* of your
context or conversation — can act on it without coming back to you for clarification.

It IS the seven parts below, in order. This is a **contract of ingredients, not a fill-in
template**: every part is present, but how you weight and phrase each is judgment for the
specific task and its domain. A rigid template would strip the context-awareness that
makes a good handoff good; the point of listing the parts is that none silently go missing.

## The parts

1. **Goal** — one sentence naming the finish line: the *outcome*, not the activity. The
   target works unattended for a long stretch; knowing exactly what "done" looks like is
   what keeps it on course instead of stopping early or wandering.
   - activity: "survey the tranche candidates"
   - goal: "a ranked go/no-go shortlist of $25k tranche-1 candidates, in `memory/tranche1-survey.md`"
   - activity: "fix the compaction bug" → goal: "`session-compact` no longer re-compacts an
     idle low-context session; PR merged with `shell-tests` green; redeployed to `~/.local/bin`"

2. **Numbered steps** — the concrete path, ordered. Enough that the target doesn't have to
   reverse-engineer your intent; not so prescriptive that you're doing its thinking for it.

3. **Known state — to VERIFY, not assume.** Everything you hold that helps, each item tagged
   with how current it is and how to confirm it. *Failure this prevents:* the target treats
   your relayed list as ground truth and builds on stale data.
   > "Candidate lineages I believe are in play: A, B, C — **this list may be out of date;
   > confirm against `<source>` before relying on it.**"

4. **Deliverable** — what to produce and *exactly where it goes*: a file path, a PR (against
   which branch), a memory entry, a report back to the launcher. Ambiguous deliverables come
   back in the wrong shape.

5. **Carried-forward guardrails.** Before sending, ask: *what governance do this target's
   peers already enforce in this domain?* Restate it explicitly in the prompt — a relay must
   never silently drop it. If unsure whether a guardrail applies, **include it and flag it to
   the human** rather than omitting it.
   > (portfolio domain) "This is **WATCH-only**. Do NOT place or execute any order. Execution
   > requires an explicit `EXECUTION_APPROVED_HUMAN=1` from chimera_defi **in this session**."

6. **Scope boundaries** — what NOT to touch (other sessions, other repos) and any bounded-scope
   rule for the target's role. Name the concrete anti-patterns for this domain ("don't
   branch from local `main`", "don't reap sessions you didn't spawn") — a named habit gets
   avoided; "be careful" does not.

7. **Stop rule** — when to keep going and when to stop and ask. Without one, the target
   either stalls asking permission for routine steps or barrels through a destructive one.
   Default wording, adjust per task:
   > "When a step doesn't need me, keep going — put status in the same message as your next
   > action. Stop and ask only if you can't continue without a decision from me, or before
   > anything destructive: deleting data, force-pushing, or changing anything outside this
   > repo."

Don't add "think carefully", "think step by step", or "ultrathink". Current Claude models
decide how much to think on their own; those lines add length, not quality. Spend the words
on the finish line and the anti-patterns instead.

## Weighting by domain

- **Research / survey** → lean on #3 (verify-don't-assume); its main failure is confident
  action on stale inputs. Also ask it to **mark anything it couldn't confirm and say where it
  looked**, so the confidence boundary is visible in the deliverable.
- **Execution-capable** (trading, deploys, anything with side effects) → put #5 (guardrails)
  *first*, above the steps — the gate must be the first thing the target reads.
- **Build / code** → sharpen #4 (which branch, PR vs direct commit, tests required). Ask it to
  **pre-review its own diff before opening the PR**: list only merge-blocking problems, each
  with file and line, why it's wrong, and how to show it fails.
- **Large audit / migration** (many files, services, or sessions) → tell it to give each
  slice its own subagent (`subagent_type: builder` or `model: "sonnet"`, so it keeps
  `advisor`) and to **check each subagent's evidence before accepting its report** —
  re-run the cited command, open the cited line. Results consolidated in one table.

## Long runs

If the task will take hours, span several PRs, or likely outlive one context window, add:

> "Keep a TASKS.md checklist (in your worktree or scratchpad, not committed) with the finish
> line at the top and one line per step. Update it as you go, and re-read it after any
> compaction before acting."

Summaries of a compacted transcript drop detail; a file on disk doesn't.

## Genericized examples (shape only — fill with real context)

**Research/survey (portfolio-ssot tranche):**
```
Goal: a go/no-go shortlist of tranche-1 candidates -> memory/tranche1-survey.md.
Steps: 1) pull the current candidate set from <source>; 2) score each on <criteria>;
       3) write the shortlist with one-line rationale each.
Known state (VERIFY, don't assume): I think X/Y/Z are live candidates — confirm against
       <source> first; this list may be stale.
Deliverable: memory/tranche1-survey.md + a one-paragraph summary back to me. Mark any
       candidate you couldn't confirm, and say where you looked.
Guardrail: WATCH-only. No orders. Execution needs EXECUTION_APPROVED_HUMAN=1 in this session.
Scope: this repo only; do not touch other portfolio sessions.
Stop rule: keep going through the survey; stop and ask only if <source> is unreachable.
```

**Build (eth2-quickstart GEO/AEO):**
```
Goal: <one-sentence outcome, e.g. "GEO/AEO metadata landed for the quickstart docs:
       PR merged, CI green">.
Steps: 1) ...; 2) ...; 3) pre-review your diff (blockers only: file:line, why, repro);
       4) open the PR and get CI green.
Known state (VERIFY): <current-state notes, each marked confirm-before-use>.
Deliverable: a PR against main (never push to main directly).
Scope: this repo; don't touch sibling sessions. Don't branch from local main.
Stop rule: keep going; stop and ask only if a test fails for a reason you can't explain,
       or before force-pushing or deleting anything.
```

## Self-check before you send

- [ ] Goal is a finish line (an outcome you can check), not an activity.
- [ ] Every relayed fact that could be stale is marked "verify, don't assume".
- [ ] Deliverable names an exact destination.
- [ ] Every domain guardrail the target's peers enforce is restated (or flagged if uncertain).
- [ ] Scope names what NOT to touch, as concrete anti-patterns rather than "be careful".
- [ ] Stop rule says when to keep going and when to ask.
- [ ] Long run? It asks for a TASKS.md. Audit/migration? It asks for subagents + evidence checks.
- [ ] No "think carefully / step by step" filler.
