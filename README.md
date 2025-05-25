# FoundryVTT Azure Solution Accelerator

[![version][version-shield]][version-url]
[![Tests][ct-shield]][ct-url]
[![License][license-shield]][license-url]
[![Azure][azure-shield]][azure-url]
[![IaC][iac-shield]][iac-url]

Deploy your own [Foundry Virtual Table Top](https://foundryvtt.com/) server (with a valid license) to Azure using the [Azure Developer CLI (azd)](https://aka.ms/install-azd) and Bicep.

This solution accelerator provisions a secure, flexible, and updatable Foundry VTT environment in Azure, using best practices for security and well-architected Framework (WAF) where possible and sensible. Although WAF maybe considered overkill for a Foundry VTT deployment, it is included to demonstrate how to deploy a secure solution in Azure and most of it can be disabled using the configuration options if you prefer a simpler deployment.

> [!IMPORTANT]
> Due to the significant structural changes in v2.0.0, it is recommended to delete any previous deployments and start fresh with the latest version of this solution accelerator. This will ensure you have the most up-to-date features and configurations. You will need to take care to preserve any data you wish to keep, such as your Foundry VTT worlds, before deleting the existing deployment. You can back up your existing Foundry VTT data by copying the contents of the Azure Files share to a local machine or another storage account using tools like [Azure Storage Explorer](https://learn.microsoft.com/azure/storage/common/storage-explorer-install) or [AzCopy](https://learn.microsoft.com/azure/storage/common/storage-use-azcopy-v10). You can also deploy the new solution accelerator to a different resource group or Azure subscription and then copy the data across to the new deployment.
>
> If there is use for an upgrade guide to migrate existing deployments to the new structure, please open an issue on the [GitHub repository](https://github.com/PlagueHO/foundryvtt-azure/issues).

---

## Requirements

Before you begin, ensure you have:

1. An active Azure subscription ([Create a free account](https://azure.microsoft.com/free/)).
1. You will need both `Contributor` and `Role Based Access Control Administrator` roles on the Azure subscription you are deploying to.
1. [Azure Developer CLI (azd)](https://aka.ms/install-azd) installed and updated.

---

## Key Features

- **Zero-trust**: Deploys resources into a virtual network with private endpoints and disables public access by default.
- **Azure Verified Modules**: Leverages [Azure Verified Modules](https://aka.ms/avm) for infrastructure.
- **Flexible compute**: Supports Azure Web App (Linux container), Azure Container Instance (lightweight), or future Azure Container Apps.
- **Persistent storage**: Uses Azure Files for Foundry VTT data.
- **Key Vault**: Uses Azure Key Vault to store storage account keys (and soon Foundry secrets).
- **Optional DDB-Proxy**: Deploy [DDB-Proxy](https://github.com/MrPrimate/ddb-proxy) for [DDB-Importer](https://github.com/MrPrimate/ddb-importer) plugin support.
- **Optional Bastion Host**: Deploy Azure Bastion for secure access.
- **Optional Diagnostics**: Deploy Azure Log Analytics and configure resource diagnostics.

---

## Compute Service Options

You can choose which Azure compute service to use for running Foundry VTT by setting the `AZURE_COMPUTE_SERVICE` environment variable before deployment. Supported options:

- **Web App** (default): Deploys Foundry VTT as a Linux container in Azure App Service. This option deploys into a virtual network by default. Recommended for most users.
- **Container Instance**: Deploys Foundry VTT in an Azure Container Instance. Useful for lightweight or temporary workloads. This option does not support deploying into a virtual network.
- **Container Apps**: Not currently supported, but may be added in the future.

Set the compute service using:

```sh
azd env set AZURE_COMPUTE_SERVICE "WebApp" # or "ContainerInstance"
```

### Feature Comparison

| Feature                        | Web App (Default, Recommended)        | Container Instance                             | Container Apps (Future)     |
| ------------------------------ | ------------------------------------- | ---------------------------------------------- | --------------------------- |
| **Description**                | Azure App Service                     | Azure Container Instance                       | Azure Container Apps        |
| **Docker Image**               | `felddy/foundryvtt:release`           | `felddy/foundryvtt:release`                    | `felddy/foundryvtt:release` |  
| **Persistent Data**            | Azure Files                           | Azure Files                                    | Azure Files                 |
| **Storage Account Access**     | Private VNET, Public Optional         | Public Only                                    | TBC                         |
| **DDB-Proxy Support**          | Yes (optional)                        | No                                             | TBC                         |
| **DDB-Proxy Docker Image**     | `ghcr.io/mrprimate/ddb-proxy:release` | N/A                                            | TBC                         |
| **Virtual Network Deployment** | Yes (default, enhances security)      | No                                             | TBC                         |
| **Current Status**             | Operational                           | Limited                                        | TBC                         |
| **URL**                        | https://<env>.azurewebsites.net       | http://<env>.<region>.azurecontainer.io:30000/ | TBC                         |
| **Secrets Stored**             | Azure Key Vault                       | In service                                     | TBC                         |

> [!NOTE]
> The ContainerApps option is not currently available, but should be added in the future. If you are interested in this option, please open an issue on the [GitHub repository](https://github.com/PlagueHO/foundryvtt-azure/issues).

---

## Deploying with Azure Developer CLI

### 1. Clone the repository

```sh
git clone https://github.com/PlagueHO/foundryvtt-azure.git
cd foundryvtt-azure
```

### 2. Authenticate with Azure

```sh
azd auth login
```

### 3. Configure environment variables

Set required and optional parameters using `azd env set`. For example:

```sh
azd env set FOUNDRY_USERNAME "<your-foundry-username>"
azd env set FOUNDRY_PASSWORD "<your-foundry-password>"
azd env set FOUNDRY_ADMIN_KEY "<your-foundry-admin-key>"
azd env set AZURE_ENV_NAME "myuniquefvtt"
azd env set AZURE_LOCATION "EastUS2"
```

> [!NOTE]
> After entering the first `azd env set` command, you will be prompted to **enter a name for your new environment**. This name will be used in resource names and URLs. It should be globally unique across Azure, so choose a name that reflects your Foundry VTT deployment (e.g., `myuniquefvtt`).

**Optional parameters:**

```sh
azd env set AZURE_DEPLOY_NETWORKING "true" # "false" to deploy without a virtual network
azd env set AZURE_STORAGE_CONFIGURATION "Premium_100GB" # or "Standard_100GB"
azd env set AZURE_COMPUTE_SERVICE "WebApp" # or "ContainerInstance"
azd env set AZURE_APP_SERVICE_PLAN_SKUNAME "P0v3" # Only for Web App
azd env set AZURE_CONTAINER_INSTANCE_CPU "2" # Only for Container Instance, from 1 to 4
azd env set AZURE_CONTAINER_INSTANCE_MEMORY_IN_GB "2" # Only for Container Instance, from 1 to 16
azd env set AZURE_DEPLOY_DDB_PROXY "false" # Only for Web App
azd env set AZURE_BASTION_HOST_DEPLOY "false" # Only for Web App and when deploying networking
azd env set AZURE_DEPLOY_DIAGNOSTICS "false"
```

> See [Configuration Options](#configuration-options) for all available variables.

### 4. Provision and deploy

```sh
azd up
```

> [!NOTE]
> The first time you run `azd up`, you will be asked to select an Azure subscription and Azure region you want to deploy the resources into. You should select a subscription that you have `Contributor` and `Role Based Access Control Administrator` roles on. If you enable the `AZURE_STORAGE_RESOURCE_LOCK_ENABLED` setting during deployment then `User Access Administrator` role as well.

This command will provision all Azure resources and deploy Foundry VTT using the parameters you set.

---

## Configuration Options

You can control deployment by setting environment variables before running `azd up`. The main parameters (see `infra/main.bicepparam`) are:

- `FOUNDRY_USERNAME` (required): Your Foundry VTT username.
- `FOUNDRY_PASSWORD` (required): Your Foundry VTT password.
- `FOUNDRY_ADMIN_KEY` (required): The admin key for Foundry VTT.
- `AZURE_ENV_NAME`: Name for the environment (used in resource names).
- `AZURE_LOCATION`: Azure region for deployment.
- `AZURE_PRINCIPAL_ID`: User or service principal ID for role assignments (provided automatically by azd).
- `AZURE_PRINCIPAL_ID_TYPE`: `User` or `ServicePrincipal`.
- `AZURE_DEPLOY_NETWORKING`: `true` or `false` to deploy a virtual network with services added into the network. Default is `true`.
- `AZURE_STORAGE_CONFIGURATION`: `Premium_100GB` or `Standard_100GB`. Default is `Premium_100GB`.
- `AZURE_STORAGE_PUBLIC_ACCESS`: To allow public access to the storage account. Default is `false`.
- `AZURE_STORAGE_RESOURCE_LOCK_ENABLED`: `true` or `false` to apply a `CanNotDelete` lock on the storage account, preventing it from being deleted (e.g. via `azd down`) until the lock is removed. Default: `false`. You will need the `User Access Administrator` role to apply this lock during deployment.
- `AZURE_DEPLOYMENT_TYPE`: `WebApp` or `ContainerInstance`. Default is `WebApp`.
- `AZURE_APP_SERVICE_PLAN_SKUNAME`: App Service SKU (e.g., `P1v2`). Default is `P0v3`.
- `AZURE_CONTAINER_INSTANCE_CPU`: CPU count for Container Instance, from `1` to `4`. Default is `2`.
- `AZURE_CONTAINER_INSTANCE_MEMORY_IN_GB`: Memory (GB) for Container Instance, from `1` to `16`. Default is `2`.
- `AZURE_DEPLOY_DDB_PROXY`: `true` or `false` to deploy DDB-Proxy.
- `AZURE_BASTION_HOST_DEPLOY`: `true` or `false` to deploy Azure Bastion.
- `AZURE_COMPUTE_SERVICE`: `WebApp` or `ContainerInstance` (controls the compute service used for Foundry VTT).
- `AZURE_DEPLOY_DIAGNOSTICS`: `true` or `false` to deploy a Log Analytics workspace and send resource diagnostics to it. Default is `false`.

For a full list, see the [infra/main.bicepparam](infra/main.bicepparam) file.

---

## Outputs

After deployment, `azd up` will output the URL to your Foundry VTT server:

```plaintext
Deployment complete!
The URL for accessing your Foundry VTT deployment is: https://<environment_name>.azurewebsites.net/
```

![Completed Deployment](/docs/images/deployment-complete.png)

---

## Next Steps

- Access your Foundry VTT server using the output URL.
- If you enabled DDB-Proxy, configure your Foundry VTT DDB-Importer plugin to use the proxy URL. See the [DDB-Proxy section](#ddb-proxy) below for details.
- If you enabled Bastion, use Azure Bastion for secure access to private resources.

---

### DDB-Proxy

The workflow will also optionally deploy a [DDB-Proxy](https://github.com/MrPrimate/ddb-proxy) into the App Service Plan for use with the awesome [DDB-Importer](https://github.com/MrPrimate/ddb-importer) plugin for Foundry VTT.

- `DEPLOY_DDBPROXY`: Setting this variable to true will deploy a DDB-Proxy into the same App Service Plan as the Foundry VTT server, but on a different URL.

Once you have deployed a DDB-Proxy into your App Service Plan you will be able to configure your Foundry VTT to use it by running the following commands in your browsers developer console:

```javascript
game.settings.set("ddb-importer", "custom-proxy", true);
game.settings.set("ddb-importer", "api-endpoint", "https://<BASE_RESOURCE_NAME>ddbproxy.azurewebsites.net");
```

For more information on how to use the DDB-Proxy with Foundry VTT, please see the [DDB-Proxy documentation](https://github.com/MrPrimate/ddb-proxy).

---

## Architecture

The following table summarizes which Azure resources are deployed for each compute service option:

| Resource                                             | Web App (Default, Recommended) | Container Instance           |
|------------------------------------------------------|--------------------------------|------------------------------|
| **Azure Resource Group**                             | ✔️                             | ✔️                          |
| **Virtual Network**                                  | ✔️ (default)                   | Not supported                |
| **Azure Storage Account (Azure Files)**              | ✔️                             | ✔️                          |
| **Azure Key Vault**                                  | ✔️                             | ✔️ (not used)               |
| **Azure Web App (Foundry VTT container)**            | ✔️                             | N/A                          |
| **Azure Web App (DDB-Proxy)**                        | ✔️ (optional)                  | N/A                          |
| **Azure Container Instance (Foundry VTT container)** | N/A                            | ✔️                           |
| **Azure Container Instance (DDB-Proxy)**             | N/A                            | Not supported                |
| **Azure Bastion**                                    | Optional                       | Not supported                |
| **Azure Log Analytics Workspace**                    | Optional                       | Optional                     |

> [!NOTE]
> [Soft-delete](https://learn.microsoft.com/azure/key-vault/general/soft-delete-overview) is not enabled for the Key Vault by default as it doesn't contain any secrets that can't be easily recreated by redeploying the solution.

---

## Deleting the Deployment

To delete all resources created by this deployment:

```sh
azd down
```

> [!NOTE]
> If you have enabled the `AZURE_STORAGE_RESOURCE_LOCK_ENABLED` variable, you will need to remove the lock on the Storage Account before running `azd down` as well as the lock on the private endpoint resource for the Storage Account. For more information on how to remove the lock, see [Lock your Azure resources to protect your infrastructure](https://learn.microsoft.com/azure/azure-resource-manager/management/lock-resources).

Some resources will be marked as deleted, but you will need to purge them before they can be redeployed (for example, Azure Key Vault), use:

```sh
azd down --purge
```

---

## Deploy with GitHub Actions

You can also deploy this solution using GitHub Actions for automated CI/CD. This approach is useful for production deployments.

### 1. Add an Environment in GitHub

[Create a new environment in your GitHub repository](https://docs.github.com/actions/managing-workflow-runs-and-deployments/managing-deployments/managing-environments-for-deployment#creating-an-environment) called `Production` (or any name you prefer). This environment will be used to manage secrets and variables for the deployment.

### 2. Configure GitHub Secrets and Variables

Set the following repository **secrets** in the new GitHub environment:

- `AZURE_CLIENT_ID`: The Application (Client) ID of the Service Principal or Workload Identity used to authenticate to Azure.
- `AZURE_TENANT_ID`: The Tenant ID of the Service Principal or Workload Identity.
- `AZURE_SUBSCRIPTION_ID`: The Subscription ID of the Azure Subscription to deploy to.
- `FOUNDRY_USERNAME`: Your Foundry VTT username.
- `FOUNDRY_PASSWORD`: Your Foundry VTT password.
- `FOUNDRY_ADMIN_KEY`: The admin key for Foundry VTT.

Set the following repository **variables** as needed:

- `AZURE_ENV_NAME`, `AZURE_LOCATION`, `AZURE_COMPUTE_SERVICE`, etc. (see [Configuration Options](#configuration-options)).

### 3. Configure Workload Identity Federation

To securely authenticate your GitHub Actions workflow to Azure, configure [Workload Identity Federation](https://learn.microsoft.com/azure/active-directory/develop/workload-identity-federation):

1. Create an Azure AD Application and Federated Credential for your GitHub repository:

    ```powershell
    $credentialname = '<The name to use for the credential & app>' # e.g., github-foundryvtt-workflow-production-environment
    $application = New-AzADApplication -DisplayName $credentialname
    $policy = "repo:<your GitHub user>/<your GitHub repo>:environment:<Production or your environment name>"
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
      -Description "The GitHub Actions deployment workflow for Foundry VTT."
    ```

    For more details, see [Microsoft Learn: Authenticate Azure deployment workflow using workload identities](https://learn.microsoft.com/training/modules/authenticate-azure-deployment-workflow-workload-identities).

### 4. Example GitHub Actions Workflow

Sample workflow files:

- [.github/workflows/deploy-production.yml](.github/workflows/deploy-production.yml)
- [.github/workflows/deploy-infrastructure.yml](.github/workflows/deploy-infrastructure.yml)

The deploy-production.yml workflow just calls the deploy-infrastructure.yml workflow to deploy the Foundry VTT solution.

The deploy-infrastructure.yml workflow performs the following steps:

1. Load the configuration options from the GitHub Actions environment variables.
1. Authenticate to Azure using workload identity.
1. Run `azd up` to provision and deploy the solution.

### 5. Complete

Once you have configured the GitHub Actions workflow, you can trigger it manually.

---

## Contributing

Contributions are welcome! Please open issues or pull requests.

---

## License

[MIT](LICENSE)

---

<!-- Badge reference links -->
[ct-shield]: https://img.shields.io/github/actions/workflow/status/PlagueHO/foundryvtt-azure/continuous-testing.yml?branch=main&label=Tests
[ct-url]: https://github.com/PlagueHO/foundryvtt-azure/actions/workflows/continuous-testing.yml

[license-shield]: https://img.shields.io/github/license/PlagueHO/foundryvtt-azure
[license-url]: https://github.com/PlagueHO/foundryvtt-azure/blob/main/LICENSE

[azure-shield]: https://img.shields.io/badge/Azure-Solution%20Accelerator-0078D4?logo=microsoftazure&logoColor=white
[azure-url]: https://azure.microsoft.com/

[iac-shield]: https://img.shields.io/badge/Infrastructure%20as%20Code-Bicep-5C2D91?logo=azurepipelines&logoColor=white
[iac-url]: https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/overview

[version-shield]: https://img.shields.io/badge/version-v2.0.0-blue
[version-url]: https://github.com/PlagueHO/foundryvtt-azure/releases/tag/v2.0.0
