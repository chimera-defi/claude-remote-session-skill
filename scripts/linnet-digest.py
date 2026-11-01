#!/usr/bin/env python3
"""Linnet: deterministic, read-only scheduled-job and alert digest.

Config: --config, HOST_TOOLS_CONFIG, then
${CRSS_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/crss}/host-tools.json,
under "linnet-digest". Paths expand ~/ and relative paths against --home.
Source readers never acknowledge or alter messages. Only explicitly selected
sinks send messages; dry runs neither send nor write (including state).
"""

import argparse
from collections import Counter
from contextlib import closing
import datetime as dt
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
from urllib.parse import quote


UTC = dt.timezone.utc
# Explicit asks only: bare words like 'approve' or 'gate' match ordinary reports.
APPROVAL = re.compile(r'EXECUTION_APPROVED|\bAPPROVAL\s*:|\bGATE\s*:|approve me\b|approval (needed|required|pending)'
                      r'|awaiting (your |operator )?approval|operator to (confirm|approve|decide)|needs? (the )?operator', re.I)
EXCERPT = 300
DATED = re.compile(r'\d{8}T\d{12}Z\.md')


def one_line(value):
    return ' '.join(str(value).splitlines())


def instant(value):
    if isinstance(value, (float, int)):
        return dt.datetime.fromtimestamp(value / 1_000_000, UTC)
    parsed = dt.datetime.fromisoformat(str(value).replace('Z', '+00:00'))
    return parsed.replace(tzinfo=parsed.tzinfo or UTC).astimezone(UTC)


def command(argv, stdin=None):
    if not isinstance(argv, list) or not argv or not all(isinstance(a, str) and a for a in argv):
        raise ValueError('command must be a nonempty argv list')
    result = subprocess.run(argv, input=stdin, capture_output=True, text=True,
                            errors='replace', timeout=30, check=False,
                            env={**os.environ, 'TZ': 'UTC', 'LC_ALL': 'C'})
    if result.returncode:
        raise ValueError(f'{Path(argv[0]).name}: exit {result.returncode}')
    return result.stdout


def properties(unit, fields):
    output = command(['systemctl', '--user', 'show', unit, '-p', fields])
    result = {}
    for line in output.splitlines():
        if '=' in line:
            key, value = line.split('=', 1)
            # systemctl repeats array properties once per timer trigger.
            result[key] = result[key] + '\n' + value if key in result else value
    return result


def period_seconds(timer):
    """Use the timer's schedule, never next-minus-last (which hides stale runs)."""
    props = properties(timer, 'TimersCalendar,TimersMonotonic')
    monotonic = props.get('TimersMonotonic', '')
    durations = []
    for value in re.findall(r'On(?:UnitActive|UnitInactive)USec=([^;]+)', monotonic):
        parts = re.findall(r'([\d.]+)\s*(us|ms|s|min|h|d|w)', value)
        seconds = sum(float(n) * {'us': .000001, 'ms': .001, 's': 1,
                                  'min': 60, 'h': 3600, 'd': 86400,
                                  'w': 604800}[u] for n, u in parts)
        if seconds > 0:
            durations.append(seconds)
    # systemd itself parses the complete OnCalendar syntax, including lists,
    # time zones and calendar aliases; no Python calendar approximation.
    calendars = re.findall(r'OnCalendar=(.*?)\s*;\s*next_elapse=',
                           props.get('TimersCalendar', ''))
    for calendar in calendars:
        output = command(['systemd-analyze', 'calendar', '--iterations=2', calendar])
        values = re.findall(r'(?:Next elapse|Iteration #2):\s*(.+)', output)
        if len(values) >= 2:
            dates = [dt.datetime.strptime(v.strip(), '%a %Y-%m-%d %H:%M:%S %Z')
                     for v in values[:2]]
            delta = (dates[1] - dates[0]).total_seconds()
            if delta > 0:
                durations.append(delta)
    return min(durations) if durations else None


