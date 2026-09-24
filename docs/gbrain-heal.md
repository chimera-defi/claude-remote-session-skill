# gbrain-heal

Keeps the gbrain brain draining and its per-source freshness stamps current.
Supersedes the never-committed `~/.local/bin/gbrain-maintenance.sh` (its
sync/extract/per-source-cycle logic is ported into `scripts/gbrain-heal.sh`,
with the rationale comments kept alongside the code they explain — see the
script itself, not this doc, for the exact commands and thresholds).

## What it fixes

`gbrain doctor`'s `cycle_freshness` check and the nightly embed drain were
degrading in ways that a naive "any backlog = unhealthy" health probe treated
as a permanent outage rather than expected, converging drain. See the header
comment in `scripts/gbrain-heal.sh` and `SPEC-gbrain-heal.md` (this repo's
session history) for the four verified root causes; in short:

- The embed drain was stalling on oversized batches vs. a too-short per-batch
  timeout. `gbrain-heal` exports the verified fix (capped batch tokens, raised
  timeout) globally, without overriding a value already set in the
  environment.
- A daily code-refresh cron intentionally syncs without embedding, so a
  growing-then-draining backlog is normal, not a failure.
- `cycle_freshness` only FAILs past 24h; running this more than once a day
  keeps it inside the warn window.
- `gbrain-heal --check`'s health verdict is keyed off `gbrain doctor`'s own
  FAIL/warn/ok checks, not a hardcoded "missing==0 && stale==0" rule.

## Running it

```bash
gbrain-heal                       # same as --check: read-only health verdict
gbrain-heal --check --json        # machine-readable verdict for monitoring

gbrain-heal --apply                              # sync -> embed -> extract -> cycle -> re-check
gbrain-heal --apply --dry-run                    # print what each phase would run; execute nothing
gbrain-heal --apply --embed-budget 3600          # cap the embed phase's wall-clock budget
gbrain-heal --apply --json                       # print the run's summary.json on stdout
```

Run `gbrain-heal --help` for the full option/exit-code reference — this doc
doesn't restate it, so it can't drift from the script.

A concurrent `--apply` (e.g. a manual run overlapping the timer) is a no-op:
it logs that another run holds the lock and exits 0. `--check` is read-only
and never takes that lock, so a monitor polling `--check` gets a meaningful
exit code regardless of what `--apply` is doing.

## Where logs go

Each `--apply` run writes `$GBRAIN_HEAL_STATE_DIR/runs/<UTC timestamp>/`
(default `~/.gbrain/heal/runs/`) containing per-phase `.out` files, `run.log`,
and `summary.json`. `$GBRAIN_HEAL_STATE_DIR/latest` symlinks to the most
recent run. The last 30 run dirs are kept; older ones are pruned automatically.
`--check` writes nothing to disk — it's a fast read-only probe safe to poll
frequently from monitoring.

## Knobs

| Knob | Default | What it does |
|---|---|---|
| `--embed-budget SECONDS` | 7200 | Wall-clock budget for the embed phase. A timeout that made progress is not a failure (it resumes next run). Zero progress against a non-empty backlog is reported as "stalled" and makes `--apply` exit non-zero, whether or not the phase actually timed out — see `run_embed_phase()` in the script for the exact condition. |
| `--json` | off | Print the machine-readable verdict/summary on stdout instead of the one-line human verdict (both are always logged to stderr). |
| `GBRAIN_BIN` | `/home/agents/.bun/bin/gbrain` | Path to the gbrain binary. |
| `GBRAIN_HEAL_STATE_DIR` | `~/.gbrain/heal` | Where the lock, run logs, and `summary.json` live. |
| `GBRAIN_EMBED_MAX_BATCH_TOKENS` | 4096 (exported if unset) | Caps embed sub-batch size (verified fix for the stall watchdog). |
| `GBRAIN_AI_EMBED_TIMEOUT_MS` | 180000 (exported if unset) | Raises the per-batch embed timeout to match. |

Never destructive: `gbrain-heal` only calls `sync`, `embed`, `extract`,
`dream --source <id>`, `doctor`, and `migrate embeddings --status`. It never
removes, purges, or archives a source, and never edits gbrain config.

## Deploy / enable

Per this repo's deploy convention (`SKILL.md`): diff before overwriting a
deployed copy, never blind-`install`.

```bash
diff /home/agents/.local/bin/gbrain-heal scripts/gbrain-heal.sh   # expect: deployed copy is missing/older
install -m 755 scripts/gbrain-heal.sh /home/agents/.local/bin/gbrain-heal

mkdir -p ~/.config/systemd/user
install -m 644 systemd/gbrain-heal.service ~/.config/systemd/user/gbrain-heal.service
install -m 644 systemd/gbrain-heal.timer   ~/.config/systemd/user/gbrain-heal.timer
systemctl --user daemon-reload
systemctl --user enable --now gbrain-heal.timer

# verify
systemctl --user list-timers gbrain-heal.timer
gbrain-heal --check
```

Deploying and enabling the timer is the orchestrator's decision after review,
not something this change does on its own.
