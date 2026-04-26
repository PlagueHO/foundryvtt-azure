# AGENTS.md — Project Guidelines for AI Agents and Contributors

This file provides broad project guidelines for all AI agents and human contributors working on the **FoundryVTT Azure Solution Accelerator**. For detailed coding conventions and patterns, see [.github/copilot-instructions.md](.github/copilot-instructions.md).

## Project Overview

This repository is an Azure Solution Accelerator that deploys [Foundry Virtual Table Top (Foundry VTT)](https://foundryvtt.com/) to Microsoft Azure using the [Azure Developer CLI (azd)](https://aka.ms/azd) and [Bicep](https://learn.microsoft.com/azure/azure-resource-manager/bicep/) Infrastructure as Code. It follows Zero-Trust security principles and uses [Azure Verified Modules (AVM)](https://aka.ms/avm) for all Azure resource deployments.

Key references:

- [README.md](README.md) — Solution overview, deployment instructions, architecture
- [spec/infrastructure-foundry-vtt-azure.md](spec/infrastructure-foundry-vtt-azure.md) — Formal infrastructure specification with requirements (R-\*), constraints (C-\*), and guidelines (G-\*)

## Repository Structure

```text
/
├── infra/                   # Infrastructure as Code (Bicep)
│   ├── main.bicep           # Main deployment template (subscription scope)
│   ├── main.bicepparam      # Parameter file (reads environment variables)
│   ├── main.json            # Compiled ARM template
│   ├── abbreviations.json   # Azure CAF resource naming abbreviations
│   └── bicepconfig.json     # Bicep linter rules and experimental features
├── scripts/                 # Utility PowerShell scripts
├── spec/                    # Machine-readable specifications
├── docs/                    # Documentation and images
│   └── images/              # Screenshots and architecture diagrams
├── .github/
│   ├── workflows/           # GitHub Actions CI/CD workflows
│   ├── instructions/        # Copilot instruction files (e.g., markdown-gfm)
│   ├── copilot-instructions.md  # Project-specific coding conventions
│   ├── ISSUE_TEMPLATE/      # Bug and feature request forms
│   ├── CODEOWNERS           # Code review ownership (@PlagueHO)
│   └── dependabot.yml       # Dependency auto-update configuration
├── .devcontainer/           # Dev container configuration
├── azure.yaml               # Azure Developer CLI project configuration
├── CHANGELOG.md             # Versioned changelog (Keep a Changelog format)
├── GitVersion.yml           # Semantic versioning configuration
└── AGENTS.md                # This file
```

## Build, Lint, and Test Gates

**All agents and contributors MUST run these validation commands after making changes.** Do not submit changes that fail any of these gates.

### Bicep Infrastructure

```bash
# Lint — validates against bicepconfig.json rules
bicep lint ./infra/main.bicep

# Build — compiles to ARM template, catches syntax and type errors
bicep build ./infra/main.bicep
```

### PowerShell Scripts

```powershell
# Lint — validates against PSScriptAnalyzer rules
Invoke-ScriptAnalyzer -Path ./scripts/ -Recurse -ReportSummary
```

### CI Pipeline Reference

The full CI pipeline is defined in `.github/workflows/continuous-testing.yml` and runs:

1. `bicep lint` via the `lint-and-publish-bicep.yml` reusable workflow
1. `azd provision` for Web App mode (test-infrastructure.yml)
1. `azd provision` for Container Instance mode (test-infrastructure.yml)
1. `azd down --purge` cleanup after each test

## Versioning and Changelog

- **Semantic Versioning**: Major.Minor.Patch (e.g., `2.0.0`)
- **Git tags**: `v#.#.#` format (e.g., `v2.0.0`)
- **Automated via GitVersion**: ContinuousDelivery mode (see `GitVersion.yml`)
- **Commit message triggers** for version bumps:
  - `+semver: breaking` or `+semver: major` — Major version bump
  - `+semver: feature` or `+semver: minor` — Minor version bump
  - `+semver: fix` or `+semver: patch` — Patch version bump
- **Branch strategy**: `main` (production), `develop` (alpha), `release/*` (beta), `feature/*`, `hotfix/*`

### Changelog Format

Follow [Keep a Changelog](https://keepachangelog.com/) format. Update `CHANGELOG.md` for all user-facing changes:

```markdown
## [Version] - YYYY-MM-DD

### Added

- Description of new feature

### Changed

- Description of change

### Fixed

- Description of fix
```

Valid categories: Added, Changed, Fixed, Deprecated, Removed, Security.

## Pull Request and Code Review Rules

- **CODEOWNERS**: `@PlagueHO` is the required reviewer for all file types
- All PRs must pass `bicep lint` before merge
- Update `CHANGELOG.md` for any user-facing change
- Infrastructure changes must comply with the specification in `spec/infrastructure-foundry-vtt-azure.md`
- Never bypass CI checks or use `--no-verify` flags

## Security Principles

These security rules are non-negotiable. Every change must adhere to them:

1. **Zero-Trust networking**: When `deployNetworking` is enabled, all resources use Private Endpoints and deny public access
1. **Secrets in Key Vault only**: All sensitive values (credentials, keys) must be stored in Azure Key Vault. Never hardcode secrets in Bicep, scripts, workflows, or documentation
1. **`@secure()` decorator**: All Bicep parameters that accept sensitive values must use the `@secure()` decorator
1. **Managed Identity and RBAC**: Web Apps use system-assigned managed identity with `Key Vault Secrets User` role. Enable `enableRbacAuthorization: true` on Key Vault
1. **Workload Identity Federation (OIDC)**: GitHub Actions authenticate to Azure via federated credentials — never store Azure credentials as GitHub secrets
1. **TLS 1.2 minimum**: All resources must enforce `minTlsVersion: '1.2'`
1. **Sensitive data cleanup**: PowerShell scripts must clean up sensitive variables in `finally` blocks

## Environment Variable Naming

- **Azure parameters**: `AZURE_` prefix with SCREAMING_SNAKE_CASE (e.g., `AZURE_COMPUTE_SERVICE`, `AZURE_DEPLOY_NETWORKING`)
- **Foundry secrets**: `FOUNDRY_` prefix (e.g., `FOUNDRY_USERNAME`, `FOUNDRY_PASSWORD`, `FOUNDRY_ADMIN_KEY`)
- **Parameter file mapping**: Environment variables map to camelCase Bicep parameters via `readEnvironmentVariable()` in `main.bicepparam`

## Specification Compliance

All infrastructure changes must comply with the formal specification at `spec/infrastructure-foundry-vtt-azure.md`. Key constraints:

- **R-1**: Deployment must succeed via `azd up` without manual prerequisites beyond `azd login`
- **R-2**: Support two compute modes: `Web App` (default) and `Container Instance`
- **R-4**: Web App with networking enabled requires VNet isolation with Private Endpoints for Storage and Key Vault
- **R-5**: All secrets must reside in Key Vault; Web App MSI granted Key Vault Secrets User
- **R-6**: Storage account name must be ≤ 24 lowercase alphanumeric characters
- **C-1**: Container Apps is out-of-scope until AVM support exists
- **C-2**: Container Instance deployments cannot use VNets (Azure limitation)
- **G-1**: Use Azure Verified Modules (`br/public:avm/*`) for all Azure resources

When adding or modifying infrastructure, verify your changes against the full specification.

## Documentation Standards

- Follow [GitHub Flavored Markdown (GFM)](https://github.github.com/gfm/) formatting rules as defined in `.github/instructions/markdown-gfm.instructions.md`
- Do not force-wrap lines at a specific length
- Use `1.` for all ordered list items (enables reordering without renumbering)
- Fenced code blocks must specify a language identifier
- Use `*` for emphasis; `_` only at word boundaries
