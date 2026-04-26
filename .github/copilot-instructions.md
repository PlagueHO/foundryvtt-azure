# Copilot Instructions — Coding Conventions and Patterns

This file defines the specific coding conventions and patterns used in this repository. For broad project guidelines (structure, build gates, versioning, security, PR rules), see [AGENTS.md](../AGENTS.md).

## Bicep Conventions

### Target Scope

The main deployment template uses subscription scope to create the resource group and all child resources:

```bicep
targetScope = 'subscription'
```

### Resource Naming

Resource names follow Azure Cloud Adoption Framework (CAF) abbreviations loaded from `abbreviations.json`:

```bicep
var abbrs = loadJsonContent('./abbreviations.json')
var virtualNetworkName string = '${abbrs.networkVirtualNetworks}${environmentName}'
```

General pattern: `${abbreviation}${environmentName}`

Special naming rules for character-limited resources:

- **Storage accounts** (max 24 chars, lowercase, no hyphens): `take(toLower(replace(environmentName, '-', '')), 24)`
- **Key Vault** (max 24 chars, no special chars): `'kv${replace(environmentName, '-', '')}'` truncated to 24
- **App Service Plan**: `take('${abbrs.webSitesAppService}${environmentName}', 60)`

Always use the `take()` function for resources with name length limits.

### Azure Verified Modules (AVM)

All Azure resources must be deployed using AVM modules from the public Bicep registry. Never use raw `resource` declarations for resources that have an AVM module.

```bicep
module storageAccount 'br/public:avm/res/storage/storage-account:0.32.0' = if (condition) {
  name: 'storage-account-deployment'
  scope: rg
  params: {
    name: storageAccountName
    location: location
    tags: tags
    // ...
  }
}
```

Key patterns:

- **Module source**: `'br/public:avm/res/<provider>/<type>:<version>'`
- **Deployment name**: Descriptive with `-deployment` suffix (e.g., `'key-vault-deployment'`)
- **Scope**: Always `scope: rg` (scoped to the resource group)
- **Conditional deployment**: Use `= if (condition) {` on the module declaration

### Parameters

#### Naming and Types

- Use **camelCase** for all parameter names (e.g., `environmentName`, `deployNetworking`, `appServicePlanSkuName`)
- Group parameters with comment section headers:

```bicep
// General configuration provided by Azure Developer CLI
// Configuration for the Foundry VTT server - Required
// Networking configuration
// Storage Account configuration
// Compute Service configuration
```

#### Decorators

Apply decorators in this order:

```bicep
@sys.description('Description of the parameter for the user.')
@minLength(1)
@maxLength(64)
@allowed(['Option1', 'Option2'])
@secure()
@metadata({
  azd: {
    type: 'location'
  }
})
param parameterName string = 'defaultValue'
```

- `@sys.description()` — Required on all parameters; use clear, user-facing language
- `@minLength()` / `@maxLength()` — For string length validation
- `@minValue()` / `@maxValue()` — For numeric range validation
- `@allowed([])` — For enum-style constraints
- `@secure()` — Required on all sensitive parameters (passwords, keys, tokens)
- `@metadata({ azd: { type: '...' } })` — For Azure Developer CLI type hints (`'location'`, `'resourceGroup'`)

#### Parameter File (main.bicepparam)

Use `readEnvironmentVariable()` with fallback defaults:

```bicep
param environmentName = readEnvironmentVariable('AZURE_ENV_NAME', 'azdtemp')
param location = readEnvironmentVariable('AZURE_LOCATION', 'EastUS2')
```

Boolean conversion pattern from environment variables:

```bicep
param deployNetworking = toLower(readEnvironmentVariable('AZURE_DEPLOY_NETWORKING', 'true')) == 'true' ? true : false
```

### Variables

- Use **camelCase** for all variable names
- Use typed variables where supported (experimental feature enabled in `bicepconfig.json`):

```bicep
var storageAccountName string = take(toLower(replace(environmentName, '-', '')), 24)
```

- **Configuration maps** for preset selections:

```bicep
var storageConfigurationMap = {
  Premium_100GB: {
    kind: 'FileStorage'
    sku: 'Premium_LRS'
    shareQuota: 100
  }
  Standard_100GB: {
    kind: 'StorageV2'
    sku: 'Standard_LRS'
    shareQuota: 100
  }
}
```

- **Conditional arrays** using ternary with empty array fallback:

