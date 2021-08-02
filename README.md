# foundryvtt-azure

Deploy your own [Foundry Virtual Table Top](https://foundryvtt.com/) server (that you've purchased a license for) to Azure using Azure Bicep and GitHub Actions.

This repository will deploy a Foundry Virtual Table top using various different methods to suit your requirements:

- [Azure Container Instances with Azure Files](#azure-container-instances-with-azure-files)

## Azure Container Instances with Azure Files

[![deploy-azure-container-instance](https://github.com/PlagueHO/foundryvtt-azure/actions/workflows/deploy-azure-container-instance.yml/badge.svg)](https://github.com/PlagueHO/foundryvtt-azure/actions/workflows/deploy-azure-container-instance.yml)

This method will deploy an [Azure Container Instance](https://docs.microsoft.com/en-us/azure/container-instances/container-instances-overview) and attach an Azure Storage account with an SMB share for persistent storage.

The workflow for this deployment can be found in [.github\workflows\deploy-azure-container-instance.yml](.github\workflows\deploy-azure-container-instance.yml).

The following environment variables should be configured to your preference and to ensure that resource names for Storage Account and Container DNS are globally unique:

- LOCATION: AustraliaEast
- BASE_RESOURCE_NAME: dsrfoundryvtt
- RESOURCE_GROUP_NAME: dsr-foundryvtt-rg

The following GitHub Secrets need to be defined:

- AZURE_CREDENTIALS: Created as per [this document](https://github.com/marketplace/actions/azure-cli-action#configure-azure-credentials-as-github-secret).
- FOUNDRY_USERNAME: Your Foundry VTT username.
- FOUNDRY_PASSWORD: Your Foundry VTT password.
- FOUNDRY_ADMIN_KEY: The admin key to set Foundry VTT up with.
