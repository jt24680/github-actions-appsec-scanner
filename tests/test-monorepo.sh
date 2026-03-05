#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE_ROOT="$REPO_ROOT/tests/fixtures"
MONOREPO_FIXTURE_ROOT="$FIXTURE_ROOT/monorepo"

pass=0
fail=0
skip=0

LIST_ONLY=false
SHOW_DETAILS=false
FILTER=""
PHASE_FILTER=""

show_help() {
  cat <<EOF
Usage: ./tests/test-monorepo.sh [--help] [--list] [--details]
                                [--phase <name>] [--filter <pattern>]

Planning harness for future monorepo test coverage.

What it does today:
  - Registers concrete monorepo test scenarios in rollout order
  - Shows which fixtures/helpers each scenario needs
  - Surfaces current blockers as explicit SKIP reasons

Phases:
  detect    Fast changed-file and project-discovery contract tests
  routing   Orchestrator routing tests against monorepo fixtures
  act       End-to-end act smoke tests for representative monorepos
  report    Artifact aggregation and summary/report safety tests
  consumer  Reusable-workflow caller compatibility tests

Examples:
  ./tests/test-monorepo.sh
  ./tests/test-monorepo.sh --list
  ./tests/test-monorepo.sh --phase detect --details
  ./tests/test-monorepo.sh --filter shared
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      show_help
      exit 0
      ;;
    --list)
      LIST_ONLY=true
      shift
      ;;
    --details)
      SHOW_DETAILS=true
      shift
      ;;
    --phase)
      if [ $# -lt 2 ]; then
        echo "--phase requires an argument" >&2
        exit 2
      fi
      PHASE_FILTER="$2"
      shift 2
      ;;
    --filter)
      if [ $# -lt 2 ]; then
        echo "--filter requires an argument" >&2
        exit 2
      fi
      FILTER="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Run './tests/test-monorepo.sh --help' for usage." >&2
      exit 2
      ;;
  esac
done

run_test() {
  local name="$1"
  shift
  local output
  if output=$("$@" 2>&1); then
    printf "%-78s %s\n" "$name" "PASS"
    pass=$((pass + 1))
  else
    printf "%-78s %s\n" "$name" "FAIL"
    echo "$output" | sed 's/^/  /'
    fail=$((fail + 1))
  fi
}

skip_test() {
  local name="$1"
  local reason="$2"
  printf "%-78s %s\n" "$name" "SKIP"
  echo "  $reason"
  skip=$((skip + 1))
}

print_detail() {
  local label="$1"
  local value="$2"
  [ -n "$value" ] || return 0
  echo "  $label: $value"
}

should_run_case() {
  local phase="$1"
  local name="$2"

  if [ -n "$PHASE_FILTER" ] && [ "$phase" != "$PHASE_FILTER" ]; then
    return 1
  fi

  if [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]]; then
    return 1
  fi

  return 0
}

fixture_status() {
  local fixture_spec="$1"

  case "$fixture_spec" in
    ""|none)
      echo "ready|no fixture dependency"
      ;;
    generated:*)
      echo "blocked|needs generated fixture helper: ${fixture_spec#generated:}"
      ;;
    monorepo/*)
      if [ -d "$MONOREPO_FIXTURE_ROOT/${fixture_spec#monorepo/}" ]; then
        echo "ready|fixture present: tests/fixtures/$fixture_spec"
      else
        echo "blocked|planned fixture missing: tests/fixtures/$fixture_spec"
      fi
      ;;
    *)
      if [ -d "$FIXTURE_ROOT/$fixture_spec" ]; then
        echo "ready|fixture present: tests/fixtures/$fixture_spec"
      else
        echo "blocked|fixture missing: tests/fixtures/$fixture_spec"
      fi
      ;;
  esac
}

plan_case() {
  local phase="$1"
  local name="$2"
  local fixture_spec="$3"
  local assertion="$4"
  local note="$5"
  local status reason

  should_run_case "$phase" "$name" || return 0
  IFS='|' read -r status reason <<< "$(fixture_status "$fixture_spec")"

  if [ "$LIST_ONLY" = "true" ]; then
    printf "%-10s %s\n" "$phase" "$name"
    return 0
  fi

  if [ "$SHOW_DETAILS" = "true" ]; then
    echo
    echo "[$phase] $name"
    print_detail "fixture" "$fixture_spec"
    print_detail "assert" "$assertion"
    print_detail "note" "$note"
    print_detail "status" "$reason"
  fi

  if [ "$status" = "ready" ]; then
    skip_test "$name" "fixture is present; scenario implementation still pending"
    return 0
  fi

  skip_test "$name" "$reason"
}

echo "==================================================="
echo " GitHub Actions AppSec Scanner — Monorepo Test Plan"
echo "==================================================="
echo
echo "Rollout order:"
echo "  1. detect"
echo "  2. routing"
echo "  3. act"
echo "  4. report"
echo "  5. consumer"
if [ "$LIST_ONLY" = "true" ]; then
  echo
fi

if [ "$LIST_ONLY" != "true" ]; then
  run_test "monorepo fixtures root exists" test -d "$FIXTURE_ROOT"
  run_test "monorepo plan file exists" test -f "$REPO_ROOT/tests/plans/_monorepotests.plan"
fi

plan_case \
  "detect" \
  "docs-only monorepo PR keeps all language flags false" \
  "monorepo/polyglot-basic" \
  "assert detect emits has_python=false, has_js=false, has_go=false, has_iac=false for docs-only diffs" \
  "Fast negative control for nested repos so docs churn does not fan out into full scans."

plan_case \
  "detect" \
  "leaf python service change enables python without enabling unrelated stacks" \
  "monorepo/polyglot-basic" \
  "assert services/api/**/*.py changes set has_python=true while js/go/iac remain false" \
  "Covers the basic monorepo promise: one package change should not route sibling ecosystems."

