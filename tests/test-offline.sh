#!/usr/bin/env bash
set -uo pipefail


# Requires Python3 (stdlib only), bash, coreutils, ripgrep (rg), and actionlint


# ── Table of Contents ─────────────────────────────────────────────
#   Helper functions & variables .................. ~28
#   Prerequisites ................................. ~406
#   YAML Syntax & Structure ....................... ~426
#   Supply Chain Pinning .......................... ~473
#   Reusable Workflow API ......................... ~495
#   Core Workflow Contracts ....................... ~569
#   Scanner-Specific Checks ...................... ~643
#   Expanded Reusable Workflow API ............... ~782
#   Expanded Workflow Contracts .................. ~803
#   Phase 5-8 Security Remediation .............. ~912
#   Tool Notices & Pinning ...................... ~983
#   Upload Contracts ........................... ~1087
#   Workflow Details ........................... ~1148
#   Setup & Cache Contracts ................... ~1192
#   Failure & Status Messages ................. ~1264
#   Run-Step Contracts ........................ ~1304
#   SARIF Conversion Contracts ................ ~1351
#   Fixture Routing Contracts ................. ~1429
#   Fixture Checks ............................ ~1516
#   README Cross-Checks ....................... ~1642
#   Summary ................................... ~1663
# ───────────────────────────────────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WF_DIR="$REPO_ROOT/.github/workflows"
ORCH_ENTRY="$WF_DIR/_orchestrator-ci.yaml"
ORCH_API="$WF_DIR/orchestrator-reusable.yaml"
README_FILE="$REPO_ROOT/README.md"
FIXTURE_ROOT="$REPO_ROOT/tests/fixtures"
FIXTURE_MANIFEST="$FIXTURE_ROOT/manifest.json"
ONLINE_TEST="$REPO_ROOT/tests/test-online.sh"

pass=0
fail=0
skip=0

WORKFLOW_FILES=(
  _orchestrator-ci.yaml
  _orchestrator-pr.yaml
  orchestrator-reusable.yaml
  _security-general.yaml
  security-go.yaml
  security-rust.yaml
  security-python.yaml
  security-js.yaml
  security-java.yaml
  security-dotnet.yaml
  security-rails.yaml
  security-ruby.yaml
  security-c.yaml
  security-php.yaml
  security-sql.yaml
  security-powershell.yaml
  security-iac.yaml
  security-github-actions.yaml
)

CALLED_WORKFLOWS=(
  _security-general.yaml
  security-go.yaml
  security-rust.yaml
  security-python.yaml
  security-js.yaml
  security-java.yaml
  security-dotnet.yaml
  security-rails.yaml
  security-ruby.yaml
  security-c.yaml
  security-php.yaml
  security-sql.yaml
  security-powershell.yaml
  security-iac.yaml
  security-github-actions.yaml
)

STEP_BASED_WORKFLOWS=(
  orchestrator-reusable.yaml
  _security-general.yaml
  security-go.yaml
  security-rust.yaml
  security-python.yaml
  security-js.yaml
  security-java.yaml
  security-dotnet.yaml
  security-rails.yaml
  security-ruby.yaml
  security-c.yaml
  security-php.yaml
  security-sql.yaml
  security-powershell.yaml
  security-iac.yaml
  security-github-actions.yaml
)

STANDARD_INPUTS=(pr_base_sha pr_head_sha runner_labels)
REPORT_NEEDS=(detect go rust python js java dotnet rails sql powershell iac c general php ruby github-actions)

run_test() {
  local name="$1"
  shift
  printf "%-65s" "$name"
  local output
  if output=$("$@" 2>&1); then
    echo "PASS"
    pass=$((pass + 1))
  else
    echo "FAIL"
    echo "$output" | sed 's/^/  /'
    fail=$((fail + 1))
  fi
}

check_enable_inputs_boolean_true() {
  python3 - "$1" <<'PY'
from pathlib import Path
import sys

lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
current = None
type_ok = False
default_ok = False
found = False
errors = []

for line in lines:
    if line.startswith("      enable_") and line.endswith(":"):
        if current and not (type_ok and default_ok):
            errors.append(f"{current} missing type/default contract")
        current = line.strip()[:-1]
        type_ok = False
        default_ok = False
        found = True
        continue
    if current:
        if line.startswith("      ") and not line.startswith("        "):
            if not (type_ok and default_ok):
                errors.append(f"{current} missing type/default contract")
            current = None
            continue
        if line.strip() == "type: boolean":
            type_ok = True
        if line.strip() == "default: true":
            default_ok = True

if current and not (type_ok and default_ok):
    errors.append(f"{current} missing type/default contract")

if not found:
    raise SystemExit("no enable_* inputs found")
if errors:
    raise SystemExit("; ".join(errors))
PY
}

check_top_level_permissions_contents_read_only() {
  python3 - "$1" <<'PY'
from pathlib import Path
import sys

lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
entries = []
capture = False

for line in lines:
    if line == "permissions:":
        capture = True
        continue
    if capture:
        if not line:
            continue
        if not line.startswith("  "):
            break
        if line.startswith("    "):
            continue
        entries.append(line.strip())

if entries != ["contents: read"]:
    raise SystemExit(f"unexpected top-level permissions: {entries}")
PY
}

check_all_runs_on_runner_labels() {
  python3 - "$1" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()
runs_on = [line.strip() for line in lines if line.startswith("    runs-on:")]
if not runs_on:
    raise SystemExit("no runs-on lines found")
bad = [line for line in runs_on if line != "runs-on: ${{ fromJSON(inputs.runner_labels) }}"]
if bad:
    raise SystemExit("unexpected runs-on lines: " + ", ".join(bad))
PY
}

check_all_harden_runner_egress_audit() {
  python3 - "$1" <<'PY'
from pathlib import Path
import sys

lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
found = 0
for idx, line in enumerate(lines):
    if "uses: step-security/harden-runner@" not in line:
        continue
    found += 1
    ok = False
    for follow in lines[idx + 1:]:
        if follow.startswith("      - name:") or follow.startswith("      - uses:") or follow.startswith("  ") and not follow.startswith("    "):
            break
        if "egress-policy: audit" in follow:
            ok = True
            break
    if not ok:
        raise SystemExit(f"missing egress-policy: audit after harden-runner near line {idx + 1}")
if found == 0:
    raise SystemExit("no harden-runner step found")
PY
}

check_all_upload_artifacts_have_retention_seven() {
  python3 - "$1" <<'PY'
from pathlib import Path
import sys

lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
found = 0
for idx, line in enumerate(lines):
    if "uses: actions/upload-artifact@" not in line:
        continue
    found += 1
    ok = False
    for follow in lines[idx + 1:]:
        if follow.startswith("      - name:") or follow.startswith("      - uses:") or follow.startswith("  ") and not follow.startswith("    "):
            break
        if "retention-days: 7" in follow:
            ok = True
            break
    if not ok:
        raise SystemExit(f"missing retention-days: 7 after upload-artifact near line {idx + 1}")
if found == 0:
    raise SystemExit("no upload-artifact steps found")
PY
}

check_manifest_workflows_resolve() {
  python3 - "$1" "$2" <<'PY'
from pathlib import Path
import json
import sys

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
wf_dir = Path(sys.argv[2])
missing = []

for entry in manifest.get("fixtures", []):
    for workflow in entry.get("workflows", []):
        if workflow == "_orchestrator-ci":
            target = wf_dir / "_orchestrator-ci.yaml"
        else:
            target = wf_dir / f"{workflow}.yaml"
        if not target.is_file():
            missing.append(f"{entry['id']} -> {workflow}")

if missing:
    raise SystemExit("missing workflow files: " + ", ".join(missing))
PY
}

check_manifest_expected_paths_exist() {
  python3 - "$1" "$2" <<'PY'
from pathlib import Path
import json
import sys

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
root = Path(sys.argv[2])
missing = []

for entry in manifest.get("fixtures", []):
    for rel_path in entry.get("expected_paths", []):
        target = root / entry["id"] / rel_path
        if not target.exists():
            missing.append(str(target.relative_to(root)))

if missing:
    raise SystemExit("missing expected fixture paths: " + ", ".join(missing))
PY
}

assert_literal_in_file() {
  grep -Fq -- "$2" "$1"
}

assert_regex_in_file() {
  grep -Eq -- "$2" "$1"
}

check_reusable_orchestrator_report_gate() {
  python3 - "$1" <<'EOF'
from pathlib import Path
import sys
needle = "if: ${{ !cancelled() && inputs.enable_report && needs.detect.result == 'success' }}"
text = Path(sys.argv[1]).read_text(encoding="utf-8")
if needle not in text:
    raise SystemExit(f"missing literal: {needle}")
EOF
}

check_step_contains_literal() {
  python3 - "$1" "$2" "$3" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
step_name = sys.argv[2]
literal = sys.argv[3]
lines = path.read_text(encoding="utf-8").splitlines()

for idx, line in enumerate(lines):
    if line.strip() != f"- name: {step_name}":
        continue
    for follow in lines[idx + 1:]:
        if follow.startswith("      - name:") or follow.startswith("      - uses:") or (follow.startswith("  ") and not follow.startswith("    ")):
            break
        if literal in follow:
            raise SystemExit(0)
    raise SystemExit(f"step {step_name!r} missing literal {literal!r}")

raise SystemExit(f"step {step_name!r} not found")
PY
}

check_manifest_entry_workflows_exact() {
  python3 - "$1" "$2" "$3" <<'PY'
from pathlib import Path
import json
import sys

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
fixture_id = sys.argv[2]
expected = [part for part in sys.argv[3].split(",") if part]

for entry in manifest.get("fixtures", []):
    if entry["id"] == fixture_id:
        actual = entry.get("workflows", [])
        if actual != expected:
            raise SystemExit(f"{fixture_id}: expected workflows {expected}, got {actual}")
        raise SystemExit(0)

raise SystemExit(f"{fixture_id}: missing from manifest")
PY
}

check_manifest_entry_field_equals() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
from pathlib import Path
import json
import sys

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
fixture_id = sys.argv[2]
field = sys.argv[3]
expected = sys.argv[4]

for entry in manifest.get("fixtures", []):
    if entry["id"] == fixture_id:
        actual = entry.get(field)
        if actual != expected:
            raise SystemExit(f"{fixture_id}: expected {field}={expected!r}, got {actual!r}")
        raise SystemExit(0)

raise SystemExit(f"{fixture_id}: missing from manifest")
PY
}

show_help() {
  cat <<HELP
Usage: ./tests/test-offline.sh [--help]

Runs offline/static checks against the reusable GitHub Actions workflows.
HELP
}

case "${1:-}" in
  "")
    ;;
  -h|--help)
    show_help
    exit 0
    ;;
  *)
    echo "Unknown option: $1" >&2
    echo "Run './tests/test-offline.sh --help' for usage." >&2
    exit 2
    ;;
esac

echo "============================================"
echo " GitHub Actions AppSec Scanner — Offline Test Suite"
echo "============================================"
echo

echo "--- Prerequisites ---"

