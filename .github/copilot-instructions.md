# Copilot Instructions

## Core Commands
- **Provision & Deploy**: `azd up`; `azd provision --no-prompt [--no-state]`
- **Teardown**: `azd down [--purge]`
- **Lint Bicep**: `bicep lint infra/main.bicep`
- **GitHub Actions** (in `.github/workflows`):
  - `continuous-testing.yml` (end-to-end infra tests)
  - `test-infrastructure.yml` (invoke with `ENVIRONMENT` input)
  - `lint-and-publish-bicep.yml`
  - `deploy-infrastructure.yml` / `deploy-production.yml`

## High-level Architecture
- **Compute**: Azure Web App (Linux container) or Azure Container Instance
- **Container Image**: `felddy/foundryvtt:release`
- **Storage**: Azure Files (persistent); Azure Key Vault for secrets
- **Networking**: Virtual Network + private endpoints; optional Bastion Host
- **Diagnostics**: Azure Log Analytics and resource diagnostics
- **Optional**: DDB-Proxy (App Service) for DDB-Importer plugin
- **IaC**: Bicep modules in `infra/`, using Azure Verified Modules

## Repo-specific Style
- **IaC**: follow Verified Modules patterns; define params in `main.bicepparam`
- **YAML**: use `actions/checkout@v4`, `Azure/setup-azd@v2.1.0`, `pwsh` for Az CLI
- **Naming**: resources prefixed `fvtt-<service>-<branch>-<runId>`
- **Env vars**: set via `azd env set` locally or `vars`/`secrets` in GitHub
- **Debug**: tests include `--debug` flag for detailed logs
- **Versioning**: Git tags `v*`; update `version-shield` badge in README

## Agent Rules & Detected Policies
- @azure Rule - **Use Azure Tools** for Azure-related requests
- @azure Rule - **Code Gen Best Practices**: invoke `azure_development-get_code_gen_best_practices`
- @azure Rule - **Deployment Best Practices**: invoke `azure_development-get_deployment_best_practices`
- @azure Rule - **Azure Functions**: invoke `azure_development-get_azure_function_code_gen_best_practices`
- @azure Rule - **Static Web Apps**: invoke `azure_development-get_swa_best_practices`
- Follow Microsoft content policies and user-provided guidelines in this repo

## References
- README.md (usage, config options, architecture table)
- `spec/infrastructure-foundry-vtt-azure.md` (detailed infra requirements)
