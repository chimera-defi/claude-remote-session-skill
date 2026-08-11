# `session-doctor idle-report` — the reusable "candidates to reap" list

`session-doctor.sh idle-report [--days N]` lists **live local** claude
`--remote-control` sessions that have had **no `type:user` transcript activity in
the last N days** (default **N=2** = "today or yesterday"). It exists so this
stops getting hand-rolled ad hoc every time someone wants to clean up idle
sessions — it's the productionized version of a prototype that kept getting
rewritten in sessions-management conversations.

```
session-doctor.sh idle-report            # idle ≥2 days (default)
session-doctor.sh idle-report --days 7   # idle ≥7 days
session-doctor.sh idle-report --days 0   # no threshold — list every live session
```

## Report-only — it never kills (same boundary as `registry-stale`)

Every row is a **still-alive** proc, so `reap-local` deliberately won't touch it
(`reap-local` only removes sessions whose `claude` process is genuinely gone).
`idle-report` produces the candidate list; you act on it in two lanes:

- **dead** sessions → `session-doctor reap-local [--force]`
- **idle-but-alive** sessions → kill by hand:
  `tmux kill-session -t <name>` + `systemctl --user disable --now <name>.service`

Do **not** wire `idle-report` into an auto-kill path — the report/act separation
is the safety property. Rows flagged `[P]` are **protected**
(`claude-remote|openclaw|hermes`) and must never be reaped.

## How it works (the non-obvious bits, verified empirically — don't re-derive)

1. **Enumerate live sessions** with `pgrep -af 'claude.*--remote-control'`, then
   keep only rows whose executable basename is `claude` (or `node`). This filter
   matters: the pattern *also* matches the **tmux launcher** and the **bash
   supervisor loop**, because both carry `claude … --remote-control` in their args.
2. **cwd** per PID from `readlink /proc/<pid>/cwd`.
3. **remote-control name → tmux name** via the script's existing `svc_to_tmux`
   (`ah-X`→`ah_X`, `agenthost-X`→`agenthost_X`; anything else unchanged — so the
   handful of non-`ah`/`agenthost` protected rows show an approximate name, which
   is fine, they're flagged `[P]` anyway).
4. **cwd → transcript dir** `~/.claude/projects/<encoded>`, where
   `encoded = cwd.replace('.', '-').replace('/', '-')`. Confirmed to hold even for
   dotted paths (`/home/agents/.openclaw` → `-home-agents--openclaw`). Not
   documented anywhere in Claude Code — verified by checking the dirs exist.
5. **Idle signal** = max `timestamp` over all `*.jsonl` entries with `type ==
   "user"`. No transcript dir/files, or files with zero `user` entries, both mean
   **"never messaged"** — shown distinctly (`never: no transcript` /
   `never: no user msgs`) because a spawned-but-never-touched session is a
   stronger reap signal than one that merely went quiet after real use. "never"
   rows always appear (they sort first, oldest).

> **`type:user` includes tool-result turns.** In Claude Code transcripts, a tool
> result is delivered as a `type:"user"` message. So a session looping
> autonomously (agent running tools with no human input) counts as **active** and
> stays *off* this list. That's intentional and the safe direction for a
> reap-candidate report: you never want live autonomous work surfaced as a reap
> candidate. If you ever need "no *human* touch in N days" specifically, that's a
> separate, named follow-up — not this tool.

## Sample (`--days 30` on the live host)

```
=== LOCAL: live sessions with NO type:user message in the last 30 day(s) — REPORT ONLY, kills nothing ===
  LAST type:user         PROT  TMUX SESSION                                   CWD
  never: no transcript   [P]   chimera-server                                 /home/agents/.openclaw
  never: no user msgs          ah_compute-nums-0808-2337                      /home/agents/.claude/worktrees/ah-compute-nums-0808-2337
  2026-07-10T05:58:00Z         chimera-server-control-20260710-0757           /home/agents/.sessions/agenthost-sessions
  ...
  --- 6 idle session(s), incl. 1 PROTECTED (never reap). All are ALIVE -> reap-local will NOT touch them.
  Report only. Reap an idle-but-alive one by hand:
    tmux kill-session -t <name> ; systemctl --user disable --now <name>.service
```

Cadence / where this fits the broader lifecycle: see
[`references/session-lifecycle.md`](../references/session-lifecycle.md).
