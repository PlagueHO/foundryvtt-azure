# foundryvtt-azure

Deploy your own [Foundry Virtual Table Top](https://foundryvtt.com/) server (that you've purchased a license for) to Azure using Azure Bicep and GitHub Actions.

This repository will deploy a Foundry Virtual Table top using various different methods to suit your requirements:

- [Azure Container Instances with Azure Files](#azure-container-instances-with-azure-files)

> IMPORTANT NOTE: You must have a valid [Foundry VTT license](https://foundryvtt.com/) attached to your account. If you don't have one, you can [buy one here](https://foundryvtt.com/purchase/).

## Azure Container Instances with Azure Files

[![deploy-azure-container-instance](https://github.com/PlagueHO/foundryvtt-azure/actions/workflows/deploy-azure-container-instance.yml/badge.svg)](https://github.com/PlagueHO/foundryvtt-azure/actions/workflows/deploy-azure-container-instance.yml)

This method will deploy an [Azure Container Instance](https://docs.microsoft.com/en-us/azure/container-instances/container-instances-overview) and attach an Azure Storage account with an SMB share for persistent storage.

It uses the `felddy/foundryvtt:release` container image from Docker Hub. The source and documentation for this container image can be found [here](https://github.com/felddy/foundryvtt-docker). It will use your Foundry VTT username and password to download the Foundry VTT application files and register it with your license key.

The workflow for this deployment can be found in [.github\workflows\deploy-azure-container-instance.yml](.github\workflows\deploy-azure-container-instance.yml).

The following environment variables should be configured in the workflow to ensure that resource names for Storage Account and Container DNS are globally unique:

- LOCATION: The Azure region to deploy the resources to. For example, `AustraliaEast`.
- STORAGE_SKU: The Azure Storage SKU to use for storing Foundry VTT user data.
- STORAGE_SHARE_QUOTA: The maximum amount of storage that will be allocated to Foundry VTT user data.
- CONTAINER_CPU: The number of CPU cores to assign to the Foundry VTT container.
- CONTAINER_MEMORY_IN_GB: The amount of memory in GB to assign to the Foundry VTT container.

The following GitHub Secrets need to be defined:

- AZURE_CREDENTIALS: Created as per [this document](https://github.com/marketplace/actions/azure-cli-action#configure-azure-credentials-as-github-secret).
- BASE_RESOURCE_NAME: The base name that will prefixed to all Azure resources deployed to ensure they are unique. For example, `myfvtt`.
- RESOURCE_GROUP_NAME: The name of the Azure resource group to create and add the resources to. For example, `myfvtt-rg`.
- FOUNDRY_USERNAME: Your Foundry VTT username. This is used by the `felddy/foundryvtt:release`
- FOUNDRY_PASSWORD: Your Foundry VTT password. This is used by the `felddy/foundryvtt:release`
- FOUNDRY_ADMIN_KEY: The admin key to set Foundry VTT up with. This will be the administrator password you log into the Foundry VTT server with.

These values should be kept secret and care taken to ensure they are not shared with anyone.
