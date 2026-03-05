#!/usr/bin/env bash
# shellcheck disable=SC2329  # functions invoked via dynamic "$@" dispatch; shellcheck can't trace indirect calls
set -euo pipefail

KEEP_TMP="${KEEP_TMP:-false}"
KEEP_TMP_ON_FAIL="${KEEP_TMP_ON_FAIL:-false}"
FAIL_FAST="${FAIL_FAST:-false}"
ONLINE_TIMEOUT="${ONLINE_TIMEOUT:-}"
ONLINE_CACHE_DIR="${ONLINE_CACHE_DIR:-}"

pass=0
fail=0
skip=0
TMP_PATHS=()
JUNIT_CASES=()
SUITE_START=$SECONDS

LIST_TESTS=false
FILTER=""
SKIP_FILTER=""
JUNIT_FILE=""
PREREQ_REASON=""
PRESERVE_TMP=false
CACHE_DIR=""
CACHE_DIR_EXPLICIT=false
CACHE_NOTICE_EMITTED=false
TIMEOUT_BIN=""

cleanup() {
  if [ "$KEEP_TMP" = "true" ] || [ "$PRESERVE_TMP" = "true" ]; then
    return
  fi

  local path
  for path in "${TMP_PATHS[@]+${TMP_PATHS[@]}}"; do
    [ -n "$path" ] && rm -rf "$path"
  done
}

trap cleanup EXIT

make_temp_dir() {
  local dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/appsec-online.XXXXXX")"
  TMP_PATHS+=("$dir")
  echo "$dir"
}

xml_escape() {
  printf '%s' "$1" \
    | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'"'"'/\&apos;/g'
}

write_junit() {
  local total=$((pass + fail + skip))
  local elapsed=$((SECONDS - SUITE_START))
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<testsuites>'
    echo "  <testsuite name=\"GitHub Actions AppSec Scanner - Online Suite\" tests=\"$total\" failures=\"$fail\" skipped=\"$skip\" time=\"$elapsed\">"
    local tc
    for tc in "${JUNIT_CASES[@]+${JUNIT_CASES[@]}}"; do
      echo "    $tc"
    done
    echo '  </testsuite>'
    echo '</testsuites>'
  } > "$JUNIT_FILE"
}

preserve_tmp_on_failure() {
  if [ "$KEEP_TMP_ON_FAIL" = "true" ]; then
    PRESERVE_TMP=true
  fi
}