run_test "all expected workflow files exist" bash -c "
  missing=0
  for f in ${WORKFLOW_FILES[*]}; do
    [ -f '$WF_DIR/'\"\$f\" ] || { echo \"missing: \$f\"; missing=1; }
  done
  exit \$missing
"

run_test "container-setup action has been removed" bash -c "
  [ ! -e '$REPO_ROOT/actions/container-setup/action.yaml' ]
"

run_test "Mode B references removed from workflows and README" bash -c "
  ! rg -n 'use_container|scanner_image|container-setup|scan-container|Mode B|all-in-one scanner image|all-in-one scanner container' \
    '$WF_DIR' '$README_FILE'
"

echo
echo "--- YAML Syntax & Structure ---"

run_test "actionlint is available" bash -c "
  command -v actionlint >/dev/null 2>&1
"

run_test "workflow YAML passes actionlint" bash -c "
  actionlint '$WF_DIR'/*.yaml
"

run_test "all workflows have required top-level keys" bash -c "
  errs=0
  for f in '$WF_DIR'/*.yaml; do
    for key in name on jobs; do
      grep -q \"^\${key}:\" \"\$f\" || { echo \"\$f: missing key: \$key\"; errs=1; }
    done
  done
  exit \$errs
"

run_test "all jobs have runs-on or uses" bash -c "
  errs=0
  for f in '$WF_DIR'/*.yaml; do
    bad=\$(awk '
      /^jobs:/ { in_jobs=1; next }
      in_jobs && /^[^ ]/ { in_jobs=0 }
      in_jobs && /^  [a-zA-Z_][a-zA-Z0-9_-]*:/ {
        if (job && !ok) print job
        j=\$0; sub(/:.*$/, \"\", j); gsub(/^ +/, \"\", j); job=j; ok=0
      }
      in_jobs && /^    runs-on:/ { ok=1 }
      in_jobs && /^    uses:/ { ok=1 }
      END { if (job && !ok) print job }
    ' \"\$f\")
    if [ -n \"\$bad\" ]; then
      echo \"\$(basename \$f): jobs missing runs-on/uses: \$bad\"
      errs=1
    fi
  done
  exit \$errs
"

run_test "no tab characters in workflow YAML" bash -c "
  ! grep -Pn '\t' '$WF_DIR'/*.yaml
"

echo
echo "--- Supply Chain Pinning ---"

run_test "all uses references are SHA pinned" bash -c "
  bad=\$(grep -rn 'uses:' '$WF_DIR'/*.yaml \
    | grep -v '#' \
    | grep -v 'uses: \./' \
    | grep -vE '@[0-9a-f]{40}' || true)
  [ -z \"\$bad\" ] || { echo \"\$bad\"; exit 1; }
"

run_test "Docker images use SHA pinning" bash -c "
  bad=\$(grep -n 'image:' '$WF_DIR'/*.yaml \
    | grep -v '#' \
    | grep -v '@sha256:' || true)
  [ -z \"\$bad\" ] || { echo \"\$bad\"; exit 1; }
"

run_test "no latest Docker tags in workflows" bash -c "
  ! grep -rn 'docker.*run.*:latest' '$WF_DIR'/*.yaml
"

echo
echo "--- Reusable Workflow API ---"


run_test "example gaas-pr workflow exists" bash -c "
  [ -f '$REPO_ROOT/examples/gaas-pr.yaml' ]
"

run_test "example gaas-pr uses the public reusable API with PR comment" bash -c "
  grep -Fq 'uses: your-org/github-actions-appsec-scanner/.github/workflows/orchestrator-reusable.yaml@main' '$REPO_ROOT/examples/gaas-pr.yaml' || exit 1
  grep -Fq 'enable_pr_comment: true' '$REPO_ROOT/examples/gaas-pr.yaml'
"

run_test "examples directory contains only supported workflow examples" bash -c "
  actual=\$(cd '$REPO_ROOT/examples' && ls -1 | sort)
  expected=\$'gaas-full-scan.yaml\ngaas-pr.yaml'
  [ \"\$actual\" = \"\$expected\" ]
"

run_test "example gaas-full-scan workflow exists" bash -c "
  [ -f '$REPO_ROOT/examples/gaas-full-scan.yaml' ]
"

run_test "example gaas-full-scan uses the public reusable API with code scanning upload" bash -c "
  grep -Fq 'uses: your-org/github-actions-appsec-scanner/.github/workflows/orchestrator-reusable.yaml@main' '$REPO_ROOT/examples/gaas-full-scan.yaml' || exit 1
  grep -Fq 'enable_code_scanning_upload: true' '$REPO_ROOT/examples/gaas-full-scan.yaml'
"

run_test "called workflows accept standard inputs" bash -c "
  errs=0
  for f in ${CALLED_WORKFLOWS[*]}; do
    for input in ${STANDARD_INPUTS[*]}; do
      grep -q \"^      \$input:\" '$WF_DIR/'\"\$f\" || { echo \"\$f: missing input \$input\"; errs=1; }
    done
  done
  exit \$errs
"

run_test "called workflows do not expose removed container inputs" bash -c "
  ! rg -n '^      (use_container|scanner_image):' '$WF_DIR'/_security-general.yaml '$WF_DIR'/security-*.yaml
"

run_test "runner_labels default consistent across called workflows" bash -c "
  defaults=\$(for f in ${CALLED_WORKFLOWS[*]}; do
    grep -A3 '^      runner_labels:' '$WF_DIR/'\"\$f\" | grep 'default:' | sed 's/.*default: //'
  done | sort -u)
  count=\$(echo \"\$defaults\" | wc -l | tr -d ' ')
  [ \"\$count\" -eq 1 ] || { echo \"runner_labels defaults diverge: \$defaults\"; exit 1; }
"

run_test "workflow_dispatch exposes no removed container inputs" bash -c "
  ! rg -n '^      (use_container|scanner_image):' '$ORCH_ENTRY'
"

run_test "reusable orchestrator exposes workflow_call" bash -c "
  grep -q '^  workflow_call:' '$ORCH_API'
"

run_test "reusable orchestrator does not define workflow_dispatch" bash -c "
  ! grep -q '^  workflow_dispatch:' '$ORCH_API'
"

run_test "reusable orchestrator accepts standard inputs" bash -c "
  errs=0
  for input in ${STANDARD_INPUTS[*]} scanners disabled_tools; do
    grep -q '^      '"\$input"':' '$ORCH_API' || { echo 'orchestrator-reusable.yaml: missing input' \$input; errs=1; }
  done
  exit \$errs
"

run_test "reusable orchestrator report toggles are boolean" bash -c "
  grep -A5 '^      enable_report:' '$ORCH_API' | grep -Fq 'type: boolean' || exit 1
  grep -A5 '^      enable_report:' '$ORCH_API' | grep -Fq 'default: true' || exit 1
  grep -A5 '^      enable_pr_comment:' '$ORCH_API' | grep -Fq 'type: boolean' || exit 1
  grep -A5 '^      enable_pr_comment:' '$ORCH_API' | grep -Fq 'default: false'
"

run_test "detect job outputs only runner_labels for runner resolution" bash -c "
  grep -q 'runner_labels:.*steps.runner.outputs.runner_labels' '$ORCH_API' ||     { echo 'detect job missing runner_labels output'; exit 1; }
  ! grep -q 'scanner_image:' '$ORCH_API'
"

run_test "CI entry orchestrator delegates to reusable orchestrator" bash -c "
  grep -Fq 'uses: ./.github/workflows/orchestrator-reusable.yaml' '$WF_DIR/_orchestrator-ci.yaml' || exit 1
  for input in runner_labels scanners disabled_tools enable_pr_comment enable_code_scanning_upload; do
    grep -q \$input '$WF_DIR/_orchestrator-ci.yaml' || { echo 'CI wrapper missing' \$input; exit 1; }
  done
  ! grep -q 'use_container\|scanner_image' '$WF_DIR/_orchestrator-ci.yaml'
"

run_test "PR entry orchestrator delegates to reusable orchestrator" bash -c "
  grep -Fq 'uses: ./.github/workflows/orchestrator-reusable.yaml' '$WF_DIR/_orchestrator-pr.yaml' || exit 1
  for input in pr_base_sha pr_head_sha enable_pr_comment enable_code_scanning_upload; do
    grep -q \$input '$WF_DIR/_orchestrator-pr.yaml' || { echo 'PR wrapper missing' \$input; exit 1; }
  done
  ! grep -q 'use_container\|scanner_image' '$WF_DIR/_orchestrator-pr.yaml'
"

echo
echo "--- Core Workflow Contracts ---"

run_test "harden-runner present in all step-based workflows" bash -c "
  missing=0
  for f in ${STEP_BASED_WORKFLOWS[*]}; do
    grep -q 'harden-runner' '$WF_DIR/'\"\$f\" || { echo \"\$f: missing harden-runner\"; missing=1; }
  done
  exit \$missing
"

run_test "all jobs have timeout-minutes set" bash -c "
  errs=0
  for f in '$WF_DIR'/*.yaml; do
    bad=\$(awk '
      /^jobs:/ { in_jobs=1; next }
      in_jobs && /^[^ ]/ { in_jobs=0 }
      in_jobs && /^  [a-zA-Z_][a-zA-Z0-9_-]*:/ {
        if (job && !ok) print job
        j=\$0; sub(/:.*$/, \"\", j); gsub(/^ +/, \"\", j); job=j; ok=0
      }
      in_jobs && /timeout-minutes:/ { ok=1 }
      in_jobs && /^    uses:/ { ok=1 }
      END { if (job && !ok) print job }
    ' \"\$f\")
    if [ -n \"\$bad\" ]; then
      echo \"\$(basename \$f): jobs missing timeout-minutes: \$bad\"
      errs=1
    fi
  done
  exit \$errs
"

run_test "SARIF validate steps use set -euo pipefail" bash -c "
  errs=0
  for f in '$WF_DIR'/*.yaml; do
    bad=\$(awk '
      /name:.*[Vv]alidate.*SARIF/ { in_val=1; name=\$0; next }
      in_val && /run: \|/ { in_run=1; next }
      in_run && /set -euo pipefail/ { ok=1 }
      in_run && /^      - name:/ {
        if (!ok) print name
        in_val=0; in_run=0; ok=0
      }
      END { if (in_run && !ok) print name }
    ' \"\$f\")
    if [ -n \"\$bad\" ]; then
      echo \"\$(basename \$f): \$bad\"
      errs=1
    fi
  done
  exit \$errs
"

run_test "online suite help advertises --list" assert_literal_in_file "$ONLINE_TEST" "--list"
run_test "online suite help advertises --filter" assert_literal_in_file "$ONLINE_TEST" "--filter <pattern>"
run_test "online suite help advertises --skip" assert_literal_in_file "$ONLINE_TEST" "--skip <pattern>"
run_test "online suite help advertises --junit" assert_literal_in_file "$ONLINE_TEST" "--junit <file>"
run_test "online suite help advertises --keep-temp" assert_literal_in_file "$ONLINE_TEST" "--keep-temp"
run_test "online suite help advertises --timeout" assert_literal_in_file "$ONLINE_TEST" "--timeout <seconds>"
run_test "online suite uses set -euo pipefail" assert_literal_in_file "$ONLINE_TEST" "set -euo pipefail"
run_test "online suite bundler smoke emits JSON output" bash -c "
  grep -Fq 'bundle_audit_bin' '$ONLINE_TEST' || exit 1
  grep -Fq 'check --format json > bundler-audit.json || true' '$ONLINE_TEST'
"

run_test "report job uses static runner" assert_literal_in_file "$ORCH_API" "runs-on: ubuntu-24.04"
run_test "report job gates on enable_report and detect success" check_reusable_orchestrator_report_gate "$ORCH_API"

run_test "report job depends on all scanner jobs" bash -c "
  errs=0
  needs_line=\$(grep 'needs:' '$ORCH_API' | tail -1)
  for job in ${REPORT_NEEDS[*]}; do
    echo \"\$needs_line\" | grep -q \"\$job\" || { echo \"report needs missing \$job\"; errs=1; }
  done
  exit \$errs
"

run_test "no plaintext secrets in workflows" bash -c "
  bad=\$(grep -rn -iE '(password|secret|token|api_key)\s*[:=]\s*['\''\"]\w{8,}' '$WF_DIR'/*.yaml \
    | grep -v 'description' \
    | grep -v 'required:' \
    | grep -v 'type:' || true)
  [ -z \"\$bad\" ] || { echo \"\$bad\"; exit 1; }
"

echo
echo "--- Scanner-Specific Checks ---"

run_test "Semgrep excludes common test files and directories" bash -c "
  gen='$WF_DIR/_security-general.yaml'
  errs=0
  for pat in '_test.go' '_test.py' '.test.js' '.spec.ts' 'test/' 'tests/' '__tests__/'; do
    grep -q \"\$pat\" \"\$gen\" || { echo \"missing Semgrep exclusion for \$pat\"; errs=1; }
  done
  exit \$errs
"

run_test "Trivy scanners include vuln secret and config" bash -c "
  line=\$(grep 'scanners:' '$WF_DIR/_security-general.yaml' | grep -v 'license' | head -1)
  echo \"\$line\" | grep -q 'vuln' || { echo 'Trivy missing vuln scanner'; exit 1; }
  echo \"\$line\" | grep -q 'secret' || { echo 'Trivy missing secret scanner'; exit 1; }
  echo \"\$line\" | grep -q 'config' || { echo 'Trivy missing config scanner'; exit 1; }
"

run_test "license scan still uses Trivy license scanner with JSON output" bash -c "
  grep -q \"scanners: 'license'\" '$WF_DIR/_security-general.yaml' || { echo 'missing scanners: license'; exit 1; }
  grep -A5 \"scanners: 'license'\" '$WF_DIR/_security-general.yaml' | grep -q \"format: 'json'\" || \
    { echo 'missing format: json for license scan'; exit 1; }
"

run_test "Go workflow no longer uses container toggles" bash -c "
  ! rg -n 'USE_CONTAINER|SCANNER_IMAGE|docker run' '$WF_DIR/security-go.yaml'
"

run_test "Rust workflow runs single native cargo-audit and clippy steps" bash -c "
  [ \"\$(grep -c 'Run cargo-audit' '$WF_DIR/security-rust.yaml')\" -eq 1 ] || exit 1
  [ \"\$(grep -c 'Run Clippy' '$WF_DIR/security-rust.yaml')\" -eq 1 ] || exit 1
  ! rg -n 'docker run|Mode B|Mode A' '$WF_DIR/security-rust.yaml'
"

run_test "PowerShell workflow uses a single native pwsh analyzer step" bash -c "
  [ \"\$(grep -c 'Run PSScriptAnalyzer' '$WF_DIR/security-powershell.yaml')\" -eq 1 ] || exit 1
  grep -A8 'Run PSScriptAnalyzer' '$WF_DIR/security-powershell.yaml' | grep -q 'shell: pwsh' || exit 1
  ! rg -n 'docker run|Mode B|Mode A' '$WF_DIR/security-powershell.yaml'
"

run_test "Java workflow uses native PMD installation only" bash -c "
  grep -q '~/pmd/bin/pmd check' '$WF_DIR/security-java.yaml' || { echo 'PMD invocation missing'; exit 1; }
  ! rg -n 'docker run|container wrapper|Mode B|scanner image' '$WF_DIR/security-java.yaml'
"

run_test "SQL workflow uses native SQLFluff and TSQLLint only" bash -c "
  grep -q 'sqlfluff lint' '$WF_DIR/security-sql.yaml' || { echo 'SQLFluff invocation missing'; exit 1; }
  grep -q '\.dotnet/tools/tsqllint' '$WF_DIR/security-sql.yaml' || { echo 'TSQLLint path missing'; exit 1; }
  ! rg -n 'docker run|container wrapper|Mode B|scanner image' '$WF_DIR/security-sql.yaml'
"

run_test "JS workflow enables corepack before audit loop" bash -c "
  grep -q 'corepack enable' '$WF_DIR/security-js.yaml'
"

run_test "dotnet workflow restores dependencies before vulnerability scan" bash -c "
  grep -q 'dotnet-targets.txt' '$WF_DIR/security-dotnet.yaml' || { echo 'missing dotnet-targets.txt'; exit 1; }
  grep -q 'dotnet restore' '$WF_DIR/security-dotnet.yaml' || { echo 'missing dotnet restore target loop'; exit 1; }
  grep -q 'dotnet list' '$WF_DIR/security-dotnet.yaml' || { echo 'missing dotnet list target scan'; exit 1; }
  grep -q 'dotnet_restore.outputs.restored_any' '$WF_DIR/security-dotnet.yaml' || { echo 'missing restore gate'; exit 1; }
"

run_test "PHPStan conditionally uses Composer autoload file" bash -c "
  grep -q 'autoload-file vendor/autoload.php' '$WF_DIR/security-php.yaml' || exit 1
  grep -q 'vendor/autoload.php' '$WF_DIR/security-php.yaml' || exit 1
"

run_test "PHP workflow excludes vendor from file discovery" bash -c "
  grep 'find.*php' '$WF_DIR/security-php.yaml' | grep -q 'vendor'
"

run_test "Cppcheck suppresses missingIncludeSystem noise" bash -c "
  grep -q 'suppress=missingIncludeSystem' '$WF_DIR/security-c.yaml'
"

run_test "Grype job uses anchore/scan-action with SARIF output" bash -c "
  grep -q 'anchore/scan-action@' '$WF_DIR/_security-general.yaml' || exit 1
  grep -q 'output-format: sarif' '$WF_DIR/_security-general.yaml' || exit 1
"

run_test "actionlint job installs binary and converts JSON to SARIF" bash -c "
  grep -q 'actionlint' '$WF_DIR/security-github-actions.yaml' || exit 1
  grep -q 'actionlint.sarif' '$WF_DIR/security-github-actions.yaml' || exit 1
"

run_test "Terraform validate job runs init -backend=false and validate -json" bash -c "
  grep -q 'terraform init -backend=false' '$WF_DIR/security-iac.yaml' || exit 1
  grep -q 'terraform validate -json' '$WF_DIR/security-iac.yaml' || exit 1
"

run_test "Terraform fmt job runs fmt -check -recursive" bash -c "
  grep -q 'terraform fmt -check -recursive' '$WF_DIR/security-iac.yaml'
"

run_test "TFLint job uses setup-tflint action and SARIF output" bash -c "
  grep -q 'terraform-linters/setup-tflint@' '$WF_DIR/security-iac.yaml' || exit 1
  grep -q 'tflint -f sarif' '$WF_DIR/security-iac.yaml' || exit 1
"

run_test "KubeLinter job uses stackrox/kube-linter-action with SARIF output" bash -c "
  grep -q 'stackrox/kube-linter-action@' '$WF_DIR/security-iac.yaml' || exit 1
  grep -q 'format: sarif' '$WF_DIR/security-iac.yaml' || exit 1
"

run_test "Hadolint job installs binary and merges per-file SARIF" bash -c "
  grep -q 'hadolint' '$WF_DIR/security-iac.yaml' || exit 1
  grep -q 'hadolint.sarif' '$WF_DIR/security-iac.yaml' || exit 1
"

run_test "orchestrator passes enable flags to child workflows (spot-check)" bash -c "
  errs=0
  for flag in enable_grype enable_actionlint enable_terraform_validate enable_terraform_fmt enable_tflint enable_kube_linter enable_hadolint enable_gitleaks enable_kubescape enable_syft enable_pluto; do
    grep -q \"\$flag\" '$ORCH_API' || { echo \"missing \$flag in orchestrator\"; errs=1; }
  done
  exit \$errs
"

run_test "Gitleaks job installs binary and outputs native SARIF" bash -c "
  grep -q 'gitleaks' '$WF_DIR/_security-general.yaml' || exit 1
  grep -q 'gitleaks.sarif' '$WF_DIR/_security-general.yaml' || exit 1
"

run_test "Syft job generates CycloneDX SBOM" bash -c "
  grep -q 'syft' '$WF_DIR/_security-general.yaml' || exit 1
  grep -q 'sbom.cdx.json' '$WF_DIR/_security-general.yaml' || exit 1
  grep -q 'CycloneDX' '$WF_DIR/_security-general.yaml' || exit 1
"

run_test "Kubescape job installs binary and outputs native SARIF" bash -c "
  grep -q 'kubescape' '$WF_DIR/security-iac.yaml' || exit 1
  grep -q 'kubescape.sarif' '$WF_DIR/security-iac.yaml' || exit 1
"

run_test "Pluto job installs binary and converts JSON to SARIF" bash -c "
  grep -q 'pluto' '$WF_DIR/security-iac.yaml' || exit 1
  grep -q 'pluto.sarif' '$WF_DIR/security-iac.yaml' || exit 1
"

echo
echo "--- Expanded Reusable Workflow API ---"

for f in "${CALLED_WORKFLOWS[@]}"; do
  wf="${f%.yaml}"
  run_test "$wf exposes workflow_call" bash -c "
    grep -q '^  workflow_call:' '$WF_DIR/$f'
  "
  run_test "$wf does not define workflow_dispatch" bash -c "
    ! grep -q '^  workflow_dispatch:' '$WF_DIR/$f'
  "
  run_test "$wf runner_labels input type string" bash -c "
    grep -A2 '^      runner_labels:' '$WF_DIR/$f' | grep -Fq 'type: string'
  "
  run_test "$wf runner_labels default ubuntu-24.04" bash -c "
    grep -Fq \"default: '\\\"ubuntu-24.04\\\"'\" '$WF_DIR/$f'
  "
  run_test "$wf enable inputs are boolean and default true" \
    check_enable_inputs_boolean_true "$WF_DIR/$f"
done

echo
echo "--- Expanded Workflow Contracts ---"

for f in "${WORKFLOW_FILES[@]}"; do
  wf="${f%.yaml}"
  # Four files have elevated top-level permissions for PR comments,
  # dependency-review comments, and Code Scanning uploads.
  if [[ "$f" == "_orchestrator-ci.yaml" || "$f" == "_orchestrator-pr.yaml" || "$f" == "orchestrator-reusable.yaml" || "$f" == "_security-general.yaml" ]]; then
    :  # Tested by dedicated assertions below.
  else
    run_test "$wf top permissions are contents: read only" \
      check_top_level_permissions_contents_read_only "$WF_DIR/$f"
  fi
  # Entry caller workflows have no steps (just uses:), so skip harden-runner check.
  if [[ "$f" != "_orchestrator-ci.yaml" && "$f" != "_orchestrator-pr.yaml" ]]; then
    run_test "$wf harden-runner uses egress-policy audit" \
      check_all_harden_runner_egress_audit "$WF_DIR/$f"
  fi
done

run_test "_orchestrator-ci top permissions include security-events write but not pull-requests write" \
  bash -c "grep -v '^#\|^  #\|^    #' '$WF_DIR/_orchestrator-ci.yaml' | grep -q 'security-events: write' && ! grep -v '^#\|^  #\|^    #' '$WF_DIR/_orchestrator-ci.yaml' | grep -q 'pull-requests: write'"

run_test "_orchestrator-pr top permissions include pull-requests write but not security-events write" \
  bash -c "grep -v '^#\|^  #\|^    #' '$WF_DIR/_orchestrator-pr.yaml' | grep -q 'pull-requests: write' && ! grep -v '^#\|^  #\|^    #' '$WF_DIR/_orchestrator-pr.yaml' | grep -q 'security-events: write'"

run_test "orchestrator-reusable top permissions include pull-requests and security-events write" \
  bash -c "grep -q 'pull-requests: write' '$WF_DIR/orchestrator-reusable.yaml' && grep -q 'security-events: write' '$WF_DIR/orchestrator-reusable.yaml'"

run_test "_security-general top permissions include pull-requests write" \
  bash -c "grep -q 'pull-requests: write' '$WF_DIR/_security-general.yaml'"

for f in "${CALLED_WORKFLOWS[@]}"; do
  wf="${f%.yaml}"
  run_test "$wf jobs run on parsed runner_labels" \
    check_all_runs_on_runner_labels "$WF_DIR/$f"
  run_test "$wf upload-artifact steps retain for seven days" \
    check_all_upload_artifacts_have_retention_seven "$WF_DIR/$f"
done

run_test "workflow_dispatch scanners input defaults to all" bash -c "
  grep -A8 '^      scanners:' '$ORCH_ENTRY' | grep -Fq \"default: 'all'\"
"

run_test "workflow_dispatch disabled_tools input defaults empty" bash -c "
  grep -A40 '^      disabled_tools:' '$ORCH_ENTRY' | grep -Fq \"default: ''\"
"

run_test "workflow_dispatch enable_code_scanning_upload input defaults true for CI" bash -c "
  grep -A8 '^      enable_code_scanning_upload:' '$ORCH_ENTRY' | grep -Fq 'default: true'
"

run_test "workflow_dispatch scanners input documents valid language IDs" bash -c "
  for lang in go rust rails sql powershell dotnet iac python js java c php ruby; do
    grep -q \$lang '$ORCH_ENTRY' || { echo 'missing scanners doc for' \$lang; exit 1; }
  done
"

run_test "workflow_dispatch disabled_tools input documents all new general tools" bash -c "
  for tool in grype actionlint gitleaks kubescape syft terraform_validate terraform_fmt tflint kube_linter hadolint pluto exploit_guards; do
    grep -q \$tool '$ORCH_ENTRY' || { echo 'missing disabled_tools doc for' \$tool; exit 1; }
  done
"

run_test "report allowlist includes exploit-guards-sarif" \
  assert_literal_in_file "$ORCH_API" "exploit-guards-sarif"
run_test "report allowlist includes pluto-sarif" \
  assert_literal_in_file "$ORCH_API" "pluto-sarif"

run_test "VALID_TOOLS includes exploit_guards" \
  assert_literal_in_file "$ORCH_API" "exploit_guards"

# ── exploit-guards regression guards ──
EG_SCRIPT="$REPO_ROOT/.github/actions/exploit-guards/github-actions-workflow-exploit-guards.sh"
EG_ACTION="$REPO_ROOT/.github/actions/exploit-guards/action.yaml"

run_test "exploit-guards scans both .yaml and .yml workflow files" bash -c "
  grep -Fq '*.yml' '$EG_SCRIPT' || { echo 'missing .yml glob'; exit 1; }
  grep -Fq '*.yaml' '$EG_SCRIPT'
"

run_test "exploit-guards action disables -e before scanner invocation" \
  assert_literal_in_file "$EG_ACTION" "set +e"

run_test "exploit-guards retention-days parser uses correct indent boundary" \
  assert_literal_in_file "$EG_SCRIPT" "indent <= upload_indent"

run_test "exploit-guards caller has validate SARIF step" \
  assert_literal_in_file "$WF_DIR/security-github-actions.yaml" "exploit-guards.sarif was not generated"

run_test "runner allowlist restricts to GitHub-hosted labels only" bash -c "
  grep -Fq 'ubuntu-22.04' '$ORCH_API' || exit 1
  grep -Fq 'ubuntu-latest' '$ORCH_API' || exit 1
  ! grep -Fq 'self-hosted' '$ORCH_API' || exit 1
  ! grep -Fq 'windows' '$ORCH_API'
"

run_test "scanner_enabled helper normalizes case and whitespace" \
  assert_literal_in_file "$ORCH_API" 'scanners=$(echo "$INPUT_SCANNERS" | tr '\''[:upper:]'\'' '\''[:lower:]'\'' | tr -d '\''[:space:]'\'')'

run_test "tool_enabled helper normalizes case and whitespace" \
  assert_literal_in_file "$ORCH_API" 'disabled=$(echo "$INPUT_DISABLED_TOOLS" | tr '\''[:upper:]'\'' '\''[:lower:]'\'' | tr -d '\''[:space:]'\'')'

run_test "tool_enabled helper accepts none sentinel" \
  assert_literal_in_file "$ORCH_API" '[ "$disabled" = "none" ] && return 0'

run_test "workflow_dispatch branch exits before PR diff path" bash -c "
  grep -Fq 'workflow_dispatch — scanners input:' '$ORCH_API' || exit 1
  grep -Fq 'exit 0' '$ORCH_API'
"

run_test "PR diff failure falls back to git ls-files" bash -c "
  grep -Fq 'CHANGED=$(git ls-files)' '$ORCH_API'
"

run_test "report downloads only SARIF artifacts" bash -c "
  grep -Fq \"pattern: '*-sarif*'\" '$ORCH_API'
"

run_test "report summary uses MAX_COMMENT_SIZE guard" bash -c "
  grep -Fq 'MAX_COMMENT_SIZE = 60000' '$ORCH_API' || exit 1
  grep -Fq 'if len(summary) > MAX_COMMENT_SIZE:' '$ORCH_API'
"

run_test "report PR comment uses stable marker and max-size guard" bash -c "
  grep -Fq \"const marker = '<!-- security-scan-summary -->';\" '$ORCH_API' || exit 1
  grep -Fq 'if (body.length > MAX_SIZE) {' '$ORCH_API'
"

run_test "report dotnet dedupe key includes package version advisory and level" bash -c "
  grep -Fq \"finding.get('package')\" '$ORCH_API' || exit 1
  grep -Fq \"finding.get('version')\" '$ORCH_API' || exit 1
  grep -Fq \"finding.get('advisory')\" '$ORCH_API' || exit 1
  grep -Fq \"finding['level']\" '$ORCH_API'
"

run_test "Dependency Review keeps restricted-token fallback" bash -c "
  grep -Fq 'Dependency Review (restricted token mode)' '$WF_DIR/_security-general.yaml'
"

run_test "Syft uploads both CycloneDX and SPDX outputs" bash -c "
  grep -Fq 'sbom.cdx.json' '$WF_DIR/_security-general.yaml' || exit 1
  grep -Fq 'sbom.spdx.json' '$WF_DIR/_security-general.yaml'
"

echo
echo "--- Phase 5-8 Security Remediation ---"

run_test "IaC detection regex includes Containerfile" \
  assert_literal_in_file "$ORCH_API" "Containerfile"

run_test "IaC detection regex includes compose.yaml" bash -c "
  grep -qE 'compose.*ya.ml' '$ORCH_API'
"

run_test "JS detection regex does NOT include bun.lockb" bash -c "
  ! grep -q 'bun\.lockb' '$ORCH_API'
"

run_test "entry orchestrator has push trigger" bash -c "
  grep -q '  push:' '$ORCH_ENTRY'
"

run_test "entry orchestrator has schedule trigger" bash -c "
  grep -q '  schedule:' '$ORCH_ENTRY'
"

run_test "entry orchestrator concurrency includes event_name" bash -c "
  grep -Fq 'github.event_name' '$ORCH_ENTRY'
"

run_test "entry orchestrator concurrency isolates workflow_dispatch runs by run_id" bash -c "
  grep -Fq 'github.run_id' '$ORCH_ENTRY'
"

run_test "entry orchestrator does not cancel workflow_dispatch runs" \
  assert_literal_in_file "$ORCH_ENTRY" 'cancel-in-progress: ${{ github.event_name != '\''workflow_dispatch'\'' }}'

run_test "PMD uses security and errorprone rulesets" \
  assert_literal_in_file "$WF_DIR/security-java.yaml" "category/java/security.xml"

run_test "report distinguishes no-SARIF state" \
  assert_literal_in_file "$ORCH_API" "No scanners produced results"

run_test "orchestrator has enable_code_scanning_upload input" \
  assert_literal_in_file "$ORCH_API" "enable_code_scanning_upload"

run_test "entry orchestrator forwards enable_code_scanning_upload" \
  assert_literal_in_file "$ORCH_ENTRY" 'enable_code_scanning_upload: ${{ github.event_name == '\''push'\'' || github.event_name == '\''schedule'\'' || (github.event_name == '\''workflow_dispatch'\'' && github.event.inputs.enable_code_scanning_upload == '\''true'\'') }}'

run_test "report job has security-events write permission" \
  assert_literal_in_file "$ORCH_API" "security-events: write"

run_test "zizmor check_workflows detects composite actions" bash -c "
  grep -Fq 'action.yml' '$WF_DIR/security-github-actions.yaml' || exit 1
  grep -Fq 'action.yaml' '$WF_DIR/security-github-actions.yaml'
"

run_test "actionlint maps security-critical kinds to error" bash -c "
  grep -Fq \"error_kinds\" '$WF_DIR/security-github-actions.yaml'
"

run_test "govulncheck extracts severity from OSV database_specific" bash -c "
  grep -Fq 'database_specific' '$WF_DIR/security-go.yaml'
"

run_test "pip-audit defaults to warning severity" bash -c "
  grep -Fq '\"level\": \"warning\"' '$WF_DIR/security-python.yaml'
"

run_test "Bandit batch merger tracks drop count" bash -c "
  grep -Fq 'drop_count' '$WF_DIR/security-python.yaml'
"

run_test "SQLFluff batch merger tracks drop count" bash -c "
  grep -Fq 'drop_count' '$WF_DIR/security-sql.yaml'
"

run_test "Python pip-audit warns about unsupported uv.lock" bash -c "
  grep -Fq 'uv.lock' '$WF_DIR/security-python.yaml'
"

run_test "README documents minimum permissions table" bash -c "
  grep -Fq 'security-events: write' '$REPO_ROOT/README.md'
"

echo
echo "--- Tool Notices & Pinning ---"

DISABLED_NOTICE_SPECS=(
  "_security-general.yaml|general trivy disabled notice|Tool Disabled::Trivy is disabled. Set enable_trivy: true to re-enable."
  "_security-general.yaml|general trufflehog disabled notice|Tool Disabled::TruffleHog is disabled. Set enable_trufflehog: true to re-enable."
  "_security-general.yaml|general dependency review disabled notice|Tool Disabled::Dependency Review is disabled. Set enable_dependency_review: true to re-enable."
  "_security-general.yaml|general license scan disabled notice|Tool Disabled::License scan is disabled. Set enable_license_scan: true to re-enable."
  "_security-general.yaml|general grype disabled notice|Tool Disabled::Grype is disabled. Set enable_grype: true to re-enable."
  "security-github-actions.yaml|general actionlint disabled notice|Tool Disabled::actionlint is disabled. Set enable_actionlint: true to re-enable."
  "_security-general.yaml|general gitleaks disabled notice|Tool Disabled::Gitleaks is disabled. Set enable_gitleaks: true to re-enable."
  "_security-general.yaml|general syft disabled notice|Tool Disabled::Syft is disabled. Set enable_syft: true to re-enable."
  "security-go.yaml|gosec disabled notice|Tool Disabled::Gosec is disabled. Set enable_gosec: true to re-enable."
  "security-go.yaml|staticcheck disabled notice|Tool Disabled::Staticcheck is disabled. Set enable_staticcheck: true to re-enable."
  "security-go.yaml|govulncheck disabled notice|Tool Disabled::Govulncheck is disabled. Set enable_govulncheck: true to re-enable."
  "security-rust.yaml|cargo-audit disabled notice|Tool Disabled::cargo-audit is disabled. Set enable_cargo_audit: true to re-enable."
  "security-rust.yaml|clippy disabled notice|Tool Disabled::Clippy is disabled. Set enable_clippy: true to re-enable."
  "security-python.yaml|bandit disabled notice|Tool Disabled::Bandit is disabled. Set enable_bandit: true to re-enable."
  "security-python.yaml|pip-audit disabled notice|Tool Disabled::pip-audit is disabled. Set enable_pip_audit: true to re-enable."
  "security-js.yaml|npm audit disabled notice|Tool Disabled::npm audit is disabled. Set enable_npm_audit: true to re-enable."
  "security-java.yaml|PMD disabled notice|Tool Disabled::PMD is disabled. Set enable_pmd: true to re-enable."
  "security-dotnet.yaml|dotnet audit disabled notice|Tool Disabled::dotnet audit is disabled. Set enable_dotnet_audit: true to re-enable."
  "security-rails.yaml|brakeman disabled notice|Tool Disabled::Brakeman is disabled. Set enable_brakeman: true to re-enable."
  "security-sql.yaml|sqlfluff disabled notice|Tool Disabled::SQLFluff is disabled. Set enable_sqlfluff: true to re-enable."
  "security-sql.yaml|tsqllint disabled notice|Tool Disabled::TSQLLint is disabled. Set enable_tsqllint: true to re-enable."
  "security-powershell.yaml|psscriptanalyzer disabled notice|Tool Disabled::PSScriptAnalyzer is disabled. Set enable_psscriptanalyzer: true to re-enable."
  "security-iac.yaml|checkov disabled notice|Tool Disabled::Checkov is disabled. Set enable_checkov: true to re-enable."
  "security-iac.yaml|ansible-lint disabled notice|Tool Disabled::ansible-lint is disabled. Set enable_ansible_lint: true to re-enable."
  "security-iac.yaml|terraform validate disabled notice|Tool Disabled::Terraform Validate is disabled. Set enable_terraform_validate: true to re-enable."
  "security-iac.yaml|terraform fmt disabled notice|Tool Disabled::Terraform Format Check is disabled. Set enable_terraform_fmt: true to re-enable."
  "security-iac.yaml|tflint disabled notice|Tool Disabled::TFLint is disabled. Set enable_tflint: true to re-enable."
  "security-iac.yaml|kube-linter disabled notice|Tool Disabled::KubeLinter is disabled. Set enable_kube_linter: true to re-enable."
  "security-iac.yaml|hadolint disabled notice|Tool Disabled::Hadolint is disabled. Set enable_hadolint: true to re-enable."
  "security-iac.yaml|kubescape disabled notice|Tool Disabled::Kubescape is disabled. Set enable_kubescape: true to re-enable."
  "security-iac.yaml|pluto disabled notice|Tool Disabled::Pluto is disabled. Set enable_pluto: true to re-enable."
  "security-c.yaml|flawfinder disabled notice|Tool Disabled::Flawfinder is disabled. Set enable_flawfinder: true to re-enable."
  "security-c.yaml|cppcheck disabled notice|Tool Disabled::Cppcheck is disabled. Set enable_cppcheck: true to re-enable."
  "security-c.yaml|semgrep c disabled notice|Tool Disabled::Semgrep (C secrets) is disabled. Set enable_semgrep_c: true to re-enable."
  "security-php.yaml|phpstan disabled notice|Tool Disabled::PHPStan is disabled. Set enable_phpstan: true to re-enable."
  "security-php.yaml|composer audit disabled notice|Tool Disabled::composer audit is disabled. Set enable_composer_audit: true to re-enable."
  "security-ruby.yaml|rubocop disabled notice|Tool Disabled::RuboCop is disabled. Set enable_rubocop: true to re-enable."
  "security-ruby.yaml|bundler-audit disabled notice|Tool Disabled::bundler-audit is disabled. Set enable_bundler_audit: true to re-enable."
)

for spec in "${DISABLED_NOTICE_SPECS[@]}"; do
  IFS='|' read -r file name literal <<< "$spec"
  run_test "$name" assert_literal_in_file "$WF_DIR/$file" "$literal"
done

PIN_SPECS=(
  "security-python.yaml|bandit pinned 1.8.3|pip install bandit==1.8.3"
  "security-python.yaml|pip-audit pinned 2.9.0|pip install pip-audit==2.9.0"
  "security-sql.yaml|sqlfluff pinned 4.0.4|pip install sqlfluff==4.0.4"
  "security-sql.yaml|sqlfluff templater pinned 4.0.4|sqlfluff-templater-dbt==4.0.4"
  "security-sql.yaml|tsqllint pinned 1.16.0 on update|dotnet tool update --global TSQLLint --version 1.16.0"
  "security-sql.yaml|tsqllint pinned 1.16.0 on install|dotnet tool install --global TSQLLint --version 1.16.0"
  "security-c.yaml|flawfinder pinned 2.0.19|pip install flawfinder==2.0.19"
  "security-c.yaml|semgrep pinned 1.152.0 in C workflow|pip install semgrep==1.152.0"
  "security-go.yaml|gosec pinned v2.23.0|go install github.com/securego/gosec/v2/cmd/gosec@v2.23.0"
  "security-go.yaml|govulncheck pinned v1.1.4|go install golang.org/x/vuln/cmd/govulncheck@v1.1.4"
  "security-rust.yaml|cargo-audit pinned 0.22.1|cargo install cargo-audit --version 0.22.1 --locked"
  "security-ruby.yaml|rubocop pinned 1.72.0|rubocop:1.72.0"
  "security-ruby.yaml|rubocop-ast pinned 1.44.1|rubocop-ast:1.44.1"
  "security-ruby.yaml|bundler-audit pinned 0.9.2|gem install bundler-audit:0.9.2 --no-document"
  "security-rails.yaml|brakeman pinned 8.0.2|gem install brakeman -v 8.0.2"
  "security-powershell.yaml|psscriptanalyzer pinned 1.23.0|Install-Module -Name PSScriptAnalyzer -RequiredVersion 1.23.0"
  "security-java.yaml|PMD pinned 7.12.0|PMD_SHA256="
  "security-java.yaml|PMD checksum enforced|sha256sum -c -"
  "security-iac.yaml|ansible-lint pinned 25.1.3|pip install ansible-lint==25.1.3"
  "security-github-actions.yaml|actionlint pinned 1.7.11|ACTIONLINT_VERSION=\"1.7.11\""
  "_security-general.yaml|gitleaks pinned 8.30.0|GITLEAKS_VERSION=\"8.30.0\""
  "_security-general.yaml|syft pinned 1.42.1|SYFT_VERSION=\"1.42.1\""
  "security-iac.yaml|hadolint pinned 2.14.0|HADOLINT_VERSION=\"2.14.0\""
  "security-iac.yaml|kubescape pinned 4.0.2|KUBESCAPE_VERSION=\"4.0.2\""
  "security-iac.yaml|pluto pinned 5.23.0|PLUTO_VERSION=\"5.23.0\""
)

for spec in "${PIN_SPECS[@]}"; do
  IFS='|' read -r file name literal <<< "$spec"
  run_test "$name" assert_literal_in_file "$WF_DIR/$file" "$literal"
done

NO_PR_SPECS=(
  "security-go.yaml|go no-PR discovery message|No PR context — discovered Go module files"
  "security-go.yaml|go no-PR empty repo message|No go.mod found — GOPATH-mode and vendored-only repositories are not supported"
  "security-js.yaml|js no-PR message|No PR context — auditing all JS/TS packages"
  "security-dotnet.yaml|dotnet no-PR message|No PR context — scanning all .NET files"
  "security-ruby.yaml|bundler no-PR message|No PR context — auditing all Gemfile.lock files"
  "security-php.yaml|php composer no-PR message|No PR context — auditing all composer.lock files"
  "security-powershell.yaml|powershell no-PR message|No PR context — scanning all PowerShell files"
  "security-c.yaml|c no-PR message|No PR context — scanning all C/C++ files"
  "security-iac.yaml|iac no-PR message|No PR context — scanning all IaC files"
  "security-iac.yaml|ansible no-PR message|No PR context — Ansible project detected, scanning whole repo"
  "security-iac.yaml|ansible no-project skip message|No PR context and no Ansible project structure found — skipping"
  "security-rust.yaml|rust no-projects skip message|No Rust projects found — skipping"
  "security-rails.yaml|rails no-apps skip message|No Rails apps found — skipping"
  "security-php.yaml|php no-projects skip message|No PHP projects found — skipping"
)

for spec in "${NO_PR_SPECS[@]}"; do
  IFS='|' read -r file name literal <<< "$spec"
  run_test "$name" assert_literal_in_file "$WF_DIR/$file" "$literal"
done

echo
echo "--- Upload Contracts ---"

UPLOAD_SPECS=(
  "_security-general.yaml|semgrep upload name|name: semgrep-sarif"
  "_security-general.yaml|trivy upload name|name: trivy-sarif"
  "_security-general.yaml|trufflehog upload name|name: trufflehog-sarif"
  "_security-general.yaml|license scan upload name|name: license-scan-sarif"
  "_security-general.yaml|grype upload name|name: grype-sarif"
  "security-github-actions.yaml|actionlint upload name|name: actionlint-sarif"
  "_security-general.yaml|gitleaks upload name|name: gitleaks-sarif"
  "_security-general.yaml|syft upload name|name: syft-sbom"
  "security-go.yaml|gosec upload name|name: gosec-sarif"
  "security-go.yaml|staticcheck upload name|name: staticcheck-sarif"
  "security-go.yaml|govulncheck upload name|name: govulncheck-sarif"
  "security-rust.yaml|cargo audit upload name|name: cargo-audit-sarif"
  "security-rust.yaml|clippy upload name|name: clippy-sarif"
  "security-python.yaml|bandit upload name|name: bandit-sarif"
  "security-python.yaml|pip-audit upload name|name: pip-audit-sarif"
  "security-js.yaml|npm audit upload name|name: npm-audit-sarif"
  "security-java.yaml|PMD upload name|name: pmd-sarif"
  "security-dotnet.yaml|dotnet upload name uses matrix|name: dotnet-vulnerable-sarif-\${{ matrix.dotnet-version }}"
  "security-rails.yaml|brakeman upload name|name: brakeman-sarif"
  "security-ruby.yaml|rubocop upload name|name: rubocop-sarif"
  "security-ruby.yaml|bundler-audit upload name|name: bundler-audit-sarif"
  "security-php.yaml|phpstan upload name|name: phpstan-sarif"
  "security-php.yaml|composer audit upload name|name: composer-audit-sarif"
  "security-sql.yaml|sqlfluff upload name|name: sqlfluff-sarif"
  "security-sql.yaml|tsqllint upload name|name: tsqllint-sarif"
  "security-powershell.yaml|powershell upload name|name: powershell-sarif"
  "security-c.yaml|flawfinder upload name|name: flawfinder-sarif"
  "security-c.yaml|cppcheck upload name|name: cppcheck-sarif"
  "security-c.yaml|c semgrep upload name|name: secrets-c-sarif"
  "security-iac.yaml|checkov upload name|name: checkov-sarif"
  "security-iac.yaml|ansible-lint upload name|name: ansible-lint-sarif"
  "security-iac.yaml|terraform validate upload name|name: terraform-validate-sarif"
  "security-iac.yaml|terraform fmt upload name|name: terraform-fmt-sarif"
  "security-iac.yaml|tflint upload name|name: tflint-sarif"
  "security-iac.yaml|kube-linter upload name|name: kube-linter-sarif"
  "security-iac.yaml|hadolint upload name|name: hadolint-sarif"
  "security-iac.yaml|kubescape upload name|name: kubescape-sarif"
  "security-iac.yaml|pluto upload name|name: pluto-sarif"
)

for spec in "${UPLOAD_SPECS[@]}"; do
  IFS='|' read -r file name literal <<< "$spec"
  run_test "$name" assert_literal_in_file "$WF_DIR/$file" "$literal"
done

run_test "dotnet upload path is dotnet-vulnerable.sarif" bash -c "
  grep -Fq 'path: dotnet-vulnerable.sarif' '$WF_DIR/security-dotnet.yaml'
"

run_test "Syft upload includes CycloneDX file" bash -c "
  grep -Fq 'sbom.cdx.json' '$WF_DIR/_security-general.yaml'
"

run_test "Syft upload includes SPDX file" bash -c "
  grep -Fq 'sbom.spdx.json' '$WF_DIR/_security-general.yaml'
"

echo
echo "--- Workflow Details ---"

DETAIL_SPECS=(
  "security-go.yaml|go detects version via go-version-file|go-version-file: \${{ steps.check_go.outputs.go_version_file }}"
  "security-go.yaml|go workspace prep can create go.work|xargs -d '\n' go work init < go-module-dirs.txt"
  "security-go.yaml|govulncheck emits JSON before conversion|govulncheck -json ./... > govulncheck.json"
  "security-rust.yaml|rust writes cargo audit manifest|cargo-audit-manifest.txt"
  "security-rust.yaml|clippy installs component|components: clippy"
  "security-rust.yaml|clippy emits machine readable JSON|cargo clippy --all-targets --message-format=json"
  "security-js.yaml|npm audit tries yarn modern command first|yarn npm audit --recursive --json"
  "security-js.yaml|npm audit supports pnpm|pnpm audit --json"
  "security-js.yaml|npm audit skips lockfile-less directories|No lock file in \$dir — skipping (cannot reliably audit without a lock file)"
  "security-java.yaml|PMD uses file-list mode|--file-list pmd_file_list.txt"
  "security-dotnet.yaml|dotnet matrix covers LTS and current|dotnet-version: ['8.0.x', '9.0.x']"
  "security-dotnet.yaml|dotnet stores discovered targets|dotnet-targets.txt"
  "security-dotnet.yaml|dotnet stores restored targets|dotnet-restored-targets.txt"
  "security-dotnet.yaml|dotnet audit uses include-transitive|dotnet list \"\$target\" package --vulnerable --include-transitive --format json"
  "security-rails.yaml|rails discovers app roots file|rails-app-roots.txt"
  "security-php.yaml|php discovers project roots file|php-project-roots.txt"
  "security-php.yaml|php root detection uses vendor autoload|vendor/autoload.php"
  "security-php.yaml|phpstan can use composer autoload|AUTOLOAD_FLAGS+=(--autoload-file \"vendor/autoload.php\")"
  "security-python.yaml|pip-audit writes target manifest|pip-audit-targets.txt"
  "security-python.yaml|pip-audit supports pipenv export|pipenv requirements"
  "security-python.yaml|pip-audit supports pip-compile export|pip-compile --quiet"
  "security-python.yaml|pip-audit supports poetry export|poetry export -f requirements.txt --without-hashes"
  "security-sql.yaml|tsqllint is T-SQL specific helper comment|TSQLLint is T-SQL specific"
  "security-c.yaml|flawfinder uses mapfile array dispatch|mapfile -t -d '' C_FILES < changed_c_files.txt"
  "_security-general.yaml|semgrep baseline args preserved for contract visibility|BASELINE_ARGS=\"--baseline-commit \$PR_BASE_SHA\""
  "security-github-actions.yaml|actionlint tolerates malformed findings|Warning: skipping malformed actionlint finding:"
  "_security-general.yaml|trufflehog skips malformed findings|Warning: skipping malformed TruffleHog finding:"
  "_security-general.yaml|syft generates SPDX output|--output spdx-json=sbom.spdx.json"
  "security-iac.yaml|checkov uses hard fail high critical|hard_fail_on: HIGH,CRITICAL"
  "security-iac.yaml|checkov uses soft fail low medium|soft_fail_on: LOW,MEDIUM"
  "security-iac.yaml|hadolint merges partial SARIF files|hadolint-partials"
  "security-iac.yaml|kubescape thresholds findings to zero exit|--compliance-threshold 0"
  "security-iac.yaml|pluto scans for target K8s version|--target-versions k8s=v1.31.0"
)

for spec in "${DETAIL_SPECS[@]}"; do
  IFS='|' read -r file name literal <<< "$spec"
  run_test "$name" assert_literal_in_file "$WF_DIR/$file" "$literal"
done

echo
echo "--- Setup & Cache Contracts ---"

SETUP_AND_ACTION_SPECS=(
  "orchestrator-reusable.yaml|report sets up Python with pinned action|uses: actions/setup-python@a26af69be951a213d495a4c3e4e4022e16d87065"
  "orchestrator-reusable.yaml|report uses Python 3.11|python-version: '3.11'"
  "_security-general.yaml|Semgrep container uses exact 1.152.0 image tag|image: semgrep/semgrep:1.152.0@sha256:e04d2cb132288d90035db8791d64f610cb255b21e727b94db046243b30c01ae9"
  "_security-general.yaml|Grype uses pinned anchore scan action|uses: anchore/scan-action@7037fa011853d5a11690026fb85feee79f4c946c"
  "security-github-actions.yaml|actionlint installer pins 1.7.11|ACTIONLINT_VERSION=\"1.7.11\""
  "_security-general.yaml|gitleaks installer pins 8.30.0|GITLEAKS_VERSION=\"8.30.0\""
  "_security-general.yaml|syft installer pins 1.42.1|SYFT_VERSION=\"1.42.1\""
  "security-go.yaml|Go uses pinned setup-go action|uses: actions/setup-go@40f1582b2485089dde7abd97c1529aa768e1baff"
  "security-go.yaml|Staticcheck uses pinned staticcheck action|uses: dominikh/staticcheck-action@a59b46bc6a3ed113d90f4562922ba956f5db4d37"
  "security-dotnet.yaml|dotnet uses pinned setup-dotnet action|uses: actions/setup-dotnet@67a3573c9a986a3f9c594539f4ab511d57bb3ce9"
  "security-java.yaml|Java uses pinned setup-java action|uses: actions/setup-java@c1e323688fd81a25caa38c78aa6df2d33d3e20d9"
  "security-java.yaml|Java setup uses Temurin distribution|distribution: 'temurin'"
  "security-java.yaml|Java setup uses version 21|java-version: '21'"
  "security-js.yaml|JS uses pinned setup-node action|uses: actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020"
  "security-js.yaml|JS uses Node 22|node-version: '22'"
  "security-rails.yaml|Rails uses pinned ruby/setup-ruby action|uses: ruby/setup-ruby@09a7688d3b55cf0e976497ff046b70949eeaccfd"
  "security-rails.yaml|Rails uses Ruby 3.2|ruby-version: '3.2'"
  "security-ruby.yaml|Ruby uses pinned ruby/setup-ruby action|uses: ruby/setup-ruby@09a7688d3b55cf0e976497ff046b70949eeaccfd"
  "security-ruby.yaml|Ruby uses Ruby 3.3|ruby-version: '3.3'"
  "security-sql.yaml|SQL uses pinned setup-dotnet action|uses: actions/setup-dotnet@67a3573c9a986a3f9c594539f4ab511d57bb3ce9"
  "security-sql.yaml|SQL TSQLLint uses dotnet 8.0.x|dotnet-version: '8.0.x'"
  "security-iac.yaml|IaC uses pinned Checkov action|uses: bridgecrewio/checkov-action@05d9f3cd4807c3dea7444d4e60dc44ad57928ab5"
  "security-iac.yaml|IaC uses pinned setup-tflint action|uses: terraform-linters/setup-tflint@4cb9feea73331a35b422df102992a03a44a3bb33"
  "security-iac.yaml|IaC uses pinned kube-linter action|uses: stackrox/kube-linter-action@87802a2f4e01abebb3ee3c67a3002fea71f6eae5"
)

for spec in "${SETUP_AND_ACTION_SPECS[@]}"; do
  IFS='|' read -r file name literal <<< "$spec"
  run_test "$name" assert_literal_in_file "$WF_DIR/$file" "$literal"
done

CACHE_SPECS=(
  "_security-general.yaml|Semgrep cache path is ~/.cache/semgrep|path: ~/.cache/semgrep"
  "_security-general.yaml|Semgrep cache key hashes .semgrep and workflow|key: \${{ runner.os }}-semgrep-rules-\${{ hashFiles('.semgrep/**') }}-\${{ hashFiles('.github/workflows/_security-general.yaml') }}"
  "security-c.yaml|Flawfinder cache path is pip cache|path: ~/.cache/pip"
  "security-c.yaml|Flawfinder cache key is workflow scoped|key: \${{ runner.os }}-pip-flawfinder-\${{ hashFiles('.github/workflows/security-c.yaml') }}"
  "security-c.yaml|Semgrep C cache key is workflow scoped|key: \${{ runner.os }}-pip-semgrep-c-\${{ hashFiles('.github/workflows/security-c.yaml') }}"
  "security-python.yaml|Bandit cache path is pip cache|path: ~/.cache/pip"
  "security-python.yaml|Bandit cache key is workflow scoped|key: \${{ runner.os }}-pip-bandit-\${{ hashFiles('.github/workflows/security-python.yaml') }}"
  "security-python.yaml|pip-audit cache key is workflow scoped|key: \${{ runner.os }}-pip-audit-\${{ hashFiles('.github/workflows/security-python.yaml') }}"
  "security-sql.yaml|SQLFluff cache path is pip cache|path: ~/.cache/pip"
  "security-sql.yaml|SQLFluff cache key is workflow scoped|key: \${{ runner.os }}-pip-sqlfluff-\${{ hashFiles('.github/workflows/security-sql.yaml') }}"
  "security-sql.yaml|TSQLLint caches global dotnet tools|path: ~/.dotnet/tools"
  "security-sql.yaml|TSQLLint cache key is dotnet-tools-tsqllint|key: \${{ runner.os }}-dotnet-tools-tsqllint"
  "security-iac.yaml|ansible-lint cache path is pip cache|path: ~/.cache/pip"
  "security-iac.yaml|ansible-lint cache key is workflow scoped|key: \${{ runner.os }}-pip-ansible-lint-\${{ hashFiles('.github/workflows/security-iac.yaml') }}"
  "security-powershell.yaml|PSScriptAnalyzer cache path is PowerShell modules|path: ~/.local/share/powershell/Modules"
  "security-powershell.yaml|PSScriptAnalyzer cache key is workflow scoped|key: \${{ runner.os }}-psmodules-\${{ hashFiles('.github/workflows/security-powershell.yaml') }}"
  "security-java.yaml|PMD cache path is ~/pmd|path: ~/pmd"
  "security-java.yaml|PMD cache key pins 7.12.0|key: \${{ runner.os }}-pmd-7.12.0"
  "security-rails.yaml|Brakeman cache path is ~/.gem|path: ~/.gem"
  "security-rails.yaml|Brakeman cache key uses Gemfile.lock hashes|key: \${{ runner.os }}-gems-brakeman-\${{ hashFiles('**/Gemfile.lock') }}"
  "security-ruby.yaml|RuboCop cache path is ~/.gem|path: ~/.gem"
  "security-ruby.yaml|RuboCop cache key is workflow scoped|key: \${{ runner.os }}-gems-rubocop-\${{ hashFiles('.github/workflows/security-ruby.yaml') }}"
  "security-ruby.yaml|bundler-audit cache key is workflow scoped|key: \${{ runner.os }}-gems-bundler-audit-\${{ hashFiles('.github/workflows/security-ruby.yaml') }}"
  "security-rust.yaml|cargo-audit cache key uses Cargo.lock hashes|key: \${{ runner.os }}-cargo-audit-\${{ hashFiles('**/Cargo.lock') }}"
  "security-rust.yaml|clippy cache key uses Cargo.lock hashes|key: \${{ runner.os }}-cargo-clippy-\${{ hashFiles('**/Cargo.lock') }}"
  "_security-general.yaml|Semgrep cache has restore-keys block|restore-keys: |"
  "security-python.yaml|Bandit cache has restore-keys block|restore-keys: |"
  "security-sql.yaml|TSQLLint cache has restore-keys block|restore-keys: |"
)

