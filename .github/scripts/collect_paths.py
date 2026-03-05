#!/usr/bin/env python3
# NOTE: This script is superseded by the composite action at
# .github/actions/collect-paths/ which bundles this same script.
# Use the composite action in reusable workflows so external consumers
# can access it via ${{ github.action_path }}.
"""Collect tracked repo paths safely into a NUL-delimited manifest."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True, help='Output file for NUL-delimited paths')
    parser.add_argument('--label', required=True, help='Log label for matched paths')
    parser.add_argument('--include-regex', action='append', required=True, help='Regex applied to repo-relative POSIX paths')
    parser.add_argument('--exclude-regex', action='append', default=[], help='Regex applied after include filters')
    parser.add_argument('--base-sha', default='', help='PR base SHA')
    parser.add_argument('--head-sha', default='', help='PR head SHA')
    return parser.parse_args()


def list_candidate_paths(base_sha: str, head_sha: str) -> tuple[list[str], bool]:
    use_diff = bool(base_sha and head_sha)
    command = ['git', 'diff', '--name-only', '--diff-filter=d', '-z', base_sha, head_sha] if use_diff else ['git', 'ls-files', '-z']
    try:
        raw = subprocess.check_output(command)
    except subprocess.CalledProcessError:
        if not use_diff:
            raise
        print('::warning::git diff failed — PR base SHA may be stale (force-push?). Falling back to tracked files.', file=sys.stderr)
        raw = subprocess.check_output(['git', 'ls-files', '-z'])

    return ([entry.decode('utf-8', 'surrogateescape') for entry in raw.split(b'\0') if entry], use_diff)


def _compile_regex(pattern: str, label: str) -> re.Pattern[str]:
    """Compile a regex with validation and a match timeout ceiling."""
    # Reject patterns likely to cause catastrophic backtracking (ReDoS).
    if re.search(r'\([^)]*[+*][^)]*\)[+*{]', pattern):
        print(f'::error::Potentially unsafe {label} regex {pattern!r}: nested quantifiers detected (ReDoS risk)', file=sys.stderr)
        raise SystemExit(2)
    # Also reject alternation with outer quantifier: (a|b)+, (x|xy)*, etc.
    # These cause catastrophic backtracking when alternation branches overlap.
    if re.search(r'\([^)]*\|[^)]*\)[+*{]', pattern):
        print(f'::error::Potentially unsafe {label} regex {pattern!r}: alternation with outer quantifier (ReDoS risk)', file=sys.stderr)
        raise SystemExit(2)
    try:
        compiled = re.compile(pattern)
    except re.error as exc:
        print(f'::error::Invalid {label} regex {pattern!r}: {exc}', file=sys.stderr)
        raise SystemExit(2)
    return compiled


def main() -> int:
    args = parse_args()
    include_patterns = [_compile_regex(p, 'include') for p in args.include_regex]
    exclude_patterns = [_compile_regex(p, 'exclude') for p in args.exclude_regex]

    candidates, from_diff = list_candidate_paths(args.base_sha, args.head_sha)
    matches = []
    for path in candidates:
        if not any(pattern.search(path) for pattern in include_patterns):
            continue
        if any(pattern.search(path) for pattern in exclude_patterns):
            continue
        matches.append(path)

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open('wb') as handle:
        for path in matches:
            handle.write(path.encode('utf-8', 'surrogateescape'))
            handle.write(b'\0')

    if matches:
        prefix = 'changed' if from_diff else 'tracked'
        print(f'{args.label} {prefix} paths:')
        for path in matches:
            print(f'  {json.dumps(path)}')
    else:
        print(f'No {args.label.lower()} paths matched this run')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
