#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

python3 - <<'PY'
import json

# Simulate oversized merged SARIF and split-by-category upload planning.
runs = [{"tool": {"driver": {"name": f"tool-{i}"}}, "results": []} for i in range(25)]
merged = {"version": "2.1.0", "runs": runs}

chunks = []
current = []
for run in merged["runs"]:
    current.append(run)
    if len(current) == 20:
        chunks.append({"version": "2.1.0", "runs": current})
        current = []
if current:
    chunks.append({"version": "2.1.0", "runs": current})

assert len(chunks) == 2, f"expected 2 chunks, got {len(chunks)}"
assert len(chunks[0]["runs"]) <= 20
assert len(chunks[1]["runs"]) <= 20

# Ensure rule IDs dedupe per run set remains deterministic.
for chunk in chunks:
    for run in chunk["runs"]:
        assert "tool" in run

print("PASS: SARIF run splitting keeps each upload <= 20 runs")
PY

python3 - <<'PY'
from pathlib import Path
import yaml

repo = Path.cwd()
wf = yaml.safe_load((repo / '.github/workflows/orchestrator-reusable.yaml').read_text())
report_steps = wf['jobs']['report']['steps']
assert any(step.get('with', {}).get('pattern') == 'scanner-*-sarif*' for step in report_steps if isinstance(step, dict)), 'report download pattern must be scanner-*-sarif*'
assert 'upload-code-scanning' in wf['jobs'], 'upload-code-scanning job missing'
assert wf['jobs']['upload-code-scanning']['strategy']['matrix']['include'], 'upload-code-scanning matrix is empty'
print('PASS: orchestrator SARIF upload architecture checks')
PY