report_preserved_paths_since() {
  local start_index="$1"
  local i

  if [ "$KEEP_TMP" != "true" ] && [ "$PRESERVE_TMP" != "true" ]; then
    return
  fi

  [ "${#TMP_PATHS[@]}" -gt "$start_index" ] || return
  echo "  Preserved temp paths:"
  for ((i = start_index; i < ${#TMP_PATHS[@]}; i++)); do
    echo "    ${TMP_PATHS[$i]}"
  done
}

run_test() {
  local name="$1"
  shift
  local start=$SECONDS
  local tracked_before=${#TMP_PATHS[@]}
  local output

  printf "%-65s" "$name"
  if output=$("$@" 2>&1); then
    local elapsed=$((SECONDS - start))
    echo "PASS (${elapsed}s)"
    pass=$((pass + 1))
    if [ -n "$JUNIT_FILE" ]; then
      JUNIT_CASES+=("<testcase name=\"$(xml_escape "$name")\" time=\"$elapsed\"/>")
    fi
  else
    local elapsed=$((SECONDS - start))
    echo "FAIL (${elapsed}s)"
    while IFS= read -r line; do
      echo "  $line"
    done <<< "$output"
    fail=$((fail + 1))
    preserve_tmp_on_failure
    report_preserved_paths_since "$tracked_before"
    if [ -n "$JUNIT_FILE" ]; then
      JUNIT_CASES+=("<testcase name=\"$(xml_escape "$name")\" time=\"$elapsed\"><failure message=\"FAIL\">$(xml_escape "$output")</failure></testcase>")
    fi
  fi
}

skip_test() {
  local name="$1"
  local reason="$2"
  printf "%-65s" "$name"
  echo "SKIP"
  echo "  $reason"
  skip=$((skip + 1))
  if [ -n "$JUNIT_FILE" ]; then
    JUNIT_CASES+=("<testcase name=\"$(xml_escape "$name")\"><skipped message=\"$(xml_escape "$reason")\"/></testcase>")
  fi
}

show_help() {
  cat <<EOF
Usage: ./tests/test-online.sh [--help] [--list] [--filter <pattern>] [--skip <pattern>]
                              [--fail-fast] [--junit <file>] [--keep-temp]
                              [--keep-temp-on-fail] [--timeout <seconds>]
                              [--cache-dir <dir>]

Runs the online/runtime GitHub Actions AppSec Scanner test suite.

What it does:
  - Runs laptop-friendly live smoke tests against real upstream services
  - Stays separate from ./tests/test-offline.sh and ./tests/test-act.sh
  - Checks live install behavior, advisory reachability, and scanner output shape

Environment variables:
  KEEP_TMP           true|false. Preserve temp dirs for all runs
  KEEP_TMP_ON_FAIL   true|false. Preserve temp dirs only after a failure
  FAIL_FAST          true|false. Stop after the first failure
  ONLINE_TIMEOUT     Seconds to allow long-running network/install commands
  ONLINE_CACHE_DIR   Tool cache directory

Flags:
  --list              Print all registered online test names and exit
  --filter <pattern>  Only run tests whose names contain <pattern>
  --skip <pattern>    Skip tests whose names contain <pattern>
  --fail-fast         Stop after the first failing selected test
  --junit <file>      Write JUnit XML results to <file>
  --keep-temp         Preserve all temp dirs
  --keep-temp-on-fail Preserve temp dirs only after a failing test
  --timeout <seconds> Override ONLINE_TIMEOUT
  --cache-dir <dir>   Override ONLINE_CACHE_DIR
  -h, --help          Show this help text and exit

Notes:
  - These tests may download packages, query advisory databases, and require internet access
  - Default cache directory: \${XDG_CACHE_HOME:-\$HOME/.cache}/github-actions-appsec-scanner/test-online
  - No GitHub-hosted workflow checks belong in this script unless they can run locally

Examples:
  ./tests/test-online.sh
  ./tests/test-online.sh --list
  ./tests/test-online.sh --filter govulncheck
  KEEP_TMP_ON_FAIL=true ONLINE_TIMEOUT=900 ./tests/test-online.sh --junit /tmp/test-online.xml
EOF
}

resolve_cache_dir() {
  local candidate
  local default_cache="${XDG_CACHE_HOME:-$HOME/.cache}/github-actions-appsec-scanner/test-online"

  if [ -n "$ONLINE_CACHE_DIR" ]; then
    candidate="$ONLINE_CACHE_DIR"
    CACHE_DIR_EXPLICIT=true
  else
    candidate="$default_cache"
  fi

  if mkdir -p "$candidate" 2>/dev/null && [ -d "$candidate" ] && [ -w "$candidate" ]; then
    CACHE_DIR="$candidate"
    return 0
  fi

  if [ "$CACHE_DIR_EXPLICIT" = "true" ]; then
    echo "Cache directory is not writable: $candidate" >&2
    exit 2
  fi

  CACHE_DIR=""
  if [ "$CACHE_NOTICE_EMITTED" = "false" ]; then
    echo "Notice: default cache directory is unavailable, falling back to per-run temp installs" >&2
    CACHE_NOTICE_EMITTED=true
  fi
}

setup_timeout_support() {
  if [ -n "$ONLINE_TIMEOUT" ]; then
    case "$ONLINE_TIMEOUT" in
      ''|*[!0-9]*)
        echo "--timeout must be a positive integer" >&2
        exit 2
        ;;
    esac
    if [ "$ONLINE_TIMEOUT" -le 0 ]; then
      echo "--timeout must be greater than 0" >&2
      exit 2
    fi
  fi

  if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_BIN="timeout"
    return 0
  fi

  if command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_BIN="gtimeout"
    return 0
  fi

  if [ -n "$ONLINE_TIMEOUT" ]; then
    echo "A timeout was requested, but neither 'timeout' nor 'gtimeout' is installed" >&2
    exit 2
  fi
}

run_with_timeout() {
  if [ -n "$ONLINE_TIMEOUT" ]; then
    "$TIMEOUT_BIN" "$ONLINE_TIMEOUT" "$@"
  else
    "$@"
  fi
}

retry() {
  local attempts="$1"
  shift
  local i=1

  while [ "$i" -le "$attempts" ]; do
    if "$@"; then
      return 0
    fi
    if [ "$i" -lt "$attempts" ]; then
      echo "Attempt $i/$attempts failed, retrying in 5s..." >&2
      sleep 5
    fi
    i=$((i + 1))
  done

  return 1
}

require_binary() {
  local binary="$1"
  if command -v "$binary" >/dev/null 2>&1; then
    return 0
  fi
  PREREQ_REASON="$binary is not installed"
  return 1
}

require_python_venv() {
  if ! command -v python3 >/dev/null 2>&1; then
    PREREQ_REASON="python3 is not installed"
    return 1
  fi
  if ! python3 -c 'import venv' >/dev/null 2>&1; then
    PREREQ_REASON="python3 venv support is not installed"
    return 1
  fi
  return 0
}

require_cargo() {
  require_binary cargo
}

require_composer() {
  require_binary composer
}

require_ruby_bundle_git() {
  local missing=()
  local tool
  for tool in ruby gem bundle git; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      missing+=("$tool")
    fi
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    return 0
  fi

  local joined
  joined="$(IFS=', '; echo "${missing[*]}")"
  PREREQ_REASON="missing prerequisites: $joined"
  return 1
}

require_go() {
  require_binary go
}

should_run() {
  local name="$1"

  if [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]]; then
    return 1
  fi

  if [ -n "$SKIP_FILTER" ] && [[ "$name" == *"$SKIP_FILTER"* ]]; then
    return 1
  fi

  return 0
}

ensure_pip_audit_venv() {
  local work_dir="$1"
  local venv_dir

  if [ -n "$CACHE_DIR" ]; then
    venv_dir="$CACHE_DIR/python/pip-audit-2.9.0/venv"
  else
    venv_dir="$work_dir/pip-audit-venv"
  fi

  mkdir -p "$(dirname "$venv_dir")"
  if [ ! -x "$venv_dir/bin/pip-audit" ] || ! "$venv_dir/bin/python" -m pip show pip-audit >/dev/null 2>&1; then
    rm -rf "$venv_dir"
    run_with_timeout python3 -m venv "$venv_dir"
    retry 3 run_with_timeout "$venv_dir/bin/python" -m pip install --quiet pip-audit==2.9.0
  fi

  echo "$venv_dir"
}

ensure_cargo_audit_root() {
  local work_dir="$1"
  local root

  if [ -n "$CACHE_DIR" ]; then
    root="$CACHE_DIR/rust/cargo-audit-0.22.1"
  else
    root="$work_dir/cargo-root"
  fi

  mkdir -p "$root"
  if [ ! -x "$root/bin/cargo-audit" ]; then
    retry 3 run_with_timeout cargo install cargo-audit --version 0.22.1 --locked --root "$root"
  fi

  echo "$root"
}

ensure_bundler_audit_root() {
  local work_dir="$1"
  local root

  if [ -n "$CACHE_DIR" ]; then
    root="$CACHE_DIR/ruby/bundler-audit-0.9.2"
  else
    root="$work_dir/gems"
  fi

  mkdir -p "$root"
  if [ ! -x "$root/bin/bundle-audit" ]; then
    retry 3 run_with_timeout env GEM_HOME="$root" GEM_PATH="$root" gem install bundler-audit:0.9.2 --no-document
  fi

  echo "$root"
}

ensure_govulncheck_bin_dir() {
  local work_dir="$1"
  local bin_dir

  if [ -n "$CACHE_DIR" ]; then
    bin_dir="$CACHE_DIR/go/govulncheck-v1.1.4/bin"
  else
    bin_dir="$work_dir/go-bin"
  fi

  mkdir -p "$bin_dir"
  if [ ! -x "$bin_dir/govulncheck" ]; then
    retry 3 run_with_timeout env GOBIN="$bin_dir" go install golang.org/x/vuln/cmd/govulncheck@v1.1.4
  fi

  echo "$bin_dir"
}

validate_pip_audit_output() {
  local file="$1"
  python3 - "$file" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

if isinstance(data, list):
    deps = data
elif isinstance(data, dict):
    deps = data.get("dependencies", [])
else:
    raise SystemExit("pip-audit output must be a JSON list or object")

if not isinstance(deps, list):
    raise SystemExit("pip-audit dependencies must be a list")

for idx, entry in enumerate(deps):
    if not isinstance(entry, dict):
        raise SystemExit(f"pip-audit entry {idx} is not an object")
    if "name" not in entry or "version" not in entry:
        raise SystemExit(f"pip-audit entry {idx} missing name/version")
    if "vulns" in entry and not isinstance(entry["vulns"], list):
        raise SystemExit(f"pip-audit entry {idx} has non-list vulns")
PY
}

validate_cargo_audit_output() {
  local file="$1"
  python3 - "$file" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

if not isinstance(data, dict):
    raise SystemExit("cargo-audit output must be a JSON object")

vulns = data.get("vulnerabilities")
if not isinstance(vulns, dict):
    raise SystemExit("cargo-audit output missing vulnerabilities object")

items = vulns.get("list")
if not isinstance(items, list):
    raise SystemExit("cargo-audit vulnerabilities.list must be a list")

for idx, entry in enumerate(items):
    if not isinstance(entry, dict):
        raise SystemExit(f"cargo-audit vulnerability {idx} is not an object")
    for key in ("advisory", "package"):
        if key in entry and not isinstance(entry[key], dict):
            raise SystemExit(f"cargo-audit vulnerability {idx} has invalid {key}")
PY
}

validate_composer_audit_output() {
  local file="$1"
  python3 - "$file" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    raw = fh.read().strip()

if raw == "No security vulnerability advisories found.":
    raise SystemExit(0)

data = json.loads(raw)

if not isinstance(data, dict):
    raise SystemExit("composer audit output must be a JSON object")

advisories = data.get("advisories")
if isinstance(advisories, list):
    if advisories:
        raise SystemExit("composer audit advisories list is only expected when empty")
    raise SystemExit(0)
if not isinstance(advisories, dict):
    raise SystemExit("composer audit output missing advisories object")

for pkg_name, entries in advisories.items():
    if not isinstance(pkg_name, str):
        raise SystemExit("composer audit advisory key must be a string")
    if entries is None:
        continue
    if not isinstance(entries, list):
        raise SystemExit(f"composer audit advisories for {pkg_name} must be a list")
    for idx, entry in enumerate(entries):
        if not isinstance(entry, dict):
            raise SystemExit(f"composer audit advisory {pkg_name}[{idx}] is not an object")
PY
}

validate_bundler_audit_output() {
  local file="$1"
  python3 - "$file" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

if isinstance(data, list):
    results = data
elif isinstance(data, dict):
    results = data.get("results", [])
else:
    raise SystemExit("bundler-audit output must be a JSON list or object")

if not isinstance(results, list):
    raise SystemExit("bundler-audit results must be a list")

for idx, entry in enumerate(results):
    if not isinstance(entry, dict):
        raise SystemExit(f"bundler-audit result {idx} is not an object")
    if entry.get("type") == "UnpatchedGem":
        if not isinstance(entry.get("gem"), dict):
            raise SystemExit(f"bundler-audit result {idx} missing gem object")
        if not isinstance(entry.get("advisory"), dict):
            raise SystemExit(f"bundler-audit result {idx} missing advisory object")
PY
}

validate_govulncheck_output() {
  local file="$1"
  python3 - "$file" <<'PY'
import json
import sys

path = sys.argv[1]
allowed = {"config", "progress", "osv", "finding", "SBOM"}
count = 0

with open(path, "r", encoding="utf-8") as fh:
    raw = fh.read()

decoder = json.JSONDecoder()
idx = 0
length = len(raw)

while idx < length:
    while idx < length and raw[idx].isspace():
        idx += 1
    if idx >= length:
        break
    msg, next_idx = decoder.raw_decode(raw, idx)
    if not isinstance(msg, dict):
        raise SystemExit(f"govulncheck message at offset {idx} is not an object")
    if not any(key in msg for key in allowed):
        raise SystemExit(f"govulncheck message at offset {idx} missing recognized envelope key")
    if "osv" in msg:
        osv = msg["osv"]
        if not isinstance(osv, dict) or not osv.get("id"):
            raise SystemExit(f"govulncheck message at offset {idx} has invalid osv envelope")
    if "finding" in msg:
        finding = msg["finding"]
        if not isinstance(finding, dict):
            raise SystemExit(f"govulncheck message at offset {idx} has invalid finding envelope")
        if not finding.get("osv"):
            raise SystemExit(f"govulncheck message at offset {idx} missing finding.osv")
        if not isinstance(finding.get("trace"), list):
            raise SystemExit(f"govulncheck message at offset {idx} missing finding.trace list")
    count += 1
    idx = next_idx

if count == 0:
    raise SystemExit("no govulncheck messages parsed")
PY
}

test_pip_audit_live_smoke() {
  local dir
  local venv_dir
  dir="$(make_temp_dir)"
  venv_dir="$(ensure_pip_audit_venv "$dir")"

  cat > "$dir/requirements.txt" <<'EOF'
requests==2.31.0
EOF

  (
    cd "$dir"
    "$venv_dir/bin/pip-audit" -r requirements.txt --format json --output pip-audit.json >/dev/null 2>&1 || true
  )
  [ -s "$dir/pip-audit.json" ]
  validate_pip_audit_output "$dir/pip-audit.json"
}

test_cargo_audit_live_smoke() {
  local dir
  local cargo_root
  dir="$(make_temp_dir)"

  cargo init --lib --name cargo_audit_smoke "$dir/project" >/dev/null 2>&1
  cat > "$dir/project/Cargo.toml" <<'EOF'
[package]
name = "cargo_audit_smoke"
version = "0.1.0"
edition = "2021"

[dependencies]
serde = "1"
EOF

  (
    cd "$dir/project"
    retry 3 run_with_timeout cargo generate-lockfile >/dev/null 2>&1
  )
  cargo_root="$(ensure_cargo_audit_root "$dir")"
  (
    cd "$dir/project"
    PATH="$cargo_root/bin:$PATH" cargo audit --json > cargo-audit.json || true
  )
  [ -s "$dir/project/cargo-audit.json" ]
  validate_cargo_audit_output "$dir/project/cargo-audit.json"
}

test_composer_audit_live_smoke() {
  local dir
  dir="$(make_temp_dir)"

  cat > "$dir/composer.json" <<'EOF'
{
  "name": "codex/composer-audit-smoke",
  "require": {
    "monolog/monolog": "^3.0"
  }
}
EOF

  (
    cd "$dir"
    retry 3 run_with_timeout composer update --no-interaction --no-progress --prefer-dist >/dev/null 2>&1
    composer audit --format=json > composer-audit.json || true
  )
  [ -s "$dir/composer-audit.json" ]
  validate_composer_audit_output "$dir/composer-audit.json"
}

test_bundler_audit_live_smoke() {
  local dir
  local gem_root
  local bundle_audit_bin
  dir="$(make_temp_dir)"

  cat > "$dir/Gemfile" <<'EOF'
source "https://rubygems.org"
gem "rack", "~> 2.2"
EOF

  (
    cd "$dir"
    retry 3 run_with_timeout bundle lock >/dev/null 2>&1
  )
  gem_root="$(ensure_bundler_audit_root "$dir")"
  bundle_audit_bin="$gem_root/bin/bundle-audit"
  [ -x "$bundle_audit_bin" ]
  (
    cd "$dir"
    retry 3 run_with_timeout env GEM_HOME="$gem_root" GEM_PATH="$gem_root" "$bundle_audit_bin" update >/dev/null 2>&1
    GEM_HOME="$gem_root" GEM_PATH="$gem_root" "$bundle_audit_bin" check --format json > bundler-audit.json || true
  )
  [ -s "$dir/bundler-audit.json" ]
  validate_bundler_audit_output "$dir/bundler-audit.json"
}

test_govulncheck_output_schema_canary() {
  local dir
  local go_bin
  dir="$(make_temp_dir)"

  mkdir -p "$dir/project"
  cat > "$dir/project/go.mod" <<'EOF'
module example.com/govulncheck-smoke

go 1.22

require golang.org/x/text v0.14.0
EOF
  cat > "$dir/project/main.go" <<'EOF'
package main

import "golang.org/x/text/language"

func main() {
	_ = language.English
}
EOF

  (
    cd "$dir/project"
    retry 3 run_with_timeout go mod tidy >/dev/null 2>&1
  )
  go_bin="$(ensure_govulncheck_bin_dir "$dir")"
  (
    cd "$dir/project"
    PATH="$go_bin:$PATH" govulncheck -json ./... > govulncheck.json || true
  )
  [ -s "$dir/project/govulncheck.json" ]
  validate_govulncheck_output "$dir/project/govulncheck.json"
}

run_registered_test() {
  local name="$1"
  local func="$2"
  local prereq_func="$3"
  local fail_before

  if ! "$prereq_func"; then
    skip_test "$name" "$PREREQ_REASON"
    return 0
  fi

  fail_before=$fail
  run_test "$name" "$func"
  if [ "$FAIL_FAST" = "true" ] && [ "$fail" -gt "$fail_before" ]; then
    return 1
  fi
}

run_selected_tests() {
  local entry name func prereq_func
  for entry in "$@"; do
    IFS='|' read -r name func prereq_func <<< "$entry"
    run_registered_test "$name" "$func" "$prereq_func" || return 1
  done
  return 0
}

TESTS=(
  "pip-audit live smoke|test_pip_audit_live_smoke|require_python_venv"
  "cargo-audit live smoke|test_cargo_audit_live_smoke|require_cargo"
  "composer audit live smoke|test_composer_audit_live_smoke|require_composer"
  "bundler-audit live smoke|test_bundler_audit_live_smoke|require_ruby_bundle_git"
  "govulncheck output schema canary|test_govulncheck_output_schema_canary|require_go"
)

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      show_help
      exit 0
      ;;
    --list)
      LIST_TESTS=true
      shift
      ;;
    --filter)
      if [ $# -lt 2 ]; then
        echo "--filter requires an argument" >&2
        exit 2
      fi
      FILTER="$2"
      shift 2
      ;;
    --skip)
      if [ $# -lt 2 ]; then
        echo "--skip requires an argument" >&2
        exit 2
      fi
      SKIP_FILTER="$2"
      shift 2
      ;;
    --fail-fast)
      FAIL_FAST=true
      shift
      ;;
    --junit)
      if [ $# -lt 2 ]; then
        echo "--junit requires a file path argument" >&2
        exit 2
      fi
      JUNIT_FILE="$2"
      shift 2
      ;;
    --keep-temp)
      KEEP_TMP=true
      shift
      ;;
    --keep-temp-on-fail)
      KEEP_TMP_ON_FAIL=true
      shift
      ;;
    --timeout)
      if [ $# -lt 2 ]; then
        echo "--timeout requires a numeric argument" >&2
        exit 2
      fi
      ONLINE_TIMEOUT="$2"
      shift 2
      ;;
    --cache-dir)
      if [ $# -lt 2 ]; then
        echo "--cache-dir requires a directory argument" >&2
        exit 2
      fi
      ONLINE_CACHE_DIR="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Run './tests/test-online.sh --help' for usage." >&2
      exit 2
      ;;
  esac
done

setup_timeout_support

if [ "$LIST_TESTS" = "true" ]; then
  for entry in "${TESTS[@]}"; do
    echo "${entry%%|*}"
  done
  exit 0
fi

resolve_cache_dir

echo "============================================"
echo " GitHub Actions AppSec Scanner - Online Test Suite"
echo "============================================"
echo

echo "--- Live Smoke Tests ---"

SELECTED_TESTS=()
for entry in "${TESTS[@]}"; do
  name="${entry%%|*}"
  should_run "$name" || continue
  SELECTED_TESTS+=("$entry")
done

run_selected_tests "${SELECTED_TESTS[@]+${SELECTED_TESTS[@]}}" || true

echo
echo "============================================"
echo " Results: $pass passed, $fail failed, $skip skipped"
echo "============================================"

if [ -n "$JUNIT_FILE" ]; then
  write_junit
  echo " JUnit XML written to: $JUNIT_FILE"
fi

exit "$fail"
