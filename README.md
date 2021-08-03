# foundryvtt-azure

Deploy your own [Foundry Virtual Table Top](https://foundryvtt.com/) server (that you've purchased a license for) to Azure using Azure Bicep and GitHub Actions.

The project uses GitHub actions to deploy the resources to Azure using the [GitHub Action Azure CLI task](https://github.com/marketplace/actions/azure-cli-action) and [Azure Bicep](https://aka.ms/Bicep).

This repository will deploy a Foundry Virtual Table top using various different methods to suit your requirements:

- [Azure Container Instances with Azure Files](#azure-container-instances-with-azure-files)
- Azure Container Instances with Azure Files and Azure Front Door - planned
- Azure App Service for Linux Containers and Azure Files - planned
- Azure Kubernetes Service with Azure App Gateway with Ingres controller (AGIC) - planned
- Azure Virtual Machines - not planned as there are other projects that covers this architecture.

> IMPORTANT NOTE: You must have a valid [Foundry VTT license](https://foundryvtt.com/) attached to your account. If you don't have one, you can [buy one here](https://foundryvtt.com/purchase/).

## Azure Container Instances with Azure Files

[![deploy-aci](https://github.com/DsrDemoOrg/foundryvtt-azure/actions/workflows/deploy-aci.yml/badge.svg)](https://github.com/DsrDemoOrg/foundryvtt-azure/actions/workflows/deploy-aci.yml)

This method will deploy an [Azure Container Instance](https://docs.microsoft.com/en-us/azure/container-instances/container-instances-overview) and attach an Azure Storage account with an SMB share for persistent storage.

It uses the `felddy/foundryvtt:release` container image from Docker Hub. The source and documentation for this container image can be found [here](https://github.com/felddy/foundryvtt-docker). It will use your Foundry VTT username and password to download the Foundry VTT application files and register it with your license key.

The workflow for this deployment can be found in [.github\workflows\deploy-aci.yml](.github\workflows\deploy-aci.yml).

The following environment variables should be configured in the workflow to define the region to deploy to and the storage and container configuration:

- `LOCATION`: The Azure region to deploy the resources to. For example, `AustraliaEast`.
- `STORAGE_CONFIGURATION`: The configuration of the Azure Storage SKU to use for storing Foundry VTT user data. Must be one of `Premium_5GB`, `Standard_5GB`, `Standard_10GB` or `Standard_20GB`.
- `CONTAINER_CONFIGURATION`: The configuration of the Azure Container Instance for running the Foundry VTT server. Must be one of `Small`, `Medium` or `Large`.

The following GitHub Secrets need to be defined to ensure that resource names for Storage Account and Container DNS are globally unique and provide access to your Azure subscription for deployment:

- `AZURE_CREDENTIALS`: Created as per [this document](https://github.com/marketplace/actions/azure-cli-action#configure-azure-credentials-as-github-secret).
- `BASE_RESOURCE_NAME`: The base name that will prefixed to all Azure resources deployed to ensure they are unique. For example, `myfvtt`.
- `RESOURCE_GROUP_NAME`: The name of the Azure resource group to create and add the resources to. For example, `myfvtt-rg`.
- `FOUNDRY_USERNAME`: Your Foundry VTT username. This is used by the `felddy/foundryvtt:release` container image.
- `FOUNDRY_PASSWORD`: Your Foundry VTT password. This is used by the `felddy/foundryvtt:release` container image.
- `FOUNDRY_ADMIN_KEY`: The admin key to set Foundry VTT up with. This will be the administrator password you log into the Foundry VTT server with.

These values should be kept secret and care taken to ensure they are not shared with anyone.
