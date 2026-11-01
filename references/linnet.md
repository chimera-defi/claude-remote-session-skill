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
are copied verbatim (first 300 characters, then a bus sequence pointer; evidence first 200), under **Needs the operator
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
    "phone_cmd": ["phone-send", "--file", "{file}"]
  }
}
```

Defaults: no bus database or mailboxes; `kepler_sender` is `kepler`; `self_sender` (Linnet's own bus sender, never re-flagged) is `linnet`;
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

Two Claude-native schedulers exist; pick by where Claude runs.

- **Claude Desktop scheduled task, Claude on the same machine as the sources.**
  In **Scheduled → New task → Set up manually**, name it Linnet, select the local
  working folder, and set 08:15 and 20:15. Prompt, verbatim:

  > Run `linnet-digest --sink file --sink bus` and reply with the Needs-the-operator section

  Save and run once to verify access. See the [official scheduled-task
  instructions](https://support.claude.com/en/articles/13854387-schedule-recurring-tasks-in-claude-cowork).
- **Desktop app driving a remote (SSH) host.** Desktop scheduled tasks run on the
  user's own computer, so a session on an SSH host cannot create one; the app
  refuses with "scheduled tasks run on the user's own computer and this session
  works on an SSH host". Use the in-session scheduler instead: in a Claude session
  on the host, `/loop` or `CronCreate` with the same prompt. These jobs belong
  to that session: they fire only while it is open and idle, pause while it is
  closed, and a recurring one expires after 7 days. Treat this path as a short-lived or test
  path; the systemd timer (path A) is the durable one.

Use one scheduler at a time to avoid duplicate runs.

## Reading and division of work

Any agent reads `publish_dir/latest.md` (by default
`~/agent-memory/shared/public/linnet/latest.md`). Kepler does ChatGPT-side
research and portfolio reports over the bus. Linnet does the local scheduled-job
and alert digest. It quotes the first 200 characters of Kepler's latest summary
and links with `bus:sequence/<sequence>`; this is a message reference for agents,
not an HTTP endpoint. Linnet never duplicates Kepler's report.

## Sample digest

Trimmed from the first live run (2026-11-01); names are generic here.

```markdown
# Linnet digest 20261101T102731Z
Window: 2026-10-31T10:27:31+00:00 to 2026-11-01T10:27:31+00:00

## Needs the operator (pass-through; still delivered by their own route)

- launcher-mailbox, sequence 12118:
Escalation: an alert book still fires for a withdrawn order [... full text: bus sequence 12118]

## What happened

- 5 scheduled jobs failed (listed below)
- 18 scheduled jobs ran OK: ack-hygiene, bus-router, morning-brief, ...
- launcher-mailbox: 13 messages since the window start
- launcher-mailbox: kepler / report: 2

## Can wait

- health-audit.service failed: exit-code (exit 1); owner: fleet ops
- qt-rotation-collect.service has never run
- launcher-mailbox: unacked: 260 (all ages; delivery routes remain active)

## Kepler

- [sequence 12189](bus:sequence/12189): Not executed: task access is disabled ...

## Sources

- Systemd user timers: 25 checked
- Bus: SQLite opened with mode=ro; no acknowledgments sent
```
