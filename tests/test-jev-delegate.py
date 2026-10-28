#!/usr/bin/env python3
"""Offline CLI contract tests; all HTTP goes to a temporary loopback server."""

import datetime as dt
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts' / 'jev-delegate.py'
FAKE_KEY = 'test-key-ZZZ123'


def answer(kind='choice'):
    if kind == 'noul':
        return {'type': kind, 'noul': 0.1}
    base = {'type': kind, 'confidence': 0.99, 'probabilities': {'yes': 0.6, 'unclear': 0.4}}
    if kind == 'choice':
        base['choice'] = 'yes'
    else:
        base.update(score=1, legend={'0': 'low', '1': 'high'})
    return base


class DelegateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                self.respond()

            def do_POST(self):
                self.respond()

            def respond(self):
                server = self.server
                length = int(self.headers.get('Content-Length', 0))
                data = self.rfile.read(length)
                server.requests.append((self.command, self.path, dict(self.headers), data))
                if server.disconnect:
                    self.connection.close()
                    return
                if server.delay:
                    time.sleep(server.delay)
                status, response = server.reply
                raw = response if isinstance(response, bytes) else json.dumps(response).encode()
                self.send_response(status)
                for name, value in server.response_headers.items():
                    self.send_header(name, value)
                self.end_headers()
                try:
                    self.wfile.write(raw)
                except (BrokenPipeError, ConnectionResetError):
                    pass

        cls.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.keyfile = self.root / 'api_key'
        self.keyfile.write_text(' \n' + FAKE_KEY + '\n')
        # An allowlist prevents inherited live credentials/configuration affecting tests.
        self.env = {k: v for k, v in os.environ.items()
                    if k in ('PATH', 'SYSTEMROOT', 'LANG', 'LC_ALL')}
        self.env.update(HOME=str(self.root), XDG_CONFIG_HOME=str(self.root / 'config'),
                        XDG_STATE_HOME=str(self.root / 'state'),
                        TYPESAFE_API_KEY_FILE=str(self.keyfile),
                        JEV_LEDGER=str(self.root / 'ledger.jsonl'),
                        JEV_API_BASE='http://127.0.0.1:' + str(self.server.server_port),
                        NO_PROXY='127.0.0.1', no_proxy='127.0.0.1')
        self.server.requests = []
        self.server.delay = 0
        self.server.response_headers = {}
        self.server.disconnect = False
        self.respond()
        self.results = []

    def tearDown(self):
        for result in self.results:
            self.assertNotIn(FAKE_KEY, result.stdout)
            self.assertNotIn(FAKE_KEY, result.stderr)
        for ledger in self.root.rglob('*.jsonl'):
            self.assertNotIn(FAKE_KEY, ledger.read_text())

    def respond(self, kind='choice', answers=None):
        self.server.reply = (200, {'model': 'jev-1.14.0',
                                  'answers': answers if answers is not None else {'q': answer(kind)},
                                  'usage': {'input_tokens': 100, 'output_tokens': 2}})

    def run_cli(self, *args, stdin=None, expected=0):
        result = subprocess.run([sys.executable, str(SCRIPT), *args], env=self.env,
                                input=stdin, text=True, capture_output=True, timeout=5)
        self.results.append(result)
        self.assertEqual(result.returncode, expected, result.stderr)
        return result

    def flags(self, kind='choice'):
        flags = ['--state', 'synthetic session text', '--question', kind,
                 '--instructions', 'Pick the best label']
        if kind == 'choice':
            flags += ['--options', 'yes=ready,unclear=']
        elif kind == 'score':
            flags += ['--options', 'low,high']
        return flags

    def body(self):
        return json.loads(self.server.requests[-1][3])

    def ledger(self):
        return [json.loads(line) for line in Path(self.env['JEV_LEDGER']).read_text().splitlines()]

    def test_flag_shapes_and_pinned_default(self):
        for kind, criteria in [('choice', {'yes': 'ready', 'unclear': None}),
                               ('noul', None), ('score', ['low', 'high'])]:
            with self.subTest(kind=kind):
                self.respond(kind)
                out = json.loads(self.run_cli(*self.flags(kind)).stdout)
                body = self.body()
                self.assertEqual(body['model'], 'jev-1.14.0')
                self.assertEqual(body['state'], 'synthetic session text')
                self.assertEqual(body['questions']['q']['type'], kind)
                self.assertEqual(body['questions']['q'].get('criteria'), criteria)
                method, path, headers, _ = self.server.requests[-1]
                self.assertEqual((method, path), ('POST', '/v1/systemone'))
                self.assertEqual(headers['Authorization'], 'Bearer ' + FAKE_KEY)
                self.assertEqual(headers['Content-Type'], 'application/json')
                self.assertAlmostEqual(out['cost_usd'], 100 * 0.042e-6)
                self.assertGreaterEqual(out['latency_ms'], 0)

    def test_request_json_file_and_stdin_multiple_questions(self):
        card = {'state': {'pane': 'synthetic'}, 'questions': {
            'label': {'type': 'choice', 'instructions': 'label', 'criteria': {'yes': None, 'unclear': None}},
            'human': {'type': 'noul', 'instructions': 'needs human',
                      'criteria': {'true': 'yes', 'false': 'no'}}}}
        self.respond(answers={'label': answer(), 'human': answer('noul')})
        path = self.root / 'card.json'
        path.write_text(json.dumps(card))
        for source in (str(path), '-'):
            self.run_cli('--request-json', source, stdin=json.dumps(card))
            self.assertEqual(self.body(), dict(card, model='jev-1.14.0'))

    def test_state_file_stdin_and_model_overrides(self):
        path = self.root / 'state.txt'
        path.write_text('synthetic café')
        rest = self.flags('noul')[2:]
        self.env['JEV_MODEL'] = 'jev-test-env'
        self.respond('noul')
        self.run_cli('--state-file', str(path), *rest)
        self.assertEqual(self.body()['state'], 'synthetic café')
        self.assertEqual(self.body()['model'], 'jev-test-env')
        self.run_cli('--state', '-', *rest, '--model', 'jev-test-flag', stdin='synthetic stdin')
        self.assertEqual(self.body()['state'], 'synthetic stdin')
        self.assertEqual(self.body()['model'], 'jev-test-flag')

    def test_check_get_only(self):
        for models in (['jev-1.14.0'], {'models': ['jev-1.14.0']}, {'data': [{'id': 'jev-1.14.0'}]}):
            self.server.reply = (200, models)
            out = json.loads(self.run_cli('--check').stdout)
            self.assertEqual(out, {'ok': True, 'models': ['jev-1.14.0']})
            self.assertEqual(self.server.requests[-1][0:2], ('GET', '/v1/models'))
            self.assertEqual(self.server.requests[-1][3], b'')
        self.assertEqual(len(self.ledger()), 3)
        self.assertEqual(self.ledger()[0]['cost_usd'], 0)

    def test_dry_run_no_http_or_ledger(self):
        out = json.loads(self.run_cli(*self.flags(), '--dry-run').stdout)
        self.assertEqual(out['model'], 'jev-1.14.0')
        self.assertEqual(self.server.requests, [])
        self.assertFalse(Path(self.env['JEV_LEDGER']).exists())

    def test_threshold_uses_top_probability_not_confidence(self):
        for kind in ('choice', 'score', 'noul'):
            with self.subTest(kind=kind):
                self.respond(kind)
                out = json.loads(self.run_cli(*self.flags(kind), '--min-confidence', '0.95', expected=5).stdout)
                self.assertTrue(out['answers']['q']['abstain'])
                self.assertAlmostEqual(out['answers']['q']['top_probability'], 0.9 if kind == 'noul' else 0.6)
                self.assertEqual(self.ledger()[-1]['exit'], 5)
        out = json.loads(self.run_cli(*self.flags('noul'), '--min-confidence', '0.9').stdout)
        self.assertFalse(out['answers']['q']['abstain'])

    def test_any_abstention_exits_five(self):
        card = {'state': 'synthetic', 'questions': {
            name: {'type': 'noul', 'instructions': 'classify'} for name in ('a', 'b')}}
        self.respond(answers={'a': {'type': 'noul', 'noul': 0.99}, 'b': {'type': 'noul', 'noul': 0.5}})
        out = json.loads(self.run_cli('--request-json', '-', '--min-confidence', '0.9',
                                     stdin=json.dumps(card), expected=5).stdout)
        self.assertFalse(out['answers']['a']['abstain'])
        self.assertTrue(out['answers']['b']['abstain'])

    def test_http_errors_exact_body_and_billing_hint(self):
        for status in (400, 402, 422, 429, 500):
            raw = b'{"detail":"billing_error: exact vendor wording"}'
            self.server.reply = (status, raw)
            result = self.run_cli(*self.flags(), expected=3)
            self.assertIn('HTTP ' + str(status) + '\n' + raw.decode(), result.stderr)
            self.assertEqual('console balance' in result.stderr, status == 402)
            self.assertEqual(self.ledger()[-1]['exit'], 3)

    def test_http_error_truncation_and_key_echo_redaction(self):
        self.server.reply = (500, b'x' * 2100)
        result = self.run_cli(*self.flags(), expected=3)
        self.assertEqual(result.stderr, 'HTTP 500\n' + 'x' * 2000 + '\n')
        self.server.reply = (500, FAKE_KEY.encode())
        self.assertIn('[REDACTED]', self.run_cli(*self.flags(), expected=3).stderr)

    def test_unparseable_missing_and_invalid_responses(self):
        responses = [b'not JSON', b'NaN', b'\xff', {}, [], {'answers': {}},
                     {'model': 'jev', 'answers': {}, 'usage': {'input_tokens': 100, 'output_tokens': 0}}]
        for response in responses:
            self.server.reply = (200, response)
            self.run_cli(*self.flags(), expected=4)
            self.assertEqual(self.ledger()[-1]['exit'], 4)
        self.respond()
        self.server.reply[1]['answers']['q']['probabilities'] = {'yes': 'bad'}
        self.run_cli(*self.flags(), expected=4)

    def test_bad_options_and_input(self):
        cases = [self.flags() + ['--options', 'bad'], self.flags() + ['--options', 'a=x,a=y'],
                 self.flags('score') + ['--options', 'low,,high'],
                 self.flags('noul') + ['--options', 'a=x'],
                 self.flags() + ['--min-confidence', 'nan'], self.flags() + ['--timeout', '0'],
                 self.flags() + ['--min-confidence', '1.1'],
                 self.flags() + ['--state-file', 'missing'], ['--check', '--state', 'text']]
        for flags in cases:
            self.run_cli(*flags, expected=2)
        for card in ('{bad', '{}', '{"model":"jev"}'):
            self.run_cli('--request-json', '-', stdin=card, expected=2)
        self.assertEqual(self.server.requests, [])

    def test_state_limit_utf8_and_object(self):
        self.run_cli('--state', 'éé', *self.flags('noul')[2:], '--max-state-bytes', '3', expected=2)
        self.run_cli(*self.flags(), '--max-state-bytes', '1', expected=2)
        card = {'state': {'text': 'too big'}, 'questions': {'q': {'type': 'noul', 'instructions': 'q'}}}
        self.run_cli('--request-json', '-', '--max-state-bytes', '2', stdin=json.dumps(card), expected=2)
        self.assertEqual(self.server.requests, [])

    def test_secret_classes_refuse_without_echoing(self):
        samples = [('private key', '-----BEGIN RSA PRIVATE KEY'), ('sk token', 'sk-' + 'A1' * 12),
                   ('GitHub token', 'ghp_' + 'A' * 22), ('Slack token', 'xoxb-' + 'synthetic'),
                   ('AWS access key', 'AKIA' + 'A' * 16), ('JWT', 'eyJ' + 'A' * 22 + '.'),
                   ('API key value', FAKE_KEY)]
        for label, secret in samples:
            result = self.run_cli('--state', secret, *self.flags('noul')[2:], expected=2)
            self.assertIn(label, result.stderr)
            self.assertNotIn(secret, result.stderr)
        card = {'state': 'synthetic', 'questions': {'q': {'type': 'noul', 'instructions': samples[0][1]}}}
        self.run_cli('--request-json', '-', stdin=json.dumps(card), expected=2)
        self.assertEqual(self.server.requests, [])

    def test_synthetic_unscanned_override_still_protects_output(self):
        self.run_cli('--state', 'sk-' + 'A1' * 12, *self.flags()[2:], '--allow-unscanned')
        self.respond()
        self.server.reply[1]['model'] = FAKE_KEY
        self.run_cli(*self.flags())
        self.run_cli('--state', FAKE_KEY, *self.flags()[2:], '--allow-unscanned', '--dry-run')

    def test_daily_cap_and_old_entries(self):
        today = dt.datetime.now(dt.timezone.utc).date().isoformat()
        path = Path(self.env['JEV_LEDGER'])
        path.write_text(json.dumps({'ts': today, 'cost_usd': 0.5}) + '\n')
        result = self.run_cli(*self.flags(), expected=3)
        self.assertIn('daily cap reached', result.stderr)
        self.assertEqual(self.server.requests, [])
        path.write_text(json.dumps({'ts': '2000-01-01', 'cost_usd': 100}) + '\n')
        self.run_cli(*self.flags())
        self.env['JEV_DAILY_CAP_USD'] = '0'
        self.run_cli(*self.flags(), expected=3)
        self.assertEqual(len(self.server.requests), 1)

    def test_invalid_ledger_or_cap_fails_before_http(self):
        Path(self.env['JEV_LEDGER']).write_text('not-json\n')
        self.run_cli(*self.flags(), expected=3)
        Path(self.env['JEV_LEDGER']).unlink()
        self.env['JEV_DAILY_CAP_USD'] = 'nan'
        self.run_cli(*self.flags(), expected=3)
        self.assertEqual(self.server.requests, [])

    def test_ledger_fields_no_state(self):
        self.run_cli(*self.flags())
        entry = self.ledger()[0]
        self.assertEqual(set(entry), {'ts', 'model', 'input_tokens', 'cost_usd', 'latency_ms', 'exit'})
        self.assertEqual(entry['exit'], 0)
        self.assertEqual(entry['input_tokens'], 100)
        self.assertNotIn('synthetic session text', Path(self.env['JEV_LEDGER']).read_text())

    def test_key_precedence_missing_and_default_path(self):
        self.env['TYPESAFE_API_KEY'] = ' ' + FAKE_KEY + ' \n'
        self.keyfile.unlink()
        self.run_cli(*self.flags())
        del self.env['TYPESAFE_API_KEY']
        result = self.run_cli(*self.flags(), expected=3)
        self.assertEqual(result.stderr.strip(), str(self.keyfile))
        del self.env['TYPESAFE_API_KEY_FILE']
        default = self.root / 'config' / 'typesafe' / 'api_key'
        result = self.run_cli(*self.flags(), expected=3)
        self.assertEqual(result.stderr.strip(), str(default))
        default.parent.mkdir(parents=True)
        default.write_text(FAKE_KEY)
        self.run_cli(*self.flags())
        self.env['TYPESAFE_API_KEY'] = '   '
        self.run_cli(*self.flags(), expected=3)

    def test_default_ledger_path(self):
        del self.env['JEV_LEDGER']
        self.run_cli(*self.flags())
        self.assertTrue((self.root / 'state' / 'jev-delegate' / 'ledger.jsonl').exists())

    def test_network_disconnect_is_call_failure(self):
        self.server.disconnect = True
        result = self.run_cli(*self.flags(), expected=3)
        self.assertNotIn('Traceback', result.stderr)
        self.assertEqual(self.ledger()[-1]['exit'], 3)

    def test_timeout_and_redirect_not_followed(self):
        self.server.delay = 0.15
        self.run_cli(*self.flags(), '--timeout', '0.02', expected=3)
        self.assertEqual(self.ledger()[-1]['exit'], 3)
        self.server.delay = 0
        self.server.response_headers = {'Location': self.env['JEV_API_BASE'] + '/redirect-target'}
        self.server.reply = (302, b'redirect')
        self.run_cli(*self.flags(), expected=3)
        self.assertEqual(len(self.server.requests), 2)


if __name__ == '__main__':
    unittest.main()
