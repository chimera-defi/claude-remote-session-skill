# CAMPAIGN_CHECKPOINT.md — the durable handoff for a long-lived owner

A campaign or lane owner keeps one `CAMPAIGN_CHECKPOINT.md` (≤60 lines) in its campaign
folder. Together with git and receipts, it is the state of record. The transcript is not.
A fresh owner, or the same owner after compaction or `session-resume`, reads it first and
runs `next_action`.

Update it at each checkpoint:
- a finished step or a decision;
- before pausing, including on a quota/429 error (put the exact error text in `paused_reason`);
- when context nears the compaction window;
- before handing the lane to another session.

On a coordination bus, post only a pointer to the file: `{task_id, path, sha, state}`.
Never post its contents.

```yaml
campaign: <TASK_ID>
finish_line: "<checkable done: PR merged + CI green, file at path X, ...>"   # required
owner: {session: <tmux-session>, model: <model that actually ran>, ctx_at_checkpoint: 0, calls: 0}
launcher: <launcher session name>          # where operator questions go
state: running            # running | paused | review | landed
paused_reason: null       # or "<exact error text>"
steps:
  - {id: 1, what: "...", status: todo, evidence: "<path|sha>"}   # status: done | todo
decisions_made:
  - {what: "...", why: "...", reversible: true}
open_for_operator:
  - {n: 1, item: "...", recommended: "..."}
unverified: ["..."]
artifacts:
  - {path: "...", sha: "..."}
budgets: {ctx_cap: 200000, builder_turns: 250}   # ctx_cap ~ where auto-compaction fires
models_ran:                # one row per piece of work, recording the model that actually ran
  - {piece: "...", model: "..."}
bus_pointer: {task_id: "...", last_msg_id: 0}
next_action: "<one line a fresh owner executes first>"
```

Rules:
- Use evidence fields for paths and shas, not prose. A fresh owner re-reads only the files it names,
  so keep that set small.
- `models_ran` holds what actually ran, not what was planned. A fallback (GPT → Sonnet, etc.) gets
  its own row.
- For builder work, record the Codex-first attempt and any Sonnet fallback as separate rows. Include
  one-shot consults too (`hub-opus-consult`, `advisor`, reviewer, etc.) so later owners can see which
  judgment path actually contributed to the decision.
- On a **Claude** 429 or spend-limit error, set `state: paused` and stop there. Send the exact error
  to the launcher and spawn no fallback Claude model (Sonnet, Fable and Opus drain the same cap).
  If a *different* provider is exhausted (e.g. GPT), falling back to a Sonnet builder is fine
  while Claude still has headroom.
