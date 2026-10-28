#!/usr/bin/env python3
"""Small, dependency-free System One client. See references/jev-delegate.md."""

import argparse
import datetime as dt
import http.client
import json
import math
import os
from pathlib import Path
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

PRICE = 0.042e-6
PATTERNS = (
    ('private key', r'-----BEGIN [A-Z ]*PRIVATE KEY'),
    ('sk token', r'sk-[A-Za-z0-9_-]{20,}'),
    ('GitHub token', r'ghp_[A-Za-z0-9]{20,}'),
    ('GitHub token', r'github_pat_[A-Za-z0-9_]{20,}'),
    ('Slack token', r'xox[abp]-'),
    ('AWS access key', r'AKIA[0-9A-Z]{16}'),
    ('JWT', r'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*\.?'),
)


class Failure(Exception):
    def __init__(self, code, message):
        self.code, self.message = code, message


class Parser(argparse.ArgumentParser):
    def error(self, message):
        # argparse normally echoes invalid values, which can contain credentials.
        raise Failure(2, 'invalid arguments; see --help')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # Never forward the bearer credential to a redirect target.


def dumps(value):
    return json.dumps(value, ensure_ascii=False, allow_nan=False)


def read_text(path):
    try:
        return sys.stdin.read() if path == '-' else Path(path).read_text(encoding='utf-8')
    except (OSError, UnicodeError):
        raise Failure(2, 'cannot read input') from None


