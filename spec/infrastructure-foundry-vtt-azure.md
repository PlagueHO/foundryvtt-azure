# Specification: Foundry VTT on Azure – Solution Accelerator

**Version:** 1.0  
**Last Updated:** 2025-05-26  
**Owner:** @PlagueHO

## 1. Purpose & Scope

Provide an unambiguous infrastructure specification for deploying Foundry Virtual Table Top (Foundry VTT) to Microsoft Azure using Bicep and the Azure Developer CLI (azd).
Audience: Azure engineers, DevOps practitioners, and CI/CD pipelines (LLMs or humans) requiring deterministic deployment behaviour.

## 2. Definitions

| Term | Definition |
|------|------------|
| FVTT | Foundry Virtual Table Top |
| AVM | Azure Verified Module |
| ACI | Azure Container Instance |
| Web App | Azure App Service (Linux Container) |
| VNet | Virtual Network |
| PE | Private Endpoint |
| Bastion | Azure Bastion Host |
| KV | Azure Key Vault |

## 3. Requirements, Constraints & Guidelines

- **R-1**: Deployment must succeed via `azd up` using `infra/main.bicep` without manual pre-reqs beyond azd login.  
- **R-2**: Support two compute modes: `Web App` (default) and `Container Instance`.  
- **R-3**: All resources share a common *environment name* to guarantee global uniqueness.  
- **R-4**: When `computeService == 'Web App'` and `deployNetworking == true`, resources MUST be isolated in a VNet with PEs for Storage and KV.  
- **R-5**: All secrets (storage key, Foundry credentials) MUST reside in KV; Web App MSI granted **Key Vault Secrets User**.  
- **R-6**: Storage account name ≤ 24 lower-case alphanumerics and may be locked (`CanNotDelete`) when `storageResourceLockEnabled == true`.  
- **C-1**: Container Apps is out-of-scope until AVM support exists.  
- **C-2**: ACI deployments cannot use VNets (Azure limitation).  
- **G-1**: Use AVM modules (`br/public:avm/*`) for all Azure resources.  
- **G-2**: Tags must at minimum include `azd-env-name`.  
- **G-3**: Optional components (Bastion, DDB-Proxy, diagnostics) are toggled via boolean parameters.

## 4. Interfaces & Data Contracts

### 4.1 Bicep Parameters (excerpt)

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `environmentName` | string | — | Globally unique env prefix |
| `location` | string | — | Azure region |
| `computeService` | string | `'Web App'` | `Web App` \| `Container Instance` |
| `deployNetworking` | bool | `true` | VNet & PEs for Web App |
| `foundryUsername` / `foundryPassword` / `foundryAdminKey` | secure string | — | Foundry VTT creds |

*See [infra/main.bicep](../infra/main.bicep) for full list.*

### 4.2 Outputs (excerpt)

| Output | Example | Purpose |
|--------|---------|---------|
| `FOUNDRY_VTT_URL` | `https://myenv.azurewebsites.net/` | Entry URL for users |
| `KEY_VAULT_NAME` | `kvmyenv` | Reference for pipelines |
| `LOG_ANALYTICS_WORKSPACE_RESOURCE_ID` | `/subscriptions/...` | Diagnostics target |

## 5. Rationale & Context

Foundry VTT is stateful; Azure Files provides persistent SMB storage mounted into the container at `/data`.
Private-endpoint isolation (Web App scenario) meets Zero-Trust goals and demo WAF best practices.
Parameterisation allows hobby users (ACI) or production-grade deployments (Web App + VNet).

## 6. Examples & Edge Cases

```sh
# Edge-case: deploy lightweight ACI without networking
azd env set AZURE_COMPUTE_SERVICE "Container Instance"
azd env set AZURE_DEPLOY_NETWORKING "false"
```

```sh
# Example: premium storage, diagnostics enabled
azd env set AZURE_STORAGE_CONFIGURATION "Premium_100GB"
azd env set AZURE_DEPLOY_DIAGNOSTICS "true"
```

```sh
# Standard Web App deployment (defaults: networking enabled, SKU P0v3)
azd env set AZURE_COMPUTE_SERVICE "Web App"
```

```sh
# Web App deployment WITHOUT networking (public endpoints)
azd env set AZURE_COMPUTE_SERVICE "Web App"
azd env set AZURE_DEPLOY_NETWORKING "false"
```

```sh
# Web App on premium plan (higher SKU)
azd env set AZURE_COMPUTE_SERVICE "Web App"
azd env set AZURE_APP_SERVICE_PLAN_SKUNAME "P1v3"
```

```sh
# Web App with DDB-Proxy and Bastion Host
azd env set AZURE_COMPUTE_SERVICE "Web App"
azd env set AZURE_DEPLOY_DDB_PROXY "true"
azd env set AZURE_BASTION_HOST_DEPLOY "true"
```

## 7. Validation Criteria

1. `azd up` completes with zero errors in both compute modes.  
1. URL in output responds with HTTP 200.  
1. KV contains four secrets; Web App MSI can read them.  
1. If `deployNetworking == true`, public network access on Storage and KV is **Disabled**.  
1. GitHub Actions workflow passes using Workload Identity Federation.

## 8. Related Specifications / Further Reading

- [Azure Developer CLI (azd)](https://aka.ms/azd)
- [Foundry VTT Documentation](https://foundryvtt.com)
- [Felddy Foundry VTT Docker Image repo](https://github.com/felddy/foundryvtt-docker)
- [MrPrimate Foundry VTT DDB Proxy](https://github.com/MrPrimate/ddb-proxy)
- [Azure Well-Architected Framework](https://learn.microsoft.com/en-us/azure/well-architected/)
- [Azure Verified Modules](https://aka.ms/avm)
- [Azure Verified Modules](https://aka.ms/avm)
