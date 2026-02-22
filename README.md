## All-in-One GitHub Actions Application Security Scanner

Supports .NET, Golang / Go, Infrastructure as Code / IaC, Java, JavaScript, PowerShell, Python, Ruby on Rails, Rust, and SQL

Notes:

- The _orchestrator.yaml workflow is the top-level director
- _security-general.yaml workflow gets called for any/all programming languages; includes Semgrep, Trivy, Trufflehog, and license checks
- All other workflow files are language-specific checks and tools
- Most things are SHA pinned to stop supply chain attacks
- Generates and uploads SARIF files
- Updates the pull request / PR with comments about the results of the scans
- IaC supports Terraform, Docker, k8s, Helm, and CloudFormation

ToDo:
- Add SBOMs
- Add Ansible support