def parse_json(text, code):
    try:
        return json.loads(text, parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
    except (ValueError, RecursionError):
        raise Failure(code, 'invalid JSON') from None


def number(value, low=0, high=math.inf):
    return (type(value) in (int, float) and math.isfinite(value)
            and low <= value <= high)


def validate_body(body, limit):
    if not isinstance(body, dict) or set(body) != {'model', 'state', 'questions'}:
        raise Failure(2, 'request requires state and questions only (model uses --model)')
    if not isinstance(body['model'], str) or not body['model'].strip():
        raise Failure(2, 'invalid model')
    state = body['state']
    if not isinstance(state, (str, dict)):
        raise Failure(2, 'state must be text or an object')
    size = len((state if isinstance(state, str) else dumps(state)).encode('utf-8'))
    if size > limit:
        raise Failure(2, 'max-state-bytes exceeded')
    questions = body['questions']
    if not isinstance(questions, dict) or not questions:
        raise Failure(2, 'questions must be a nonempty object')
    for qid, q in questions.items():
        if not qid or not isinstance(q, dict) or set(q) - {'type', 'instructions', 'criteria'}:
            raise Failure(2, 'invalid question')
        if not isinstance(q.get('instructions'), str) or not q['instructions'].strip():
            raise Failure(2, 'question requires instructions')
        kind, criteria = q.get('type'), q.get('criteria')
        if kind == 'choice':
            valid = (isinstance(criteria, dict) and 1 <= len(criteria) <= 255
                     and all(k.strip() and (v is None or isinstance(v, str))
                             for k, v in criteria.items()))
        elif kind == 'score':
            valid = (isinstance(criteria, list) and 1 <= len(criteria) <= 10
                     and all(isinstance(v, str) and v.strip() for v in criteria))
        elif kind == 'noul':
            valid = ('criteria' not in q or (isinstance(criteria, dict)
                     and set(criteria) == {'true', 'false'}
                     and all(isinstance(v, str) for v in criteria.values())))
        else:
            valid = False
        if not valid:
            raise Failure(2, 'invalid question type or criteria')


def build_body(args):
    if args.request_json is not None:
        if any(v is not None for v in (args.question, args.instructions, args.options)):
            raise Failure(2, 'request-json cannot be combined with question flags')
        body = parse_json(read_text(args.request_json), 2)
        if not isinstance(body, dict) or 'model' in body:
            raise Failure(2, 'request-json must be an object without model')
        body['model'] = args.model
    else:
        if args.state is None and args.state_file is None:
            raise Failure(2, 'state is required')
        if not args.question or args.instructions is None:
            raise Failure(2, 'question and instructions are required')
        state = (read_text(args.state_file) if args.state_file is not None else
                 read_text('-') if args.state == '-' else args.state)
        q = {'type': args.question, 'instructions': args.instructions}
        if args.question == 'choice':
            criteria = {}
            for option in (args.options or '').split(','):
                name, sep, desc = option.partition('=')
                name = name.strip()
                if not sep or not name or name in criteria:
                    raise Failure(2, 'choice options require unique name=description entries')
                criteria[name] = desc.strip() or None
            q['criteria'] = criteria
        elif args.question == 'score':
            q['criteria'] = [s.strip() for s in (args.options or '').split(',')]
        elif args.options is not None:
            raise Failure(2, 'noul does not accept options; use request-json for criteria')
        body = {'model': args.model, 'state': state, 'questions': {'q': q}}
    validate_body(body, args.max_state_bytes)
    return body


def key_path():
    config = Path(os.environ.get('XDG_CONFIG_HOME') or Path.home() / '.config')
    return Path(os.environ.get('TYPESAFE_API_KEY_FILE', config / 'typesafe' / 'api_key'))


def load_key():
    path = key_path()
    key = os.environ.get('TYPESAFE_API_KEY')
    if key is None:
        try:
            key = path.read_text(encoding='utf-8')
        except (OSError, UnicodeError):
            raise Failure(3, str(path)) from None
    key = key.strip()
    if not key:
        raise Failure(3, str(path))
    return key


def scan(body, key):
    serialized = dumps(body)
    for name, pattern in PATTERNS:
        if re.search(pattern, serialized):
            raise Failure(2, 'refused secret pattern: ' + name)
    if key in serialized or dumps(key)[1:-1] in serialized:
        raise Failure(2, 'refused secret pattern: API key value')


def redact(text, key):
    if key:
        for secret in sorted({key, dumps(key)[1:-1]}, key=len, reverse=True):
            text = text.replace(secret, '[REDACTED]')
    return text


def redact_object(value, key):
    if isinstance(value, str):
        return redact(value, key)
    if isinstance(value, dict):
        return {redact(k, key): redact_object(v, key) for k, v in value.items()}
    if isinstance(value, list):
        return [redact_object(v, key) for v in value]
    return value


def contains_credential(value, key):
    if isinstance(value, str):
        return key in value
    if isinstance(value, dict):
        return any(contains_credential(k, key) or contains_credential(v, key)
                   for k, v in value.items())
    if isinstance(value, list):
        return any(contains_credential(v, key) for v in value)
    return False


def ledger_open():
    root = Path(os.environ.get('XDG_STATE_HOME') or Path.home() / '.local' / 'state')
    path = Path(os.environ.get('JEV_LEDGER', root / 'jev-delegate' / 'ledger.jsonl'))
    try:
        cap = float(os.environ.get('JEV_DAILY_CAP_USD', '0.50'))
        if not number(cap):
            raise ValueError()
        path.parent.mkdir(parents=True, exist_ok=True)
        ledger = path.open('a+', encoding='utf-8')
        try:
            ledger.seek(0)
            today = dt.datetime.now(dt.timezone.utc).date().isoformat()
            total = 0.0
            for line in ledger:
                entry = json.loads(line)
                if (not isinstance(entry, dict) or not number(entry.get('cost_usd'))
                        or not isinstance(entry.get('ts'), str)):
                    raise ValueError()
                if dt.datetime.fromisoformat(entry['ts']).date().isoformat() == today:
                    total += entry['cost_usd']
            if total >= cap:
                raise Failure(3, 'daily cap reached')
            return ledger
        except Exception:
            ledger.close()
            raise
    except Failure:
        raise
    except (OSError, ValueError, OverflowError):
        raise Failure(3, 'cannot validate spend ledger or daily cap') from None


def response_result(data, body, threshold):
    if not isinstance(data, dict):
        raise Failure(4, 'invalid response object')
    usage = data.get('usage')
    if (not isinstance(data.get('model'), str) or not isinstance(usage, dict)
            or any(type(usage.get(k)) is not int or usage[k] < 0
                   for k in ('input_tokens', 'output_tokens'))
            or not isinstance(data.get('answers'), dict)):
        raise Failure(4, 'invalid response model, answers or usage')
    answers = {}
    abstains = False
    for qid, question in body['questions'].items():
        answer = data['answers'].get(qid)
        kind = question['type']
        if not isinstance(answer, dict) or answer.get('type') != kind:
            raise Failure(4, 'missing or invalid question answer')
        if kind == 'noul':
            p = answer.get('noul')
            if not number(p, 0, 1):
                raise Failure(4, 'invalid noul probability')
            top = max(p, 1 - p)
        else:
            probs = answer.get('probabilities')
            if (not isinstance(probs, dict) or set(probs) != set(question['criteria'])
                    or not all(number(p, 0, 1) for p in probs.values())
                    or not 0.95 <= sum(probs.values()) <= 1.05
                    or not number(answer.get('confidence'), 0, 1)):
                raise Failure(4, 'invalid answer probabilities or confidence')
            if kind == 'choice' and (not isinstance(answer.get('choice'), str)
                                     or answer['choice'] not in question['criteria']):
                raise Failure(4, 'invalid choice answer')
            if kind == 'score' and (not number(answer.get('score'))
                                    or not isinstance(answer.get('legend'), dict)):
                raise Failure(4, 'invalid score answer')
            top = max(probs.values())
        answer = dict(answer)
        if threshold is not None:
            answer.update(top_probability=top, abstain=top < threshold)
            abstains |= answer['abstain']
        answers[qid] = answer
    return {'model': data['model'], 'answers': answers, 'usage': usage}, 5 if abstains else 0


def call(args, body, key):
    base = os.environ.get('JEV_API_BASE', 'https://api.typesafe.ai').rstrip('/')
    parsed = urllib.parse.urlsplit(base)
    if parsed.scheme not in ('http', 'https') or not parsed.hostname or parsed.username or parsed.password:
        raise Failure(2, 'invalid API base URL')
    headers = {'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'}
    payload = None if args.check else dumps(body).encode('utf-8')
    try:
        request = urllib.request.Request(base + ('/v1/models' if args.check else '/v1/systemone'),
                                         data=payload, headers=headers)
    except ValueError:
        raise Failure(2, 'invalid request configuration') from None
    ledger = ledger_open()
    started = time.monotonic()
    code, tokens, model = 3, 0, args.model
    try:
        try:
            with urllib.request.build_opener(NoRedirect).open(request, timeout=args.timeout) as response:
                raw = response.read().decode('utf-8')
        except urllib.error.HTTPError as exc:
            try:
                error_body = exc.read().decode('utf-8', errors='replace')
                try:
                    decoded_body = json.loads(error_body)
                except ValueError:
                    decoded_body = error_body
                if contains_credential(decoded_body, key):
                    error_body = '[body withheld: contained credential]'
                error_body = redact(error_body, key)[:2000]
            except Exception:
                error_body = ''
            message = f'HTTP {exc.code}\n{error_body}'
            if exc.code == 402:
                message += '\nA console balance is not proof of API credit.'
            raise Failure(3, message) from None
        except UnicodeError:
            code = 4
            raise Failure(4, 'response is not UTF-8') from None
        except (OSError, ValueError, urllib.error.URLError, http.client.HTTPException) as exc:
            raise Failure(3, f'API call failed: {type(exc).__name__}: {exc}') from None
        code = 4
        data = parse_json(raw, 4)
        if args.check:
            # Accept alias names, plain lists and OpenAI-style model IDs.
            models = data if isinstance(data, list) else data.get('models', data.get('data')) if isinstance(data, dict) else None
            if not isinstance(models, list):
                raise Failure(4, 'invalid models response')
            ids = [m if isinstance(m, str) else m.get('name', m.get('id')) if isinstance(m, dict) else None for m in models]
            if not all(isinstance(m, str) and m for m in ids):
                raise Failure(4, 'invalid model IDs')
            code = 0
            return {'ok': True, 'models': ids}, code
        if isinstance(data, dict) and isinstance(data.get('usage'), dict):
            reported = data['usage'].get('input_tokens')
            if type(reported) is int and reported >= 0:
                tokens = reported
        result, code = response_result(data, body, args.min_confidence)
        model = result['model']
        result.update(cost_usd=tokens * PRICE, latency_ms=round((time.monotonic() - started) * 1000))
        return result, code
    finally:
        entry = {'ts': dt.datetime.now(dt.timezone.utc).isoformat(), 'model': model,
                 'input_tokens': tokens, 'cost_usd': tokens * PRICE,
                 'latency_ms': round((time.monotonic() - started) * 1000), 'exit': code}
        try:
            ledger.write(dumps(redact_object(entry, key)) + '\n')
            ledger.flush()
        except OSError:
            raise Failure(3, 'cannot append spend ledger') from None
        finally:
            ledger.close()


def main():
    key = ''
    try:
        parser = Parser(description=__doc__)
        source = parser.add_mutually_exclusive_group()
        source.add_argument('--state')
        source.add_argument('--state-file')
        source.add_argument('--request-json')
        parser.add_argument('--question', choices=('choice', 'noul', 'score'))
        parser.add_argument('--instructions')
        parser.add_argument('--options')
        parser.add_argument('--model', default=os.environ.get('JEV_MODEL', 'jev-1.14.0'))
        parser.add_argument('--min-confidence', type=float)
        parser.add_argument('--timeout', type=float, default=15)
        parser.add_argument('--max-state-bytes', type=int, default=200000)
        mode = parser.add_mutually_exclusive_group()
        mode.add_argument('--check', action='store_true')
        mode.add_argument('--dry-run', action='store_true')
        parser.add_argument('--allow-unscanned', action='store_true', help='synthetic data only')
        args = parser.parse_args()
        if (not number(args.timeout, 0) or args.timeout == 0 or args.max_state_bytes < 0
                or (args.min_confidence is not None and not number(args.min_confidence, 0, 1))):
            raise Failure(2, 'invalid timeout, size limit or confidence threshold')
        if args.check and any(v is not None for v in (args.state, args.state_file, args.request_json,
                                                       args.question, args.instructions, args.options)):
            raise Failure(2, 'check does not accept question input')
        body = None if args.check else build_body(args)
        key = load_key()
        if body is not None and not args.allow_unscanned:
            scan(body, key)
        if args.dry_run:
            result, code = body, 0
        else:
            result, code = call(args, body, key)
        print(dumps(redact_object(result, key)))
        return code
    except Failure as exc:
        print(redact(exc.message, key), file=sys.stderr)
        return exc.code
    except (OSError, ValueError, OverflowError, RecursionError):
        print('invalid input or local I/O failure', file=sys.stderr)
        return 2
    except Exception as exc:
        print(redact('internal error: ' + type(exc).__name__, key), file=sys.stderr)
        return 3


if __name__ == '__main__':
    sys.exit(main())
