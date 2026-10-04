#!/usr/bin/env python3
"""Scan tracked source and reachable history; report locations, never secret values."""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
def git(*args):
    return subprocess.check_output(['git', *args], cwd=root)
rules = {
    'private-key': rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
    'github-token': rb'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b',
    'aws-access-key': rb'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b',
    'credential-assignment': rb'(?i)(?:api[_-]?key|password|secret|access[_-]?token)\s*[:=]\s*[\x22\x27][A-Za-z0-9_+/=-]{20,}[\x22\x27]',
}
issues = set()
seen = set()
for commit in git('rev-list', '--all').decode().splitlines():
    for entry in git('ls-tree', '-r', '-z', commit).split(b'\0'):
        if not entry: continue
        info, name = entry.split(b'\t', 1)
        mode, kind, oid = info.split()
        if kind != b'blob' or oid in seen: continue
        seen.add(oid)
        content = git('cat-file', 'blob', oid.decode())
        for rule, pattern in rules.items():
            if re.search(pattern, content): issues.add((name.decode(), rule))
for name in git('ls-files', '-z', '--cached', '--others', '--exclude-standard').decode().split('\0'):
    if not name: continue
    path = root / name
    if not path.is_file(): continue
    content = path.read_bytes()
    for rule, pattern in rules.items():
        if re.search(pattern, content): issues.add((name, rule))
    if path.suffix in {'.p12', '.pfx', '.key', '.mobileprovision'}:
        issues.add((name, 'signing-material'))
for name, rule in sorted(issues):
    print(f'REVIEW: {name}: {rule}')
email_count = len(set(git('log', '--all', '--format=%ae%n%ce').decode().splitlines()))
print(f'Inspected {len(seen)} historical blobs and current source. {email_count} distinct author/committer email(s) are present in git metadata; values withheld.')
print('Pattern scan is not proof of absence. Review personal data, provenance, and redistribution rights separately.')
sys.exit(1 if issues else 0)