for spec in "${CACHE_SPECS[@]}"; do
  IFS='|' read -r file name literal <<< "$spec"
  run_test "$name" assert_literal_in_file "$WF_DIR/$file" "$literal"
done

echo
echo "--- Failure & Status Messages ---"

STATUS_SPECS=(
  "_security-general.yaml|Semgrep missing-file warning is explicit|No semgrep.sarif file found, skipping ERROR check"
  "_security-general.yaml|TruffleHog install retries print attempt message|Attempt \$i/3 failed, retrying in 10s..."
  "_security-general.yaml|actionlint install retries print attempt message|Attempt \$i/3 failed, retrying in 10s..."
  "_security-general.yaml|Gitleaks install retries print attempt message|Attempt \$i/3 failed, retrying in 10s..."
  "_security-general.yaml|Syft install retries print attempt message|Attempt \$i/3 failed, retrying in 10s..."
  "security-python.yaml|Bandit warns when no output shards exist|::warning::No Bandit output files found — scanner may have failed"
  "security-sql.yaml|SQLFluff warns when no output shards exist|::warning::No SQLFluff output files found — scanner may have failed"
  "security-dotnet.yaml|dotnet audit reports complete invocation failure|::error::dotnet audit found \$targets_found target(s) but all invocations failed — check dotnet availability"
  "security-js.yaml|npm audit reports complete invocation failure|::error::npm audit found \$targets_found lockfile director(ies) but all invocations failed — check package manager availability"
  "security-python.yaml|pip-audit reports complete invocation failure|::error::pip-audit found \$targets_found target(s) but all invocations failed"
  "security-php.yaml|PHPStan reports complete invocation failure|::error::PHPStan found \$project_count PHP project(s) but all invocations failed"
  "security-php.yaml|composer audit reports complete invocation failure|::error::composer audit found \$targets_found composer.lock file(s) but all invocations failed — check composer availability"
  "security-ruby.yaml|bundler-audit reports complete invocation failure|::error::bundler-audit found \$targets_found Gemfile.lock file(s) but all invocations failed — check bundler-audit installation"
  "security-rust.yaml|cargo-audit reports complete invocation failure|::error::cargo-audit found \$project_count Rust project(s) but all invocations failed"
  "security-rust.yaml|clippy reports complete invocation failure|::error::clippy found \$project_count Rust project(s) but all invocations failed"
  "security-rails.yaml|Brakeman reports complete invocation failure|::error::Brakeman found \$app_count Rails app(s) but all invocations failed"
  "security-iac.yaml|Checkov warns when SARIF rename fails|::warning::No Checkov SARIF output found"
  "security-go.yaml|Go PR mode reports no changed files|No Go files changed in this PR"
  "security-js.yaml|JS PR mode reports no changed files|No JS/TS files changed in this PR"
  "security-java.yaml|Java PR mode reports no changed files|No Java/Kotlin files in manifest"
  "security-dotnet.yaml|dotnet PR mode reports no changed files|No .NET files changed in this PR"
  "security-powershell.yaml|PowerShell PR mode reports no changed files|No PowerShell files changed in this PR"
  "security-c.yaml|C PR mode reports no changed files|No C files changed in this PR"
  "security-iac.yaml|IaC PR mode reports no changed files|No IaC files changed in this PR"
  "security-iac.yaml|Ansible PR mode reports no changed files|No Ansible files changed in this PR"
  "security-php.yaml|composer audit PR mode reports no changed lockfile|No composer.lock changed in this PR"
  "security-ruby.yaml|bundler-audit PR mode reports no changed lockfile|No Gemfile.lock changed in this PR"
  "security-php.yaml|composer audit no-target message is explicit|No composer.lock files found — skipping"
  "security-ruby.yaml|bundler-audit no-target message is explicit|No Gemfile.lock files found — skipping"
)

