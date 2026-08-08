# Massaging a raw task into a handoff prompt

A handoff prompt is **self-contained**: the target session — which has *none* of your
context or conversation — can act on it without coming back to you for clarification.

It IS the six parts below, in order. This is a **contract of ingredients, not a fill-in
template**: every part is present, but how you weight and phrase each is judgment for the
specific task and its domain. A rigid template would strip the context-awareness that
makes a good handoff good; the point of listing the parts is that none silently go missing.

## The parts

1. **Goal** — one sentence naming what "done" looks like: the *outcome*, not the activity.
   - activity: "survey the tranche candidates"
   - goal: "a ranked go/no-go shortlist of $25k tranche-1 candidates, in `memory/tranche1-survey.md`"

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
   rule for the target's role.

## Weighting by domain

- **Research / survey** → lean on #3 (verify-don't-assume); its main failure is confident
  action on stale inputs.
- **Execution-capable** (trading, deploys, anything with side effects) → put #5 (guardrails)
  *first*, above the steps — the gate must be the first thing the target reads.
- **Build / code** → sharpen #4 (which branch, PR vs direct commit, tests required).

## Genericized examples (shape only — fill with real context)

**Research/survey (portfolio-ssot tranche):**
```
Goal: a go/no-go shortlist of tranche-1 candidates -> memory/tranche1-survey.md.
Steps: 1) pull the current candidate set from <source>; 2) score each on <criteria>;
       3) write the shortlist with one-line rationale each.
Known state (VERIFY, don't assume): I think X/Y/Z are live candidates — confirm against
       <source> first; this list may be stale.
Deliverable: memory/tranche1-survey.md + a one-paragraph summary back to me.
Guardrail: WATCH-only. No orders. Execution needs EXECUTION_APPROVED_HUMAN=1 in this session.
Scope: this repo only; do not touch other portfolio sessions.
```

**Build (eth2-quickstart GEO/AEO):**
```
Goal: <one-sentence outcome, e.g. "GEO/AEO metadata landed for the quickstart docs">.
Steps: 1) ...; 2) ...; 3) ...
Known state (VERIFY): <current-state notes, each marked confirm-before-use>.
Deliverable: a PR against main (never push to main directly).
Scope: this repo; don't touch sibling sessions.
```

## Self-check before you send

- [ ] Goal is an outcome, not an activity.
- [ ] Every relayed fact that could be stale is marked "verify, don't assume".
- [ ] Deliverable names an exact destination.
- [ ] Every domain guardrail the target's peers enforce is restated (or flagged if uncertain).
- [ ] Scope says what NOT to touch.
