# openclaw gateway token — rotation plan (investigated 2026-08-10, NOT executed)

Follow-up to the security finding in `context-footprint.md` §3. Rotating a live
shared secret without flipping every consumer together would break the gateway
bridge, so the **full rotation (§ steps 1, 3–6) remains a plan only — not
executed**; it needs a human to run the ordered steps below during a controlled
window.

## STATUS — Step 2 (`--token-file`) IMPLEMENTED 2026-08-10 (human-approved)

The inline `--token <64-char>` in `~/.claude/settings.json` →
`mcpServers.openclaw.args` was replaced with `--token-file
/home/agents/.openclaw/gateway-token` (a 0600 file holding the **same,
unchanged** value). The plaintext secret is gone from `settings.json` (grep: 0
occurrences). **The token value was not changed → no gateway restart, no
disruption to other sessions.** Verified functionally: `openclaw mcp serve
--token-file <path>` connects/authenticates to the running gateway (a
deliberately-wrong token-file was rejected with `unauthorized: gateway token
mismatch`, the real one was accepted). Backups: pre-swap `settings.json` at
`~/.claude/backups/token-file-swap-2026-08-10/` (and the earlier
`context-trim-2026-08-10/` copy, confirmed identical pre-edit).

> **Finding worth the operator's attention:** in *two* throwaway sessions (a
> pure-default `claude` and one with the spawn `--settings` layer), the
> `mcpServers` entries from `settings.json` (`openclaw`, `token-savior`) did
> **not** appear in `/mcp` — Claude Code sourced its live MCP servers from
> `~/.claude.json` (`headroom`) + claude.ai account connectors instead. openclaw
> exists **only** in `settings.json` (not `~/.claude.json`). So this plaintext
> token was in a config block that does not appear to be an actively-loaded
> Claude MCP client in this CLI version (2.1.206) — the swap is therefore valid
> security hygiene at ~zero functional risk, and the `--token-file` invocation
> still works for any consumer that does spawn it. Worth confirming against the
> live protected interactive session if openclaw is expected to be active there.

## What the token actually is

The value in `~/.claude/settings.json` → `mcpServers.openclaw.args`
(`openclaw mcp serve --token <64-char>`) is the **OpenClaw Gateway shared auth
token** — a symmetric secret every gateway client must present.

- **Issuance model:** operator-chosen shared secret (not CA-minted). The 64-char
  length matches `openssl rand -hex 32`. `--token` help: *"Shared token required
  in connect.params.auth.token (default: OPENCLAW_GATEWAY_TOKEN env if set)."*
- **Canonical store:** `~/.openclaw/secrets.json` → **`.gateway.auth.token`**
  (mode 0600) holds the exact same value.
- **Server:** the gateway is running as `node …/openclaw/dist/index.js gateway
  --port 18789` and reads the token from `secrets.json` (launched with **no**
  inline `--token`). So the *server* side already keeps it in a 0600 secret store.
- **Client (the leak):** only `~/.claude/settings.json` passes it **inline on the
  command line**, which is why it lands in `/context`, backups, `ps`, and logs.
- `openclaw mcp serve` supports **`--token-file <path>`** and `--password-file` —
  the clean client-side fix (below). `openclaw config set` also supports SecretRef
  indirection (`--ref-provider … --ref-source env --ref-id <ENV>` / file/vault).
- `openclaw devices rotate|revoke` rotates **device** tokens per role — a
  *different* mechanism from the gateway shared `auth.token`; not the lever here.

## Blast radius

**Functional (must flip together or the bridge breaks):**
| Consumer | Where | Role |
|---|---|---|
| Gateway server | `~/.openclaw/secrets.json` `.gateway.auth.token` | source of truth (server validates against this) |
| Claude Code MCP client | `~/.claude/settings.json` `mcpServers.openclaw` | presents token to gateway (currently inline) |

Swept for other live clients — **none found**: the token value appears in no
`/home/agents/workspace/*/.claude/` config, no workspace `settings.json`
references `openclaw` (6 repos checked), and there is no `~/.mcp.json`. So
`~/.claude/settings.json` is the **only** live `mcpServers.openclaw` client.
(Still confirm no off-box gateway clients — other hosts, dashboards, paired
devices — depend on the same shared token before rotating.)

**Exposure (stale OLD-token copies to scrub AFTER rotation — value has already
leaked to ~13 files):**
- `~/.claude/settings.json` + siblings: `settings.json.bak`,
  `settings.json.terminally-social-backup-1781593341974`
- **`~/.claude/backups/context-trim-2026-08-10/settings.json`** — *created by me in
  the previous session's guardrail backup; I own this one in the cleanup.*
- `~/.claude/projects.backup-20260608…/*.jsonl` (3 old Claude transcripts)
- `~/.openclaw/agents/main/…/sessions/*.jsonl`, `rollout-*.jsonl`,
  `*.trajectory.jsonl` (openclaw agent logs)
- `~/.openclaw/workspace/backups/headroom-20260610-175941/_claude_settings_json`
- `~/.openclaw/secrets.json` (this is the *new* home post-rotation, not a scrub target)

## Rotation plan (ordered — DO NOT run piecemeal)

0. **Pre-flight:** enumerate every gateway client (this Claude host + any others).
   Pick a low-traffic window; expect the openclaw MCP tool to be briefly
   unavailable in live Claude sessions.
1. **Generate** a new secret: `NEW=$(openssl rand -hex 32)`.
2. **Stage the client fix** (do this regardless of rotation — it's the real
   containment win): write `NEW` to a 0600 file, e.g.
   `install -m600 /dev/null ~/.openclaw/gateway-token && printf %s "$NEW" > ~/.openclaw/gateway-token`,
   and change `~/.claude/settings.json` `mcpServers.openclaw.args` from
   `["mcp","serve","--token","<value>"]` to
   `["mcp","serve","--token-file","/home/agents/.openclaw/gateway-token"]`.
   (No secret bytes ever sit in settings.json again.)
3. **Flip the server + client together:**
   - Set the new token in the canonical store:
     `openclaw config set gateway.auth.token "$NEW"` (writes `secrets.json`;
     `config set … --dry-run` first to preview).
   - Restart the gateway so it reloads: `openclaw daemon restart` (or stop/start
     the `gateway` service). Until this happens, clients presenting `NEW` are
     rejected — that's why server + token-file must land in the same window.
4. **Reload clients:** `openclaw mcp reload` (dispose cached MCP runtimes), and
   restart any live Claude Code sessions that use the openclaw MCP so they re-read
   `settings.json`.
5. **Verify:** `openclaw mcp status` / `openclaw mcp probe` connects and lists
   capabilities; confirm the `openclaw` MCP tools work in a fresh Claude session.
6. **Scrub OLD-token copies** from every file in the Exposure list above
   (including my `context-trim-2026-08-10/settings.json` backup — or delete that
   backup once the profile work is accepted). The old value is inert post-rotation
   but should not linger in transcripts/backups.

## If you only do one thing

**Step 2 alone** (switch the client to `--token-file`) removes the token from
`settings.json`/`/context`/backups without touching the live secret — the lowest-
risk containment. Full rotation (steps 1–6) is warranted because the value already
leaked to ~13 files.
