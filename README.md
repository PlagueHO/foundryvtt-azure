# foundryvtt-azure

[![deploy-foundryvtt](https://github.com/DsrDemoOrg/foundryvtt-azure/actions/workflows/deploy-foundryvtt.yml/badge.svg)](https://github.com/DsrDemoOrg/foundryvtt-azure/actions/workflows/deploy-foundryvtt.yml)

Deploy your own [Foundry Virtual Table Top](https://foundryvtt.com/) server (that you've purchased a license for) to Azure using Azure Bicep and GitHub Actions.

The project uses GitHub actions to deploy the resources to Azure using the [GitHub Action Azure CLI task](https://github.com/marketplace/actions/azure-cli-action) and [Azure Bicep](https://aka.ms/Bicep).

This repository will deploy a Foundry Virtual Table top using various different Azure architectures to suit your requirements. The compute and storage is separated into different services to enable update and redeployment of the server without loss of the Foundry VTT data.

You can choose which Azure architecture to use by setting the `TYPE` environment variable in the [deploy-foundryvtt](https://github.com/DsrDemoOrg/foundryvtt-azure/actions/workflows/deploy-foundryvtt.yml) workflow.

The available architectures are (prefixed by the `TYPE` value to provide in the workflow):

- `AAS` (Default): [Azure App Service for Linux Containers and Azure Files](#azure-app-service-for-linux-containers-and-azure-files).
- `ACI`: [Azure Container Instances with Azure Files](#azure-container-instances-with-azure-files).
- Azure Container Instances with Azure Files and Azure Front Door - planned.
- Azure Kubernetes Service with Azure App Gateway with Ingres controller (AGIC) - planned.
- Azure Virtual Machines - not planned as there are other projects that covers this architecture.

> IMPORTANT NOTE: You must have a valid [Foundry VTT license](https://foundryvtt.com/) attached to your account. If you don't have one, you can [buy one here](https://foundryvtt.com/purchase/).

## Azure App Service for Linux Containers and Azure Files

This method will deploy an [Azure App Service Web App running Linux Containers](https://docs.microsoft.com/en-us/azure/app-service/configure-custom-container) and attach an Azure Storage account with an SMB share for persistent storage.

It uses the `felddy/foundryvtt:release` container image from Docker Hub. The source and documentation for this container image can be found [here](https://github.com/felddy/foundryvtt-docker). It will use your Foundry VTT username and password to download the Foundry VTT application files and register it with your license key.

The following environment variables should be configured in the workflow to define the region to deploy to and the storage and container configuration:

- `LOCATION`: The Azure region to deploy the resources to. For example, `AustraliaEast`.
- `STORAGE_CONFIGURATION`: The configuration of the Azure Storage SKU to use for storing Foundry VTT user data. Must be one of `Premium_5GB`, `Premium_10GB`, `Premium_20GB`, `Standard_5GB`, `Standard_10GB` or `Standard_20GB`.
- `APPSERVICEPLAN_CONFIGURATION`: The configuration of the Azure App Service Plan for running the Foundry VTT server. Must be one of `B1`, `P1V2`, `P2V2`, `P3V2`, `P1V3`, `P2V3`, `P3V3`.

The following GitHub Secrets need to be defined to ensure that resource names for Storage Account and Web App DNS are globally unique and provide access to your Azure subscription for deployment:

- `AZURE_CREDENTIALS`: Created as per [this document](https://github.com/marketplace/actions/azure-cli-action#configure-azure-credentials-as-github-secret).
- `BASE_RESOURCE_NAME`: The base name that will prefixed to all Azure resources deployed to ensure they are unique. For example, `myfvtt`.
- `RESOURCE_GROUP_NAME`: The name of the Azure resource group to create and add the resources to. For example, `myfvtt-rg`.
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

This method will deploy an [Azure Container Instance](https://docs.microsoft.com/en-us/azure/container-instances/container-instances-overview) and attach an Azure Storage account with an SMB share for persistent storage.

It uses the `felddy/foundryvtt:release` container image from Docker Hub. The source and documentation for this container image can be found [here](https://github.com/felddy/foundryvtt-docker). It will use your Foundry VTT username and password to download the Foundry VTT application files and register it with your license key.

The following environment variables should be configured in the workflow to define the region to deploy to and the storage and container configuration:

- `LOCATION`: The Azure region to deploy the resources to. For example, `AustraliaEast`.
- `STORAGE_CONFIGURATION`: The configuration of the Azure Storage SKU to use for storing Foundry VTT user data. Must be one of `Premium_5GB`, `Premium_10GB`, `Premium_20GB`, `Standard_5GB`, `Standard_10GB` or `Standard_20GB`.
- `CONTAINER_CONFIGURATION`: The configuration of the Azure Container Instance for running the Foundry VTT server. Must be one of `Small`, `Medium` or `Large`.

The following GitHub Secrets need to be defined to ensure that resource names for Storage Account and Container DNS are globally unique and provide access to your Azure subscription for deployment:

- `AZURE_CREDENTIALS`: Created as per [this document](https://github.com/marketplace/actions/azure-cli-action#configure-azure-credentials-as-github-secret).
- `BASE_RESOURCE_NAME`: The base name that will prefixed to all Azure resources deployed to ensure they are unique. For example, `myfvtt`.
- `RESOURCE_GROUP_NAME`: The name of the Azure resource group to create and add the resources to. For example, `myfvtt-rg`.
- `FOUNDRY_USERNAME`: Your Foundry VTT username. This is used by the `felddy/foundryvtt:release` container image.
- `FOUNDRY_PASSWORD`: Your Foundry VTT password. This is used by the `felddy/foundryvtt:release` container image.
- `FOUNDRY_ADMIN_KEY`: The admin key to set Foundry VTT up with. This will be the administrator password you log into the Foundry VTT server with.

These values should be kept secret and care taken to ensure they are not shared with anyone.