for spec in "${STATUS_SPECS[@]}"; do
  IFS='|' read -r file name literal <<< "$spec"
  run_test "$name" assert_literal_in_file "$WF_DIR/$file" "$literal"
done

echo
echo "--- Run-Step Contracts ---"

CONTINUE_SPECS=(
  "_security-general.yaml|Semgrep run step uses continue-on-error|Run Semgrep|continue-on-error: true"
  "_security-general.yaml|Trivy run step uses continue-on-error|Run Trivy|continue-on-error: true"
  "_security-general.yaml|TruffleHog run step uses continue-on-error|Run TruffleHog|continue-on-error: true"
  "_security-general.yaml|License scan run step uses continue-on-error|Run Trivy license scan|continue-on-error: true"
  "security-github-actions.yaml|actionlint run step uses continue-on-error|Run actionlint|continue-on-error: true"
  "security-github-actions.yaml|exploit-guards run step uses continue-on-error|Run exploit-guards|continue-on-error: true"
  "_security-general.yaml|Gitleaks run step uses continue-on-error|Run Gitleaks|continue-on-error: true"
  "_security-general.yaml|Syft generation step uses continue-on-error|Generate SBOM|continue-on-error: true"
  "security-c.yaml|Flawfinder run step uses continue-on-error|Run Flawfinder|continue-on-error: true"
  "security-c.yaml|Cppcheck run step uses continue-on-error|Run Cppcheck|continue-on-error: true"
  "security-c.yaml|C Semgrep run step uses continue-on-error|Run Semgrep (secrets)|continue-on-error: true"
  "security-dotnet.yaml|dotnet vulnerable package step uses continue-on-error|Check for vulnerable packages|continue-on-error: true"
  "security-go.yaml|Gosec run step uses continue-on-error|Run Gosec|continue-on-error: true"
  "security-go.yaml|Staticcheck run step uses continue-on-error|Run Staticcheck|continue-on-error: true"
  "security-go.yaml|Govulncheck run step uses continue-on-error|Run govulncheck|continue-on-error: true"
  "security-iac.yaml|ansible-lint run step uses continue-on-error|Run ansible-lint|continue-on-error: true"
  "security-iac.yaml|terraform validate run step uses continue-on-error|Run terraform validate|continue-on-error: true"
  "security-iac.yaml|terraform fmt run step uses continue-on-error|Run terraform fmt|continue-on-error: true"
  "security-iac.yaml|TFLint run step uses continue-on-error|Run TFLint|continue-on-error: true"
  "security-iac.yaml|KubeLinter run step uses continue-on-error|Run KubeLinter|continue-on-error: true"
  "security-iac.yaml|Hadolint run step uses continue-on-error|Run hadolint|continue-on-error: true"
  "security-iac.yaml|Kubescape run step uses continue-on-error|Run Kubescape|continue-on-error: true"
  "security-iac.yaml|Pluto run step uses continue-on-error|Run Pluto|continue-on-error: true"
  "security-java.yaml|PMD run step uses continue-on-error|Run PMD|continue-on-error: true"
  "security-js.yaml|npm audit run step uses continue-on-error|Run npm audit|continue-on-error: true"
  "security-php.yaml|PHPStan run step uses continue-on-error|Run PHPStan|continue-on-error: true"
  "security-php.yaml|composer audit run step uses continue-on-error|Run composer audit|continue-on-error: true"
  "security-powershell.yaml|PSScriptAnalyzer run step uses continue-on-error|Run PSScriptAnalyzer|continue-on-error: true"
  "security-python.yaml|Bandit run step uses continue-on-error|Run Bandit|continue-on-error: true"
  "security-python.yaml|pip-audit run step uses continue-on-error|Run pip-audit|continue-on-error: true"
  "security-rails.yaml|Brakeman run step uses continue-on-error|Run Brakeman|continue-on-error: true"
  "security-ruby.yaml|RuboCop run step uses continue-on-error|Run RuboCop|continue-on-error: true"
  "security-ruby.yaml|bundler-audit run step uses continue-on-error|Run bundler-audit|continue-on-error: true"
  "security-rust.yaml|cargo-audit run step uses continue-on-error|Run cargo-audit|continue-on-error: true"
  "security-rust.yaml|Clippy run step uses continue-on-error|Run Clippy|continue-on-error: true"
  "security-sql.yaml|SQLFluff run step uses continue-on-error|Run SQLFluff|continue-on-error: true"
  "security-sql.yaml|TSQLLint run step uses continue-on-error|Run TSQLLint|continue-on-error: true"
)

