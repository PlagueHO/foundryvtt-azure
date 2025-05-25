targetScope = 'subscription'

// General configuration provided by Azure Developer CLI
@sys.description('Name of the the environment which is used to generate a short unique hash used in all resources')
@minLength(1)
@maxLength(64)
param environmentName string

@sys.description('Location for all resources')
@minLength(1)
@metadata({
  azd: {
    type: 'location'
  }
})
param location string

// User or service principal deploying the resources
@sys.description('Id of the user or app to assign application roles.')
param principalId string

@sys.description('Type of the principal referenced by principalId.')
@allowed([
  'User'
  'ServicePrincipal'
])
param principalIdType string = 'User'

@sys.description('The Azure resource group where new resources will be deployed.')
@metadata({
  azd: {
    type: 'resourceGroup'
  }
})
param resourceGroupName string = 'rg-${environmentName}'

// Configuration for the Foundry VTT server - Required
@sys.description('Your Foundry VTT username.')
@secure()
param foundryUsername string

@sys.description('Your Foundry VTT password.')
@secure()
param foundryPassword string

@sys.description('The admin key to set Foundry VTT up with.')
@secure()
param foundryAdminKey string

// Networking configuration

@sys.description('Deploy a Virtual Network for network isolation. This may be required for some enviornments.')
param deployNetworking bool = true

// Storage Account configuration
@sys.description('The configuration of the Azure Storage SKU to use for storing Foundry VTT user data.')
@allowed([
  'Premium_100GB'
  'Standard_100GB'
])
param storageConfiguration string = 'Premium_100GB'

@sys.description('Enable public access to the Azure Storage Account. This is not recommended for production environments.')
param storagePublicAccess bool = false

@sys.description('Lock the storage account to prevent deletion. Must be removed before azd down.')
param storageResourceLockEnabled bool = false

// Compute Service configuration
@sys.description('The compute service to use for deploying Foundry VTT.')
@allowed([
  'Web App'
  'Container Instance'
  // 'Container App' - not supported yet
])
param computeService string = 'Web App'

// App Service Plan Parameters (required when ComputeService is set to Web App)
@sys.description('The Azure App Service SKU for running the Foundry VTT server and optionally the DDB-Proxy. Only used when deploying into an Azure Web App.')
@allowed([
  'F1'
  'B1'
  'B2'
  'B3'
  'P1v2'
  'P2v2'
  'P3v2'
  'P0v3'
  'P1v3'
  'P2v3'
  'P3v3'
  'P0v4'
  'P1v4'
  'P2v4'
  'P3v4'
])
param appServicePlanSkuName string = 'P0v3'

// Container Instance Parameters (required when ComputeService is set to Container Instance)
@description('The CPUs to assign to the Azure Container Instance for running the Foundry VTT server. Only used when deploying into an Azure Container Instance.')
@minValue(1)
@maxValue(4)
param containerInstanceCpu int = 2

@description('The Memory in GB to assign to the Azure Container Instance for running the Foundry VTT server. Only used when deploying into an Azure Container Instance.')
// Allowed values are 0.5 increments from 1 to 16
@allowed(['1', '1.5', '2', '2.5', '3', '3.5', '4', '4.5', '5', '5.5', '6', '6.5', '7', '7.5', '8', '8.5', '9', '9.5', '10', '10.5', '11', '11.5', '12', '12.5', '13', '13.5', '14', '14.5', '15', '15.5', '16'])
param containerInstanceMemoryInGB string = '2'

// Azure Contaier Apps Parameters (required when ComputeService is set to ContainerApps)
// TBC

// Deploy a DDB Proxy
@sys.description('Deploy a D&D Beyond proxy into the app service plan.')
param deployDdbProxy bool = false

// Deploy a Bastion Host into the Virtual Network
@sys.description('Deploy a Bastion host into the VNET.')
param bastionHostDeploy bool = false

@sys.description('Deploy Azure Log Analytics and configure diagnostics for resources. Default is false.')
param deployDiagnostics bool = false

// tags that should be applied to all resources.
var tags = {
  'azd-env-name': environmentName
}

// Load the abbreviations from the JSON file
var abbrs = loadJsonContent('./abbreviations.json')

