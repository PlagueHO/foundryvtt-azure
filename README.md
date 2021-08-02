# foundryvtt-azure

Deploy your own [Foundry Virtual Table Top](https://foundryvtt.com/) server (that you've purchased a license for) to Azure using Azure Bicep and GitHub Actions.

This repository will deploy a Foundry Virtual Table top using various different methods to suit your requirements:

- [Azure Container Instances with Azure Files](#azure-container-instances-with-azure-files)

## Azure Container Instances with Azure Files

This method will deploy an [Azure Container Instance](https://docs.microsoft.com/en-us/azure/container-instances/container-instances-overview) and attach an Azure Storage account with an SMB share for persistent storage.
