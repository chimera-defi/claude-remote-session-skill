# jev-delegate

A stdlib-only Python 3 wrapper for TypeSafe System One (the Jev model family).
There is no official Jev CLI: TypeSafe ships Python/JS SDKs. Several third-party
`jev-cli` projects exist and are unvetted; this wrapper deliberately uses `urllib`.

## Fit and evidence

Our eval of **jev-1.13.0, 2026-09-28** measured hosted p50 **250 ms** (p95
310 ms), versus Claude Haiku via `claude -p` p50 **2.5 s**; **$0.0165 per
1,000 decisions**, versus Haiku approximately **$0.98**. Pooled accuracy was
**80.5% versus 81.6%** (N=261, statistically indistinguishable).
**jev-1.14.0 is the pinned default and is UNTESTED on our sets.**

Weak spots: ordinal score questions; PR change-type / needs-redeploy triage
(at majority baseline, with hosted redeploy biased to “no” on 20/24); and no
native abstention. Jev always returns a distribution and was confidently wrong
on 5/13 not-offered items. The case is latency, cost, and keeping bulk triage
out of an orchestrator's context, rather than higher accuracy.

Every choice question must offer an explicit **none/unclear** option. Prefer
choice/noul over score. Use `--min-confidence` and escalate exits **5 or 3** to
an existing Haiku lane or the orchestrator. Top probability is a routing signal,
not proof that a decision is correct.

## Data rules

Self-serve keys have **standard retention**; zero retention is enterprise-only.
Send only synthetic, public, or session-tooling text. Never send credentials,
private memory notes, brokerage/portfolio data, or anything from a `private/`
directory. Redact session text before invoking the wrapper. The secret scanner
is a backstop, not a licence to send sensitive material.

Before sending (including dry-run), the wrapper scans the serialized body for
private-key headers, sk/GitHub/Slack/AWS/JWT token shapes, and the literal API key.
Refusals name the pattern class without echoing its match.
`--allow-unscanned` skips scanning **for synthetic data only**. Key values are
still redacted from output, including vendor errors that echo a credential;
otherwise HTTP status and body are preserved verbatim, up to 2,000 characters.

## Delegation slots

These are candidate slots; this change wires none into session tools.

| Slot | Question shape | Data class | Gate/escalation | Expected saving | Status |
|---|---|---|---|---|---|
| Session-state classification for ambiguous session-doctor/fleet-status cases: working / waiting_input / idle_done / error_loop / quota_or_auth_blocked / unclear | choice + noul needs_human | Redacted session pane tail | <0.9 → existing heuristic/Haiku | ~10x latency, ~60x cost versus a Haiku read | First pilot; check against live sessions before wiring into any tool |
| Lane routing: codex build / haiku read-only / grok second-opinion / devin browser-sandbox / orchestrator-decides / unclear | choice | Task brief text | <0.85 → orchestrator | Saves an orchestrator turn per dispatch | Shadow mode first: log versus actual choice |
| Coordination-bus message triage: kind, needs_operator, urgency buckets | choice + noul; urgency as choice, never score | Bus summaries from tooling lanes only | <0.9 → leave unsorted | Faster inbox sort | Shadow |
| Memory dedup: duplicate / supersedes / related / distinct / unclear | choice per pair; many pairs per call | New note versus top-k hits, PUBLIC/shared namespaces only | <0.9 → keep both, human/agent review | Cuts dedup reads | Pilot |
| Durable-lesson detection before compaction | is_durable_lesson noul + category choice | Redacted tool-session transcript snippets only | <0.8 → keep | Cheaper than a Haiku pass | Proposed |
| PR body claim versus diff: does the diff support claim X? | noul per claim | Public repo diffs | <0.9 or “no” → flag for reviewer, never block | Adds a cheap check | Shadow |
| Review-finding dedup / severity bucket | choice | Review text from public repos | <0.85 → keep separate | Fewer duplicate findings | Proposed |
| Skill suggestion: which skill applies / none | choice | Prompt text only where prompts carry no private data | <0.9 → no suggestion | 250 ms fits a hook budget | Proposed, opt-in |

Not recommended: PR change-type / needs-redeploy triage (eval at majority
baseline); any trading, broker, crypto, or execution decision; any enforcing
gate (shadow only).

At fleet volume (hundreds to low thousands of decisions/day), dollar saving
versus Haiku is roughly **$1/day**. The real wins are approximately **2 s less
latency per decision** and avoiding Claude quota/context use.

## Usage

