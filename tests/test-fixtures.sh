#!/usr/bin/env bash
# shellcheck disable=SC2329  # functions invoked via dynamic "$@" dispatch; shellcheck can't trace indirect calls
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WF_SRC_DIR="$REPO_ROOT/.github/workflows"
FIXTURE_ROOT="$REPO_ROOT/tests/fixtures"
FIXTURE_MANIFEST="$FIXTURE_ROOT/manifest.json"

ACT_BIN="${ACT_BIN:-act}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
GIT_BIN="${GIT_BIN:-git}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
ACT_IMAGE="${ACT_IMAGE:-catthehacker/ubuntu:act-24.04}"
ACT_ARCH="${ACT_ARCH:-linux/amd64}"
ACT_PULL="${ACT_PULL:-true}"
ACT_VERBOSE="${ACT_VERBOSE:-false}"
ACT_TIMEOUT="${ACT_TIMEOUT:-}"   # optional: seconds before killing a single act run
KEEP_TMP="${KEEP_TMP:-false}"
KEEP_TMP_ON_FAIL="${KEEP_TMP_ON_FAIL:-false}"
FAIL_FAST="${FAIL_FAST:-false}"
LOG_DIR="${LOG_DIR:-}"
JOBS="${JOBS:-1}"
PRESERVE_TMP="${PRESERVE_TMP:-false}"
ACT_INTERNAL_TEST_FUNC="${ACT_INTERNAL_TEST_FUNC:-}"
ACT_INTERNAL_TEST_NAME="${ACT_INTERNAL_TEST_NAME:-}"
ACT_INTERNAL_RESULT_FILE="${ACT_INTERNAL_RESULT_FILE:-}"

pass=0
fail=0
skip=0
TMP_PATHS=()   # temp dirs AND files tracked for cleanup
JUNIT_CASES=() # accumulated <testcase> XML snippets
SUITE_START=$SECONDS

LIST_TESTS=false
FILTER=""
JUNIT_FILE=""
PREREQ_REASON=""

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

# Escape the five XML special characters.
xml_escape() {
  printf '%s' "$1" \
    | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'"'"'/\&apos;/g'
}

run_test() {
  local name="$1"
  shift
  local start=$SECONDS
  printf "%-65s" "$name"
  local output
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
    echo "$output" | sed 's/^/  /'
    fail=$((fail + 1))
    preserve_tmp_on_failure
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
Usage: ./tests/test-fixtures.sh [--help] [--keep-temp] [--keep-temp-on-fail]
                           [--verbose] [--list] [--fail-fast]
                           [--filter <pattern>] [--junit <file>]
                           [--log-dir <dir>] [--jobs <count>]

Runs fixture combination smoke tests using act.

What it does:
  - Stages this repo's workflows into a temporary .github/ tree
  - Rewrites GitHub-hosted-only steps (harden-runner/cache/artifact actions)
    into local no-op shims for act
  - Creates fixture repos combining multiple language fixtures
  - Runs targeted act scenarios against the staged orchestrator workflow

Required tools:
  - act
  - docker
  - git
  - python3

Environment variables:
  ACT_BIN       Path to act (default: act)
  DOCKER_BIN    Path to docker (default: docker)
  GIT_BIN       Path to git (default: git)
  GITHUB_TOKEN  Optional GitHub token passed through to act for fetching
                marketplace actions and handling API-backed steps
  PYTHON_BIN    Path to python3 (default: python3)
  ACT_IMAGE     Runner image for ubuntu-24.04
                (default: catthehacker/ubuntu:act-24.04)
  ACT_ARCH      Container architecture passed to act
                (default: linux/amd64)
  ACT_PULL      true|false. When false, pass --pull=false to act
  ACT_VERBOSE   true|false. When true, pass --verbose to act
  ACT_TIMEOUT   Seconds before killing a single act invocation (default: none)
  KEEP_TMP      true|false. When true, preserve staged temp repos and log files
  KEEP_TMP_ON_FAIL
                true|false. When true, preserve staged temp repos and log files
                only after a failing test
  LOG_DIR       Directory for per-test log files (default: temp files)
  JOBS          Number of tests to run in parallel (default: 1)

Flags:
  --list              Print all test names and exit
  --filter <pattern>  Only run tests whose names contain <pattern>
  --junit <file>      Write JUnit XML results to <file>
  --keep-temp         Preserve staged temp repos and log files (same as KEEP_TMP=true)
  --keep-temp-on-fail Preserve staged temp repos and log files after a failure
  --fail-fast         Stop after the first failing test or failing batch
  --log-dir <dir>     Write per-test logs into <dir>
  --jobs <count>      Run up to <count> tests in parallel
  --verbose           Pass --verbose to act

Examples:
  ./tests/test-fixtures.sh
  ./tests/test-fixtures.sh --filter python
  ./tests/test-fixtures.sh --filter go --junit results.xml
  ./tests/test-fixtures.sh --jobs 4 --log-dir /tmp/act-logs
  ACT_IMAGE=catthehacker/ubuntu:full-24.04 ./tests/test-fixtures.sh
  KEEP_TMP=true ACT_TIMEOUT=300 ./tests/test-fixtures.sh --verbose
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      show_help
      exit 0
      ;;
    --keep-temp)
      KEEP_TMP=true
      shift
      ;;
    --keep-temp-on-fail)
      KEEP_TMP_ON_FAIL=true
      shift
      ;;
    --verbose)
      ACT_VERBOSE=true
      shift
      ;;
    --fail-fast)
      FAIL_FAST=true
      shift
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
    --junit)
      if [ $# -lt 2 ]; then
        echo "--junit requires a file path argument" >&2
        exit 2
      fi
      JUNIT_FILE="$2"
      shift 2
      ;;
    --log-dir)
      if [ $# -lt 2 ]; then
        echo "--log-dir requires a directory argument" >&2
        exit 2
      fi
      LOG_DIR="$2"
      shift 2
      ;;
    --jobs)
      if [ $# -lt 2 ]; then
        echo "--jobs requires a numeric argument" >&2
        exit 2
      fi
      JOBS="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Run './tests/test-fixtures.sh --help' for usage." >&2
      exit 2
      ;;
  esac
done

case "$JOBS" in
  ''|*[!0-9]*)
    echo "--jobs must be a positive integer" >&2
    exit 2
    ;;
esac

[ "$JOBS" -gt 0 ] || {
  echo "--jobs must be greater than 0" >&2
  exit 2
}

if [ -n "$LOG_DIR" ]; then
  mkdir -p "$LOG_DIR"
fi

sanitize_name() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9._-]/-/g; s/-\{2,\}/-/g; s/^-//; s/-$//'
}

make_log_file() {
  local name="${1:-act-log}"
  local safe base path
  safe="$(sanitize_name "$name")"
  [ -n "$safe" ] || safe="act-log"

  # macOS mktemp does not support a suffix after the X's, so create a tempfile
  # with X's at the end, then rename it to add the .log extension.
  if [ -n "$LOG_DIR" ]; then
    base="$(mktemp "$LOG_DIR/${safe}.XXXXXX")"
  else
    base="$(mktemp "${TMPDIR:-/tmp}/appsec-act-${safe}.XXXXXX")"
    TMP_PATHS+=("${base}.log")
  fi
  mv "$base" "${base}.log"
  path="${base}.log"

  echo "$path"
}

make_result_file() {
  local name="${1:-act-result}"
  local safe base path
  safe="$(sanitize_name "$name")"
  [ -n "$safe" ] || safe="act-result"
  # macOS mktemp does not support a suffix after the X's.
  base="$(mktemp "${TMPDIR:-/tmp}/appsec-act-${safe}.XXXXXX")"
  mv "$base" "${base}.result"
  path="${base}.result"
  TMP_PATHS+=("$path")
  echo "$path"
}

