# Architecture

## Workflow Topology

1. Entry workflows:
- `.github/workflows/_orchestrator-pr.yaml` handles `pull_request` runs.
- `.github/workflows/_orchestrator-ci.yaml` handles `push`, `schedule`, and `workflow_dispatch`.

2. Reusable orchestrator:
- `.github/workflows/orchestrator-reusable.yaml` performs detection, routes to language/tool workflows, aggregates SARIF, posts summaries, and uploads SARIF to Code Scanning.

3. Scanner workflows:
- `.github/workflows/security-*.yaml` and `.github/workflows/_security-general.yaml` run language/tool-specific scanners and emit SARIF artifacts.

## Permission Model

- Entry workflows grant least-privilege permissions for event type.
- `orchestrator-reusable.yaml` declares a permission ceiling; jobs narrow permissions per task.
- Child scanner workflows declare workflow-level `contents: read` and job-level `permissions` blocks.

## SARIF Flow

1. Scanner jobs create SARIF output.
2. Scanner workflows upload SARIF artifacts (`scanner-*-sarif*`).
3. Orchestrator report job downloads artifacts, validates provenance, and generates summary output.
4. `upload-code-scanning` uploads scanner SARIF files individually with category IDs and provenance metadata.

## Scanner Roster

Current scanner families include:
- General: Semgrep, Trivy, TruffleHog, license scan, Grype, Gitleaks, Syft.
- Languages: Go, Rust, Python, JS/TS, Java, .NET, Rails, Ruby, SQL, PowerShell, C/C++, PHP.
- IaC: Checkov, Ansible Lint, Terraform validate/fmt, TFLint, Kube-linter, Hadolint, Kubescape, Pluto.
- GitHub Actions security: zizmor, poutine, actionlint, exploit-guards.