for spec in "${CONTINUE_SPECS[@]}"; do
  IFS='|' read -r file name step literal <<< "$spec"
  run_test "$name" check_step_contains_literal "$WF_DIR/$file" "$step" "$literal"
done

echo
echo "--- SARIF Conversion Contracts ---"

SARIF_LITERAL_SPECS=(
  "_security-general.yaml|TruffleHog SARIF schema is pinned|json.schemastore.org/sarif-2.1.0.json"
  "_security-general.yaml|TruffleHog SARIF version is 2.1.0|\"version\": \"2.1.0\""
  "_security-general.yaml|TruffleHog SARIF driver name is correct|\"name\": \"TruffleHog\""
  "_security-general.yaml|License SARIF driver name is correct|\"name\": \"license-scan\""
  "_security-general.yaml|License SARIF info URI points to Trivy docs|\"informationUri\": \"https://aquasecurity.github.io/trivy/\""
  "security-github-actions.yaml|actionlint SARIF driver name is correct|\"name\": \"actionlint\""
  "security-github-actions.yaml|actionlint SARIF info URI points to actionlint docs|\"informationUri\": \"https://github.com/rhysd/actionlint\""
  "security-go.yaml|govulncheck SARIF schema is pinned|json.schemastore.org/sarif-2.1.0.json"
  "security-go.yaml|govulncheck SARIF version is 2.1.0|\"version\": \"2.1.0\""
  "security-go.yaml|govulncheck SARIF driver name is correct|\"name\": \"govulncheck\""
  "security-go.yaml|govulncheck SARIF info URI points to pkg.go.dev|\"informationUri\": \"https://pkg.go.dev/golang.org/x/vuln/cmd/govulncheck\""
  "security-dotnet.yaml|dotnet SARIF schema is pinned|json.schemastore.org/sarif-2.1.0.json"
  "security-dotnet.yaml|dotnet SARIF version is 2.1.0|\"version\": \"2.1.0\""
  "security-dotnet.yaml|dotnet SARIF driver name is correct|\"name\": \"dotnet-vulnerable-packages\""
  "security-dotnet.yaml|dotnet SARIF info URI points to NuGet auditing docs|\"informationUri\": \"https://learn.microsoft.com/en-us/nuget/concepts/auditing-packages\""
  "security-c.yaml|Cppcheck SARIF schema is pinned|json.schemastore.org/sarif-2.1.0.json"
  "security-c.yaml|Cppcheck SARIF version is 2.1.0|\"version\": \"2.1.0\""
  "security-c.yaml|Cppcheck SARIF driver name is correct|\"name\": \"Cppcheck\""
  "security-c.yaml|Cppcheck SARIF info URI points to cppcheck site|\"informationUri\": \"https://cppcheck.sourceforge.io/\""
  "security-sql.yaml|SQLFluff SARIF schema is pinned|json.schemastore.org/sarif-2.1.0.json"
  "security-sql.yaml|SQLFluff SARIF version is 2.1.0|\"version\": \"2.1.0\""
  "security-sql.yaml|SQLFluff SARIF driver name is correct|\"name\": \"SQLFluff\""
  "security-sql.yaml|SQLFluff SARIF info URI points to sqlfluff site|\"informationUri\": \"https://www.sqlfluff.com/\""
  "security-sql.yaml|TSQLLint SARIF driver name is correct|\"name\": \"TSQLLint\""
  "security-rust.yaml|cargo-audit SARIF schema is pinned|json.schemastore.org/sarif-2.1.0.json"
  "security-rust.yaml|cargo-audit SARIF version is 2.1.0|\"version\": \"2.1.0\""
  "security-rust.yaml|cargo-audit SARIF driver name is correct|\"name\": \"cargo-audit\""
  "security-rust.yaml|cargo-audit SARIF info URI points to rustsec|\"informationUri\": \"https://rustsec.org/\""
  "security-rust.yaml|Clippy SARIF driver name is correct|\"name\": \"Clippy\""
  "security-rust.yaml|Clippy SARIF info URI points to clippy docs|\"informationUri\": \"https://rust-lang.github.io/rust-clippy/\""
  "security-ruby.yaml|RuboCop SARIF schema is pinned|json.schemastore.org/sarif-2.1.0.json"
  "security-ruby.yaml|RuboCop SARIF version is 2.1.0|\"version\": \"2.1.0\""
  "security-ruby.yaml|RuboCop SARIF driver name is correct|\"name\": \"RuboCop\""
  "security-ruby.yaml|RuboCop SARIF info URI points to rubocop docs|\"informationUri\": \"https://rubocop.org/\""
  "security-ruby.yaml|bundler-audit SARIF driver name is correct|\"name\": \"bundler-audit\""
  "security-ruby.yaml|bundler-audit SARIF info URI points to rubysec repo|\"informationUri\": \"https://github.com/rubysec/bundler-audit\""
  "security-js.yaml|npm-audit SARIF schema is pinned|json.schemastore.org/sarif-2.1.0.json"
  "security-js.yaml|npm-audit SARIF version is 2.1.0|\"version\": \"2.1.0\""
  "security-js.yaml|npm-audit SARIF driver name is correct|\"name\": \"npm-audit\""
  "security-js.yaml|npm-audit SARIF info URI points to npm docs|\"informationUri\": \"https://docs.npmjs.com/cli/audit\""
  "security-php.yaml|PHPStan SARIF schema is pinned|json.schemastore.org/sarif-2.1.0.json"
  "security-php.yaml|PHPStan SARIF version is 2.1.0|\"version\": \"2.1.0\""
  "security-php.yaml|PHPStan SARIF driver name is correct|\"name\": \"PHPStan\""
  "security-php.yaml|PHPStan SARIF info URI points to phpstan site|\"informationUri\": \"https://phpstan.org/\""
  "security-php.yaml|composer-audit SARIF driver name is correct|\"name\": \"composer-audit\""
  "security-php.yaml|composer-audit SARIF info URI points to composer docs|\"informationUri\": \"https://getcomposer.org/doc/03-cli.md#audit\""
  "security-python.yaml|Bandit SARIF schema is pinned|json.schemastore.org/sarif-2.1.0.json"
  "security-python.yaml|Bandit SARIF version is 2.1.0|\"version\": \"2.1.0\""
  "security-python.yaml|Bandit SARIF driver name is correct|\"name\": \"Bandit\""
  "security-python.yaml|Bandit SARIF info URI points to bandit docs|\"informationUri\": \"https://bandit.readthedocs.io/\""
  "security-python.yaml|pip-audit SARIF driver name is correct|\"name\": \"pip-audit\""
  "security-python.yaml|pip-audit SARIF info URI points to pip-audit package|\"informationUri\": \"https://pypi.org/project/pip-audit/\""
  "security-iac.yaml|terraform-validate SARIF driver name is correct|\"name\": \"terraform-validate\""
  "security-iac.yaml|terraform-validate SARIF info URI points to validate docs|\"informationUri\": \"https://developer.hashicorp.com/terraform/cli/commands/validate\""
  "security-iac.yaml|terraform-fmt SARIF driver name is correct|\"name\": \"terraform-fmt\""
  "security-iac.yaml|terraform-fmt SARIF info URI points to fmt docs|\"informationUri\": \"https://developer.hashicorp.com/terraform/cli/commands/fmt\""
  "security-iac.yaml|TFLint SARIF driver name is correct|\"name\": \"TFLint\""
  "security-iac.yaml|TFLint SARIF info URI points to tflint repo|\"informationUri\": \"https://github.com/terraform-linters/tflint\""
  "security-iac.yaml|Hadolint SARIF driver name is correct|\"name\": \"Hadolint\""
  "security-iac.yaml|Hadolint SARIF info URI points to hadolint repo|\"informationUri\": \"https://github.com/hadolint/hadolint\""
  "security-iac.yaml|Pluto SARIF driver name is correct|\"name\": \"Pluto\""
  "security-iac.yaml|Pluto SARIF info URI points to pluto repo|\"informationUri\": \"https://github.com/FairwindsOps/pluto\""
  "security-powershell.yaml|PSScriptAnalyzer SARIF schema is pinned|json.schemastore.org/sarif-2.1.0.json"
  "security-powershell.yaml|PSScriptAnalyzer SARIF version is 2.1.0|version = '2.1.0'"
  "security-powershell.yaml|PSScriptAnalyzer SARIF driver name is correct|name = 'PSScriptAnalyzer'"
  "security-powershell.yaml|PSScriptAnalyzer SARIF tool version is pinned|version = '1.23.0'"
  'security-rails.yaml|Brakeman merge preserves upstream schema|data.get("$schema")'
  "security-rails.yaml|Brakeman merge defaults SARIF version to 2.1.0|\"version\": data.get(\"version\", \"2.1.0\")"
  "security-rails.yaml|Brakeman merge extends runs from partial SARIFs|merged[\"runs\"].extend(data.get(\"runs\", []))"
)

