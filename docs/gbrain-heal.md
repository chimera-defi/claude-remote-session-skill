# gbrain-heal

Keeps the gbrain brain draining and its per-source freshness stamps current.
Supersedes the never-committed `~/.local/bin/gbrain-maintenance.sh` (its
sync/extract/per-source-cycle logic is ported into `scripts/gbrain-heal.sh`,
with the rationale comments kept alongside the code they explain — see the
script itself, not this doc, for the exact commands and thresholds).

## Root causes

See the header comment in `scripts/gbrain-heal.sh` and `SPEC-gbrain-heal.md`
(this repo's session history) for the full detail and source citations; short
version:

- **Oversized embed batches vs. a too-short per-batch timeout.** `gbrain-heal`
  exports the verified fix (capped `GBRAIN_EMBED_MAX_BATCH_TOKENS`, raised
  `GBRAIN_AI_EMBED_TIMEOUT_MS`) globally, without overriding a value already
  set in the environment.
- **Stall watchdog is progress-keyed per PAGE, not per sub-batch.** Even with
  the batch cap fixing per-request latency, gbrain's stall watchdog
  (`src/core/embed-stall.ts`) only resets on a persisted chunk, and chunks
  persist once per page — a single huge page (~170 sub-batch requests) can run
  well past the watchdog's 900s default with zero visible progress, so it
  fires mid-page every run and nothing ever banks for that page. `gbrain-heal`
  also raises `GBRAIN_EMBED_STALL_ABORT_SECONDS` past the worst single-page time.
- **Embed also has its own, independent soft wall-clock cap.**
  `GBRAIN_EMBED_TIME_BUDGET_MS` (default 30 min, checked between pages) can
  still fire on a single very large page even with the other knobs tuned,
  exiting 0 with zero chunks banked. `gbrain-heal` sizes it off
  `--embed-budget` so a page started just before the cap fires still has
  margin before the outer `timeout` kills the whole phase.
- **A daily `--no-embed` code-refresh cron is the backlog's source, by
  design.** It intentionally syncs without embedding, so a
  growing-then-draining backlog is normal, not a failure.
- **`cycle_freshness` only FAILs past 24h; a once-daily timer sits at that
  edge.** Running this more than once a day (see `systemd/gbrain-heal.timer`)
  keeps it inside the warn window.
- **A prior health check required zero tolerance** (`stale==0 && missing==0`),
  so any backlog at all read as "degraded" even while draining normally.
  `gbrain-heal --check` is keyed off `gbrain doctor`'s own FAIL/warn/ok checks
  by default (see "Check semantics" below); the old zero-tolerance rule is
  still available via `--strict`.

## Check semantics

`--check` reports one of three states, independent of `--strict`:

| State | Condition | Default exit | `--strict` exit |
|---|---|---|---|
| `healthy` | 0 doctor FAILs AND `missing==0` AND `stale==0` | 0 | 0 (if migration marker is also `none`) |
| `draining` | 0 doctor FAILs, but an embedding backlog (`missing>0` or `stale>0`) | 0 | 1 |
| `unhealthy` | a real doctor FAIL (e.g. `cycle_freshness` >24h) | 1 | 1 |

`--strict` reproduces the old `server-health-audit.sh:97` zero-tolerance rule
(migration marker is `none` AND `stale==0` AND `missing==0` AND doctor
fail-count `==0`) as an opt-in exit-code tightening — the reported `state`
doesn't change, only whether `draining` (or a `none`-marker violation) counts
as a passing exit. Tool errors (gbrain missing, unparsable JSON) always exit 2
regardless of `--strict`. `--apply`'s own final re-check always runs
non-strict — a draining backlog is an acceptable end state for `--apply`.

The JSON summary also carries `gbrain_http`: `"ok"` or `"not_responding"`,
a read-only probe of `gbrain-http.service`'s health endpoint. It's
informational only — it never changes `state` or `exit_ok`. See "gbrain-http
self-heal" below for what `--apply` does when it's not responding.

## Non-fatal outcomes `--apply` tolerates

Several conditions look like failures at a glance but are treated as
non-fatal, benign, or resumable — each phase status is set exactly once, so
`run_phase()` / `run_embed_phase()` / `cycle_sources()` in the script are the
source of truth for the precise condition, not this list:

- **Lock contention** (`sync --all` hitting `SyncLockBusyError`, or `embed`
  hitting its own single-flight backfill lock): `skipped(lock-held)` —
  another process already holds the source's lock; retried next run.
- **`extract`'s budget exhausted** (`timeout-partial`, budget raised to 1800s):
  it stamps progress per batch, so a mid-run kill only loses the current
  small batch.
- **`embed`'s chunk-level failures with real progress**
  (`partial(chunk-failures=N)`): some chunks failed but `missing` still
  decreased; the failure count is preserved in the phase status.
- **A per-source `dream --source <id>` cycle hitting `cycle_already_running`**:
  counted as skipped in the cycle phase's summary, not rolled into "ok".
- **`embed`'s three stall-shaped exits** (our own `--embed-budget` timeout,
  gbrain's stall watchdog, or its independent wall-clock cap): `timeout-partial`
  if progress was made, `stalled` (the one case here that DOES fail `--apply`)
  if the backlog didn't move at all.

### gbrain-http self-heal

`--apply` probes `gbrain-http.service`'s health endpoint before running any
phase and, if it's not responding, attempts one `systemctl --user restart` +
re-probe (2026-09-19 incident: this service can wedge — process alive per
systemd, but its listener stops answering, so `Restart=on-failure` never
fires). This never blocks or fails the run either way: sync/embed/extract/
dream/doctor/migrate all talk to postgres directly, not this endpoint.
`--check` only probes and reports (see `gbrain_http` above) — it never
restarts anything.

## Running it

```bash
gbrain-heal                       # same as --check: read-only health verdict
gbrain-heal --check --json        # machine-readable verdict for monitoring
gbrain-heal --check --strict      # zero-tolerance: draining backlog also exits 1

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
| `--embed-budget SECONDS` | 7200 | Wall-clock budget for the embed phase. Keep it comfortably above `GBRAIN_EMBED_STALL_ABORT_SECONDS` so gbrain's own watchdog fires first, not our `timeout`. A stall-shaped exit (our `timeout`'s rc=124, or gbrain's own watchdog self-aborting) that still made progress is not a failure — it resumes next run. Zero progress against a non-empty backlog is reported "stalled" and makes `--apply` exit non-zero regardless of which of the two aborted it — see `run_embed_phase()` in the script for the exact condition. |
| `--strict` | off | `--check` only — tightens `draining` to also exit 1 (see "Check semantics" above). |
| `--json` | off | Print the machine-readable verdict/summary on stdout instead of the one-line human verdict (both are always logged to stderr). |
| `GBRAIN_BIN` | `/home/agents/.bun/bin/gbrain` | Path to the gbrain binary. |
| `GBRAIN_HEAL_STATE_DIR` | `~/.gbrain/heal` | Where the lock, run logs, and `summary.json` live. |
| `GBRAIN_EMBED_MAX_BATCH_TOKENS` | 4096 (exported if unset) | Caps embed sub-batch size (verified fix for root cause #1). |
| `GBRAIN_AI_EMBED_TIMEOUT_MS` | 180000 (exported if unset) | Raises the per-batch embed timeout to match. |
| `GBRAIN_EMBED_STALL_ABORT_SECONDS` | 3600 (exported if unset) | Raises gbrain's own stall-watchdog threshold past the worst single-page drain time (verified fix for root cause #1b; gbrain's own default is 900s). |
| `GBRAIN_EMBED_TIME_BUDGET_MS` | `(--embed-budget - 2400)s` in ms, floored at 600000 (exported if unset) | Raises embed's own independent soft wall-clock cap past `--embed-budget` minus a margin, so it doesn't fire mid-page and exit 0 with nothing banked (verified fix for root cause #1c; gbrain's own default is 1800000ms/30min). |
| `GBRAIN_HEALTH_URL` | `http://127.0.0.1:3131/health` | `gbrain-http.service`'s health endpoint, probed by `--check` and self-healed by `--apply` (see "gbrain-http self-heal" above). |

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
