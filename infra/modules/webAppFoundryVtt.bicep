param location string
param appServicePlanId string
param storageAccountName string
param webAppName string

@secure()
param foundryUsername string

@secure()
param foundryPassword string

@secure()
param foundryAdminKey string

// New parameter for App Service subnet ID from the VNET module
param appServiceSubnetId string

var linuxFxVersion = 'DOCKER|felddy/foundryvtt:release'

resource webApp 'Microsoft.Web/sites@2023-12-01' = {
  name: webAppName
  location: location
  kind: 'app,linux,container'
  properties: {
    serverFarmId: appServicePlanId
    httpsOnly: true
    virtualNetworkSubnetId: appServiceSubnetId
    siteConfig: {
      numberOfWorkers: 1
      linuxFxVersion: linuxFxVersion
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
          value: foundryUsername
        }
        {
          name: 'FOUNDRY_PASSWORD'
          value: foundryPassword
        }
        {
          name: 'FOUNDRY_ADMIN_KEY'
          value: foundryAdminKey
        }
        {
          name: 'FOUNDRY_MINIFY_STATIC_FILES'
          value: 'true'
        }
        // Set the container start time limit to max because Foundry VTT
        // container may take some time to start up depending on the number
        // of modules added.
        {
          name: 'WEBSITES_CONTAINER_START_TIME_LIMIT'
          value: '1800'
        }
        {
          name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE'
          value: 'false'
        }
        {
          name: 'WEBSITES_PORT'
          value: '30000'
        }
      ]
    }
  }

  resource config 'config@2023-12-01' = {
    name: 'web'
    properties: {
      linuxFxVersion: linuxFxVersion
      azureStorageAccounts: {
        foundrydata: {
          type: 'AzureFiles'
          accountName: storageAccountName
          shareName: 'foundryvttdata'
          mountPath: '/data'
          accessKey: listkeys(resourceId('Microsoft.Storage/storageAccounts', storageAccountName), '2023-05-01').keys[0].value
        }
      }
      httpLoggingEnabled: true
      logsDirectorySizeLimit: 35
      detailedErrorLoggingEnabled: true
    }
  }
}

output url string = 'https://${webAppName}.azurewebsites.net'