// Resource names
var virtualNetworkName string = '${abbrs.networkVirtualNetworks}${environmentName}'
var storageAccountName string = take(toLower(replace(environmentName, '-', '')),24)
var appServicePlanName string = take('${abbrs.webSitesAppService}${environmentName}',60)
var webAppFoundryVttName string = environmentName
var webAppDdbProxyName string = '${environmentName}ddbproxy'
var containerInstanceFoundryVttName string = '${abbrs.containerInstanceContainerGroups}${environmentName}'
var bastionHostName string = '${abbrs.networkBastionHosts}${environmentName}'
var keyVaultPrivateDnsZoneName = 'privatelink.vaultcore.azure.net'
var logAnalyticsWorkspaceName = take('${abbrs.operationalInsightsWorkspaces}${environmentName}', 63)

// Key Vault Configuration
var keyVaultName = take('kv${replace(environmentName, '-', '')}', 24)
var storageAccountKeySecretName = 'storageAccountKey'
var foundryUsernameSecretName   = 'foundryUsername'
var foundryPasswordSecretName   = 'foundryPassword'
var foundryAdminKeySecretName   = 'foundryAdminKey'

// Docker image names and tags
var foundryVttDockerImageName string = 'felddy/foundryvtt'
var foundryVttDockerImageTag string = 'release'
var ddbProxyDockerImageName string = 'ghcr.io/mrprimate/ddb-proxy'
var ddbProxyDockerImageTag string = 'latest'

// Log Analytics configuration
var sendToLogAnalyticsName = 'send-to-loganalytics-${environmentName}'
var sendToLogAnalytics = deployDiagnostics ? [
  {
    name: sendToLogAnalyticsName
    workspaceResourceId: logAnalyticsWorkspace.outputs.resourceId
    logCategoriesAndGroups: [
      {
        categoryGroup: 'allLogs'
      }
    ]
    metricCategories: []
  }
] : []

var effectiveDeployNetworking = deployNetworking && computeService == 'Web App' // Only deploy networking if using Web App

// ---------- RESOURCE GROUP ----------
resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: !empty(resourceGroupName) ? resourceGroupName : 'rg-${environmentName}'
  location: location
  tags: tags
}

// ------------- LOG ANALYTICS WORKSPACE (OPTIONAL) -------------
module logAnalyticsWorkspace 'br/public:avm/res/operational-insights/workspace:0.11.2' = if (deployDiagnostics) {
  name: 'log-analytics-workspace-deployment'
  scope: rg
  params: {
    name: logAnalyticsWorkspaceName
    location: location
    tags: tags
  }
}

// ---------- NETWORKING ----------
var subnets = [
  {
    // Default subnet (generally not used)
    name: 'default'
    addressPrefix: '10.0.0.0/24'
  }
  {
    // Storage Subnet (Storage Account private endpoints)
    name: 'storage'
    addressPrefix: '10.0.1.0/24'
    privateEndpointNetworkPolicies: 'Disabled'
    networkSecurityGroupResourceId: effectiveDeployNetworking ? networkSecurityGroupStorage.outputs.resourceId : null
  }
  {
    // Key Vault Subnet (Key Vault private endpoints)
    name: 'keyVault'
    addressPrefix: '10.0.2.0/24'
    privateEndpointNetworkPolicies: 'Disabled'
    networkSecurityGroupResourceId: effectiveDeployNetworking ? networkSecurityGroupKeyVault.outputs.resourceId : null
  }
  {
    // Web App Subnet (App Service private endpoints)
    // Only used when deploying into an Azure Web App with networking
    name: 'webApp'
    addressPrefix: '10.0.3.0/24'
    delegation: 'Microsoft.Web/serverFarms'
    networkSecurityGroupResourceId: effectiveDeployNetworking ? networkSecurityGroupWebApp.outputs.resourceId : null
  }
  {
    // Azure Bastion Subnet (Bastion Host)
    // Only used when deploying an Azure Bastion Host with networking
    name: 'AzureBastionSubnet'
    addressPrefix: '10.0.10.0/27'
  }
]

module networkSecurityGroupWebApp 'br/public:avm/res/network/network-security-group:0.5.1' = if (effectiveDeployNetworking) {
  name: 'network-security-group-web-app-deployment'
  scope: rg
  params: {
    name: take('${abbrs.networkNetworkSecurityGroups}${environmentName}-webApp' ,60)
    location: location
    securityRules: []
    tags: tags
  }
}

module networkSecurityGroupStorage 'br/public:avm/res/network/network-security-group:0.5.1' = if (effectiveDeployNetworking) {
  name: 'network-security-group-storage-deployment'
  scope: rg
  params: {
    name: take('${abbrs.networkNetworkSecurityGroups}${environmentName}-storage' ,60)
    location: location
    securityRules: []
    tags: tags
  }
}