for spec in "${SARIF_LITERAL_SPECS[@]}"; do
  IFS='|' read -r file name literal <<< "$spec"
  run_test "$name" assert_literal_in_file "$WF_DIR/$file" "$literal"
done

echo
echo "--- Fixture Routing Contracts ---"

FIXTURE_WORKFLOW_SPECS=(
  "common/docs-only|docs-only routes only to orchestrator|_orchestrator-ci"
  "python/bandit-basic|python fixture routes to python workflow and orchestrator|security-python,_orchestrator-ci"
  "java/pmd-basic|java fixture routes to java workflow and orchestrator|security-java,_orchestrator-ci"
  "dotnet/basic|dotnet fixture routes to dotnet workflow and orchestrator|security-dotnet,_orchestrator-ci"
  "js/npm-basic|js fixture routes to js workflow and orchestrator|security-js,_orchestrator-ci"
  "sql/basic|sql fixture routes to sql workflow and orchestrator|security-sql,_orchestrator-ci"
  "iac/checkov-basic|terraform fixture routes to iac workflow and orchestrator|security-iac,_orchestrator-ci"
  "iac/ansible-lint-basic|ansible fixture routes to iac workflow and orchestrator|security-iac,_orchestrator-ci"
  "go/basic|go fixture routes to go workflow and orchestrator|security-go,_orchestrator-ci"
  "rust/basic|rust fixture routes to rust workflow and orchestrator|security-rust,_orchestrator-ci"
  "c/basic|c fixture routes to c workflow and orchestrator|security-c,_orchestrator-ci"
  "c/cpp-only-basic|cpp-only fixture routes only to orchestrator|_orchestrator-ci"
  "ruby/basic|ruby fixture routes to ruby workflow and orchestrator|security-ruby,_orchestrator-ci"
  "rails/basic|rails fixture routes to rails workflow and orchestrator|security-rails,_orchestrator-ci"
  "php/basic|php fixture routes to php workflow and orchestrator|security-php,_orchestrator-ci"
  "powershell/basic|powershell fixture routes to powershell workflow and orchestrator|security-powershell,_orchestrator-ci"
  "general/semgrep-basic-positive|semgrep positive routes only to general workflow|_security-general"
  "general/semgrep-basic-negative|semgrep negative routes only to general workflow|_security-general"
  "general/trufflehog-fake-secret-positive|trufflehog positive routes only to general workflow|_security-general"
  "general/trufflehog-clean-negative|trufflehog negative routes only to general workflow|_security-general"
  "iac/dockerfile-basic|dockerfile fixture routes to iac workflow and orchestrator|security-iac,_orchestrator-ci"
  "iac/k8s-basic|k8s fixture routes to iac workflow and orchestrator|security-iac,_orchestrator-ci"
  "github-actions/actionlint-basic|actionlint fixture routes to github-actions workflow|security-github-actions"
  "general/gitleaks-fake-secret-positive|gitleaks positive routes only to general workflow|_security-general"
  "general/gitleaks-clean-negative|gitleaks negative routes only to general workflow|_security-general"
  "iac/kubescape-basic|kubescape fixture routes to iac workflow and orchestrator|security-iac,_orchestrator-ci"
  "iac/pluto-basic|pluto fixture routes to iac workflow and orchestrator|security-iac,_orchestrator-ci"
  "iac/cloudformation-basic|cloudformation fixture routes to iac workflow and orchestrator|security-iac,_orchestrator-ci"
  "iac/helm-basic|helm fixture routes to iac workflow and orchestrator|security-iac,_orchestrator-ci"
  "general/trivy-vuln-positive|trivy positive routes only to general workflow|_security-general"
  "general/grype-vuln-positive|grype positive routes only to general workflow|_security-general"
  "orchestrator/reusable-pr-mode|reusable PR fixture routes only to reusable orchestrator|orchestrator-reusable"
  "orchestrator/reusable-full-scan|reusable full-scan fixture routes only to reusable orchestrator|orchestrator-reusable"
  "general/license-copyleft-positive|license positive routes only to general workflow|_security-general"
)

