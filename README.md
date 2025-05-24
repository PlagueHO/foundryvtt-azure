# FoundryVTT Azure Solution Accelerator

[![deploy-foundryvtt](https://github.com/PlagueHO/foundryvtt-azure/actions/workflows/deploy-foundryvtt.yml/badge.svg)](https://github.com/PlagueHO/foundryvtt-azure/actions/workflows/deploy-foundryvtt.yml)
[![CD][cd-shield]][cd-url]
[![License][license-shield]][license-url]
[![Azure][azure-shield]][azure-url]
[![IaC][iac-shield]][iac-url]

Deploy your own [Foundry Virtual Table Top](https://foundryvtt.com/) server (with a valid license) to Azure using the [Azure Developer CLI (azd)](https://aka.ms/install-azd) and Bicep.

This solution accelerator provisions a secure, flexible, and updatable Foundry VTT environment in Azure, using best practices for resource isolation, managed identities, and persistent storage.

---

## Requirements

Before you begin, ensure you have:

1. An active Azure subscription ([Create a free account](https://azure.microsoft.com/free/)).
2. [Azure Developer CLI (azd)](https://aka.ms/install-azd) installed and updated.
3. **Windows Only:** [PowerShell](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows) (for local development).
4. (Recommended) [Python 3.10+](https://www.python.org/downloads/) for sample tools.

---

## Key Features

- **Zero-trust**: Deploys resources into a virtual network with private endpoints and disables public access by default.
- **Managed identities**: Uses managed identities for secure resource authentication.
- **Azure Verified Modules**: Leverages [Azure Verified Modules](https://aka.ms/avm) for infrastructure.
- **Flexible compute**: Supports Azure Web App (Linux container) or Azure Container Instance.
- **Persistent storage**: Uses Azure Files for Foundry VTT data.
- **Optional DDB-Proxy**: Deploy [DDB-Proxy](https://github.com/MrPrimate/ddb-proxy) for [DDB-Importer](https://github.com/MrPrimate/ddb-importer) plugin support.
- **Optional Bastion Host**: Deploy Azure Bastion for secure access.

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

| Feature                        | Web App (Default)                     | Container Instance               | Container Apps (Future)     |
| ------------------------------ | --------------------------------------| -------------------------------- | --------------------------- |
| **Description**                | Azure App Service                     | Azure Container Instance         | Azure Container Apps        |
| **Docker Image**               | `felddy/foundryvtt:release`           | `felddy/foundryvtt:release`      | `felddy/foundryvtt:release` |  
| **Persistent Data**            | Azure Files                           | Azure Files                      | Azure Files                 |
| **Storage Account Access**     | Private VNET, Public Optional         | Public Only                      | TBC                         |
| **DDB-Proxy Support**          | Yes (optional)                        | No                               | TBC                         |
| **DDB-Proxy Docker Image**     | `ghcr.io/mrprimate/ddb-proxy:release` | N/A                              | TBC                         |
| **Virtual Network Deployment** | Yes (default, enhances security)      | No                               | TBC                         |
| **Current Status**             | Operational                           | Limited                          | TBC                         |

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
azd env set AZURE_ENV_NAME "myfoundryenv"
azd env set AZURE_LOCATION "EastUS2"
```

**Optional parameters:**

```sh
azd env set DEPLOY_NETWORK "true" # "false" to deploy without a virtual network
azd env set AZURE_STORAGE_CONFIGURATION "Premium_100GB" # or "Standard_100GB"
azd env set AZURE_COMPUTE_SERVICE "WebApp" # or "ContainerInstance"
azd env set AZURE_APP_SERVICE_PLAN_SKUNAME "P0v3"
azd env set AZURE_CONTAINER_INSTANCE_CPU "2"
azd env set AZURE_CONTAINER_INSTANCE_MEMORY_IN_GB "2"
azd env set AZURE_DEPLOY_DDB_PROXY "false"
azd env set AZURE_BASTION_HOST_DEPLOY "false"
```

> See [Configuration Options](#configuration-options) for all available variables.

### 4. Provision and deploy

```sh
azd up
```

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
- `DEPLOY_NETWORK`: `true` or `false` to deploy a virtual network with services added into the network. Default is `true`.
- `AZURE_STORAGE_CONFIGURATION`: `Premium_100GB` or `Standard_100GB`. Default is `Premium_100GB`.
- `AZURE_STORAGE_PUBLIC_ACCESS`: To allow public access to the storage account. Default is `false`.
- `AZURE_DEPLOYMENT_TYPE`: `WebApp` or `ContainerInstance`. Default is `WebApp`.
- `AZURE_APP_SERVICE_PLAN_SKUNAME`: App Service SKU (e.g., `P1v2`). Default is `P0v3`.
- `AZURE_CONTAINER_INSTANCE_CPU`: CPU count for Container Instance, from `1` to `4`. Default is `2`.
- `AZURE_CONTAINER_INSTANCE_MEMORY_IN_GB`: Memory (GB) for Container Instance, from `1` to `16`. Default is `2`.
- `AZURE_DEPLOY_DDB_PROXY`: `true` or `false` to deploy DDB-Proxy.
- `AZURE_BASTION_HOST_DEPLOY`: `true` or `false` to deploy Azure Bastion.
- `AZURE_COMPUTE_SERVICE`: `WebApp` or `ContainerInstance` (controls the compute service used for Foundry VTT).

For a full list, see the [infra/main.bicepparam](infra/main.bicepparam) file.

---

## Outputs

After deployment, `azd up` will output resource URLs and connection info, including:

- Foundry VTT Web App URL
- DDB-Proxy URL (if enabled)
- Resource group name
- Bastion Host info (if enabled)

---

## Next Steps

- Access your Foundry VTT server using the output URL.
- If you enabled DDB-Proxy, configure your Foundry VTT DDB-Importer plugin as described in the [DDB-Proxy documentation](https://github.com/MrPrimate/ddb-proxy).
- If you enabled Bastion, use Azure Bastion for secure access to private resources.

---

## Architecture

The solution deploys:

- Azure Resource Group
- Virtual Network with subnets for storage, web app, container group, and Bastion
- Azure Storage Account (Azure Files)
- Azure Web App (Linux container) or Azure Container Instance
- (Optional) DDB-Proxy container
- (Optional) Azure Bastion

---

## Deleting the Deployment

To delete all resources created by this deployment:

```sh
azd down
```

---

## Contributing

Contributions are welcome! Please open issues or pull requests.

---

## License

[MIT](LICENSE)

---

## GitHub Actions

You can also deploy this solution using GitHub Actions for automated CI/CD. This approach is useful for team-based or production deployments.

### 1. Configure GitHub Secrets and Variables

Set the following repository **secrets** in your GitHub repository:

- `AZURE_CLIENT_ID`: The Application (Client) ID of the Service Principal or Workload Identity used to authenticate to Azure.
- `AZURE_TENANT_ID`: The Tenant ID of the Service Principal or Workload Identity.
- `AZURE_SUBSCRIPTION_ID`: The Subscription ID of the Azure Subscription to deploy to.
- `FOUNDRY_USERNAME`: Your Foundry VTT username.
- `FOUNDRY_PASSWORD`: Your Foundry VTT password.
- `FOUNDRY_ADMIN_KEY`: The admin key for Foundry VTT.

Set the following repository **variables** as needed:

- `AZURE_ENV_NAME`, `AZURE_LOCATION`, `AZURE_COMPUTE_SERVICE`, etc. (see [Configuration Options](#configuration-options)).

### 2. Configure Workload Identity Federation

To securely authenticate your GitHub Actions workflow to Azure, configure [Workload Identity Federation](https://learn.microsoft.com/azure/active-directory/develop/workload-identity-federation):

1. Create an Azure AD Application and Federated Credential for your GitHub repository:

   ```powershell
   $credentialname = '<The name to use for the credential & app>' # e.g., github-foundryvtt-workflow
   $application = New-AzADApplication -DisplayName $credentialname
   $policy = "repo:<your GitHub user>/<your GitHub repo>:ref:refs/heads/main"
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

### 3. Example GitHub Actions Workflow

A sample workflow file (`.github/workflows/deploy-foundryvtt.yml`) should:

- Authenticate to Azure using workload identity.
- Run `azd up` to provision and deploy the solution.
- Use the secrets and variables as environment variables.

Example snippet:

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read
    steps:
      - uses: actions/checkout@v4
      - uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
          enable-AzPSSession: false

      - name: Set up Azure Developer CLI
        uses: Azure/setup-azd@v1

      - name: Set environment variables
        run: |
          azd env set FOUNDRY_USERNAME "${{ secrets.FOUNDRY_USERNAME }}"
          azd env set FOUNDRY_PASSWORD "${{ secrets.FOUNDRY_PASSWORD }}"
          azd env set FOUNDRY_ADMIN_KEY "${{ secrets.FOUNDRY_ADMIN_KEY }}"
          # Set other variables as needed

      - name: Deploy Foundry VTT
        run: azd up --no-prompt
```

---

<!-- Badge reference links -->
[cd-shield]: https://img.shields.io/github/actions/workflow/status/PlagueHO/foundryvtt-azure/continuous-delivery.yml?branch=main&label=CD
[cd-url]: https://github.com/PlagueHO/foundryvtt-azure/actions/workflows/continuous-delivery.yml

[license-shield]: https://img.shields.io/github/license/PlagueHO/foundryvtt-azure
[license-url]: https://github.com/PlagueHO/foundryvtt-azure/blob/main/LICENSE

[azure-shield]: https://img.shields.io/badge/Azure-Solution%20Accelerator-0078D4?logo=microsoftazure&logoColor=white
[azure-url]: https://azure.microsoft.com/

[iac-shield]: https://img.shields.io/badge/Infrastructure%20as%20Code-Bicep-5C2D91?logo=azurepipelines&logoColor=white
[iac-url]: https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/overview
[iac-shield]: https://img.shields.io/badge/Infrastructure%20as%20Code-Bicep-5C2D91?logo=azurepipelines&logoColor=white
[iac-url]: https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/overview
