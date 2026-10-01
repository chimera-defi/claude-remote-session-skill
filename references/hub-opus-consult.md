# Hub Opus Consult

`CLAUDE_SESSION_PROFILE=hub` is a long-lived Sonnet owner/hub profile. It keeps the full
tool set, including native `advisor`, and adds a short system contract telling the hub when
to ask Opus for a one-shot second opinion.

## When to Consult

Consult Opus only at real forks:

- before destructive or irreversible action;
- when a design choice is genuinely ambiguous after normal investigation;
- before declaring a multi-step task done.

Do not use Opus or Fable as a polling, waiting, monitoring, or resident session. The hub
does the resident work on Sonnet; Opus is a bounded advisor at forks.

## Protocol

1. Write a frozen packet first, normally at `.claude/hub-opus-frozen-packet.md` in the run
   directory.
2. Spawn a one-shot subagent with the Agent tool and `model: "opus"`.
3. Give the subagent only the packet path and the packet contents. Never forward the
   transcript.
4. Treat the consult as advice. The Sonnet hub owns the final decision and records what ran
   in `models_ran`.

## Frozen Packet Template

```markdown
# Hub Opus Frozen Packet

State:
- ...

Options:
- A: ...
- B: ...

Hub recommendation:
- ...

UNVERIFIED:
- ...

Relevant file paths:
- `path/to/file`

Question for Opus:
- Choose between the options, name missing evidence, or identify the blocking flaw.
```

## Cost Rationale

Sonnet is the resident hub because it keeps the native `advisor`, has the full owner-class
tool surface, and costs less for long-running coordination. Opus is reserved for bounded
consults where its judgment is most useful. Builders stay Codex-first (`new-session
--backend codex` or `codex exec`), then Sonnet fallback when Codex cannot handle the work.

## Cross-check ordering

Per the host second-opinion ruling (2026-10-02): Opus first, then a GPT-5.5 cross-check via
`codex exec` on the same packet, Fable last and only if the two disagree or the call is
irreversible. Never close a fork on one model family alone.
