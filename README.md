# GitHub Actions AppSec Scanner (GAAS)

Auto-detects any & all code types in a given repo, scans, and reports. Supports both programming languages and infrastructure as code (IaC).

Includes a custom **GitHub Actions workflow exploit guard** that checks for 50+ security exploits and anti-patterns in GitHub Actions YAMLs that other scanners don't search for. If it finds any issues it will report the "why" behind the error and suggest / require a fix
 [link](.github/actions/exploit-guards/github-actions-workflow-exploit-guards.sh). Simple, strong, wide-coverage.

## Contents

- [How to Use](#how-to-use)
- [Permissions](#permissions)
- [Trust Model](#trust-model)
- [Language-Specific Tools](#language-specific-tools)
- [Infrastructure as Code (IaC) Tools](#infrastructure-as-code-iac-tools)
- [Tool Descriptions](#tool-descriptions)
- [Testing](#testing)
- [ToDo](#todo)

## How to Use

- `./.github/workflows/orchestrator-reusable.yaml`
  The GitHub Actions reusable workflow or high-level API. It runs language detection, fans out into the child workflows, and aggregates the final report.

Supported inputs for `orchestrator-reusable.yaml`:

| Input | Type | Default | Purpose |
|---|---|---|---|
| `pr_base_sha` | string | empty | Base commit for PR-aware diff mode. |
| `pr_head_sha` | string | empty | Head commit for PR-aware diff mode. |
| `runner_labels` | string | `"ubuntu-24.04"` | JSON-quoted GitHub-hosted runner image label for child workflows (e.g., `"ubuntu-24.04"`). |
| `scanners` | string | `all` | Comma-separated language scanners to enable, or `all`. Valid values: `go`, `rust`, `rails`, `sql`, `powershell`, `dotnet`, `iac`, `python`, `js`, `java`, `c`, `php`, `ruby`, `gha`. |
| `disabled_tools` | string | empty | Comma-separated tool IDs to disable for this run. |
| `enable_report` | boolean | `true` | Generate the aggregate SARIF summary and workflow summary. |
| `enable_pr_comment` | boolean | `false` | Post or update the PR summary comment when PR context exists. |
| `enable_code_scanning_upload` | boolean | `false` | Upload merged SARIF to GitHub Code Scanning. Requires `security-events: write`. |

Supported secrets:

| Secret | Required | Purpose |
|---|---|---|
| `SEMGREP_APP_TOKEN` | No | Enables Semgrep App/Pro rules instead of community-only mode. |

Execution modes:

- PR-aware mode: pass `pr_base_sha` and `pr_head_sha` to scan only changes detected from the diff.
- Full-scan mode: omit the SHAs to let the orchestrator enable the selected scanners across the full repository.

See the [examples/](examples/) directory for ready-to-use caller workflows.

PR-aware example:

```yaml
name: AppSec
on:
  pull_request:

permissions:
  contents: read
  pull-requests: write

jobs:
  scan:
    uses: your-org/github-actions-appsec-scanner/.github/workflows/orchestrator-reusable.yaml@main  # replace with a pinned SHA
    secrets:
      SEMGREP_APP_TOKEN: ${{ secrets.SEMGREP_APP_TOKEN }}
    with:
      pr_base_sha: ${{ github.event.pull_request.base.sha }}
      pr_head_sha: ${{ github.event.pull_request.head.sha }}
      enable_pr_comment: true
```

Full-scan example:

```yaml
name: AppSec Full Scan
on:
  workflow_dispatch:

permissions:
  contents: read

jobs:
  scan:
    uses: your-org/github-actions-appsec-scanner/.github/workflows/orchestrator-reusable.yaml@main  # replace with a pinned SHA
    with:
      scanners: all
      disabled_tools: syft
```

If you need fine-grained control, you can still call the child workflows such as `security-php.yaml` or `_security-general.yaml` directly.

[↑ top](#github-actions-appsec-scanner-gaas)

## Permissions

Minimum caller permissions for `orchestrator-reusable.yaml`:

| Permission | Required | Purpose |
|---|---|---|
| `contents: read` | Always | Read source code for scanning |
| `pull-requests: write` | If `enable_pr_comment: true` | Post or update PR summary comment |
| `security-events: write` | If `enable_code_scanning_upload: true` | Upload findings to GitHub Code Scanning |

If you do not need PR comments or Code Scanning, only `contents: read` is required.

### Least-privilege recommendation: split caller workflows

GitHub Actions does not support conditional `permissions:` blocks, so a single workflow
covering all event types would grant every job the union of all write scopes — even on
events where they are unused. To enforce least privilege, this project uses **separate
caller workflows per event type**:

| Workflow | Triggers | Permissions | Template |
|---|---|---|---|
| PR scanning | `pull_request` | `contents: read` + `pull-requests: write` | `_orchestrator-pr.yaml` |
| CI scanning | `push`, `schedule`, `workflow_dispatch` | `contents: read` + `security-events: write` | `_orchestrator-ci.yaml` |

This ensures each workflow's GITHUB_TOKEN carries only the permissions its event type
actually exercises.

See [`examples/gaas-pr.yaml`](examples/gaas-pr.yaml) and
[`examples/gaas-full-scan.yaml`](examples/gaas-full-scan.yaml) for ready-to-use examples.

This scanner uses GitHub-hosted runners exclusively. Fork PRs are automatically
forced to `ubuntu-24.04` as a defense-in-depth measure.

One important nuance from the research: I would not weaken the current `workflow_run` ban. Older GitHub Security Lab guidance proposed `pull_request -> workflow_run` as a safer split, but newer research and CodeQL rules now document artifact poisoning, env-file injection, and other `workflow_run` abuse paths. The blanket ban here is stricter than the older guidance and still defensible.

[↑ top](#github-actions-appsec-scanner-gaas)

## Trust Model

This scanner framework operates under three trust contexts:

| Context | Trust Level | Runner | Permissions |
|---|---|---|---|
| Fork PRs | Untrusted | Forced to `ubuntu-24.04` | `contents: read` only; no PR comments |
| Internal PRs | Trusted | Configurable GitHub-hosted image | `contents: read` + `pull-requests: write` for report |
| Manual dispatch | Trusted | Configurable GitHub-hosted image | `contents: read` |

Fork PRs are forced to `ubuntu-24.04` as defense-in-depth to prevent untrusted code
from influencing runner image selection. PR commenting is also disabled for fork PRs
to prevent the `pull-requests: write` token from being accessible in the untrusted
execution context. This project supports GitHub-hosted Linux runners only
(`ubuntu-22.04`, `ubuntu-24.04`, `ubuntu-latest`).

[↑ top](#github-actions-appsec-scanner-gaas)

## Language-Specific Tools

| Language | Tools |
|---|---|
| All Languages | Semgrep (SAST), Trivy (SCA), Grype (SCA), TruffleHog (secrets), Gitleaks (secrets), Dependency Review (SCA), License-scan (Trivy), Syft (CycloneDX/SPDX SBOM) |
| .NET | dotnet audit |
| C | flawfinder, cppcheck, semgrep (C secrets) |
| Go | gosec, staticcheck, govulncheck |
| Java | PMD |
| JavaScript/TypeScript | npm audit |
| PHP | phpstan, composer audit |
| PowerShell | PSScriptAnalyzer |
| Python | bandit, pip-audit |
| Rails | brakeman |
| Ruby | rubocop, bundler-audit |
| Rust | cargo-audit, clippy |
| SQL | sqlfluff, tsqllint |

[↑ top](#github-actions-appsec-scanner-gaas)

## Infrastructure as Code (IaC) Tools

| IaC | Tools |
|---|---|
| Ansible | ansible-lint, hadolint, trufflehog |
| CloudFormation | checkov, Trivy, trufflehog |
| Dockerfile | checkov, Trivy, trufflehog |
| GitHub Actions | actionlint, zizmor, poutine, exploit-guards |
| Helm | checkov, Trivy, trufflehog |
| Kubernetes | checkov, kube-linter, kubescape, pluto, Trivy, trufflehog |
| Terraform | checkov, terraform validate, terraform fmt, tflint, Trivy, trufflehog |

[↑ top](#github-actions-appsec-scanner-gaas)

## Tool Descriptions

| Tool | Description |
|---|---|
| actionlint | Lints GitHub Actions workflow files for syntax errors, type mismatches, and insecure patterns. |
| poutine | Detects supply-chain vulnerabilities and injection risks in GitHub Actions workflows, including unpinned action references, dangerous use of user-controlled expressions, and actions sourced from forked repositories. |
| zizmor | Static security analyzer for GitHub Actions workflows. Detects expression injection, excessive GITHUB_TOKEN permissions, dangerous pull_request_target usage, unpinned action references, and actions with known CVEs. |
| ansible-lint | Checks Ansible playbooks and roles for practices that could be improved or cause issues. |
| bandit | Scans Python code for common security issues such as hardcoded passwords, SQL injection, and insecure function calls. |
| brakeman | Static analysis tool specifically designed to find security vulnerabilities in Ruby on Rails applications. |
| bundler-audit | Checks Ruby gem dependencies for known vulnerabilities and insecure sources. |
| cargo-audit | Audits Rust Cargo.lock files for crates with known security vulnerabilities. |
| checkov | Scans Infrastructure as Code files (Terraform, Docker, Kubernetes, Helm, CloudFormation) for security misconfigurations. |
| clippy | Rust linter that catches common mistakes, suggests idiomatic improvements, and flags potential correctness issues. |
| composer audit | Checks PHP Composer dependencies for known security vulnerabilities. |
| cppcheck | Static analysis tool for C code that detects bugs, undefined behavior, and dangerous coding patterns. |
| Dependency Review | GitHub-native action that checks pull requests for newly introduced dependency vulnerabilities. |
| dotnet audit | Scans .NET project dependencies for known security vulnerabilities using NuGet advisory data. |
| flawfinder | Scans C source code for potential security flaws by matching against a database of known-risky function calls. |
| Gitleaks | Detects hardcoded secrets, passwords, and API keys in source code using regex patterns and entropy analysis. Complements TruffleHog with different detection heuristics. |
| Grype | Scans filesystem dependencies for known vulnerabilities using Anchore's vulnerability database. Complementary to Trivy (different vuln DB and matchers). |
| gosec | Inspects Go source code for security issues by scanning the AST. |
| govulncheck | Checks Go dependencies against the Go vulnerability database. Only reports vulnerabilities in functions your code actually calls. |
| hadolint | Lints Dockerfiles for best practices including pinned base images, layer optimization, and shell safety. |
| kube-linter | Checks Kubernetes manifests for operational best practices like resource limits, readiness probes, and anti-affinity. |
| Kubescape | Scans Kubernetes manifests, Helm charts, and Dockerfiles against NSA-CISA, MITRE ATT&CK, and CIS benchmarks for security misconfigurations. |
| License-scan | Uses Trivy to identify dependency licenses and flags restricted (AGPL, GPL, SSPL) or copyleft (LGPL, MPL) licenses. |
| npm audit | Checks Node.js dependencies for known vulnerabilities using the npm registry advisory database. |
| phpstan | Static analysis tool for PHP that finds bugs without running the code. Catches type errors, dead code, and logic mistakes. |
| pip-audit | Audits Python dependencies for known vulnerabilities using the PyPI advisory database. |
| Pluto | Detects deprecated and removed Kubernetes API versions in manifests and Helm charts. Prevents cluster upgrades from breaking workloads that use outdated API versions. |
| PMD | Static analysis tool that finds common programming flaws in Java source code such as unused variables, empty catch blocks, and unnecessary object creation. |
| PSScriptAnalyzer | Static analysis tool for PowerShell that checks scripts against best practice rules and security guidelines. |
| rubocop | Ruby linter and formatter with security-focused cops that detect unsafe patterns. |
| Semgrep | Lightweight static analysis engine that finds bugs and security vulnerabilities using pattern-matching rules. Supports 30+ languages with community and pro rulesets. |
| sqlfluff | Lints and auto-formats SQL code against configurable style rules. |
| staticcheck | Advanced Go linter that finds bugs, performance issues, and code simplifications. |
| terraform fmt | Enforces consistent HCL formatting across Terraform configuration files. |
| terraform validate | Validates Terraform configuration for syntax errors, broken references, and internal consistency. |
| tflint | Provider-aware Terraform linter that catches invalid resource arguments, deprecated features, and naming conventions. |
| Trivy | Scans filesystems for known vulnerabilities in dependencies, secrets, and misconfigurations. |
| TruffleHog | Detects secrets and credentials leaked in git history and source code. Verifies found secrets are still active to reduce false positives. |
| tsqllint | Lints T-SQL code for syntax errors, style violations, and common anti-patterns. |
| exploit-guards | Checks GitHub Actions workflow files for exploit patterns including unsafe expression injection, untrusted input usage, dangerous pull_request_target triggers, and missing permission restrictions. |

[↑ top](#github-actions-appsec-scanner-gaas)

## Testing

Four executable test suites plus one monorepo planning harness live under `tests/`. Run them from the repo root.

### Offline (static checks)

```
./tests/test-offline.sh
```

No network access required. Prerequisites: Python 3, bash, coreutils, ripgrep (`rg`), actionlint.

Checks YAML syntax, supply-chain pinning, reusable workflow API contracts, workflow job contracts, scanner-specific behavior contracts, SARIF conversion contracts, fixture routing contracts, and README cross-checks. Also includes a separate exploit-guards regression suite:

```
./tests/test-workflow-exploit-guards.sh
```

Legacy alias (kept for compatibility):

```
./tests/github-actions-workflow-exploit-guards.sh
```

Runs the full set of 60+ exploit-guard checks against every workflow file in `.github/workflows/`. Prerequisites: bash, Python 3, ripgrep (`rg`).

### Online (live tool smoke tests)

```
./tests/test-online.sh
```

Downloads real tools and queries upstream advisory databases. Internet access required. Results are cached at `${XDG_CACHE_HOME:-$HOME/.cache}/github-actions-appsec-scanner/test-online` to speed up re-runs.

Key flags:

| Flag | Purpose |
|---|---|
| `--list` | Print all registered test names and exit |
| `--filter <pattern>` | Only run tests whose names contain `<pattern>` |
| `--skip <pattern>` | Skip tests whose names contain `<pattern>` |
| `--fail-fast` | Stop after the first failing test |
| `--junit <file>` | Write JUnit XML results to `<file>` |
| `--keep-temp-on-fail` | Preserve temp dirs after a failure for debugging |
| `--timeout <seconds>` | Override default per-command timeout |
| `--cache-dir <dir>` | Override tool cache directory |

```
# Examples
./tests/test-online.sh --list
./tests/test-online.sh --filter govulncheck
KEEP_TMP_ON_FAIL=true ONLINE_TIMEOUT=900 ./tests/test-online.sh --junit /tmp/results.xml
```

### Act (end-to-end with Docker)

```
./tests/test-act.sh
```

Runs scanner workflows locally using [act](https://github.com/nektos/act). Stages the repo's workflows into a temporary `.github/` tree, rewrites GitHub-hosted-only steps (harden-runner, cache, artifact actions) into local no-op shims, then runs targeted scenarios against the fixture repos.

Prerequisites: `act`, `docker`, `git`, `python3`.

Key flags and environment variables:

| Flag / Env | Purpose |
|---|---|
| `--filter <pattern>` | Only run tests whose names contain `<pattern>` |
| `--jobs <count>` | Run up to `<count>` tests in parallel |
| `--junit <file>` | Write JUnit XML results to `<file>` |
| `--log-dir <dir>` | Write per-test logs into `<dir>` |
| `--verbose` | Pass `--verbose` to act |
| `--keep-temp-on-fail` | Preserve staged repos after a failure |
| `ACT_IMAGE` | Runner image (default: `catthehacker/ubuntu:act-24.04`) |
| `ACT_TIMEOUT` | Seconds before killing a single act invocation |
| `GITHUB_TOKEN` | Optional token for fetching marketplace actions |

```
# Examples
./tests/test-act.sh --filter python
./tests/test-act.sh --jobs 4 --log-dir /tmp/act-logs
ACT_IMAGE=catthehacker/ubuntu:full-24.04 ./tests/test-act.sh
KEEP_TMP=true ACT_TIMEOUT=300 ./tests/test-act.sh --verbose
```

### Monorepo planning harness

```
./tests/test-monorepo.sh
```

This script is currently a planning harness that tracks monorepo test rollout, fixture readiness, and open blockers. It is intentionally read-only and reports planned scenarios as `SKIP` until fixtures and implementations are added.

### Fixtures

Test fixtures live at `tests/fixtures/<scope>/<scenario>/`. Each fixture is a small, real source tree that exercises one primary behavior.

`tests/fixtures/manifest.json` describes every fixture's class and assertion mode:

| Class | Meaning |
|---|---|
| `deterministic` | Exact or near-exact scanner output is expected |
| `bounded-drift` | Upstream advisories or registries may change output over time |
| `github-native` | Tests workflow/report/permission behavior rather than source findings |

Fixtures cover all supported languages and IaC types, plus positive and negative cases for secrets detection, vulnerability scanning, and license scanning.

[↑ top](#github-actions-appsec-scanner-gaas)

## ToDo

| Area | Description |
|---|---|
| Monorepo tests and architecture | Continue to expand this and make it truly robust |

[↑ top](#github-actions-appsec-scanner-gaas)