module networkSecurityGroupKeyVault 'br/public:avm/res/network/network-security-group:0.5.1' = if (effectiveDeployNetworking) {
  name: 'network-security-group-keyvault-deployment'
  scope: rg
  params: {
    name: take('${abbrs.networkNetworkSecurityGroups}${environmentName}-keyvault', 60)
    location: location
    securityRules: []
    tags: tags
  }
}

module virtualNetwork 'br/public:avm/res/network/virtual-network:0.6.1' = if (effectiveDeployNetworking) {
  name: 'virtualNetwork'
  scope: rg
  params: {
    name: virtualNetworkName
    location: location
    addressPrefixes: [
      '10.0.0.0/16'
    ]
    subnets: subnets
    tags: tags
  }
}

// ---------- PRIVATE DNS ZONES (REQUIRED FOR NETWORK ISOLATION) ----------
module storageFilePrivateDnsZone 'br/public:avm/res/network/private-dns-zone:0.7.1' = if (effectiveDeployNetworking) {
  name: 'storage-file-private-dns-zone'
  scope: rg
  params: {
    name: 'privatelink.file.${environment().suffixes.storage}'
    location: 'global'
    virtualNetworkLinks: [
      {
        virtualNetworkResourceId: virtualNetwork.outputs.resourceId
        registrationEnabled: false
      }
    ]
    tags: tags
  }
}

module keyVaultPrivateDnsZone 'br/public:avm/res/network/private-dns-zone:0.7.1' = if (effectiveDeployNetworking) {
  name: 'keyvault-private-dns-zone'
  scope: rg
  params: {
    name: keyVaultPrivateDnsZoneName
    location: 'global'
    virtualNetworkLinks: [
      {
        virtualNetworkResourceId: virtualNetwork.outputs.resourceId
        registrationEnabled: false
      }
    ]
    tags: tags
  }
}

// ----------- STORAGE ACCOUNT -----------
var storageConfigurationMap = {
  Premium_100GB: {
    kind: 'FileStorage'
    sku: 'Premium_LRS'
    shareQuota: 100
  }
  Standard_100GB: {
    kind: 'StorageV2'
    sku: 'Standard_LRS'
    shareQuota: 100
  }
}
var endpoints = effectiveDeployNetworking ? [
  {
    name: 'file'
    privateEndpointConnections: [
      {
        privateLinkServiceConnectionState: {
          status: 'Approved'
          description: 'Approved by Bicep template'
        }
      }
    ]
  }
] : []

var privateEndpoints = effectiveDeployNetworking ? [
  {
    privateDnsZoneGroup: {
      name: 'default' // Name for the Private DNS Zone Group
      privateDnsZoneGroupConfigs: [
        {
          name: 'storagefiledns' // Name for this specific DNS zone config
          privateDnsZoneResourceId: storageFilePrivateDnsZone.outputs.resourceId
        }
      ]
    }
    service: 'file'
    subnetResourceId: virtualNetwork.outputs.subnetResourceIds[1] // Storage Subnet
    tags: tags
  }
] : []

module storageAccount 'br/public:avm/res/storage/storage-account:0.19.0' = {
  name: 'storage-account-deployment'
  scope: rg
  params: {
    name: storageAccountName
    diagnosticSettings: deployDiagnostics ? sendToLogAnalytics : []
    enableHierarchicalNamespace: false
    enableNfsV3: false
    enableSftp: false
    fileServices: {
      shares: [
        {
          name: 'foundryvttdata'
          shareQuota: storageConfigurationMap[storageConfiguration].shareQuota
        }
      ]
      endpoints: endpoints
    }
    kind: storageConfigurationMap[storageConfiguration].kind
    largeFileSharesState: 'Enabled'
    location: location
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
    privateEndpoints: privateEndpoints
    publicNetworkAccess: storagePublicAccess || ! effectiveDeployNetworking ? 'Enabled' : 'Disabled'
    requireInfrastructureEncryption: false
    sasExpirationPeriod: '180.00:00:00'
    skuName: storageConfigurationMap[storageConfiguration].sku
    tags: tags
    lock: storageResourceLockEnabled ? {
      kind: 'CanNotDelete'
      name: '${storageAccountName}-delete-lock'
    } : null
  }
}