```bicep
var sendToLogAnalytics = deployDiagnostics ? [
  {
    name: sendToLogAnalyticsName
    // ...
  }
] : []
```

- **Effective booleans** that combine multiple conditions:

```bicep
var effectiveDeployNetworking = deployNetworking && computeService == 'Web App'
```

### Section Headers

Use dashed comment blocks to separate logical sections:

```bicep
// ---------- RESOURCE GROUP ----------
// ------------- LOG ANALYTICS WORKSPACE (OPTIONAL) -------------
// ------------- STORAGE ACCOUNT -------------
```

Mark sections as `(OPTIONAL)` or `(REQUIRED)` where applicable.

### Tags

All resources must include the `tags` variable:

```bicep
var tags = {
  'azd-env-name': environmentName
}
```

Pass `tags: tags` to every module and resource.

### Null Safety

Use the safe navigation operator and null coalescing for optional module outputs:

```bicep
serverFarmResourceId: appServicePlan.?outputs.?resourceId ?? ''
networkSecurityGroupResourceId: effectiveDeployNetworking ? networkSecurityGroupStorage.?outputs.?resourceId ?? null : null
```

Pattern: `module.?outputs.?property ?? fallback`

### Existing Resource References

Reference pre-existing resources with the `existing` keyword:

```bicep
resource storageAccountReference 'Microsoft.Storage/storageAccounts@2021-04-01' existing = {
  name: storageAccountName
  scope: rg
  dependsOn: [storageAccount]
}
```

### Key Vault Secrets

- Secret names use **camelCase**: `storageAccountKey`, `foundryUsername`, `foundryPassword`, `foundryAdminKey`
- Web App settings reference secrets via: `'@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName=${secretName})'`

### Network Security

- Default deny when networking enabled: `defaultAction: effectiveDeployNetworking ? 'Deny' : 'Allow'`
- Always bypass Azure services: `bypass: 'AzureServices'`
- Enforce TLS 1.2: `minTlsVersion: '1.2'`
- FTPS only: `ftpsState: 'FtpsOnly'`

### Diagnostics

- Diagnostics settings name pattern: `'send-to-loganalytics-${environmentName}'`
- Conditional deployment:  wrap in `deployDiagnostics` flag

### Resource Locks

Conditional lock pattern:

```bicep
lock: storageResourceLockEnabled ? {
  kind: 'CanNotDelete'
  name: '${storageAccountName}-delete-lock'
} : null
```

### Future Work Markers

- `// TODO:` for actionable items (e.g., `// TODO: AVM module doesn't currently support diagnostics`)
- `// TBC` for features under consideration (e.g., `// TBC: Support for DB Proxy in Container Instance`)

### Bicep Linter Configuration

The `bicepconfig.json` enables:

- `no-unused-params`: warning level
- `typedVariables`: experimental feature enabled
- `extensibility`: experimental feature enabled

All new code must pass `bicep lint` with zero errors. Warnings should be addressed when practical.

## PowerShell Conventions

### Script Structure

```powershell
#Requires -Modules Az.Storage

<#
.SYNOPSIS
    Single-line purpose description.

.DESCRIPTION
    Detailed behavior description including edge cases and cross-tenant support.

.PARAMETER ParameterName
    Description of the parameter.

.EXAMPLE
    .\Script-Name.ps1 -Param1 "value1" `
                      -Param2 "value2"

