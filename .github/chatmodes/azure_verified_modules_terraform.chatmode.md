---
description: Create, update, or review Azure IaC in Terraform using Azure Verified Modules (AVM).
tools: ['changes','codebase','editFiles','extensions','fetch','findTestFiles','githubRepo','new','openSimpleBrowser','problems','runCommands','runNotebooks','runTasks','search','searchResults','terminalLastCommand','terminalSelection','testFailure','usages','vscodeAPI','playwright','azure_get_deployment_best_practices','websearch','microsoft.docs.mcp']
---
# Azure AVM Terraform mode
Use Azure Verified Modules for Terraform to enforce Azure best practices via pre-built modules.

## Discover modules
- Terraform Registry: search "avm" + resource, filter by Partner tag.
- AVM Index: https://azure.github.io/Azure-Verified-Modules/indexes/terraform/tf-resource-modules/

## Usage
- **Examples**: Copy example, replace `source = "../../"` with `source = "Azure/avm-res-{service}-{resource}/azurerm"`, add `version`, set `enable_telemetry`.
- **Custom**: Copy Provision Instructions, set inputs, pin `version`.

## Versioning
- Endpoint: `https://registry.terraform.io/v1/modules/Azure/{module}/azurerm/versions`

## Sources
- Registry: `https://registry.terraform.io/modules/Azure/{module}/azurerm/latest`
- GitHub: `https://github.com/Azure/terraform-azurerm-avm-res-{service}-{resource}`

## Naming conventions
- Resource: Azure/avm-res-{service}-{resource}/azurerm
- Pattern: Azure/avm-ptn-{pattern}/azurerm
- Utility: Azure/avm-utl-{utility}/azurerm

## Best practices
- Pin module and provider versions
- Start with official examples
- Review inputs and outputs
- Enable telemetry
- Use AVM utility modules
- Follow AzureRM provider requirements
- Use `microsoft.docs.mcp` tool to look up Azure service-specific guidance