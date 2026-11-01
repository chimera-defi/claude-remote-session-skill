#!/usr/bin/env bash
# Snapshot local memory repositories; Python keeps paths and content binary-safe.
exec python3 - "$@" <<'PY'
"""Commit local notes, excluding secret-shaped files. Never contact remotes."""
import argparse
from fnmatch import fnmatchcase
import json
import os
from pathlib import Path
import re
import subprocess
import sys


SECRET = re.compile(
    rb'-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----|'
    rb'sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|'
    rb'github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|'
    rb'xox[abprs]-[A-Za-z0-9-]{10,}|'
    rb'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}')
ASSIGNMENT = re.compile(
    rb'''(password|passwd|secret|token|api[_-]?key|private[_-]?key|mnemonic|seed phrase)\s*["']?\s*[:=]\s*["']?[^\s"']{6,}''', re.I)
HEX_KEY = re.compile(rb'(?<![0-9a-f])(?:0x)?[0-9a-f]{64}(?![0-9a-f])', re.I)
KEY_CONTEXT = re.compile(rb'key|private|secret|wallet|seed', re.I)


def secret(name, content):
    path = Path(name)
    if 'secrets' in path.parts[:-1] or any(fnmatchcase(path.name, pattern) for pattern in
            ('.env', '.env.*', '*.pem', '*.key', '*.p12', '*.pfx',
             'id_rsa*', 'id_ed25519*', '*keystore*')):
        return True
    return bool(SECRET.search(content) or any(
        ASSIGNMENT.search(line) or (HEX_KEY.search(line) and KEY_CONTEXT.search(line))
        for line in content.splitlines()))


def git(repo, *args):
    result = subprocess.run(
        ['git', '-c', 'core.hooksPath=/dev/null', '-C', str(repo), *args],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        env={**os.environ, 'GIT_OPTIONAL_LOCKS': '0', 'GIT_LITERAL_PATHSPECS': '1'})
    if result.returncode:
        # Git diagnostics can include file content or credential-bearing paths.
        raise RuntimeError(f'git {args[0]} failed (exit {result.returncode})')
    return result.stdout


def names(data):
    return {os.fsdecode(p) for p in data.split(b'\0') if p}


def snapshot(repo, dry):
    gitdir = Path(os.fsdecode(git(repo, 'rev-parse', '--absolute-git-dir')).strip())
    if (gitdir / 'index.lock').exists():
        return 'skipped(index.lock)'
    if any((gitdir / name).exists() for name in
           ('MERGE_HEAD', 'rebase-merge', 'rebase-apply')):
        return 'skipped(merge/rebase in progress)'
    staged = names(git(repo, 'diff', '--cached', '--name-only', '-z'))
    pending = (staged | names(git(repo, 'diff', '--name-only', '-z')) |
               names(git(repo, 'ls-files', '--others', '--exclude-standard', '-z')))
    if not pending:
        return 'clean'
    skipped = set()
    nested = set()
    for name in pending:
        path = repo / name
        if path.is_symlink():
            content = os.fsencode(os.readlink(path))
        elif path.is_file():
            content = path.read_bytes()
        elif path.is_dir():
            # Nested repositories are visited separately, never staged as gitlinks.
            nested.add(name)
            continue
        else:
            content = b''  # A deletion contains no new secret.
        if secret(name, content):
            skipped.add(name)
    for name in staged:
        entries = git(repo, 'ls-files', '--stage', '-z', '--', name)
        for entry in entries.split(b'\0'):
            if entry:
                metadata = entry.split(b'\t', 1)[0].split()
                if metadata[2] != b'0':
                    return 'skipped(unmerged index)'
                if metadata[0] != b'160000' and secret(
                        name, git(repo, 'cat-file', 'blob', metadata[1].decode())):
                    skipped.add(name)
    if staged & skipped:
        return 'skipped(secret); index preserved'
    if staged & nested:
        return 'skipped(nested repo in index; index preserved)'
    safe = sorted(pending - skipped - nested)
    note = f'; skipped(secret): {len(skipped)} files' if skipped else ''
    if nested:
        note += f'; skipped(nested repo): {len(nested)} files'
    if not safe:
        return note.removeprefix('; ')
    if dry:
        return f'skipped(dry-run: would stage {len(safe)} files)' + note
    # Literal pathspecs handle whitespace, newlines, leading dashes and colons.
    git(repo, 'add', '-A', '--', *safe)
    changed = names(git(repo, 'diff', '--cached', '--name-only', '-z'))
    # Also inspect the actual staged blobs: clean filters may alter file content.
    for name in changed:
        for entry in git(repo, 'ls-files', '--stage', '-z', '--', name).split(b'\0'):
            if entry:
                metadata = entry.split(b'\t', 1)[0].split()
                if metadata[0] != b'160000' and secret(
                        name, git(repo, 'cat-file', 'blob', metadata[1].decode())):
                    return 'skipped(secret); found in staged content'
    if not changed:
        return 'clean' + note
    git(repo, 'commit', '-m', f'snapshot: {len(changed)} files (memory-snapshot)')
    return f'committed {len(changed)}' + note


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--home', default=os.environ.get('HOME', str(Path.home())))
    parser.add_argument('--config')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    home = Path(args.home).absolute()

    def path(value):
        value = str(value)
        if value == '~' or value.startswith('~/'):
            return home / value[2:] if value != '~' else home
        p = Path(value)
        return p if p.is_absolute() else home / p

    overlay = os.environ.get('CRSS_HOME') or str(
        Path(os.environ.get('XDG_CONFIG_HOME') or home / '.config') / 'crss')
    filename = args.config or os.environ.get('HOST_TOOLS_CONFIG') or str(Path(overlay) / 'host-tools.json')
    try:
        config = json.loads(path(filename).read_text()).get('memory-snapshot', {})
    except FileNotFoundError:
        config = {}
    repos = set()

    def visit(directory, depth):
        if directory.is_symlink() or not directory.is_dir():
            return
        if (directory / '.git').exists():
            repos.add(directory.absolute())
        if depth < 5:
            for child in sorted(directory.iterdir()):
                if child.name != '.git' and not child.is_symlink() and child.is_dir():
                    visit(child, depth + 1)

    for root in config.get('roots', ['~/agent-memory']):
        visit(path(root), 0)
    for extra in config.get('extra_repos', []):
        visit(path(extra), 5)
    failed = False
    for repo in sorted(repos):
        try:
            result = snapshot(repo, args.dry_run)
        except (OSError, RuntimeError) as exc:
            result = f'skipped(hard error: {exc.__class__.__name__})'
            failed = True
        print(f'{str(repo).replace(chr(10), "?").replace(chr(13), "?")}: {result}')
    return int(failed)


try:
    sys.exit(main())
except (OSError, ValueError, TypeError, AttributeError):
    print('memory-snapshot: hard error reading config or roots', file=sys.stderr)
    sys.exit(1)
PY