for spec in "${FIXTURE_WORKFLOW_SPECS[@]}"; do
  IFS='|' read -r fixture_id name workflows <<< "$spec"
  run_test "$name" check_manifest_entry_workflows_exact "$FIXTURE_MANIFEST" "$fixture_id" "$workflows"
done

FIXTURE_MODE_SPECS=(
  "common/docs-only|docs-only fixture uses shape assertions|assertion_mode|shape"
  "python/bandit-basic|python fixture uses shape assertions|assertion_mode|shape"
  "dotnet/basic|dotnet fixture uses shape assertions|assertion_mode|shape"
  "go/basic|go fixture uses shape assertions|assertion_mode|shape"
  "rust/basic|rust fixture uses shape assertions|assertion_mode|shape"
  "general/semgrep-basic-positive|semgrep positive fixture uses minimum assertions|assertion_mode|minimum"
  "general/semgrep-basic-negative|semgrep negative fixture uses shape assertions|assertion_mode|shape"
  "general/trufflehog-fake-secret-positive|trufflehog positive fixture uses minimum assertions|assertion_mode|minimum"
  "general/trufflehog-clean-negative|trufflehog negative fixture uses shape assertions|assertion_mode|shape"
  "general/gitleaks-fake-secret-positive|gitleaks positive fixture uses minimum assertions|assertion_mode|minimum"
  "general/gitleaks-clean-negative|gitleaks negative fixture uses shape assertions|assertion_mode|shape"
  "general/trivy-vuln-positive|trivy positive fixture uses minimum assertions|assertion_mode|minimum"
  "general/grype-vuln-positive|grype positive fixture uses minimum assertions|assertion_mode|minimum"
  "general/license-copyleft-positive|license positive fixture uses minimum assertions|assertion_mode|minimum"
  "iac/helm-basic|helm fixture uses shape assertions|assertion_mode|shape"
  "general/trivy-vuln-positive|trivy positive fixture is bounded-drift|class|bounded-drift"
  "general/grype-vuln-positive|grype positive fixture is bounded-drift|class|bounded-drift"
  "general/license-copyleft-positive|license positive fixture is bounded-drift|class|bounded-drift"
  "dotnet/basic|dotnet fixture is bounded-drift|class|bounded-drift"
  "js/npm-basic|js fixture is bounded-drift|class|bounded-drift"
  "go/basic|go fixture is bounded-drift|class|bounded-drift"
  "rust/basic|rust fixture is bounded-drift|class|bounded-drift"
  "ruby/basic|ruby fixture is bounded-drift|class|bounded-drift"
  "rails/basic|rails fixture is bounded-drift|class|bounded-drift"
  "php/basic|php fixture is bounded-drift|class|bounded-drift"
  "common/docs-only|docs-only fixture is deterministic|class|deterministic"
  "general/semgrep-basic-positive|semgrep positive fixture is deterministic|class|deterministic"
  "general/trufflehog-fake-secret-positive|trufflehog positive fixture is deterministic|class|deterministic"
  "general/gitleaks-fake-secret-positive|gitleaks positive fixture is deterministic|class|deterministic"
  "iac/cloudformation-basic|cloudformation fixture is deterministic|class|deterministic"
  "orchestrator/reusable-pr-mode|reusable PR fixture uses shape assertions|assertion_mode|shape"
  "orchestrator/reusable-full-scan|reusable full-scan fixture uses shape assertions|assertion_mode|shape"
  "orchestrator/reusable-pr-mode|reusable PR fixture is github-native|class|github-native"
  "orchestrator/reusable-full-scan|reusable full-scan fixture is github-native|class|github-native"
  "iac/helm-basic|helm fixture is deterministic|class|deterministic"
)

