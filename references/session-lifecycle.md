# Session lifecycle, reaping & expiry

Remote-control sessions exist in **three independent layers**. Cleaning one does not
clean the others — this is the #1 source of "I reaped everything but the session
count is still high" confusion.

| Layer | Where | Lives until | Cleaned by |
|-------|-------|-------------|------------|
| **tmux window** | `tmux ls` on the host | host reboot or `tmux kill-session` | `session-doctor reap-local` |
| **systemd --user unit** | `~/.config/systemd/user/agenthost-*.service` | `systemctl --user disable` + `rm` | `session-doctor reap-local` |
| **registry entry** | `GET /v1/sessions` (org-wide, all devices) | explicit `DELETE` (never expires on its own) | manual `DELETE` (see below) |

**Key fact:** the registry is org-wide and effectively permanent. It accumulates:
- **disconnected** entries (session ended, registration lingers), and
- **zombies** — `connection_status: connected` but the real process died without a clean
  disconnect (common after host reboots / OOM kills). These keep counting as "connected."

Reaping local tmux/systemd does **not** remove registry entries, so it does little for
any per-org session-count pressure. Registry hygiene is a separate, deliberate step.

## The tool: `scripts/session-doctor.sh`

```
session-doctor.sh                       # read-only 3-layer audit (default)
session-doctor.sh reap-local            # DRY-RUN: list dead local tmux + orphan units
session-doctor.sh reap-local --force    # actually reap them
session-doctor.sh registry-stale --days 30   # list registry entries disconnected > N days
```

Safety guarantees:
- Never touches protected plumbing: `claude-remote*`, `*openclaw*`, `*hermes*`.
- Only reaps local items whose `claude` process is genuinely gone.
- `reap-local` is dry-run unless `--force` — so a control session merely inside a
  supervisor restart window is never reaped by accident.
- **Registry deletion is never automated.** `registry-stale` prints candidates and the
  exact `curl -X DELETE …` to run by hand after you verify each one.

## Recommended cadence (expiry policy)

1. **Weekly:** `session-doctor.sh report`. If orphan units or dead tmux pile up,
   `reap-local --force`.
2. **Monthly:** `session-doctor.sh registry-stale --days 30`. Verify the list is truly
   dead (titles + age make this obvious), then `DELETE` them. Anything > 90 days
   disconnected is essentially always safe to delete.
3. **After a host reboot:** expect zombies (registry says connected, process gone).
   Respawn the sessions you still want; the old registry entries become deletable.

## Why sessions stop registering (the 2026-07 regression)

If a **new** session never appears on the phone, the usual cause is the remote-control
bridge gate: the CLI only enables the bridge when `ANTHROPIC_BASE_URL` is absent or its
host is `api.anthropic.com`. A proxy base URL (e.g. headroom `127.0.0.1`) silently
disables registration. The launcher fixes this by forcing a first-party base URL via
`--settings …/rc-firstparty.settings.json`. If you see a session live in `tmux` but
absent/disconnected in `session-doctor report`'s registry section, check that its
`claude` process carries that `--settings` flag.