// This is required to reference to allow the Key Vault to get the storage account key
resource storageAccountReference 'Microsoft.Storage/storageAccounts@2021-04-01' existing = {
  name: storageAccountName
  scope: rg
  dependsOn: [
    storageAccount
  ]
}

// ------------- KEY VAULT -------------
module keyVault 'br/public:avm/res/key-vault/vault:0.12.1' = {
  name: 'key-vault-deployment'
  scope: rg
  dependsOn: [
    storageAccountReference
  ]
  params: {
    name: keyVaultName
    location: location
    tags: tags
    sku: 'standard'
    diagnosticSettings: deployDiagnostics ? sendToLogAnalytics : []
    enablePurgeProtection: false
    enableRbacAuthorization: true
    secrets: [
      {
        name: storageAccountKeySecretName
        value: storageAccountReference.listKeys('2024-01-01').keys[0].value
      }
      {
        name: foundryUsernameSecretName
        value: foundryUsername
      }
      {
        name: foundryPasswordSecretName
        value: foundryPassword
      }
      {
        name: foundryAdminKeySecretName
        value: foundryAdminKey
      }
    ]
    networkAcls: { // Restrict public access if VNet deployed, otherwise allow (as PEs won't exist)
      defaultAction: effectiveDeployNetworking ? 'Deny' : 'Allow'
      bypass: 'AzureServices'
    }
    privateEndpoints: effectiveDeployNetworking ? [
      {
        subnetResourceId: virtualNetwork.outputs.subnetResourceIds[2] // Key Vault Subnet
        service: 'vault' // Sub-resource for Key Vault
        privateDnsZoneGroup: {
          name: 'default' // Name for the Private DNS Zone Group
          privateDnsZoneGroupConfigs: [
            {
              name: 'keyvaultdns' // Name for this specific DNS zone config
              privateDnsZoneResourceId: keyVaultPrivateDnsZone.outputs.resourceId
            }
          ]
        }
        tags: tags
      }
    ] : []
    roleAssignments: concat(
      [
        {
          roleDefinitionIdOrName: 'Key Vault Secrets Officer'
          principalId: principalId
          principalType: principalIdType
        }
      ],
      (computeService == 'Web App' ? [
        {
          roleDefinitionIdOrName: 'Key Vault Secrets User'
          principalId: webAppFoundryVtt.outputs.?systemAssignedMIPrincipalId // Removed '?' as identity is always enabled for WebApp
          principalType: 'ServicePrincipal'
        }
      ] : [])
    )
  }
}

// ------------- APP SERVICE PLAN (IF COMPUTE SERVICE IS WEB APP) -------------
module appServicePlan 'br/public:avm/res/web/serverfarm:0.4.1' = if (computeService == 'Web App') {
  name: 'app-service-plan-deployment'
  scope: rg
  params: {
    name: appServicePlanName
    kind: 'linux'
    location: location
    skuCapacity: 1
    skuName: appServicePlanSkuName
    tags: tags
    zoneRedundant: false
    diagnosticSettings: deployDiagnostics ? sendToLogAnalytics : []

  }
}