plan_case \
  "detect" \
  "shared js package change enables js for nested workspace layouts" \
  "monorepo/js-workspaces" \
  "assert libs/web-shared/package.json or src changes set has_js=true for nested package roots" \
  "Targets nested package.json discovery and workspace-heavy repositories."

plan_case \
  "detect" \
  "multiple go.mod files still resolve has_go=true" \
  "monorepo/go-multi-module" \
  "assert detect turns on Go when any module changes and scanner workflows can enumerate all go.mod roots" \
  "Matches existing workflow comments about multi-module monorepos and highest-version go.mod selection."

plan_case \
  "detect" \
  "mixed rails and ruby roots keep rails and ruby routing distinct" \
  "monorepo/ruby-rails-mixed" \
  "assert Rails app changes set has_rails=true and generic Ruby-only changes can still exercise has_ruby=true" \
  "Protects the current split between Rails app detection and generic Ruby routing."

plan_case \
  "routing" \
  "workflow_dispatch full monorepo scan reaches every present scanner once" \
  "monorepo/polyglot-basic" \
  "assert a polyglot fixture can trigger the expected child workflows under workflow_dispatch all-scanners mode" \
  "High-signal fixture-based routing test before heavier act coverage."

plan_case \
  "routing" \
  "pull_request leaf service change only routes matching language jobs" \
  "monorepo/polyglot-basic" \
  "assert detect + orchestrator job selection stay limited to the changed service language and general scanners" \
  "Turns changed-file contracts into reusable-workflow routing assertions."

plan_case \
  "routing" \
  "lockfile-only changes preserve dependency scanner coverage in nested packages" \
  "monorepo/dependency-lockfiles" \
  "assert package-lock.json, composer.lock, Gemfile.lock, and go.sum changes keep their dependency scanners enabled" \
  "Protects monorepo dependency audit behavior where source files may be untouched."

plan_case \
  "act" \
  "act smoke: python service only change in polyglot monorepo" \
  "monorepo/polyglot-basic" \
  "run _orchestrator with PR history and assert python succeeds while unrelated language jobs stay skipped" \
  "First end-to-end monorepo act canary; should stay small and deterministic."

plan_case \
  "act" \
  "act smoke: infra-only change in service monorepo" \
  "monorepo/polyglot-basic" \
  "assert Terraform/Kubernetes changes route to IaC jobs without enabling app-language scanners" \
  "Covers a common mixed application + infrastructure repo layout."

plan_case \
  "act" \
  "act smoke: shared lockfile change in multi-package repo" \
  "monorepo/dependency-lockfiles" \
  "assert dependency-focused jobs still run from the correct package directories" \
  "Targets per-package audit loops in JS, PHP, and Ruby workflows."

plan_case \
  "report" \
  "artifact aggregation preserves package identity across many sibling projects" \
  "generated:multi-artifact-sarif-fixture" \
  "feed multiple SARIF artifacts from same-language sibling packages and assert summaries keep distinct file/package paths" \
  "Focused golden test for monorepo summaries without requiring full scanner execution."

plan_case \
  "report" \
  "unexpected SARIF artifact directories are rejected before aggregation" \
  "generated:artifact-provenance-fixture" \
  "assert report removes non-allowlisted artifacts while retaining expected package SARIF directories" \
  "Hardens the monorepo case where many artifacts exist and name collisions become easier."

plan_case \
  "report" \
  "one package failure does not hide successful sibling results" \
  "generated:partial-failure-sarif-fixture" \
  "assert report warning path triggers while successful package findings still appear in the summary" \
  "Directly covers the partial-failure requirement called out in tests.plan."

plan_case \
  "consumer" \
  "downstream reusable-workflow caller can request partial monorepo scans" \
  "monorepo/reusable-caller" \
  "assert an external-style caller passes scanners and disabled_tools inputs that keep monorepo routing stable" \
  "Validates the public workflow API, not only internal fixture behavior."

if [ "$LIST_ONLY" = "true" ]; then
  exit 0
fi

echo
echo "==================================================="
echo " Results: $pass passed, $fail failed, $skip skipped"
echo "==================================================="

exit "$fail"
