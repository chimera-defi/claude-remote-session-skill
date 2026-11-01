# Linnet

Linnet gives a plain-English digest of local scheduled jobs and configured alert
mailboxes since the previous successful run (24 hours on first use). It reads
user systemd timers and service results, the bus SQLite database, Kepler's latest
report, and the newest env-refresh report's status line. Calendar periods use
`systemd-analyze calendar`; interval periods use the timer's monotonic schedule.
Unsupported periods and broken sources are marked `unavailable:`.

Source access is read-only: SQLite is opened with `file:<path>?mode=ro`. Linnet
never invokes a bus read/ack command, writes a source table, acknowledges,
consumes, mutes, or suppresses alerts. Questions and approval/execution alerts
are copied verbatim, including evidence, under **Needs the operator
(pass-through; still delivered by their own route)**. Other delivery routes
continue independently. Counts of unacked messages cover all ages; message
activity and pass-through alerts use the digest window. Unknown ack schemas
produce a note rather than an invented count.

## Configuration

Lookup follows `--config`, `HOST_TOOLS_CONFIG`, then
`${CRSS_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/crss}/host-tools.json`.
Only the `linnet-digest` key is read. `--home` sets the base for `~/` and relative
paths. All keys are optional; configure sources and delivery before enabling.

```json
{
  "linnet-digest": {
    "bus_db": "~/service-state/bus.sqlite",
    "mailboxes": ["alerts"],
    "kepler_sender": "kepler",
    "operator_units": ["critical-job.service"],
    "owners": {"housekeeping.service": "maintenance owner"},
    "sinks": ["file", "bus"],
    "publish_dir": "~/agent-memory/shared/public/linnet",
    "bus_post_cmd": ["bus-post", "--recipient", "{recipient}", "--summary-file", "{summary_file}", "--idempotency-key", "{idempotency_key}"],
    "bus_recipients": ["digest-reader"],
    "phone_cmd": ["hermes", "send", "--to", "telegram", "--quiet", "--file", "{file}"]
  }
}
```

Defaults: no bus database or mailboxes; `kepler_sender` is `kepler`;
`operator_units`, `owners`, and `bus_recipients` are empty. `sinks` defaults to
`["stdout"]`. `publish_dir` defaults to `~/agent-memory/shared/public/linnet`.
Command values are argv arrays, never shell commands. Bus posting must use a
local adapter that accepts the documented recipient, summary-file, and
idempotency-key arguments. It receives this header:

```text
WHAT: Linnet digest <stamp> / STATUS: <n> need operator, <n> failing / NEXT: read latest.md / REPLY_TO: none
```

Each recipient gets one post with key `linnet-<stamp>`. `{recipient}`,
`{summary_file}`, and `{idempotency_key}` are substituted in `bus_post_cmd`;
`{file}` is substituted in `phone_cmd`. Bus content is the header; read the
published digest for details. Phone content is at most 15 lines: counts and the
operator items, with an overflow count when needed.

Optional `summarize_cmd` is an argv array receiving only **What happened** on
stdin; its stdout replaces only that section. Empty output or any command
failure retains the template. There is no LLM call by default. Dry runs skip
this optional command too, so it cannot cause writes or sends.

`--sink` is repeatable and overrides configured sinks. `--dry-run` prints the
digest and proposed sink actions, without writes or sends. State lives in
`${XDG_STATE_HOME:-~/.local/state}/crss/linnet/last.json`; the window advances
only after all selected sinks succeed on a non-dry run. Partial delivery errors
return nonzero and leave the window unchanged.

The file sink writes `digests/<UTC stamp>.md` below that state directory and
writes both a dated copy and `latest.md` into `publish_dir`. Only dated files
matching `YYYYMMDDTHHMMSSffffffZ.md` in `publish_dir` are pruned, keeping 30;
other files are untouched. State-directory copies are retained. Sink failures
can leave earlier successful outputs in place; inspect them before retrying.

## Start path A: our tools

From a checkout, install the script and unit files, then enable the timer:

```bash
install -Dm755 scripts/linnet-digest.py "$HOME/.local/bin/linnet-digest"
install -Dm644 systemd/linnet-digest.service "$HOME/.config/systemd/user/linnet-digest.service"
install -Dm644 systemd/linnet-digest.timer "$HOME/.config/systemd/user/linnet-digest.timer"
linnet-digest --dry-run
systemctl --user daemon-reload
systemctl --user enable --now linnet-digest.timer
```

The service uses configured sinks; set `sinks` to `["file", "bus"]` for shared
publication and bus delivery. The timer runs at 08:15 and 20:15 in local time
and catches up after downtime with `Persistent=true`.

Alternatively, put a bounded task in a file and start an existing session
project with `new-session <project> workspace --task-file <task-file>`. Example
task text: "Run linnet-digest --sink file --sink bus, then report its Needs the
operator section." A session launch is a single run; use the timer for cadence.

## Start path B: Claude native

Create a local scheduled task in Claude Desktop on the machine that has these
sources and the installed executable. In **Scheduled → New task → Set up
manually**, name it Linnet, select the local working folder, and set a daily
08:15 schedule. Create a second task for 20:15 if the form supports one time per
task. Use this prompt verbatim:

> Run `linnet-digest --sink file --sink bus` and reply with the Needs-the-operator section

Save and run once to verify executable access and permissions. A local task
needs this host's files and tools; a cloud task without host access cannot read
these sources. Use either the native schedule or the systemd timer to avoid
duplicate runs. See the [official scheduled-task creation instructions](https://support.claude.com/en/articles/13854387-schedule-recurring-tasks-in-claude-cowork).

## Reading and division of work

Any agent reads `publish_dir/latest.md` (by default
`~/agent-memory/shared/public/linnet/latest.md`). Kepler does ChatGPT-side
research and portfolio reports over the bus. Linnet does the local scheduled-job
and alert digest. It quotes the first 200 characters of Kepler's latest summary
and links with `bus:sequence/<sequence>`; this is a message reference for agents,
not an HTTP endpoint. Linnet never duplicates Kepler's report.

## Sample digest

_To be filled by the orchestrator._
