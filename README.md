# foundryvtt-azure

[![deploy-foundryvtt](https://github.com/DsrDemoOrg/foundryvtt-azure/actions/workflows/deploy-foundryvtt.yml/badge.svg)](https://github.com/DsrDemoOrg/foundryvtt-azure/actions/workflows/deploy-foundryvtt.yml)

Deploy your own [Foundry Virtual Table Top](https://foundryvtt.com/) server (that you've purchased a license for) to Azure using Azure Bicep and GitHub Actions.

The project uses GitHub actions to deploy the resources to Azure using the [GitHub Action for Azure Resource Manager (ARM) deployment task](https://github.com/Azure/arm-deploy) and [Azure Bicep](https://aka.ms/Bicep).

This repository will deploy a Foundry Virtual Table top using various different Azure architectures to suit your requirements. The compute and storage is separated into different services to enable update and redeployment of the server without loss of the Foundry VTT data.

> IMPORTANT NOTE: This project has been to use Azure AD Workload Identity for the workflow to connect to Azure. Please see [this document](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure) for details on how to set this up.

You can choose which Azure architecture to use by setting the `TYPE` environment variable in the [deploy-foundryvtt](https://github.com/DsrDemoOrg/foundryvtt-azure/actions/workflows/deploy-foundryvtt.yml) workflow.

The available architectures are (prefixed by the `TYPE` value to provide in the workflow):

- `AAS` (Default): [Azure App Service for Linux Containers and Azure Files](#azure-app-service-for-linux-containers-and-azure-files).
- `ACI`: [Azure Container Instances with Azure Files](#azure-container-instances-with-azure-files).
- Azure Container Instances with Azure Files and Azure Front Door - planned.
- Azure Kubernetes Service with Azure App Gateway with Ingres controller (AGIC) - planned.
- Azure Virtual Machines - not planned as there are other projects that covers this architecture.

> IMPORTANT NOTE: You must have a valid [Foundry VTT license](https://foundryvtt.com/) attached to your account. If you don't have one, you can [buy one here](https://foundryvtt.com/purchase/).

## Azure App Service for Linux Containers and Azure Files

This method will deploy an [Azure App Service Web App running Linux Containers](https://learn.microsoft.com/azure/app-service/configure-custom-container) and attach an Azure Storage account with an SMB share for persistent storage.

It uses the `felddy/foundryvtt:release` container image from Docker Hub. The source and documentation for this container image can be found [here](https://github.com/felddy/foundryvtt-docker). It will use your Foundry VTT username and password to download the Foundry VTT application files and register it with your license key.

The following environment variables should be configured in the repository to define the region to deploy to and the storage and container configuration:

- `TYPE`: Should be set to `ASS` to deploy the Azure App Service for Linux Containers and Azure Files architecture.
- `LOCATION`: The Azure region to deploy the resources to. For example, `AustraliaEast`.
- `BASE_RESOURCE_NAME`: The base name that will prefixed to all Azure resources deployed to ensure they are unique. For example, `myfvtt`.
- `RESOURCE_GROUP_NAME`: The name of the Azure resource group to create and add the resources to. For example, `myfvtt-rg`.
- `STORAGE_CONFIGURATION`: The configuration of the Azure Storage SKU to use for storing Foundry VTT user data. Must be one of `Premium_100GB` or `Standard_100GB`.
- `APPSERVICEPLAN_CONFIGURATION`: The configuration of the Azure App Service Plan for running the Foundry VTT server. Must be one of `B1`, `P1V2`, `P2V2`, `P3V2`, `P1V3`, `P2V3`, `P3V3`.

The following GitHub Secrets need to be defined to ensure that resource names for Storage Account and Web App DNS are globally unique and provide access to your Azure subscription for deployment:

- `AZURE_CLIENT_ID`: The Application (Client) ID of the Service Principal used to authenticate to Azure. This is generated as part of configuring Workload Identity Federation.
- `AZURE_TENANT_ID`: The Tenant ID of the Service Principal used to authenticate to Azure.
- `AZURE_SUBSCRIPTION_ID`: The Subscription ID of the Azure Subscription to deploy to.
- `FOUNDRY_USERNAME`: Your Foundry VTT username. This is used by the `felddy/foundryvtt:release` container image.
- `FOUNDRY_PASSWORD`: Your Foundry VTT password. This is used by the `felddy/foundryvtt:release` container image.
- `FOUNDRY_ADMIN_KEY`: The admin key to set Foundry VTT up with. This will be the administrator password you log into the Foundry VTT server with.

These values should be kept secret and care taken to ensure they are not shared with anyone.

### DDB-Proxy

The workflow will also optionally deploy a [DDB-Proxy](https://github.com/MrPrimate/ddb-proxy) into the App Service Plan for use with the awesome [DDB-Importer](https://github.com/MrPrimate/ddb-importer) plugin for Foundry VTT.

- `DEPLOY_DDBPROXY`: Setting this to true will deploy a DDB-Proxy into the same App Service Plan as the Foundry VTT server, but on a different URL.

Once you have deployed a DDB-Proxy into your App Service Plan you will be able to configure your Foundry VTT to use it by running the following commands in your browsers developer console:

```javascript
game.settings.set("ddb-importer", "custom-proxy", true);
game.settings.set("ddb-importer", "api-endpoint", "https://<BASE_RESOURCE_NAME>ddbproxy.azurewebsites.net");
```

## Azure Container Instances with Azure Files

This method will deploy an [Azure Container Instance](https://learn.microsoft.com/azure/container-instances/container-instances-overview) and attach an Azure Storage account with an SMB share for persistent storage.

It uses the `felddy/foundryvtt:release` container image from Docker Hub. The source and documentation for this container image can be found [here](https://github.com/felddy/foundryvtt-docker). It will use your Foundry VTT username and password to download the Foundry VTT application files and register it with your license key.

The following variables should be configured in the repository to define the region to deploy to and the storage and container configuration:

- `TYPE`: Should be set to `ACI` to deploy an Azure Container Instance.
- `LOCATION`: The Azure region to deploy the resources to. For example, `AustraliaEast`.
- `BASE_RESOURCE_NAME`: The base name that will prefixed to all Azure resources deployed to ensure they are unique. For example, `myfvtt`.
- `RESOURCE_GROUP_NAME`: The name of the Azure resource group to create and add the resources to. For example, `myfvtt-rg`.
- `STORAGE_CONFIGURATION`: The configuration of the Azure Storage SKU to use for storing Foundry VTT user data. Must be one of `Premium_100GB` or `Standard_100GB`.
- `CONTAINER_CONFIGURATION`: The configuration of the Azure Container Instance for running the Foundry VTT server. Must be one of `Small`, `Medium` or `Large`.

The following GitHub Secrets need to be defined to ensure that resource names for Storage Account and Container DNS are globally unique and provide access to your Azure subscription for deployment:

- `AZURE_CLIENT_ID`: The Application (Client) ID of the Service Principal used to authenticate to Azure. This is generated as part of configuring Workload Identity Federation.
- `AZURE_TENANT_ID`: The Tenant ID of the Service Principal used to authenticate to Azure.
- `AZURE_SUBSCRIPTION_ID`: The Subscription ID of the Azure Subscription to deploy to.
- `AZURE_CREDENTIALS`: Created as per [this document](https://github.com/marketplace/actions/azure-cli-action#configure-azure-credentials-as-github-secret).
- `BASE_RESOURCE_NAME`: The base name that will prefixed to all Azure resources deployed to ensure they are unique. For example, `myfvtt`.
- `RESOURCE_GROUP_NAME`: The name of the Azure resource group to create and add the resources to. For example, `myfvtt-rg`.
- `FOUNDRY_USERNAME`: Your Foundry VTT username. This is used by the `felddy/foundryvtt:release` container image.
- `FOUNDRY_PASSWORD`: Your Foundry VTT password. This is used by the `felddy/foundryvtt:release` container image.
- `FOUNDRY_ADMIN_KEY`: The admin key to set Foundry VTT up with. This will be the administrator password you log into the Foundry VTT server with.

These values should be kept secret and care taken to ensure they are not shared with anyone.

## Configuring Workload Identity Federation for GitHub Actions workflow

Customize and run this code in Azure Cloud Shell to create the credential for the GitHub workflow to use to deploy to Azure.
[Workload Identity Federation](https://learn.microsoft.com/azure/active-directory/develop/workload-identity-federation) will be used by GitHub Actions to authenticate to Azure.

```powershell
$credentialname = '<The name to use for the credential & app>' # e.g., github-dsrfoundryvtt-workflow
$application = New-AzADApplication -DisplayName $credentialname
$policy = "repo:<your GitHub user>/<your GitHub repo>:ref:refs/heads/main" # e.g., repo:DsrDemoOrg/foundryvtt-azure:ref:refs/heads/main
$subscriptionId = '<your Azure subscription>'

New-AzADAppFederatedCredential `
    -Name $credentialname `
    -ApplicationObjectId $application.Id `
    -Issuer 'https://token.actions.githubusercontent.com' `
    -Audience 'api://AzureADTokenExchange' `
    -Subject $policy
New-AzADServicePrincipal -AppId $application.AppId

New-AzRoleAssignment `
  -ApplicationId $application.AppId `
  -RoleDefinitionName Contributor `
  -Scope "/subscriptions/$subscriptionId" `
  -Description "The deployment workflow for the foundry VTT."
```

To learn how to configure Workload Identity Federation with GitHub Actions, see [this Microsoft Learn Module](https://learn.microsoft.com/training/modules/authenticate-azure-deployment-workflow-workload-identities).