preserve_tmp_on_failure() {
  if [ "$KEEP_TMP_ON_FAIL" = "true" ]; then
    PRESERVE_TMP=true
  fi
}

require_runtime_prereqs() {
  local missing=()

  command -v "$ACT_BIN" >/dev/null 2>&1 || missing+=("$ACT_BIN")
  command -v "$DOCKER_BIN" >/dev/null 2>&1 || missing+=("$DOCKER_BIN")
  command -v "$GIT_BIN" >/dev/null 2>&1 || missing+=("$GIT_BIN")
  command -v "$PYTHON_BIN" >/dev/null 2>&1 || missing+=("$PYTHON_BIN")

  if [ "${#missing[@]}" -gt 0 ]; then
    PREREQ_REASON="missing required tool(s): ${missing[*]}"
    return 1
  fi

  if ! "$DOCKER_BIN" info >/dev/null 2>&1; then
    PREREQ_REASON="docker daemon is not reachable"
    return 1
  fi

  return 0
}

make_temp_repo() {
  local dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/appsec-act.XXXXXX")"
  TMP_PATHS+=("$dir")

  mkdir -p "$dir/.github/workflows" "$dir/.github/events"
  cp "$WF_SRC_DIR"/*.yaml "$dir/.github/workflows/"
  cp -R "$REPO_ROOT/.github/actions" "$dir/.github/actions"
  cp -R "$REPO_ROOT/.github/scripts" "$dir/.github/scripts"

  echo "$dir"
}

normalize_for_act() {
  local dir="$1"

  "$PYTHON_BIN" - "$dir" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])

shim_actions = {
    "step-security/harden-runner@": "step-security/harden-runner",
    "actions/cache@": "actions/cache",
    "actions/upload-artifact@": "actions/upload-artifact",
    "actions/download-artifact@": "actions/download-artifact",
    "actions/setup-node@": "actions/setup-node",
    "actions/setup-python@": "actions/setup-python",
    "actions/setup-java@": "actions/setup-java",
    "actions/setup-dotnet@": "actions/setup-dotnet",
    "actions/setup-go@": "actions/setup-go",
    "dtolnay/rust-toolchain@": "dtolnay/rust-toolchain",
    "ruby/setup-ruby@": "ruby/setup-ruby",
    "dominikh/staticcheck-action@": "dominikh/staticcheck-action",
}


def step_name(block):
    for line in block:
        stripped = line.lstrip()
        if stripped.startswith("- name: "):
            return stripped.split(":", 1)[1].strip()
    return ""


def emit_shim(indent, name, label, commands):
    lines = [
        f"{indent}- name: {name} (act shim)\n",
        f"{indent}  run: |\n",
        f"{indent}    echo \"Skipping {label} under act\"\n",
    ]
    for command in commands:
        lines.append(f"{indent}    {command}\n")
    return lines


def emit_java_pmd_stub(indent):
    return [
        f"{indent}- name: Install PMD (act shim)\n",
        f"{indent}  run: |\n",
        f"{indent}    mkdir -p \"$HOME/pmd/bin\"\n",
        f"{indent}    cat > \"$HOME/pmd/bin/pmd\" <<'EOF'\n",
        f"{indent}    #!/usr/bin/env bash\n",
        f"{indent}    # Handle --version so Verify PMD binary integrity passes.\n",
        f"{indent}    if [ \"${{1:-}}\" = \"--version\" ]; then echo \"PMD 7.12.0\"; exit 0; fi\n",
        f"{indent}    cat <<'SARIF'\n",
        f"{indent}    {{\"version\":\"2.1.0\",\"runs\":[{{\"tool\":{{\"driver\":{{\"name\":\"pmd-act-shim\",\"informationUri\":\"https://pmd.github.io/\"}}}},\"results\":[]}}]}}\n",
        f"{indent}    SARIF\n",
        f"{indent}    EOF\n",
        f"{indent}    chmod +x \"$HOME/pmd/bin/pmd\"\n",
    ]


# ── Tool stub helpers ──────────────────────────────────────────────────────────

def emit_stub_binary(indent, step_label, bin_name, bin_dir, script_lines, extra_after=None):
    """Emit a step that writes a stub binary to bin_dir/bin_name and adds bin_dir to PATH."""
    # Use a unique heredoc tag derived from the binary name (uppercase, hyphens->underscores).
    tag = bin_name.upper().replace("-", "_") + "EOF"
    lines = [
        f"{indent}- name: {step_label} (act shim)\n",
        f"{indent}  run: |\n",
        f"{indent}    echo \"Creating {bin_name} stub for act\"\n",
        f"{indent}    mkdir -p \"{bin_dir}\"\n",
        f"{indent}    cat > \"{bin_dir}/{bin_name}\" <<'{tag}'\n",
    ]
    for script_line in script_lines:
        lines.append(f"{indent}    {script_line}\n")
    lines.append(f"{indent}    {tag}\n")
    lines.extend([
        f"{indent}    chmod +x \"{bin_dir}/{bin_name}\"\n",
        f"{indent}    printf '%s\\n' \"{bin_dir}\" >> \"$GITHUB_PATH\"\n",
        f"{indent}    export PATH=\"{bin_dir}:$PATH\"\n",
    ])
    if extra_after:
        for cmd in extra_after:
            lines.append(f"{indent}    {cmd}\n")
    return lines


EMPTY_SARIF = '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"TOOLNAME"}},"results":[]}]}'


def emit_sarif_stub(indent, step_label, sarif_file, tool_name):
    sarif = EMPTY_SARIF.replace("TOOLNAME", tool_name)
    return [
        f"{indent}- name: {step_label} (act shim)\n",
        f"{indent}  run: |\n",
        f"{indent}    echo \"Stubbing {tool_name} under act — emitting empty SARIF\"\n",
        f"{indent}    cat > {sarif_file} <<'SARIFEOF'\n",
        f"{indent}    {sarif}\n",
        f"{indent}    SARIFEOF\n",
    ]


def dotnet_channel(block_text):
    match = re.search(r"dotnet-version:\s*['\"]?([^'\"\n]+)", block_text)
    if not match:
        return "${{ matrix.dotnet-version }}"
    version = match.group(1).strip()
    if version == "${{ matrix.dotnet-version }}":
        return version
    return re.sub(r"\.x$", "", version)

for path in root.joinpath(".github").rglob("*.yaml"):
    lines = path.read_text().splitlines(keepends=True)
    out = []
    i = 0

    while i < len(lines):
      line = lines[i]
      stripped = line.lstrip()

      if stripped.startswith("- name: "):
          indent = line[: len(line) - len(stripped)]
          block = [line]
          i += 1

          while i < len(lines):
              nxt = lines[i]
              nxt_stripped = nxt.lstrip()
              nxt_indent = nxt[: len(nxt) - len(nxt_stripped)]
              if nxt_stripped.startswith("- ") and nxt_indent == indent:
                  break
              # Also break at a shallower indent (e.g. next job key) so job
              # headers between steps don't get swallowed into the current block.
              if nxt_stripped and len(nxt_indent) < len(indent):
                  break
              block.append(nxt)
              i += 1

          block_text = "".join(block)
          name = step_name(block)
          matched = None
          for needle, label in shim_actions.items():
              if needle in block_text:
                  matched = label
                  break

          # ── Per-file named-step stubs ──────────────────────────────────────
          if path.name == "security-java.yaml" and name == "Install PMD":
              out.extend(emit_java_pmd_stub(indent))

          # Go: stub gosec and govulncheck so Go is not required in the act image.
          elif path.name == "security-go.yaml" and name == "Run Gosec":
              out.extend(emit_sarif_stub(indent, "Run Gosec", "gosec.sarif", "gosec"))
          elif path.name == "security-go.yaml" and name == "Install govulncheck":
              out.extend(emit_shim(indent, "Install govulncheck", "Install govulncheck", ["true"]))
          elif path.name == "security-go.yaml" and name == "Run govulncheck":
              out.extend(emit_shim(indent, "Run govulncheck", "govulncheck", [
                  "echo 'Stubbing govulncheck under act'",
                  "printf '' > govulncheck.json",
              ]))

          # Ruby: stub rubocop and bundler-audit gem installs.
          elif path.name == "security-ruby.yaml" and name == "Install RuboCop":
              out.extend(emit_stub_binary(indent, "Install RuboCop", "rubocop",
                  "${HOME}/.local/bin", [
                  "#!/bin/sh",
                  "out=\"\"",
                  "while [ $# -gt 0 ]; do",
                  "  case \"$1\" in",
                  "    --out) out=\"$2\"; shift 2 ;;",
                  "    *) shift ;;",
                  "  esac",
                  "done",
                  "json='{\"metadata\":{},\"files\":[],\"summary\":{\"offense_count\":0,\"target_file_count\":0}}'",
                  "if [ -n \"$out\" ]; then printf '%s\\n' \"$json\" > \"$out\"; else printf '%s\\n' \"$json\"; fi",
              ]))
          elif path.name == "security-ruby.yaml" and name == "Install bundler-audit":
              out.extend(emit_stub_binary(indent, "Install bundler-audit", "bundle-audit",
                  "${HOME}/.local/bin", [
                  "#!/bin/sh",
                  "printf '{\"results\":[],\"ignored\":[]}'",
              ]))

          # Rails: stub brakeman gem install; Run Brakeman uses the stub automatically.
          elif path.name == "security-rails.yaml" and name == "Install Brakeman":
              out.extend(emit_stub_binary(indent, "Install Brakeman", "brakeman",
                  "${HOME}/.local/bin", [
                  "#!/bin/sh",
                  "out=\"\"",
                  "while [ $# -gt 0 ]; do",
                  "  case \"$1\" in",
                  "    --output|-o) out=\"$2\"; shift 2 ;;",
                  "    *) shift ;;",
                  "  esac",
                  "done",
                  "sarif='{\"version\":\"2.1.0\",\"runs\":[{\"tool\":{\"driver\":{\"name\":\"brakeman\",\"version\":\"8.0.2\",\"informationUri\":\"https://brakemanscanner.org/\"}},\"results\":[]}]}'",
                  "if [ -n \"$out\" ]; then printf '%s\\n' \"$sarif\" > \"$out\"; else printf '%s\\n' \"$sarif\"; fi",
              ]))

          # PHP: stub phpstan install; stub composer audit to emit minimal JSON.
          elif path.name == "security-php.yaml" and name == "Install PHPStan":
              out.extend(emit_stub_binary(indent, "Install PHPStan", "phpstan",
                  "${HOME}/.local/bin", [
                  "#!/bin/sh",
                  "printf '{\"totals\":{\"errors\":0,\"file_errors\":0},\"files\":{},\"errors\":[]}'",
              ]))
          elif path.name == "security-php.yaml" and name == "Run composer audit":
              out.extend(emit_shim(indent, "Run composer audit", "composer audit", [
                  "echo 'Stubbing composer audit under act'",
                  "printf '[]' > composer-audit.json",
              ]))

          # C: stub cppcheck installation (apt-get fails in catthehacker image).
          # The stub binary writes minimal valid XML to stderr (cppcheck's output channel).
          elif path.name == "security-c.yaml" and name == "Install Cppcheck":
              out.extend(emit_stub_binary(indent, "Install Cppcheck", "cppcheck",
                  "${HOME}/.local/bin", [
                  "#!/bin/sh",
                  "# Ignore all args; write empty cppcheck XML to stderr (cppcheck's output channel)",
                  "printf '<?xml version=\"1.0\" encoding=\"UTF-8\"?>\\n<results version=\"2\">\\n  <cppcheck version=\"2.16\"/>\\n  <errors/>\\n</results>\\n' >&2",
              ]))

          # PowerShell: replace the pwsh step with a bash step that emits empty SARIF.
          elif path.name == "security-powershell.yaml" and name == "Run PSScriptAnalyzer":
              out.extend(emit_sarif_stub(indent, "Run PSScriptAnalyzer", "powershell.sarif", "PSScriptAnalyzer"))

          # GitHub Actions: stub marketplace-backed tool installs for act.
          elif path.name == "security-github-actions.yaml" and name == "Install zizmor":
              out.extend(emit_stub_binary(indent, "Install zizmor", "zizmor",
                  "${HOME}/.local/bin", [
                  "#!/bin/sh",
                  "printf '{\"version\":\"2.1.0\",\"runs\":[{\"tool\":{\"driver\":{\"name\":\"zizmor\"}},\"results\":[]}]}'",
              ]))
          elif path.name == "security-github-actions.yaml" and name == "Install poutine":
              out.extend(emit_stub_binary(indent, "Install poutine", "poutine",
                  "${HOME}/.local/bin", [
                  "#!/bin/sh",
                  "printf '{\"version\":\"2.1.0\",\"runs\":[{\"tool\":{\"driver\":{\"name\":\"poutine\"}},\"results\":[]}]}'",
              ]))
          elif path.name == "security-github-actions.yaml" and name == "Install actionlint":
              out.extend(emit_stub_binary(indent, "Install actionlint", "actionlint",
                  "${HOME}/.local/bin", [
                  "#!/bin/sh",
                  "# No findings under act; emit an empty JSON stream.",
                  "exit 0",
              ]))

          elif matched:
              commands = ["true"]
              if matched == "actions/setup-python":
                  commands = [
                      'ACT_PYTHON_DIR="${RUNNER_TEMP:-/tmp}/act-python"',
                      'if [ ! -x "$ACT_PYTHON_DIR/bin/python" ]; then python3 -m venv "$ACT_PYTHON_DIR"; fi',
                      'printf \'%s\\n\' "$ACT_PYTHON_DIR/bin" >> "$GITHUB_PATH"',
                      '"$ACT_PYTHON_DIR/bin/python" --version',
                  ]
              elif matched == "actions/setup-node":
                  commands = [
                      'node --version',
                      'npm --version',
                  ]
              elif matched == "actions/setup-java":
                  commands = ['echo "Java setup is stubbed because PMD is stubbed under act"']
              elif matched == "actions/setup-dotnet":
                  channel = dotnet_channel(block_text)
                  commands = [
                      'ACT_DOTNET_DIR="${RUNNER_TEMP:-/tmp}/act-dotnet"',
                      f'ACT_DOTNET_CHANNEL="$(printf \'%s\' "{channel}" | sed \'s/\\.x$//\')"',
                      'if [ ! -x "$ACT_DOTNET_DIR/dotnet" ]; then curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh && bash /tmp/dotnet-install.sh --channel "$ACT_DOTNET_CHANNEL" --install-dir "$ACT_DOTNET_DIR"; fi',
                      'printf \'%s\\n\' "$ACT_DOTNET_DIR" >> "$GITHUB_PATH"',
                      'printf \'DOTNET_ROOT=%s\\n\' "$ACT_DOTNET_DIR" >> "$GITHUB_ENV"',
                      '"$ACT_DOTNET_DIR/dotnet" --info',
                  ]
              elif matched == "actions/setup-go":
                  # Go tools (gosec, govulncheck) are stubbed per-step above; Go itself is not needed.
                  commands = ['echo "Go toolchain not required under act — scanners are stubbed"']
              elif matched == "dtolnay/rust-toolchain":
                  # Create lightweight cargo + cargo-audit stubs so no Rust installation is needed.
                  commands = [
                      'echo "Creating cargo stub for act"',
                      'mkdir -p "${HOME}/.cargo/bin"',
                      "cat > \"${HOME}/.cargo/bin/cargo-audit\" <<'CARGOAUDITEOF'",
                      '#!/bin/sh',
                      'printf \'{"vulnerabilities":{"list":[]},"warnings":{}}\''  ,
                      'CARGOAUDITEOF',
                      'chmod +x "${HOME}/.cargo/bin/cargo-audit"',
                      "cat > \"${HOME}/.cargo/bin/cargo\" <<'CARGOEOF'",
                      '#!/bin/sh',
                      'cmd="$1"; shift',
                      'case "$cmd" in',
                      '  install) exit 0 ;;',
                      '  audit)   "${HOME}/.cargo/bin/cargo-audit" "$@" ;;',
                      '  clippy)  exit 0 ;;',
                      '  *)       exit 0 ;;',
                      'esac',
                      'CARGOEOF',
                      'chmod +x "${HOME}/.cargo/bin/cargo"',
                      'printf \'%s\\n\' "${HOME}/.cargo/bin" >> "$GITHUB_PATH"',
                      'export PATH="${HOME}/.cargo/bin:$PATH"',
                      'echo "cargo stub installed"',
                  ]
              elif matched == "ruby/setup-ruby":
                  # Ruby tools (rubocop, bundler-audit, brakeman) are stubbed per-step above.
                  commands = ['echo "Ruby toolchain not required under act — tools are stubbed"']
              elif matched == "dominikh/staticcheck-action":
                  # Emit empty staticcheck SARIF (staticcheck is disabled in the go test but shim for completeness).
                  commands = [
                      "cat > staticcheck.sarif <<'SARIFEOF'",
                      '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"staticcheck"}},"results":[]}]}',
                      "SARIFEOF",
                  ]
              out.extend(emit_shim(indent, name, matched, commands))
          else:
              for blk_line in block:
                  blk_stripped = blk_line.lstrip()
                  if blk_stripped.startswith("run: ") and not blk_stripped.startswith("run: |"):
                      blk_indent = blk_line[: len(blk_line) - len(blk_stripped)]
                      command = blk_stripped[len("run: "):].rstrip("\n")
                      out.append(f"{blk_indent}run: |\n")
                      out.append(f"{blk_indent}  {command}\n")
                  else:
                      out.append(blk_line)
      else:
          if path.name == "_orchestrator-ci.yaml" and stripped.startswith("general:") and line.startswith("  "):
              out.append("  general:\n")
              out.append("    runs-on: ubuntu-24.04\n")
              out.append("    steps:\n")
              out.append("      - name: Skip general reusable workflow under act\n")
              out.append("        run: echo \"Skipping general reusable workflow under act\"\n")
              i += 1
              while i < len(lines):
                  nxt = lines[i]
                  nxt_stripped = nxt.lstrip()
                  nxt_indent = nxt[: len(nxt) - len(nxt_stripped)]
                  if nxt_indent == "  " and nxt_stripped and not nxt_stripped.startswith("#") and nxt_stripped.endswith(":\n"):
                      break
                  i += 1
              continue
          out.append(line)
          i += 1

    path.write_text("".join(out))
PY
}

disable_general_job_for_act() {
  local dir="$1"
  # Optional second argument: path to the workflow file (relative to $dir).
  # Defaults to _orchestrator-ci.yaml for backward compatibility.  Combo tests
  # that invoke the orchestrator via the reusable workflow should pass
  # orchestrator-reusable.yaml, which is where the general: job actually lives.
  local wf_file="${2:-.github/workflows/_orchestrator-ci.yaml}"

  "$PYTHON_BIN" - "$dir/$wf_file" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text().splitlines(keepends=True)
out = []
i = 0

while i < len(lines):
    line = lines[i]
    if line == "  general:\n":
        out.extend([
            "  general:\n",
            "    runs-on: ubuntu-24.04\n",
            "    steps:\n",
            "      - name: Skip general reusable workflow under act\n",
            "        run: echo \"Skipping general reusable workflow under act\"\n",
        ])
        i += 1
        while i < len(lines):
            nxt = lines[i]
            if nxt.startswith("  ") and not nxt.startswith("    ") and nxt.strip().endswith(":") and nxt.strip() != "general:":
                break
            i += 1
        continue
    out.append(line)
    i += 1

path.write_text("".join(out))
PY
}

# ── Fixture staging helpers ──────────────────────────────────────────────────

copy_fixture() {
  local dir="$1"
  local fixture_id="$2"
  local fixture_path="$FIXTURE_ROOT/$fixture_id"

  [ -d "$fixture_path" ] || {
    echo "missing fixture directory: $fixture_id" >&2
    return 1
  }

  cp -R "$fixture_path/." "$dir/"
}

copy_fixture_set() {
  local dir="$1"
  shift

  local fixture_id
  for fixture_id in "$@"; do
    copy_fixture "$dir" "$fixture_id" || return 1
  done
}

fixture_expected_paths() {
  local fixture_id="$1"

  "$PYTHON_BIN" - "$FIXTURE_MANIFEST" "$fixture_id" <<'PY'
import json
import sys

manifest_path = sys.argv[1]
fixture_id = sys.argv[2]

with open(manifest_path, "r", encoding="utf-8") as handle:
    manifest = json.load(handle)

for entry in manifest.get("fixtures", []):
    if entry.get("id") == fixture_id:
        for path in entry.get("expected_paths", []):
            print(path)
        break
else:
    raise SystemExit(f"fixture not found in manifest: {fixture_id}")
PY
}

assert_fixture_paths_exist() {
  local dir="$1"
  shift

  local fixture_id path
  for fixture_id in "$@"; do
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      [ -e "$dir/$path" ] || {
        echo "fixture $fixture_id missing expected path: $path" >&2
        return 1
      }
    done < <(fixture_expected_paths "$fixture_id")
  done
}

# ── Git helpers ───────────────────────────────────────────────────────────────

init_git_repo() {
  local dir="$1"
  (
    cd "$dir" || exit
    "$GIT_BIN" init -q -b main
    "$GIT_BIN" config user.name "act"
    "$GIT_BIN" config user.email "act@example.com"
    "$GIT_BIN" add .
    "$GIT_BIN" commit -qm "initial fixture"
  )
}

# ── Event writers ─────────────────────────────────────────────────────────────

write_dispatch_event() {
  local dir="$1"
  local scanners="$2"
  local disabled_tools="$3"
  local extra_inputs="${4:-}"

  cat > "$dir/.github/events/workflow_dispatch.json" <<EOF
{
  "ref": "refs/heads/main",
  "repository": {
    "default_branch": "main"
  },
  "sender": {
    "login": "act"
  },
  "inputs": {
    "scanners": "$scanners",
    "runner_labels": "",
    "disabled_tools": "$disabled_tools"${extra_inputs}
  }
}
EOF
}

# ── act runner ────────────────────────────────────────────────────────────────

run_act() {
  local dir="$1"
  shift
  local github_token="${GITHUB_TOKEN:-}"

  local args=(
    --container-architecture "$ACT_ARCH"
    -P "ubuntu-24.04=$ACT_IMAGE"
    --env ACT=true
  )

  if [ -n "$github_token" ]; then
    args+=(--secret "GITHUB_TOKEN=$github_token")
  fi

  if [ "$ACT_PULL" = "false" ]; then
    args+=(--pull=false)
  fi

  if [ "$ACT_VERBOSE" = "true" ]; then
    args+=(--verbose)
  fi

  if [ -n "$ACT_TIMEOUT" ]; then
    # Portable timeout: prefer GNU timeout/gtimeout, fall back to perl alarm().
    # macOS ships without timeout; perl is always present.
    local timeout_cmd
    if command -v timeout >/dev/null 2>&1; then
      timeout_cmd="timeout"
    elif command -v gtimeout >/dev/null 2>&1; then
      timeout_cmd="gtimeout"
    else
      timeout_cmd=""
    fi

    if [ -n "$timeout_cmd" ]; then
      (cd "$dir" || exit; "$timeout_cmd" "$ACT_TIMEOUT" "$ACT_BIN" "$@" "${args[@]}")
    else
      (cd "$dir" || exit; perl -e 'my $t = shift @ARGV; alarm $t; exec @ARGV or die "exec: $!"' \
        "$ACT_TIMEOUT" "$ACT_BIN" "$@" "${args[@]}")
    fi
  else
    (cd "$dir" || exit; "$ACT_BIN" "$@" "${args[@]}")
  fi
}

# ── Assertion helpers ─────────────────────────────────────────────────────────

assert_log_contains() {
  local logfile="$1"
  local pattern="$2"
  grep -Fq "$pattern" "$logfile"
}

assert_log_not_contains() {
  local logfile="$1"
  local pattern="$2"
  ! grep -Fq "$pattern" "$logfile"
}

# ── JUnit XML writer ──────────────────────────────────────────────────────────

write_junit() {
  local total=$((pass + fail + skip))
  local elapsed=$((SECONDS - SUITE_START))
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<testsuites>'
    echo "  <testsuite name=\"GitHub Actions AppSec Scanner — act Suite\" tests=\"$total\" failures=\"$fail\" skipped=\"$skip\" time=\"$elapsed\">"
    local tc
    for tc in "${JUNIT_CASES[@]+${JUNIT_CASES[@]}}"; do
      echo "    $tc"
    done
    echo '  </testsuite>'
    echo '</testsuites>'
  } > "$JUNIT_FILE"
}

# ── Test registration ─────────────────────────────────────────────────────────

should_run() {
  [ -z "$FILTER" ] && return 0
  [[ "$1" == *"$FILTER"* ]] && return 0
  return 1
}

# Format: "display name|function_name"
TESTS=()

# ── Fixture combination tests ─────────────────────────────────────────────────
#
# Exercises every pairwise combination of the 12 language fixtures (64 pairs —
# ruby+rails is excluded because both fixtures own Gemfile/Gemfile.lock), all
# IAC sub-type variants, all GHA fixtures together, 4 triples, and 3 large
# combos.  Each test copies the listed fixture directories into a single temp
# repo and runs the matching scanner(s), asserting SARIF validation succeeds for
# every expected tool.
#
# Implementation notes:
#   • build_repo_for_combo — generic repo builder (bypasses build_repo_for_suite)
#   • run_combo_act        — always uses || true; correctness is checked via the
#                            SARIF validation assertion, not the act exit code
#   • COMBO_SPECS          — pipe-separated data driving test generation
#   • The eval loop below  — generates one named bash function per entry and
#                            appends it to TESTS so the parallel runner can pick
#                            it up without any further changes

# Build a temp repo containing an arbitrary set of fixture directories.
# Usage: build_repo_for_combo <combo_id> <scanners> <disabled_tools> <fixture1> [fixture2 ...]
#
# act derives Docker container names by SHA-256 hashing the string:
#   "act-{caller_job_name}/{reusable_workflow_name}/{inner_job_name}"
# All three name components are static across every combo run, so all parallel
# invocations would hash to the same container name and conflict.  Fix: stamp
# the combo_id into the reusable workflow's top-level `name:` field so each
# parallel run's container names hash to a unique value.
build_repo_for_combo() {
  local combo_id="$1"
  local scanners="$2"
  local disabled_tools="$3"
  shift 3
  local dir
  dir="$(make_temp_repo)"
  normalize_for_act "$dir"
  # Combo tests run via orchestrator-reusable.yaml, so disable the general job
  # there (not in the CI entry-point wrapper which doesn't define any jobs).
  disable_general_job_for_act "$dir" ".github/workflows/orchestrator-reusable.yaml"
  # Stamp combo_id into the top-level `name:` field of every workflow file.
  # act hashes "act-{caller_job_name}/{wf_name}/{inner_job_name}" to derive
  # Docker container names.  Changing wf_name in each child workflow makes every
  # parallel combo run produce distinct hashes across all job levels.
  "$PYTHON_BIN" - "$dir/.github/workflows" "$combo_id" <<'PYEOF'
import os, re, sys
wf_dir, cid = sys.argv[1], sys.argv[2]
# Match 'name: <value>' where value may or may not be quoted.
# Strip any surrounding quotes, append combo_id, and re-quote to produce valid YAML.
pat = re.compile(r'^(name:\s*)(.+)$', re.MULTILINE)
def stamp(m):
    val = m.group(2).strip().strip('"').strip("'")
    return f'{m.group(1)}"{val} ({cid})"'
for fname in os.listdir(wf_dir):
    if not fname.endswith('.yaml'):
        continue
    fp = os.path.join(wf_dir, fname)
    text = open(fp).read()
    new_text = pat.sub(stamp, text, count=1)
    if new_text != text:
        open(fp, 'w').write(new_text)
PYEOF
  copy_fixture_set "$dir" "$@" || return 1
  assert_fixture_paths_exist "$dir" "$@" || return 1
  init_git_repo "$dir"
  write_dispatch_event "$dir" "$scanners" "$disabled_tools"
  echo "$dir"
}

# Run act for a combo test.  Always tolerates a non-zero act exit: some scanners
# (checkov, ansible-lint) produce real findings and exit non-zero.  Correctness
# is verified by asserting "Success - Main Validate X SARIF" in the log.
run_combo_act() {
  local logfile="$1"
  local dir="$2"
  shift 2
  run_act "$dir" "$@" >"$logfile" 2>&1 || true
}

# Combo spec format (five pipe-separated fields):
#   suite_id | scanners | disabled_tools | fix1:fix2:... | marker1:marker2:...
#
# • suite_id        — unique slug; becomes the test function suffix (hyphens→underscores)
# • scanners        — passed as the `scanners` workflow_dispatch input
# • disabled_tools  — passed as the `disabled_tools` input (may be empty)
# • fixtures        — colon-separated list of fixture IDs to copy into the repo
# • markers         — colon-separated "Validate X SARIF" strings; each is checked
#                     as "Success - Main <marker>" in the act log
COMBO_SPECS=(
  # ── IAC sub-type suites ───────────────────────────────────────────────────
  # dockerfile only: hadolint + checkov (checkov scans Dockerfiles)
  "iac-dockerfile|iac|ansible_lint,terraform_validate,terraform_fmt,tflint|iac/dockerfile-basic|Validate Hadolint SARIF:Validate Checkov SARIF"
  # k8s manifests: kube-linter on deployment, pluto on ingress (deprecated API)
  "iac-k8s|iac|ansible_lint,terraform_validate,terraform_fmt,tflint,hadolint|iac/k8s-basic:iac/pluto-basic|Validate KubeLinter SARIF:Validate Pluto SARIF"
  # kubescape only
  "iac-kubescape|iac|ansible_lint,terraform_validate,terraform_fmt,tflint,hadolint,pluto|iac/kubescape-basic|Validate Kubescape SARIF"
  # helm chart: checkov + kube-linter both support Helm
  "iac-helm|iac|ansible_lint,terraform_validate,terraform_fmt,tflint,hadolint|iac/helm-basic|Validate Checkov SARIF:Validate KubeLinter SARIF"
  # CloudFormation template: checkov only
  "iac-cloudformation|iac|ansible_lint,terraform_validate,terraform_fmt,tflint,hadolint,kube_linter,kubescape,pluto|iac/cloudformation-basic|Validate Checkov SARIF"
  # ansible playbook only
  "iac-ansible|iac|terraform_validate,terraform_fmt,tflint,hadolint,kube_linter,kubescape,pluto|iac/ansible-lint-basic|Validate ansible-lint SARIF"
  # all IAC types combined (kubescape-basic excluded — k8s/deployment.yaml conflicts with k8s-basic)
  "iac-all|iac||iac/checkov-basic:iac/ansible-lint-basic:iac/dockerfile-basic:iac/k8s-basic:iac/pluto-basic:iac/cloudformation-basic:iac/helm-basic|Validate Checkov SARIF:Validate ansible-lint SARIF:Validate Hadolint SARIF:Validate KubeLinter SARIF:Validate Pluto SARIF:Validate Terraform Validate SARIF:Validate TFLint SARIF"

  # ── GHA all-in-one ────────────────────────────────────────────────────────
  # actionlint, zizmor (template injection), and poutine (unpinned actions) run together
  "gha-all|gha||github-actions/actionlint-basic:github-actions/zizmor-basic:github-actions/poutine-basic|Validate actionlint SARIF:Validate zizmor SARIF:Validate poutine SARIF"

  # ── Language pairs ────────────────────────────────────────────────────────
  # python × {java, go, rust, dotnet, sql, c, php, powershell, ruby, rails}
  "python-java|python,java|pip_audit|python/bandit-basic:java/pmd-basic|Validate Bandit SARIF:Validate PMD SARIF"
  "python-go|python,go|pip_audit,staticcheck|python/bandit-basic:go/basic|Validate Bandit SARIF:Validate Gosec SARIF"
  "python-rust|python,rust|pip_audit|python/bandit-basic:rust/basic|Validate Bandit SARIF:Validate cargo-audit SARIF"
  "python-dotnet|python,dotnet|pip_audit|python/bandit-basic:dotnet/basic|Validate Bandit SARIF:Validate .NET SARIF"
  "python-sql|python,sql|pip_audit|python/bandit-basic:sql/basic|Validate Bandit SARIF:Validate SQLFluff SARIF"
  "python-c|python,c|pip_audit,semgrep_c|python/bandit-basic:c/basic|Validate Bandit SARIF:Validate Flawfinder SARIF"
  "python-php|python,php|pip_audit|python/bandit-basic:php/basic|Validate Bandit SARIF:Validate PHPStan SARIF"
  "python-powershell|python,powershell|pip_audit|python/bandit-basic:powershell/basic|Validate Bandit SARIF:Validate PowerShell SARIF"
  "python-ruby|python,ruby|pip_audit|python/bandit-basic:ruby/basic|Validate Bandit SARIF:Validate RuboCop SARIF"
  "python-rails|python,rails|pip_audit|python/bandit-basic:rails/basic|Validate Bandit SARIF:Validate Brakeman SARIF"
  # go × {rust, java, js, dotnet, sql, c, php, powershell, ruby, rails}
  "go-rust|go,rust|staticcheck|go/basic:rust/basic|Validate Gosec SARIF:Validate cargo-audit SARIF"
  "go-java|go,java|staticcheck|go/basic:java/pmd-basic|Validate Gosec SARIF:Validate PMD SARIF"
  "go-js|go,js|staticcheck|go/basic:js/npm-basic|Validate Gosec SARIF:Validate npm-audit SARIF"
  "go-dotnet|go,dotnet|staticcheck|go/basic:dotnet/basic|Validate Gosec SARIF:Validate .NET SARIF"
  "go-sql|go,sql|staticcheck|go/basic:sql/basic|Validate Gosec SARIF:Validate SQLFluff SARIF"
  "go-c|go,c|staticcheck,semgrep_c|go/basic:c/basic|Validate Gosec SARIF:Validate Flawfinder SARIF"
  "go-php|go,php|staticcheck|go/basic:php/basic|Validate Gosec SARIF:Validate PHPStan SARIF"
  "go-powershell|go,powershell|staticcheck|go/basic:powershell/basic|Validate Gosec SARIF:Validate PowerShell SARIF"
  "go-ruby|go,ruby|staticcheck|go/basic:ruby/basic|Validate Gosec SARIF:Validate RuboCop SARIF"
  "go-rails|go,rails|staticcheck|go/basic:rails/basic|Validate Gosec SARIF:Validate Brakeman SARIF"
  # rust × {java, js, dotnet, sql, c, php, powershell, ruby, rails}
  "rust-java|rust,java||rust/basic:java/pmd-basic|Validate cargo-audit SARIF:Validate PMD SARIF"
  "rust-js|rust,js||rust/basic:js/npm-basic|Validate cargo-audit SARIF:Validate npm-audit SARIF"
  "rust-dotnet|rust,dotnet||rust/basic:dotnet/basic|Validate cargo-audit SARIF:Validate .NET SARIF"
  "rust-sql|rust,sql||rust/basic:sql/basic|Validate cargo-audit SARIF:Validate SQLFluff SARIF"
  "rust-c|rust,c|semgrep_c|rust/basic:c/basic|Validate cargo-audit SARIF:Validate Flawfinder SARIF"
  "rust-php|rust,php||rust/basic:php/basic|Validate cargo-audit SARIF:Validate PHPStan SARIF"
  "rust-powershell|rust,powershell||rust/basic:powershell/basic|Validate cargo-audit SARIF:Validate PowerShell SARIF"
  "rust-ruby|rust,ruby||rust/basic:ruby/basic|Validate cargo-audit SARIF:Validate RuboCop SARIF"
  "rust-rails|rust,rails||rust/basic:rails/basic|Validate cargo-audit SARIF:Validate Brakeman SARIF"
  # java × {js, dotnet, sql, c, php, powershell, ruby, rails}
  "java-js|java,js||java/pmd-basic:js/npm-basic|Validate PMD SARIF:Validate npm-audit SARIF"
  "java-dotnet|java,dotnet||java/pmd-basic:dotnet/basic|Validate PMD SARIF:Validate .NET SARIF"
  "java-sql|java,sql||java/pmd-basic:sql/basic|Validate PMD SARIF:Validate SQLFluff SARIF"
  "java-c|java,c|semgrep_c|java/pmd-basic:c/basic|Validate PMD SARIF:Validate Flawfinder SARIF"
  "java-php|java,php||java/pmd-basic:php/basic|Validate PMD SARIF:Validate PHPStan SARIF"
  "java-powershell|java,powershell||java/pmd-basic:powershell/basic|Validate PMD SARIF:Validate PowerShell SARIF"
  "java-ruby|java,ruby||java/pmd-basic:ruby/basic|Validate PMD SARIF:Validate RuboCop SARIF"
  "java-rails|java,rails||java/pmd-basic:rails/basic|Validate PMD SARIF:Validate Brakeman SARIF"
  # js × {dotnet, sql, c, php, powershell, ruby, rails}
  "js-dotnet|js,dotnet||js/npm-basic:dotnet/basic|Validate npm-audit SARIF:Validate .NET SARIF"
  "js-sql|js,sql||js/npm-basic:sql/basic|Validate npm-audit SARIF:Validate SQLFluff SARIF"
  "js-c|js,c|semgrep_c|js/npm-basic:c/basic|Validate npm-audit SARIF:Validate Flawfinder SARIF"
  "js-php|js,php||js/npm-basic:php/basic|Validate npm-audit SARIF:Validate PHPStan SARIF"
  "js-powershell|js,powershell||js/npm-basic:powershell/basic|Validate npm-audit SARIF:Validate PowerShell SARIF"
  "js-ruby|js,ruby||js/npm-basic:ruby/basic|Validate npm-audit SARIF:Validate RuboCop SARIF"
  "js-rails|js,rails||js/npm-basic:rails/basic|Validate npm-audit SARIF:Validate Brakeman SARIF"
  # dotnet × {sql, c, php, powershell, ruby, rails}
  "dotnet-sql|dotnet,sql||dotnet/basic:sql/basic|Validate .NET SARIF:Validate SQLFluff SARIF"
  "dotnet-c|dotnet,c|semgrep_c|dotnet/basic:c/basic|Validate .NET SARIF:Validate Flawfinder SARIF"
  "dotnet-php|dotnet,php||dotnet/basic:php/basic|Validate .NET SARIF:Validate PHPStan SARIF"
  "dotnet-powershell|dotnet,powershell||dotnet/basic:powershell/basic|Validate .NET SARIF:Validate PowerShell SARIF"
  "dotnet-ruby|dotnet,ruby||dotnet/basic:ruby/basic|Validate .NET SARIF:Validate RuboCop SARIF"
  "dotnet-rails|dotnet,rails||dotnet/basic:rails/basic|Validate .NET SARIF:Validate Brakeman SARIF"
  # sql × {c, php, powershell, ruby, rails}
  "sql-c|sql,c|semgrep_c|sql/basic:c/basic|Validate SQLFluff SARIF:Validate Flawfinder SARIF"
  "sql-php|sql,php||sql/basic:php/basic|Validate SQLFluff SARIF:Validate PHPStan SARIF"
  "sql-powershell|sql,powershell||sql/basic:powershell/basic|Validate SQLFluff SARIF:Validate PowerShell SARIF"
  "sql-ruby|sql,ruby||sql/basic:ruby/basic|Validate SQLFluff SARIF:Validate RuboCop SARIF"
  "sql-rails|sql,rails||sql/basic:rails/basic|Validate SQLFluff SARIF:Validate Brakeman SARIF"
  # c × {php, powershell, ruby, rails}
  "c-php|c,php|semgrep_c|c/basic:php/basic|Validate Flawfinder SARIF:Validate PHPStan SARIF"
  "c-powershell|c,powershell|semgrep_c|c/basic:powershell/basic|Validate Flawfinder SARIF:Validate PowerShell SARIF"
  "c-ruby|c,ruby|semgrep_c|c/basic:ruby/basic|Validate Flawfinder SARIF:Validate RuboCop SARIF"
  "c-rails|c,rails|semgrep_c|c/basic:rails/basic|Validate Flawfinder SARIF:Validate Brakeman SARIF"
  # php × {powershell, ruby, rails}
  "php-powershell|php,powershell||php/basic:powershell/basic|Validate PHPStan SARIF:Validate PowerShell SARIF"
  "php-ruby|php,ruby||php/basic:ruby/basic|Validate PHPStan SARIF:Validate RuboCop SARIF"
  "php-rails|php,rails||php/basic:rails/basic|Validate PHPStan SARIF:Validate Brakeman SARIF"
  # powershell × {ruby, rails}
  "powershell-ruby|powershell,ruby||powershell/basic:ruby/basic|Validate PowerShell SARIF:Validate RuboCop SARIF"
  "powershell-rails|powershell,rails||powershell/basic:rails/basic|Validate PowerShell SARIF:Validate Brakeman SARIF"
  # ruby+rails excluded — both own Gemfile/Gemfile.lock (path conflict)

  # ── Triples ───────────────────────────────────────────────────────────────
  "python-go-rust|python,go,rust|pip_audit,staticcheck|python/bandit-basic:go/basic:rust/basic|Validate Bandit SARIF:Validate Gosec SARIF:Validate cargo-audit SARIF"
  "java-js-dotnet|java,js,dotnet||java/pmd-basic:js/npm-basic:dotnet/basic|Validate PMD SARIF:Validate npm-audit SARIF:Validate .NET SARIF"
  "c-sql-powershell|c,sql,powershell|semgrep_c|c/basic:sql/basic:powershell/basic|Validate Flawfinder SARIF:Validate SQLFluff SARIF:Validate PowerShell SARIF"
  # ruby+php+c — all non-conflicting web/systems trio
  "ruby-php-c|ruby,php,c|semgrep_c|ruby/basic:php/basic:c/basic|Validate RuboCop SARIF:Validate PHPStan SARIF:Validate Flawfinder SARIF"

  # ── Large combos ──────────────────────────────────────────────────────────
  # web-stack: the four most common web-app languages
  "web-stack|python,js,java,dotnet|pip_audit|python/bandit-basic:js/npm-basic:java/pmd-basic:dotnet/basic|Validate Bandit SARIF:Validate npm-audit SARIF:Validate PMD SARIF:Validate .NET SARIF"
  # systems-stack: the three systems/native languages
  "systems-stack|go,rust,c|staticcheck,semgrep_c|go/basic:rust/basic:c/basic|Validate Gosec SARIF:Validate cargo-audit SARIF:Validate Flawfinder SARIF"
  # all-languages: every scanner type in one run (ruby excluded to avoid rails Gemfile conflict;
  # ruby scanner still runs because rails/basic contains .rb files)
  "all-languages|all|pip_audit,staticcheck,semgrep_c,zizmor,poutine|python/bandit-basic:java/pmd-basic:js/npm-basic:dotnet/basic:sql/basic:go/basic:rust/basic:c/basic:php/basic:powershell/basic:rails/basic:github-actions/actionlint-basic:iac/checkov-basic:iac/ansible-lint-basic|Validate Bandit SARIF:Validate PMD SARIF:Validate npm-audit SARIF:Validate .NET SARIF:Validate SQLFluff SARIF:Validate Gosec SARIF:Validate cargo-audit SARIF:Validate Flawfinder SARIF:Validate PHPStan SARIF:Validate PowerShell SARIF:Validate Brakeman SARIF:Validate actionlint SARIF:Validate Checkov SARIF:Validate ansible-lint SARIF"
)

# Run the combo test identified by suite_id, looked up in COMBO_SPECS.
run_combo_test() {
  local target_id="$1"
  local spec found_spec=""
  for spec in "${COMBO_SPECS[@]}"; do
    if [[ "$spec" == "${target_id}|"* ]]; then
      found_spec="$spec"
      break
    fi
  done
  [ -n "$found_spec" ] || { echo "unknown combo: $target_id" >&2; return 1; }

  local _id scanners disabled_tools fixtures_csv markers_csv
  IFS='|' read -r _id scanners disabled_tools fixtures_csv markers_csv <<< "$found_spec"

  local -a fixtures markers
  IFS=':' read -ra fixtures <<< "$fixtures_csv"
  IFS=':' read -ra markers <<< "$markers_csv"

  local dir logfile
  dir="$(build_repo_for_combo "$target_id" "$scanners" "$disabled_tools" "${fixtures[@]}")" || return 1
  logfile="$(make_log_file "combo-${target_id}")"

  run_combo_act "$logfile" "$dir" \
    workflow_dispatch -W .github/workflows/_orchestrator-ci.yaml \
    -e .github/events/workflow_dispatch.json

  local marker
  for marker in "${markers[@]}"; do
    assert_log_contains "$logfile" "Success - Main $marker" || return 1
  done
}

# Dynamically generate one bash function per combo and append it to TESTS.
# shellcheck disable=SC2116,SC2294
for _cspec in "${COMBO_SPECS[@]}"; do
  _cid="${_cspec%%|*}"
  _cfunc="test_combo_${_cid//-/_}"
  eval "$( echo "${_cfunc}() { run_combo_test '${_cid}'; }" )"
  TESTS+=("fixture combo ${_cid//-/ }|${_cfunc}")
done
unset _cspec _cid _cfunc

test_disable_tools_skips_scanner_steps() {
  local dir logfile
  dir="$(build_repo_for_combo "disable-tools" "python,java" "pmd" "python/bandit-basic" "java/pmd-basic")" || return 1
  logfile="$(make_log_file "combo-disable-tools")"

  run_combo_act "$logfile" "$dir" \
    workflow_dispatch -W .github/workflows/_orchestrator-ci.yaml \
    -e .github/events/workflow_dispatch.json

  assert_log_contains "$logfile" "Tool Disabled::PMD is disabled" || return 1
  assert_log_contains "$logfile" "Success - Main Validate Bandit SARIF" || return 1
  assert_log_not_contains "$logfile" "Success - Main Validate PMD SARIF" || return 1
}
TESTS+=("fixture combo disable tools skips requested scanners|test_disable_tools_skips_scanner_steps")

run_internal_test_mode() {
  local start elapsed status output exit_code

  start=$SECONDS
  if output=$("$ACT_INTERNAL_TEST_FUNC" 2>&1); then
    status="PASS"
    exit_code=0
  else
    status="FAIL"
    exit_code=1
    preserve_tmp_on_failure
  fi
  elapsed=$((SECONDS - start))

  printf 'status=%s\nelapsed=%s\n' "$status" "$elapsed" > "$ACT_INTERNAL_RESULT_FILE"
  if [ -n "$output" ]; then
    printf '%s\n' "$output"
  fi

  exit "$exit_code"
}

record_parallel_result() {
  local name="$1"
  local logfile="$2"
  local resultfile="$3"
  local wait_status="$4"
  local status elapsed output

  status=""
  elapsed=0
  # shellcheck disable=SC1090
  [ -f "$resultfile" ] && . "$resultfile"

  printf "%-65s" "$name"
  if [ "$wait_status" -eq 0 ] && [ "$status" = "PASS" ]; then
    echo "PASS (${elapsed}s)"
    pass=$((pass + 1))
    if [ -n "$JUNIT_FILE" ]; then
      JUNIT_CASES+=("<testcase name=\"$(xml_escape "$name")\" time=\"$elapsed\"/>")
    fi
    return 0
  fi

  echo "FAIL (${elapsed}s)"
  if [ -s "$logfile" ]; then
    sed 's/^/  /' "$logfile"
    output="$(cat "$logfile")"
  else
    output="parallel child exited with status $wait_status"
  fi
  fail=$((fail + 1))
  preserve_tmp_on_failure
  if [ -n "$JUNIT_FILE" ]; then
    JUNIT_CASES+=("<testcase name=\"$(xml_escape "$name")\" time=\"$elapsed\"><failure message=\"FAIL\">$(xml_escape "$output")</failure></testcase>")
  fi
  return 1
}

run_parallel_batch() {
  local batch_failed i pid wait_status name func logfile resultfile entry
  local -a pids=()
  local -a names=()
  local -a logfiles=()
  local -a resultfiles=()

  batch_failed=false
  for entry in "$@"; do
    name="${entry%%|*}"
    func="${entry##*|}"
    logfile="$(make_log_file "$name")"
    resultfile="$(make_result_file "$name")"
    ACT_INTERNAL_TEST_FUNC="$func" \
    ACT_INTERNAL_TEST_NAME="$name" \
    ACT_INTERNAL_RESULT_FILE="$resultfile" \
    ACT_BIN="$ACT_BIN" \
    DOCKER_BIN="$DOCKER_BIN" \
    GIT_BIN="$GIT_BIN" \
    PYTHON_BIN="$PYTHON_BIN" \
    ACT_IMAGE="$ACT_IMAGE" \
    ACT_ARCH="$ACT_ARCH" \
    ACT_PULL="$ACT_PULL" \
    ACT_VERBOSE="$ACT_VERBOSE" \
    ACT_TIMEOUT="$ACT_TIMEOUT" \
    KEEP_TMP="$KEEP_TMP" \
    KEEP_TMP_ON_FAIL="$KEEP_TMP_ON_FAIL" \
    LOG_DIR="$LOG_DIR" \
    "$REPO_ROOT/tests/test-fixtures.sh" >"$logfile" 2>&1 &
    pids+=("$!")
    names+=("$name")
    logfiles+=("$logfile")
    resultfiles+=("$resultfile")
  done

  for i in "${!pids[@]}"; do
    pid="${pids[$i]}"
    wait_status=0
    wait "$pid" || wait_status=$?
    record_parallel_result "${names[$i]}" "${logfiles[$i]}" "${resultfiles[$i]}" "$wait_status" || batch_failed=true
  done

  [ "$batch_failed" = false ]
}

run_all_selected_tests() {
  local -a batch_entries=()
  local entry name func fail_before

  if [ "$JOBS" -le 1 ]; then
    for entry in "$@"; do
      name="${entry%%|*}"
      func="${entry##*|}"
      fail_before=$fail
      run_test "$name" "$func"
      if [ "$FAIL_FAST" = "true" ] && [ "$fail" -gt "$fail_before" ]; then
        return 1
      fi
    done
    return 0
  fi

  for entry in "$@"; do
    batch_entries+=("$entry")
    if [ "${#batch_entries[@]}" -lt "$JOBS" ]; then
      continue
    fi

    run_parallel_batch "${batch_entries[@]}" || {
      [ "$FAIL_FAST" = "true" ] && return 1
    }
    batch_entries=()
  done

  if [ "${#batch_entries[@]}" -gt 0 ]; then
    run_parallel_batch "${batch_entries[@]}" || {
      [ "$FAIL_FAST" = "true" ] && return 1
    }
  fi
}

if [ -n "$ACT_INTERNAL_TEST_FUNC" ]; then
  run_internal_test_mode
fi

# ── List mode ─────────────────────────────────────────────────────────────────

if [ "$LIST_TESTS" = "true" ]; then
  echo "act, docker, git, and python3 are available"
  for entry in "${TESTS[@]}"; do
    echo "${entry%%|*}"
  done
  exit 0
fi

# ── Main runner ───────────────────────────────────────────────────────────────

echo "=================================================="
echo " GitHub Actions AppSec Scanner — Fixture Combos"
echo "=================================================="
echo

echo "--- Prerequisites ---"
if require_runtime_prereqs; then
  run_test "act, docker, git, and python3 are available" true
else
  skip_test "act, docker, git, and python3 are available" "$PREREQ_REASON"
fi

echo
echo "--- Fixture Combination Tests ---"
SELECTED_TESTS=()
for entry in "${TESTS[@]}"; do
  name="${entry%%|*}"
  should_run "$name" || continue
  SELECTED_TESTS+=("$entry")
done

if [ -n "$PREREQ_REASON" ]; then
  for entry in "${SELECTED_TESTS[@]}"; do
    name="${entry%%|*}"
    skip_test "$name" "$PREREQ_REASON"
  done
else
  run_all_selected_tests "${SELECTED_TESTS[@]}"
fi

echo
echo "=================================================="
echo " Results: $pass passed, $fail failed, $skip skipped"
echo "=================================================="

if [ -n "$JUNIT_FILE" ]; then
  write_junit
  echo " JUnit XML written to: $JUNIT_FILE"
fi

exit "$fail"
