#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/exploit-guards.txt" <<'TXT'
workflows do not use workflow_run                                  FAIL
  workflow_run triggers present: bad.yaml:workflow_run
  Why: workflow_run can bridge trust boundaries.
  Fix: Replace workflow_run with workflow_call.
TXT

TMP_DIR="$TMP_DIR" python3 - <<'PY'
import json
import os
import re
from pathlib import Path

root = Path(os.environ.get('TMP_DIR', '.'))
text = (root / 'exploit-guards.txt').read_text(encoding='utf-8')
text = re.sub(r'\x1b\[[0-9;]*m', '', text)

rule_id = 'workflows-do-not-use-workflow-run'
sarif = {
    '$schema': 'https://json.schemastore.org/sarif-2.1.0.json',
    'version': '2.1.0',
    'runs': [{
        'tool': {
            'driver': {
                'name': 'exploit-guards',
                'rules': [{
                    'id': rule_id,
                    'shortDescription': {'text': 'workflows do not use workflow_run'},
                    'fullDescription': {'text': 'workflow_run can bridge trust boundaries.'},
                    'help': {
                        'text': 'workflow_run can bridge trust boundaries. Fix: Replace workflow_run with workflow_call.',
                        'markdown': '## Why\n\nworkflow_run can bridge trust boundaries.\n\n## Fix\n\nReplace workflow_run with workflow_call.'
                    },
                    'properties': {'tags': ['security', 'CWE-829']},
                }]
            }
        },
        'invocations': [{'executionSuccessful': True, 'exitCode': 1}],
        'results': [{
            'ruleId': rule_id,
            'level': 'error',
            'message': {'text': 'workflow_run triggers present: bad.yaml:workflow_run'},
            'locations': [{
                'physicalLocation': {
                    'artifactLocation': {'uri': '.github/workflows/bad.yaml'},
                    'region': {'startLine': 1},
                }
            }]
        }]
    }]
}

out = root / 'exploit-guards.sarif'
out.write_text(json.dumps(sarif, indent=2), encoding='utf-8')

loaded = json.loads(out.read_text(encoding='utf-8'))
run = loaded['runs'][0]
assert run['invocations'][0]['exitCode'] == 1
rule = run['tool']['driver']['rules'][0]
assert 'fullDescription' in rule
assert 'help' in rule and 'markdown' in rule['help']
assert 'CWE-829' in rule['properties']['tags']
print('PASS: exploit-guards SARIF conversion schema checks')
PY