module webAppFoundryVtt 'br/public:avm/res/web/site:0.16.0' = if (computeService == 'Web App') {
  name: 'web-app-foundry-vtt-deployment'
  scope: rg
  params: {
    kind: 'app,linux,container'
    name: webAppFoundryVttName
    configs: [
      {
        name: 'azurestorageaccounts'
        properties: {
          foundrydata: {
            accessKey: '@AppSettingRef(STORAGE_ACCOUNT_KEY)'
            accountName: storageAccountName
            protocol: 'Smb'
            mountPath: '/data'
            shareName: 'foundryvttdata'
            type: 'AzureFiles'
          }
        }
      }
    ]
    managedIdentities: {
      systemAssigned: true
    }
    serverFarmResourceId: appServicePlan.outputs.resourceId
    siteConfig: {
      alwaysOn: true
      appSettings: [
        {
          name: 'DOCKER_REGISTRY_SERVER_PASSWORD'
          value: ''
        }
        {
          name: 'DOCKER_REGISTRY_SERVER_URL'
          value: 'https://index.docker.io/v1'
        }
        {
          name: 'DOCKER_REGISTRY_SERVER_USERNAME'
          value: ''
        }
        {
          name: 'FOUNDRY_USERNAME'
          value: '@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName=${foundryUsernameSecretName})'
        }
        {
          name: 'FOUNDRY_PASSWORD'
          value: '@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName=${foundryPasswordSecretName})'
        }
        {
          name: 'FOUNDRY_ADMIN_KEY'
          value: '@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName=${foundryAdminKeySecretName})'
        }
        {
          name: 'FOUNDRY_MINIFY_STATIC_FILES'
          value: 'true'
        }
        {
          name: 'WEBSITES_CONTAINER_START_TIME_LIMIT'
          value: '1800'
        }
        {
          name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE'
          value: 'false' // Important: Disables default storage, we provide our own via Azure Files
        }
        {
          name: 'WEBSITES_PORT'
          value: '30000'
        }
        {
          name: 'STORAGE_ACCOUNT_KEY'
          value: '@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName=${storageAccountKeySecretName})'
        }
      ]
      vnetRouteAllEnabled: effectiveDeployNetworking // Route all traffic through VNet if integrated, for KV access
      detailedErrorLoggingEnabled: true
      ftpsState: 'FtpsOnly'
      httpLoggingEnabled: true
      logsDirectorySizeLimit: 35
      linuxFxVersion: 'DOCKER|${foundryVttDockerImageName}:${foundryVttDockerImageTag}'
      minTlsVersion: '1.2'
      numberOfWorkers: 1
    }
    tags: tags
    virtualNetworkSubnetId: effectiveDeployNetworking ? virtualNetwork.outputs.subnetResourceIds[3] : null // Web App Subnet
    diagnosticSettings: deployDiagnostics ? [
      {
        name: sendToLogAnalyticsName
        workspaceResourceId: logAnalyticsWorkspace.outputs.resourceId
        logCategoriesAndGroups: [
          // Common App Service log categories
          { category: 'AppServiceHTTPLogs' }
          { category: 'AppServiceConsoleLogs' }
          { category: 'AppServiceAppLogs' }
          { category: 'AppServiceAuditLogs' }
          { category: 'AppServiceIPSecAuditLogs' }
          { category: 'AppServicePlatformLogs' }
        ]
        metricCategories: []
      }
    ] : []
  }
}

module webAppDdbProxy 'br/public:avm/res/web/site:0.16.0' = if (computeService == 'Web App' && deployDdbProxy) {
  name: 'web-app-ddbproxy-deployment'
  scope: rg
  params: {
    diagnosticSettings: deployDiagnostics ? [
      {
        name: sendToLogAnalyticsName
        workspaceResourceId: logAnalyticsWorkspace.outputs.resourceId
        logCategoriesAndGroups: [
          { category: 'AppServiceHTTPLogs' }
          { category: 'AppServiceConsoleLogs' }
          { category: 'AppServiceAppLogs' }
          { category: 'AppServiceAuditLogs' }
          { category: 'AppServiceIPSecAuditLogs' }
          { category: 'AppServicePlatformLogs' }
        ]
        metricCategories: []
      }
    ] : []
    kind: 'app,linux,container'
    name: webAppDdbProxyName
    serverFarmResourceId: appServicePlan.outputs.resourceId
    siteConfig: {
      numberOfWorkers: 1
      linuxFxVersion: 'DOCKER|${ddbProxyDockerImageName}:${ddbProxyDockerImageTag}'
      alwaysOn: true
      appSettings: [
        {
          name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE'
          value: 'false'
        }
        {
          name: 'VIRTUAL_HOST'
          value: webAppFoundryVttName
        }
        {
          name: 'VIRTUAL_PORT'
          value: '3000'
        }
        {
          name: 'DOCKER_REGISTRY_SERVER_URL'
          value: 'https://ghcr.io'
        }
      ]
      ftpsState: 'FtpsOnly'
      minTlsVersion: '1.2'
      healthCheckPath: '/ping' // Added health check path
    }
    tags: tags
    virtualNetworkSubnetId: effectiveDeployNetworking ? virtualNetwork.outputs.subnetResourceIds[3] : null // Web App Subnet
  }
}

