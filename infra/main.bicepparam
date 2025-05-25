using './main.bicep'

// General configuration provided by Azure Developer CLI
param environmentName = readEnvironmentVariable('AZURE_ENV_NAME', 'azdtemp')
param location = readEnvironmentVariable('AZURE_LOCATION', 'EastUS2')
param resourceGroupName = readEnvironmentVariable('AZURE_RESOURCE_GROUP', 'rg-${environmentName}')

// User or service principal deploying the resources
param principalId = readEnvironmentVariable('AZURE_PRINCIPAL_ID', '')
param principalIdType = toLower(readEnvironmentVariable('AZURE_PRINCIPAL_ID_TYPE', 'user')) == 'serviceprincipal' ? 'ServicePrincipal' : 'User'

// Foundry Parameters
param foundryUsername = readEnvironmentVariable('FOUNDRY_USERNAME', '')
param foundryPassword = readEnvironmentVariable('FOUNDRY_PASSWORD', '')
param foundryAdminKey = readEnvironmentVariable('FOUNDRY_ADMIN_KEY', '')

// Network Isolation
param deployNetworking = toLower(readEnvironmentVariable('DEPLOY_NETWORKING', 'true')) == 'true' ? true : false

// Deploy Log Analytics and Diagnostics
param deployDiagnostics = toLower(readEnvironmentVariable('AZURE_DEPLOY_DIAGNOSTICS', 'false')) == 'true' ? true : false

// Optional parameters
param storageConfiguration = readEnvironmentVariable('AZURE_STORAGE_CONFIGURATION', 'Premium_100GB')
param storagePublicAccess = toLower(readEnvironmentVariable('AZURE_STORAGE_PUBLIC_ACCESS', 'false')) == 'true' ? true : false
param computeService = readEnvironmentVariable('AZURE_COMPUTE_SERVICE', 'Web App')

// Lock storage account to prevent accidental deletion
param storageResourceLockEnabled = toLower(readEnvironmentVariable('AZURE_STORAGE_RESOURCE_LOCK_ENABLED', 'false')) == 'true' ? true : false

// App Service Plan Parameters (required when ComputeService is set to Web App)
param appServicePlanSkuName = readEnvironmentVariable('AZURE_APP_SERVICE_PLAN_SKUNAME', 'P0v3')

// Container Instance Parameters (required when ComputeService is set to ContainerInstance)
param containerInstanceCpu = int(readEnvironmentVariable('AZURE_CONTAINER_INSTANCE_CPU', '2'))
param containerInstanceMemoryInGB = readEnvironmentVariable('AZURE_CONTAINER_INSTANCE_MEMORY_IN_GB', '2')

// Azure Contaier Apps Parameters (required when ComputeService is set to ContainerApps)
// TBC

// Deploy a DDB Proxy
param deployDdbProxy = toLower(readEnvironmentVariable('AZURE_DEPLOY_DDB_PROXY', 'false')) == 'true' ? true : false

// Deploy a Bastion Host into the Virtual Network
param bastionHostDeploy = toLower(readEnvironmentVariable('AZURE_BASTION_HOST_DEPLOY', 'false')) == 'true' ? true : false
