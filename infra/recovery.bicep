targetScope = 'resourceGroup'

@sys.description('Existing environment name for the approved recovery.')
@minLength(1)
@maxLength(60)
param environmentName string

@sys.description('Existing storage account. No storage resource is deployed.')
param storageAccountName string

@sys.description('Existing Key Vault. No secret value is supplied or deployed.')
param vaultName string

@sys.description('Existing Web App integration subnet resource ID.')
param subnetResourceId string

@sys.description('Existing Log Analytics workspace resource ID.')
param workspaceResourceId string

@sys.description('Unique owner identifier for targeted recovery cleanup.')
param recoveryId string

@sys.description('Read-only application-container probe encoded for Node import.')
param probeBase64 string

@sys.description('Preserve the configured Foundry image tag.')
param foundryImageTag string = 'release'

@sys.description('Preserve the existing proxy configuration on the same plan.')
param deployProxy bool = true

var abbrs = loadJsonContent('./abbreviations.json')
var tags = {
  'azd-env-name': environmentName
  'fvtt-recovery-id': recoveryId
}
var diagnostics = [
  {
    name: 'send-to-loganalytics-${environmentName}'
    workspaceResourceId: workspaceResourceId
    logCategoriesAndGroups: [
      { category: 'AppServicePlatformLogs' }
      { category: 'AppServiceConsoleLogs' }
      { category: 'AppServiceHTTPLogs' }
      { category: 'AppServiceAppLogs' }
      { category: 'AppServiceAuditLogs' }
      { category: 'AppServiceIPSecAuditLogs' }
    ]
    metricCategories: []
  }
]

module plan 'br/public:avm/res/web/serverfarm:0.7.0' = {
  name: 'recovery-plan-deployment'
  params: {
    name: take('${abbrs.webSitesAppService}${environmentName}', 60)
    location: resourceGroup().location
    kind: 'linux'
    skuName: 'P0v3'
    skuCapacity: 1
    zoneRedundant: false
    enableTelemetry: false
    tags: tags
  }
}

module app 'br/public:avm/res/web/site:0.24.0' = {
  name: 'recovery-app-deployment'
  params: {
    name: environmentName
    location: resourceGroup().location
    kind: 'app,linux,container'
    enabled: false
    enableTelemetry: false
    serverFarmResourceId: plan.outputs.resourceId
    managedIdentities: { systemAssigned: true }
    virtualNetworkSubnetResourceId: subnetResourceId
    outboundVnetRouting: { allTraffic: true }
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
      {
        name: 'logs'
        properties: {
          applicationLogs: { fileSystem: { level: 'Information' } }
          httpLogs: { fileSystem: { retentionInMb: 35, retentionInDays: 1, enabled: true } }
        }
      }
    ]
    siteConfig: {
      alwaysOn: true
      numberOfWorkers: 1
      linuxFxVersion: 'DOCKER|felddy/foundryvtt:${foundryImageTag}'
      minTlsVersion: '1.2'
      ftpsState: 'FtpsOnly'
      detailedErrorLoggingEnabled: true
      httpLoggingEnabled: true
      logsDirectorySizeLimit: 35
      appSettings: [
        { name: 'DOCKER_REGISTRY_SERVER_URL', value: 'https://index.docker.io/v1' }
        { name: 'DOCKER_REGISTRY_SERVER_USERNAME', value: '' }
        { name: 'DOCKER_REGISTRY_SERVER_PASSWORD', value: '' }
        { name: 'FOUNDRY_USERNAME', value: '@Microsoft.KeyVault(VaultName=${vaultName};SecretName=foundryUsername)' }
        { name: 'FOUNDRY_PASSWORD', value: '@Microsoft.KeyVault(VaultName=${vaultName};SecretName=foundryPassword)' }
        { name: 'FOUNDRY_ADMIN_KEY', value: '@Microsoft.KeyVault(VaultName=${vaultName};SecretName=foundryAdminKey)' }
        {
          name: 'STORAGE_ACCOUNT_KEY'
          value: '@Microsoft.KeyVault(VaultName=${vaultName};SecretName=storageAccountKey)'
        }
        { name: 'FOUNDRY_MINIFY_STATIC_FILES', value: 'true' }
        { name: 'WEBSITES_CONTAINER_START_TIME_LIMIT', value: '1800' }
        { name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE', value: 'false' }
        { name: 'WEBSITES_PORT', value: '30000' }
        { name: 'NODE_OPTIONS', value: '--import=data:text/javascript;base64,${probeBase64}' }
      ]
    }
    diagnosticSettings: diagnostics
    tags: tags
  }
}

module proxy 'br/public:avm/res/web/site:0.24.0' = if (deployProxy) {
  name: 'recovery-proxy-deployment'
  params: {
    name: '${environmentName}ddbproxy'
    location: resourceGroup().location
    kind: 'app,linux,container'
    enabled: false
    enableTelemetry: false
    serverFarmResourceId: plan.outputs.resourceId
    virtualNetworkSubnetResourceId: subnetResourceId
    siteConfig: {
      numberOfWorkers: 1
      alwaysOn: true
      linuxFxVersion: 'DOCKER|ghcr.io/mrprimate/ddb-proxy:latest'
      minTlsVersion: '1.2'
      ftpsState: 'FtpsOnly'
      healthCheckPath: '/ping'
      appSettings: [
        { name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE', value: 'false' }
        { name: 'VIRTUAL_HOST', value: environmentName }
        { name: 'VIRTUAL_PORT', value: '3000' }
        { name: 'DOCKER_REGISTRY_SERVER_URL', value: 'https://ghcr.io' }
      ]
    }
    diagnosticSettings: diagnostics
    tags: tags
  }
}