class Digest:
    def __init__(self, args):
        self.args = args
        self.home = Path(args.home).absolute()
        self.now = dt.datetime.now(UTC)
        self.stamp = self.now.strftime('%Y%m%dT%H%M%S%fZ')
        self.needs = []
        self.happened = []
        self.ok_runs = []
        self.wait = []
        self.kepler = []
        self.sources = []
        self.bus_available = False
        self.failing = 0
        overlay = os.environ.get('CRSS_HOME') or str(
            Path(os.environ.get('XDG_CONFIG_HOME') or self.home / '.config') / 'crss')
        filename = args.config or os.environ.get('HOST_TOOLS_CONFIG') or str(Path(overlay) / 'host-tools.json')
        try:
            self.config = json.loads(self.path(filename).read_text()).get('linnet-digest', {})
            if not isinstance(self.config, dict):
                raise ValueError('linnet-digest must be an object')
        except FileNotFoundError:
            self.config = {}
        except (OSError, ValueError, AttributeError) as exc:
            self.config = {}
            self.sources.append(f'Config unavailable: {one_line(exc)}')
        self.state = self.path(str(Path(os.environ.get('XDG_STATE_HOME') or
                                       self.home / '.local/state') / 'crss/linnet'))
        self.start = self.now - dt.timedelta(hours=24)
        try:
            previous = json.loads((self.state / 'last.json').read_text())
            self.start = instant(previous['window_end'])
            if self.start > self.now:
                raise ValueError('last window end is in the future')
        except FileNotFoundError:
            pass
        except (OSError, ValueError, KeyError, TypeError) as exc:
            self.start = self.now - dt.timedelta(hours=24)
            self.sources.append(f'State unavailable: {one_line(exc)}; using the last 24 hours')

    def path(self, value):
        value = str(value)
        if value == '~' or value.startswith('~/'):
            return self.home / value[2:] if value != '~' else self.home
        p = Path(value)
        return p if p.is_absolute() else self.home / p

    def timers(self):
        rows = json.loads(command(['systemctl', '--user', 'list-timers', '--all', '--output=json']))
        if not isinstance(rows, list):
            raise ValueError('timer listing is not a list')
        for row in rows:
            try:
                timer = row['unit']
                unit = row.get('activates') or timer.removesuffix('.timer') + '.service'
                props = properties(unit, 'Result,ExecMainStatus,ActiveEnterTimestamp,Description')
                if 'Result' not in props:
                    raise ValueError('service Result is missing')
                result = props['Result']
                failed = bool(result and result != 'success')
                if failed:
                    self.failing += 1
                    owner = self.config.get('owners', {}).get(unit)
                    line = f'{unit} failed: {result} (exit {props.get("ExecMainStatus", "unknown")})'
                    if owner:
                        line += f'; owner: {one_line(owner)}'
                    target = self.needs if unit in self.config.get('operator_units', []) else self.wait
                    target.append(line)
                last = row.get('last')
                if not last or last in ('n/a', '-', '0') or last == 18446744073709551615:
                    self.wait.append(f'{unit} has never run')
                    continue
                last = instant(last)
                if self.start <= last <= self.now and not failed:
                    self.ok_runs.append(unit.removesuffix('.service'))
                try:
                    period = period_seconds(timer)
                    if period and (self.now - last).total_seconds() > 2 * period:
                        self.wait.append(f'{unit} last ran at {last.isoformat()}, over twice its {period:g}s period ago')
                    elif period is None:
                        self.sources.append(f'{timer} period unavailable: no repeating schedule found')
                except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
                    self.sources.append(f'{timer} period unavailable: {one_line(exc)}')
            except (OSError, ValueError, KeyError, TypeError, AttributeError, OverflowError,
                    subprocess.TimeoutExpired) as exc:
                self.sources.append(f'Timer unavailable: {one_line(exc)}')
        self.sources.append(f'Systemd user timers: {len(rows)} checked')

    def bus(self):
        filename = self.config.get('bus_db')
        if not filename:
            raise ValueError('bus_db is not configured')
        uri = 'file:' + quote(str(self.path(filename)), safe='/') + '?mode=ro'
        with closing(sqlite3.connect(uri, uri=True, timeout=5)) as db:
            db.row_factory = sqlite3.Row
            # A single read transaction keeps message and acknowledgment counts
            # consistent even while the bus receives new messages.
            db.execute('BEGIN')
            self.sources.append('Bus: SQLite opened with mode=ro; no acknowledgments sent')
            mailboxes = self.config.get('mailboxes', [])
            for mailbox in mailboxes:
                messages = db.execute(
                    'SELECT * FROM coordination_messages WHERE recipient = ? '
                    'AND julianday(created_at) > julianday(?) '
                    'AND julianday(created_at) <= julianday(?) ORDER BY sequence',
                    (mailbox, self.start.isoformat(), self.now.isoformat())).fetchall()
                self.happened.append(f'{mailbox}: {len(messages)} messages since the window start')
                counts = Counter((m['sender'], m['kind']) for m in messages)
                for (sender, kind), count in sorted(counts.items()):
                    self.happened.append(f'{mailbox}: {sender} / {kind}: {count}')
                for message in messages:
                    summary = message['summary'] or ''
                    evidence = message['evidence_json'] or ''
                    if message['kind'] == 'question' or APPROVAL.search(summary + '\n' + evidence):
                        # Preserve the original text, including its line breaks.
                        # Verbatim excerpt; the full text still reaches the operator by its own route.
                        def cut(text, n):
                            return text if len(text) <= n else text[:n] + f' [... full text: bus sequence {message["sequence"]}]'
                        self.needs.append(f'{mailbox}, sequence {message["sequence"]}:\n'
                                          + cut(summary, EXCERPT) + ('\n' + cut(evidence, 200) if evidence.strip() not in ('', '[]', '{}') else ''))
                self.acks(db, mailbox)
            try:
                message = db.execute(
                    'SELECT sequence, summary FROM coordination_messages WHERE sender = ? '
                    'ORDER BY sequence DESC LIMIT 1', (self.config.get('kepler_sender', 'kepler'),)).fetchone()
                if message:
                    seq = message['sequence']
                    self.kepler.append(f'[sequence {seq}](bus:sequence/{seq}): '
                                       + one_line((message['summary'] or '')[:200]))
                else:
                    self.kepler.append('No report found')
            except sqlite3.Error as exc:
                self.kepler.append(f'unavailable: {one_line(exc)}')

    def acks(self, db, mailbox):
        try:
            columns = {r['name'] for r in db.execute('PRAGMA table_info(coordination_acks)')}
            # Only known, unambiguous joins; never interpolate discovered names.
            if 'message_id' in columns:
                join = 'a.message_id = m.message_id'
            elif 'sequence' in columns:
                join = 'a.sequence = m.sequence'
            elif 'message_sequence' in columns:
                join = 'a.message_sequence = m.sequence'
            else:
                raise ValueError('acknowledgment identifier is not obvious')
            if 'recipient' in columns:
                join += ' AND a.recipient = m.recipient'
            elif 'mailbox' in columns:
                join += ' AND a.mailbox = m.recipient'
            else:
                raise ValueError('acknowledgment recipient is not obvious')
            count = db.execute(
                'SELECT count(*) FROM coordination_messages m WHERE m.recipient = ? '
                'AND NOT EXISTS (SELECT 1 FROM coordination_acks a WHERE ' + join + ')',
                (mailbox,)).fetchone()[0]
            self.wait.append(f'{mailbox}: unacked: {count} (all ages; delivery routes remain active)')
        except (sqlite3.Error, ValueError) as exc:
            self.sources.append(f'{mailbox}: unacked count unavailable: {one_line(exc)}')

    def environment(self):
        reports = self.path('~/.local/state/crss/env-refresh/reports')
        # Honor the same state root as env-refresh itself.
        if os.environ.get('XDG_STATE_HOME'):
            reports = self.path(os.environ['XDG_STATE_HOME']) / 'crss/env-refresh/reports'
        files = list(reports.glob('*.md'))
        if not files:
            raise FileNotFoundError('no env-refresh reports')
        newest = max(files, key=lambda p: p.stat().st_mtime_ns)
        with newest.open(encoding='utf-8', errors='replace') as stream:
            for line in stream:
                if re.match(r'^(?:DUE|OK):', line):
                    self.happened.append('Environment refresh: ' + line.strip())
                    self.sources.append(f'Environment refresh: {newest.name} (status line only)')
                    return
        raise ValueError('latest env-refresh report has no status line')

    def collect(self):
        for name, read in (('Systemd', self.timers), ('Bus', self.bus),
                           ('Environment refresh', self.environment)):
            try:
                read()
                if name == 'Bus':
                    self.bus_available = True
            except (OSError, ValueError, TypeError, KeyError, AttributeError,
                    OverflowError, sqlite3.Error, subprocess.TimeoutExpired) as exc:
                self.sources.append(f'{name} unavailable: {one_line(exc)}')
                if name == 'Bus':
                    self.kepler.append(f'unavailable: {one_line(exc)}')
                    self.sources.append('cursor not advanced: bus unavailable')
        if self.ok_runs:
            names = sorted(set(self.ok_runs))
            self.happened.insert(0, f'{len(names)} scheduled jobs ran OK: ' + ', '.join(names))
        if self.failing:
            self.happened.insert(0, f'{self.failing} scheduled jobs failed (listed below)')
        if not self.happened:
            self.happened.append('No activity found in the available sources')
        summarize = self.config.get('summarize_cmd')
        if summarize and not self.args.dry_run:
            try:
                prose = command(self.argv(summarize), '\n'.join(self.happened) + '\n').strip()
                if not prose:
                    raise ValueError('empty summary')
                # Flattening prevents a rewrite from creating other sections.
                self.happened = [one_line(prose)]
            except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
                self.sources.append(f'Summarizer unavailable: {one_line(exc)}; using template')
        elif summarize:
            self.sources.append('Summarizer skipped during dry-run (template shown)')

    def markdown(self):
        lines = [f'# Linnet digest {self.stamp}',
                 f'Window: {self.start.isoformat()} to {self.now.isoformat()}', '']
        sections = [('Needs the operator (pass-through; still delivered by their own route)', self.needs),
                    ('What happened', self.happened), ('Can wait', self.wait),
                    ('Kepler', self.kepler), ('Sources', self.sources)]
        for title, entries in sections:
            lines += ['## ' + title, '', *['- ' + line for line in (entries or ['None'])], '']
        return '\n'.join(lines)

    def argv(self, template, **values):
        if not isinstance(template, list) or not template or not all(isinstance(s, str) and s for s in template):
            raise ValueError('command must be a nonempty argv list')
        result = []
        for part in template:
            for key, value in values.items():
                part = part.replace('{' + key + '}', str(value))
            result.append(part)
        if result[0].startswith('~/'):
            result[0] = str(self.path(result[0]))
        return result

    def deliver(self, report):
        sinks = self.args.sink if self.args.sink is not None else self.config.get('sinks', ['stdout'])
        sinks = list(dict.fromkeys(sinks or ['stdout']))
        if any(s not in ('stdout', 'file', 'bus', 'phone') for s in sinks):
            raise ValueError('unknown sink')
        publish = self.path(self.config.get('publish_dir', '~/agent-memory/shared/public/linnet'))
        digest_file = self.state / 'digests' / (self.stamp + '.md')
        summary_file = self.state / 'digests' / (self.stamp + '.summary.txt')
        phone_file = self.state / 'digests' / (self.stamp + '.phone.txt')
        summary = (f'WHAT: Linnet digest {self.stamp} / STATUS: {len(self.needs)} need operator, '
                   f'{self.failing} failing / NEXT: read latest.md / REPLY_TO: none\n')
        actions = []
        # Validate delivery configuration before creating any output files.
        if 'file' in sinks:
            actions.append(f'file: write {digest_file} and {publish / "latest.md"}; retain 30 dated copies')
        bus_calls = []
        if 'bus' in sinks:
            template = self.config.get('bus_post_cmd')
            recipients = self.config.get('bus_recipients', [])
            if not recipients:
                raise ValueError('bus sink needs bus_recipients')
            for recipient in recipients:
                call = self.argv(template, recipient=recipient, summary_file=summary_file,
                                 idempotency_key='linnet-' + self.stamp)
                bus_calls.append(call)
                actions.append('bus: ' + json.dumps(call))
        phone_call = None
        if 'phone' in sinks:
            phone_call = self.argv(self.config.get('phone_cmd'), file=phone_file)
            actions.append('phone: ' + json.dumps(phone_call))
        if self.args.dry_run:
            print(report)
            print('Dry-run sink actions:')
            for action in actions or ['stdout: print digest']:
                print('- ' + action)
            print('- State unchanged; nothing written or sent')
            return
        if 'stdout' in sinks:
            print(report)
        if any(s in sinks for s in ('file', 'bus', 'phone')):
            digest_file.parent.mkdir(parents=True, exist_ok=True)
        if 'file' in sinks:
            atomic_write(digest_file, report)
            publish.mkdir(parents=True, exist_ok=True)
            atomic_write(publish / (self.stamp + '.md'), report)
            atomic_write(publish / 'latest.md', report)
            dated = sorted(p for p in publish.iterdir() if DATED.fullmatch(p.name) and p.is_file())
            for old in dated[:-30]:
                old.unlink()
        if bus_calls:
            atomic_write(summary_file, summary)
            for call in bus_calls:
                command(call)
        if phone_call:
            phone = [f'Linnet: {len(self.needs)} need operator; {self.failing} failing',
                     'Needs the operator (their own routes still deliver):']
            phone += [one_line(line) for line in self.needs[:12]]
            if len(self.needs) > 12:
                phone.append(f'{len(self.needs) - 12} more; read latest.md')
            atomic_write(phone_file, '\n'.join(phone) + '\n')
            command(phone_call)
        if self.bus_available:
            self.state.mkdir(parents=True, exist_ok=True)
            atomic_write(self.state / 'last.json', json.dumps({'window_end': self.now.isoformat()}) + '\n')


def atomic_write(path, text):
    temporary = path.with_name(path.name + '.tmp')
    temporary.write_text(text, encoding='utf-8')
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--home', default=os.environ.get('HOME', str(Path.home())))
    parser.add_argument('--config')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--sink', action='append', choices=['stdout', 'file', 'bus', 'phone'])
    args = parser.parse_args()
    digest = Digest(args)
    digest.collect()
    try:
        digest.deliver(digest.markdown())
    except (OSError, ValueError, TypeError, subprocess.TimeoutExpired) as exc:
        print(f'linnet-digest: delivery unavailable: {one_line(exc)}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