.NOTES
    - Implementation requirements and assumptions
    - External tool dependencies
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ParameterName,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 168)]
    [int]$NumericParam = 24,

    [Parameter(Mandatory = $false)]
    [switch]$BooleanFlag
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
```

### Naming Conventions

| Element | Convention | Example |
|---|---|---|
| Functions | Verb-Noun (approved verbs) | `Connect-AzureTenantSubscription`, `New-FileShareSasToken` |
| Parameters | PascalCase | `$SourceSubscriptionId`, `$SasTokenExpiryHours` |
| Variables | camelCase | `$storageAccount`, `$publicNetworkAccess` |
| Switch parameters | Descriptive boolean names | `$Overwrite`, `$DryRun`, `$SkipNetworkAccessCheck` |

### File Naming

PowerShell scripts use **Verb-Noun** PascalCase naming: `Copy-AzureFileShareData.ps1`

### Parameter Validation

Always use validation attributes:

- `[ValidateNotNullOrEmpty()]` — For required strings
- `[ValidateRange(min, max)]` — For numeric bounds (add comment explaining the range)
- `[ValidateSet('Value1', 'Value2')]` — For enum-like restrictions
- `[switch]` — For boolean flags (never use `[bool]`)

### Error Handling

```powershell
try {
    # Main script logic
} catch {
    Write-ColorOutput "`n=== Script Execution Failed ===" -Color Red
    Write-ColorOutput "Error: $($_.Exception.Message)" -Color Red
    Write-ColorOutput "Stack Trace: $($_.ScriptStackTrace)" -Color Yellow
    exit 1
} finally {
    # Clean up sensitive variables
    Remove-Variable -Name sensitiveVar -Force -ErrorAction SilentlyContinue
}
```

- Set `$ErrorActionPreference = 'Stop'` at script level
- Use exit codes: `0` = success, `1` = failure
- Clean up sensitive data in `finally` blocks
- Suppress verbose output with `| Out-Null`

### Console Output Colors

Use consistent semantic colors:

- **Green** (`✓`) — Success messages
- **Red** (`✗`) — Error messages and failures
- **Yellow** (`⚠️`) — Warnings and cautions
- **Cyan** — Section headers (e.g., `=== Section Name ===`)
- **Gray** — Debug/detailed info

### Function Design Patterns

- **Return early** when validation passes (avoid deep nesting)
- **Graceful fallback**: Try primary approach, catch and try alternative
- **Time tracking** for long operations:

```powershell
$startTime = Get-Date
# ... operation ...
$duration = (Get-Date) - $startTime
Write-ColorOutput "Completed in $($duration.ToString('hh\:mm\:ss'))" -Color Green
```

## GitHub Actions Workflow Conventions

### Reusable Workflows

All workflows use the reusable workflow pattern via `workflow_call`:

- Define `inputs` with description, required flag, and type
- Define `secrets` with description and required flag
- Reference with `uses: ./.github/workflows/<workflow>.yml`

### Authentication

Always use Workload Identity Federation (OIDC) for Azure authentication:

```yaml
- name: Authenticate azd (Federated Credentials)
  run: |
    azd auth login `
      --client-id "$Env:AZURE_CLIENT_ID" `
      --federated-credential-provider "github" `
      --tenant-id "$Env:AZURE_TENANT_ID"
  shell: pwsh
```

Never store Azure credentials as repository secrets.

### Conventions

- **Shell**: Use `pwsh` for cross-platform PowerShell steps
- **Action versions**: Pin to major version (e.g., `actions/checkout@v6`, `actions/upload-artifact@v7`)
- **Environments**: Use GitHub Environments for deployment protection rules
- **Test cleanup**: Always run `azd down --no-prompt --purge --force` in test workflows (use `if: always()` to ensure cleanup)
- **Sequential testing**: Run test environments in series when constrained by licensing (Web App before Container Instance)
- **Naming**: Workflow files use kebab-case (e.g., `continuous-testing.yml`, `lint-and-publish-bicep.yml`)
- **Permissions**: Declare minimal permissions at job or workflow level (`id-token: write`, `contents: read`)

## Specification Document Conventions

### Structure

Specification documents in `spec/` follow this section structure:

1. Purpose & Scope
1. Definitions (glossary table)
1. Requirements, Constraints & Guidelines
1. Interfaces & Data Contracts
1. Rationale & Context
1. Examples & Edge Cases
1. Validation Criteria
1. Related Specifications / Further Reading

### Requirement Numbering

- **R-\*** — Functional requirements (what must be true)
- **C-\*** — Constraints/limitations (what cannot be done)
- **G-\*** — Guidelines/best practices (how to achieve quality)

### Metadata Block

```markdown
**Version:** 1.0
**Last Updated:** YYYY-MM-DD
**Owner:** @PlagueHO
```

### Examples

Precede each example with a bash comment explaining intent:

```bash
# Edge-case: lightweight deployment without networking
azd env set AZURE_COMPUTE_SERVICE "Container Instance"
azd env set AZURE_DEPLOY_NETWORKING "false"
```

## Azure Developer CLI (azure.yaml)

### Post-Provision Hooks

The `azure.yaml` supports post-provision hooks for both Windows (PowerShell) and POSIX shells. Hooks output deployment results (e.g., the Foundry VTT URL) after `azd up` completes.

### Naming

- Project name matches the repository name: `foundryvtt-azure`
- Template metadata uses `@version` suffix: `foundryvtt-azure@1.0`