// ------------- CONTAINER INSTANCE (IF COMPUTE SERVICE IS CONTAINER INSTANCE) -------------
// TODO: AVM module doesn't currently support diagnostics
module containerGroup 'br/public:avm/res/container-instance/container-group:0.5.0' = if (computeService == 'Container Instance') {
  name: 'foundry-vtt-container-group-deployment'
  scope: rg
  params: {
    name: containerInstanceFoundryVttName
    location: location
    availabilityZone: -1
    containers: [
      {
        name: 'foundryvtt'
        properties: {
          environmentVariables: [
            {
              name: 'FOUNDRY_USERNAME'
              secureValue: foundryUsername
            }
            {
              name: 'FOUNDRY_PASSWORD'
              secureValue: foundryPassword
            }
            {
              name: 'FOUNDRY_ADMIN_KEY'
              secureValue: foundryAdminKey
            }
          ]
          image: '${foundryVttDockerImageName}:${foundryVttDockerImageTag}'
          ports: [
            {
              protocol: 'TCP'
              port: 30000
            }
          ]
          resources: {
            requests: {
              cpu: containerInstanceCpu
              memoryInGB: containerInstanceMemoryInGB
            }
          }
          volumeMounts: [
            {
              name: 'foundrydata'
              mountPath: '/data'
            }
          ]
        }
      }
    ]
    ipAddress: {
      ports: [
        {
          protocol: 'TCP'
          port: 30000
        }
      ]
      type: 'Public'
      dnsNameLabel: environmentName
    }
    osType: 'Linux'
    tags: tags
    volumes: [
      {
        name: 'foundrydata'
        azureFile: {
          shareName: 'foundryvttdata'
          storageAccountName: storageAccountName
          storageAccountKey: storageAccountReference.listKeys('2024-01-01').keys[0].value
        }
      }
    ]
  }
}

// TBC: Support for DB Proxy in Container Instance - will require a second container instance because needs to be exposed publicaly

// ------------- BASTION HOST (OPTIONAL) -------------
module bastionHost 'br/public:avm/res/network/bastion-host:0.6.1' = if (effectiveDeployNetworking && bastionHostDeploy) {
  name: 'bastion-host-deployment'
  scope: rg
  params: {
    name: bastionHostName
    location: location
    virtualNetworkResourceId: virtualNetwork.outputs.resourceId
    skuName: 'Developer' // Consider making this configurable or choosing based on needs
    tags: tags
    diagnosticSettings: deployDiagnostics ? [
      {
        name: sendToLogAnalyticsName
        workspaceResourceId: logAnalyticsWorkspace.outputs.resourceId
        logCategoriesAndGroups: [
          {
            category: 'BastionAuditLogs'
          }
        ]
        metricCategories: []
      }
    ] : []
  }
}

// WebApp Outputs
output WEBAPP_FOUNDRY_VTT_URL string = computeService == 'Web App' ? webAppFoundryVtt.outputs.defaultHostname : ''
output WEBAPP_DDBPROXY_URL string = computeService == 'Web App' && deployDdbProxy ? webAppDdbProxy.outputs.defaultHostname : ''
output WEBAPP_FOUNDRY_VTT_RESOURCE_ID string = computeService == 'Web App' ? webAppFoundryVtt.outputs.resourceId : ''

// Container Instance Outputs
output CONTAINER_INSTANCE_FOUNDRY_VTT_IPV4ADDRESS string = computeService == 'Container Instance' ? containerGroup.outputs.iPv4Address : ''
output CONTAINER_INSTANCE_FOUNDRY_VTT_RESOURCE_ID string = computeService == 'Container Instance' ? containerGroup.outputs.resourceId : ''

// Azure Container Apps Outputs
// TBC

// General Outputs
output AZURE_ENV_NAME string = environmentName
output AZURE_LOCATION string = location
output AZURE_RESOURCE_GROUP_NAME string = rg.name
output AZURE_PRINCIPAL_ID string = principalId
output AZURE_PRINCIPAL_ID_TYPE string = principalIdType

// Key Vault Outputs
output KEY_VAULT_NAME string = keyVault.outputs.name
output KEY_VAULT_URI string = keyVault.outputs.uri
output KEY_VAULT_RESOURCE_ID string = keyVault.outputs.resourceId

// Log Analytics Outputs
output LOG_ANALYTICS_WORKSPACE_NAME string = deployDiagnostics ? logAnalyticsWorkspace.outputs.name : ''
output LOG_ANALYTICS_WORKSPACE_RESOURCE_ID string = deployDiagnostics ? logAnalyticsWorkspace.outputs.resourceId : ''

// Foundry VTT URL
output FOUNDRY_VTT_URL string = computeService == 'Web App' ? 'https://${webAppFoundryVtt.outputs.defaultHostname}/' : (computeService == 'Container Instance' ? 'http://${containerGroup.outputs.iPv4Address}:30000/' : '')