for spec in "${FIXTURE_MODE_SPECS[@]}"; do
  IFS='|' read -r fixture_id name field expected <<< "$spec"
  run_test "$name" check_manifest_entry_field_equals "$FIXTURE_MANIFEST" "$fixture_id" "$field" "$expected"
done

echo
echo "--- Fixture Checks ---"

run_test "fixture manifest exists and parses as JSON" bash -c "
  [ -f '$FIXTURE_MANIFEST' ] || exit 1
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$FIXTURE_MANIFEST'
"

run_test "fixture manifest entries point to real fixture directories" bash -c "
  python3 - '$FIXTURE_MANIFEST' '$FIXTURE_ROOT' <<'PY'
import json
import pathlib
import sys

manifest_path = pathlib.Path(sys.argv[1])
fixture_root = pathlib.Path(sys.argv[2])
manifest = json.load(open(manifest_path))
missing = []

for entry in manifest.get('fixtures', []):
    fixture_id = entry['id']
    fixture_dir = fixture_root / fixture_id
    if not fixture_dir.is_dir():
        missing.append(fixture_id)

if missing:
    raise SystemExit('missing fixture directories: ' + ', '.join(missing))
PY
"

run_test "fixture manifest uses only recognized classes and assertion modes" bash -c "
  python3 - '$FIXTURE_MANIFEST' <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1]))
valid_classes = {'deterministic', 'bounded-drift', 'github-native'}
valid_modes = {'exact', 'minimum', 'shape'}

for entry in manifest.get('fixtures', []):
    fixture_id = entry['id']
    if entry.get('class') not in valid_classes:
        raise SystemExit(f'{fixture_id}: invalid class {entry.get(\"class\")}')
    if entry.get('assertion_mode') not in valid_modes:
        raise SystemExit(f'{fixture_id}: invalid assertion_mode {entry.get(\"assertion_mode\")}')
PY
"

run_test "fixture manifest workflow references resolve to real workflow files" \
  check_manifest_workflows_resolve "$FIXTURE_MANIFEST" "$WF_DIR"

run_test "fixture manifest expected_paths exist on disk" \
  check_manifest_expected_paths_exist "$FIXTURE_MANIFEST" "$FIXTURE_ROOT"

run_test "docs-only fixture maps only to orchestrator" bash -c "
  python3 - '$FIXTURE_MANIFEST' <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1]))
for entry in manifest['fixtures']:
    if entry['id'] == 'common/docs-only':
        if entry.get('workflows') != ['_orchestrator-ci']:
            raise SystemExit(f\"unexpected workflows: {entry.get('workflows')}\")
        break
else:
    raise SystemExit('common/docs-only missing from manifest')
PY
"

run_test "actionlint fixture includes ci workflow file" bash -c "
  [ -f '$FIXTURE_ROOT/github-actions/actionlint-basic/.github/workflows/ci.yaml' ]
"

run_test "actionlint fixture ci.yaml has permissions block" bash -c "
  grep -q 'permissions:' '$FIXTURE_ROOT/github-actions/actionlint-basic/.github/workflows/ci.yaml'
"

run_test "actionlint fixture ci.yaml checkout has persist-credentials false" bash -c "
  grep -Fq 'persist-credentials: false' '$FIXTURE_ROOT/github-actions/actionlint-basic/.github/workflows/ci.yaml'
"

run_test "actionlint fixture ci.yaml checkout is SHA-pinned" bash -c "
  grep -qE 'uses: actions/checkout@[0-9a-f]{40}' '$FIXTURE_ROOT/github-actions/actionlint-basic/.github/workflows/ci.yaml'
"

run_test "poutine fixture has permissions block" bash -c "
  grep -q 'permissions:' '$FIXTURE_ROOT/github-actions/poutine-basic/.github/workflows/unpinned.yaml'
"

run_test "poutine fixture checkout has persist-credentials false" bash -c "
  grep -Fq 'persist-credentials: false' '$FIXTURE_ROOT/github-actions/poutine-basic/.github/workflows/unpinned.yaml'
"

run_test "poutine fixture retains unpinned action refs for poutine detection" bash -c "
  grep -qE 'uses: actions/[^@]+@v[0-9]' '$FIXTURE_ROOT/github-actions/poutine-basic/.github/workflows/unpinned.yaml'
"

run_test "orchestrator reusable-full-scan fixture suppresses zizmor unpinned-uses" bash -c "
  grep -Fq 'zizmor:ignore[unpinned-uses]' '$FIXTURE_ROOT/orchestrator/reusable-full-scan/.github/workflows/appsec.yaml'
"

run_test "orchestrator reusable-pr-mode fixture suppresses zizmor unpinned-uses" bash -c "
  grep -Fq 'zizmor:ignore[unpinned-uses]' '$FIXTURE_ROOT/orchestrator/reusable-pr-mode/.github/workflows/appsec.yaml'
"

run_test "C++ only fixture is orchestrator-only" bash -c "
  python3 - '$FIXTURE_MANIFEST' <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1]))
for entry in manifest['fixtures']:
    if entry['id'] == 'c/cpp-only-basic':
        workflows = entry.get('workflows', [])
        if workflows != ['_orchestrator-ci']:
            raise SystemExit(f'unexpected workflows: {workflows}')
        break
else:
    raise SystemExit('c/cpp-only-basic missing from manifest')
PY
"

run_test "TruffleHog positive and negative fixtures both exist" bash -c "
  [ -d '$FIXTURE_ROOT/general/trufflehog-fake-secret-positive' ] && \
  [ -d '$FIXTURE_ROOT/general/trufflehog-clean-negative' ]
"

run_test "Gitleaks positive and negative fixtures both exist" bash -c "
  [ -d '$FIXTURE_ROOT/general/gitleaks-fake-secret-positive' ] && \
  [ -d '$FIXTURE_ROOT/general/gitleaks-clean-negative' ]
"

run_test "CloudFormation fixture exists with template" bash -c "
  [ -f '$FIXTURE_ROOT/iac/cloudformation-basic/cloudformation/template.yaml' ]
"

run_test "Helm chart fixture exists with Chart.yaml and templates" bash -c "
  [ -f '$FIXTURE_ROOT/iac/helm-basic/helm/Chart.yaml' ] && \
  [ -f '$FIXTURE_ROOT/iac/helm-basic/helm/values.yaml' ] && \
  [ -f '$FIXTURE_ROOT/iac/helm-basic/helm/templates/deployment.yaml' ]
"

run_test "Trivy vulnerability positive fixture exists" bash -c "
  [ -f '$FIXTURE_ROOT/general/trivy-vuln-positive/requirements.txt' ] && \
  [ -f '$FIXTURE_ROOT/general/trivy-vuln-positive/app.py' ]
"

run_test "Grype vulnerability positive fixture exists" bash -c "
  [ -f '$FIXTURE_ROOT/general/grype-vuln-positive/package.json' ] && \
  [ -f '$FIXTURE_ROOT/general/grype-vuln-positive/package-lock.json' ]
"

run_test "License copyleft positive fixture exists" bash -c "
  [ -f '$FIXTURE_ROOT/general/license-copyleft-positive/package.json' ] && \
  [ -f '$FIXTURE_ROOT/general/license-copyleft-positive/package-lock.json' ]
"

echo
echo "--- README Cross-Checks ---"

README_SPECS=(
  "README mentions C toolchain row::^\\| C \\| flawfinder, cppcheck, semgrep \\(C secrets\\) \\|$"
  "README mentions PHP toolchain row::^\\| PHP \\| phpstan, composer audit \\|$"
  "README mentions Checkov in IaC table::[Cc]heckov"
  "README mentions KubeLinter in IaC table::kube-linter"
  "README mentions Hadolint in IaC table::hadolint"
  "README mentions Kubescape in IaC table::Kubescape"
  "README mentions Pluto in IaC table::[Pp]luto"
  "README mentions ansible-lint in IaC table::ansible-lint"
  "README mentions CycloneDX SBOMs::CycloneDX"
  "README mentions SPDX SBOMs::SPDX"
)

for spec in "${README_SPECS[@]}"; do
  name="${spec%%::*}"
  literal="${spec#*::}"
  run_test "$name" assert_regex_in_file "$README_FILE" "$literal"
done

echo
echo "--- Summary ---"
echo "Passed: $pass"
echo "Failed: $fail"
echo "Skipped: $skip"

if [ "$fail" -ne 0 ]; then
  exit 1
fi