Run `python3 scripts/jev-delegate.py` (or the executable directly) in this checkout.
Flag mode names its single question `q`. Choice options are comma-separated
`name=description` entries; an empty description becomes JSON null. Score options
are an ordered comma-separated list of 1–10 descriptions. Use JSON mode when
names/descriptions contain commas or when sending several questions.

```bash
python3 scripts/jev-delegate.py --state 'Synthetic pane: ready for input' \
  --question choice --instructions 'Classify the pane state' \
  --options 'working=Running,waiting_input=Needs input,unclear=Cannot tell' \
  --min-confidence 0.9

printf '%s' 'Synthetic pane: waiting' | python3 scripts/jev-delegate.py \
  --state - --question noul --instructions 'Does this need human input?' \
  --min-confidence 0.9

python3 scripts/jev-delegate.py --state-file synthetic.txt \
  --question score --instructions 'Rate completeness' --options 'missing,partial,complete'

python3 scripts/jev-delegate.py --request-json card.json --min-confidence 0.9
python3 scripts/jev-delegate.py --request-json card.json --dry-run
python3 scripts/jev-delegate.py --check
```

`--request-json PATH|-` accepts a full card **without model**, with text or object
state and one or more questions. For example:

```json
{"state":"Synthetic pane: waiting","questions":{"state":{"type":"choice","instructions":"Classify","criteria":{"waiting":"Needs input","unclear":null}},"human":{"type":"noul","instructions":"Needs human input?","criteria":{"true":"Intervention needed","false":"No intervention"}}}}
```

`--model` overrides `JEV_MODEL`; the default is pinned `jev-1.14.0`, never
`jev-latest`. `--timeout S` defaults to 15 seconds. `--max-state-bytes N`
defaults to 200000: raw UTF-8 bytes for text state, serialized UTF-8 bytes for
object state. API limits remain 64k tokens/request and 32k/question; bytes are
not tokens. `--dry-run` validates and prints the request body without network
or a ledger entry; a configured key is required to scan for its literal value.
`--check` only GETs `/v1/models`, returning `{"ok":true,"models":["…"]}`.

A successful inference prints one JSON object containing `model`, `answers`,
`usage`, `cost_usd`, and `latency_ms`. Input costs **$0.042/million tokens**;
output is free. With `--min-confidence X`, every answer gains `top_probability`
and `abstain`; the threshold compares the maximum distribution probability
(noul: `max(p,1-p)`), independently of the vendor's `confidence` field.

| Exit | Meaning |
|---|---|
| 0 | Success, check, or dry-run |
| 2 | Invalid input, state too large, or secret scanner refusal |
| 3 | Network/HTTP/timeout, unavailable key, ledger failure, or daily cap; caller may fall back to Haiku |
| 4 | Unparseable/invalid response or missing question |
| 5 | At least one answer below `--min-confidence`; JSON includes abstention flags |

Errors go to stderr. HTTP errors preserve exact status and response body
(truncated to 2,000 characters, credential redaction excepted); 402 additionally
explains that a console balance is not proof of API credit. Nothing retries.
Redirects are refused to avoid forwarding credentials.

| Environment variable | Meaning/default |
|---|---|
| `TYPESAFE_API_KEY` | First key source when set; whitespace stripped |
| `TYPESAFE_API_KEY_FILE` | Otherwise read this file; default `${XDG_CONFIG_HOME:-$HOME/.config}/typesafe/api_key` |
| `XDG_CONFIG_HOME` | Config root; otherwise `$HOME/.config` |
| `JEV_API_BASE` | Default `https://api.typesafe.ai`; loopback override for tests |
| `JEV_MODEL` | Default model override; CLI `--model` wins |
| `JEV_LEDGER` | Override ledger path |
| `XDG_STATE_HOME` | Ledger root; default `$HOME/.local/state` |
| `JEV_DAILY_CAP_USD` | Default `0.50`; refuse before sending when today's recorded cost is at least this value |

The default ledger is `${XDG_STATE_HOME:-$HOME/.local/state}/jev-delegate/ledger.jsonl`.
Each real call, including checks and failures, appends `ts` (UTC), `model`,
`input_tokens`, `cost_usd`, `latency_ms`, and `exit`. No state text or key is
recorded. Unknown usage on failed calls records zero; the ledger is local
accounting, not a billing reconciliation. The cap sums UTC-day recorded cost;
it cannot reserve the unknown cost of the next call or coordinate concurrent
processes. Unreadable or malformed ledger data refuses calls.
