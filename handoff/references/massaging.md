# Massaging a raw task into a handoff prompt

A handoff prompt is **self-contained**: the target session, which has none of your context,
can act on it without coming back for clarification.

It IS the seven parts below, in order: a **contract of ingredients, not a fill-in template**.
Every part is present; weighting and phrasing are judgment for the task and domain. For a
ready starting shape per prompt type (orchestrator, Sonnet builder, Fable reviewer, one-shot
handoff) use [`kickoff-templates.md`](kickoff-templates.md).

Before writing, read `$CRSS_HOME/local.md` if it exists (this host's escalation channel,
project guardrail index, delegate routing); otherwise use the generic defaults here and in
`kickoff-templates.md`.

## The parts

1. **Goal**: one sentence naming the finish line, the *outcome* not the activity. The target
   works unattended for a long stretch; a checkable "done" stops it quitting early or wandering.
   - activity: "survey the tranche candidates" -> goal: "a ranked go/no-go shortlist of $25k
     tranche-1 candidates, in `memory/tranche1-survey.md`"
   - activity: "fix the compaction bug" -> goal: "`session-compact` no longer re-compacts an
     idle low-context session; PR merged with `shell-tests` green; redeployed to `~/.local/bin`"

2. **Numbered steps**: the concrete ordered path. Enough that the target needn't reverse-engineer
   your intent; not so prescriptive that you do its thinking.

3. **Known state, to VERIFY not assume.** Everything you hold, each item tagged with how current
   it is and how to confirm it. Prevents the target building on a stale relayed list.
   > "Candidate lineages I believe are in play: A, B, C. **This list may be out of date;
   > confirm against `<source>` before relying on it.**"

4. **Deliverable**: what to produce and *exactly where it goes* (file path, PR against which
   branch, memory entry, report to the launcher). Ambiguity returns the wrong shape.

5. **Carried-forward guardrails.** Ask: what governance do this target's peers already enforce
   in this domain? Restate it; a relay must never silently drop it. If unsure it applies,
   include it and flag it to the human.
   > (destructive domain) "This is **read-only**. Do NOT delete, migrate, or deploy anything.
   > Any write requires an explicit `WRITE_APPROVED_HUMAN=1` from the operator **in this
   > session**."

6. **Scope boundaries**: what NOT to touch (other sessions, other repos) and any role-bound
   limits. Name concrete anti-patterns ("don't branch from local `main`", "don't reap sessions
   you didn't spawn"); a named habit gets avoided, "be careful" does not.

7. **Stop rule**: when to keep going, when to stop and ask, *and through what channel*. Without
   it the target stalls on routine steps or barrels through a destructive one; without a named
   channel an operator-owned question sits in the target's own pane (a stall dressed as
   escalation). Name a real command. Default wording:
   > "When a step doesn't need me, keep going and put status in the same message as your next
   > action. Stop and ask only if you can't continue without a decision from me, or before
   > anything destructive: deleting data, force-pushing, or changing anything outside this repo.
   > Anything genuinely my call goes to me via `session-send <parent-session> --file <f>`, a
   > numbered list with your recommended option. Decide defaults yourself when there's a normal
   > recommended answer; report them afterwards."

Don't add "think carefully", "think step by step", or "ultrathink": current models size their own
thinking, so those lines add length not quality.

## Weighting by domain

- **Research / survey**: lean on #3; the failure is confident action on stale inputs. Ask it to
  mark anything it couldn't confirm and say where it looked.
- **Execution-capable** (trading, deploys, side effects): put #5 *first*, above the steps; the
  gate must be the first thing the target reads.
- **Build / code**: sharpen #4 (branch, PR vs direct commit, tests required). Ask it to
  pre-review its own diff before opening the PR: only merge-blocking problems, each with file
  and line, why it's wrong, and how to show it fails.
- **Large audit / migration**: one subagent per slice (`subagent_type: builder` or
  `model: "sonnet"`, so it keeps `advisor`), each writing large output to a file and returning a
  short summary. Check each subagent's evidence before accepting its report (re-run the cited
  command, open the cited line); consolidate results in one table.
- **Eval / hillclimb** (model, prompt, harness, grader, agent loop): carry the compact add-on from
  [`kickoff-templates.md`](kickoff-templates.md#e-evalhillclimb-campaign-kickoff-add-on) and make
  [`eval-hillclimb-protocol.md`](eval-hillclimb-protocol.md) canonical. Don't paste hidden
  failures; declare budgets, splits, noise, minimum effect, parity tolerance, novelty reserve and
  the machine decision gate up front.

## Long runs

If the task will take hours, span several PRs, or likely outlive one context window, add:

> "Keep a TASKS.md checklist (in your worktree or scratchpad, not committed) with the finish line
> at the top and one line per step. Update it as you go, and re-read it after any compaction
> before acting."

A compacted transcript's summary drops detail; a file on disk doesn't.

## Example shape (fill with real context)

```
Goal: a go/no-go shortlist of tranche-1 candidates -> memory/tranche1-survey.md.
Steps: 1) pull the candidate set from <source>; 2) score each on <criteria>; 3) write the
       shortlist with a one-line rationale each.
Known state (VERIFY, don't assume): I think X/Y/Z are live; confirm against <source>, may be stale.
Deliverable: memory/tranche1-survey.md + a one-paragraph summary to me. Mark any candidate you
       couldn't confirm, and say where you looked.
Guardrail: read-only. No deletes or deploys. Writes need WRITE_APPROVED_HUMAN=1 in this session.
Scope: this repo only; don't touch other project sessions.
Stop rule: keep going; stop and ask only if <source> is unreachable. My-call items go to me via
       `session-send <parent> --file <f>`.
```

## Self-check before you send

Use the pre-send checklist in [`kickoff-templates.md`](kickoff-templates.md#pre-send-checklist);
it covers every item below plus the template-specific ones: goal is a checkable finish line;
stale-able facts marked "verify"; deliverable has an exact destination; peers' guardrails
restated; scope has concrete anti-patterns; stop rule names the real channel; eval campaigns name
the protocol and `scripts/eval-hillclimb-decision.py`; long runs ask for TASKS.md; no
"think carefully" filler.
